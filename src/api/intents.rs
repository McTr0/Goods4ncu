//! Intent endpoints.
//!
//! The interface an intent needs is smaller than a listing form's, and that is
//! the point: say it in your own words, optionally pin down what you actually
//! care about, and leave the rest alone. Nothing here requires a price, a
//! category or a time.

use axum::{
    extract::{Path, Query, State},
    Json,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::session::{Session, VerifiedTenant};
use crate::api::AppState;
use crate::services::intent::{
    kinds,
    slots::{PriceSlot, Slots},
    status, Intent, IntentService, NewIntent,
};

const INTENT_RANKING_VERSION: &str = "2026.07-intent-hard-v1";

#[derive(Serialize)]
struct RankedIntent {
    #[serde(flatten)]
    intent: Intent,
    /// Stable code. Clients localize it; the server does not reveal weights or
    /// infer private facts to explain a deterministic filter.
    rank_reason: &'static str,
    /// Stable codes derived only from tenant/lifecycle constraints and slots
    /// the two authors actually stated.
    match_summary: Vec<&'static str>,
    source: &'static str,
    ranking_version: &'static str,
}

#[derive(Deserialize)]
pub struct CreateIntentRequest {
    pub kind: String,
    /// What the author said. The only required field.
    pub raw_input: String,
    /// Whatever they chose to pin down. Absent slots stay absent.
    #[serde(default)]
    pub slots: Slots,
    #[serde(default)]
    pub valid_until: Option<chrono::DateTime<chrono::Utc>>,
    /// `private` keeps it out of the matching pool while still recording it.
    #[serde(default)]
    pub visibility: Option<String>,
}

/// POST /api/intents — record an intent the author stated themselves.
///
/// Author-stated intents go straight to `active`. Only *inferred* ones — a
/// photo split into items, a sentence read as several wishes — arrive as drafts
/// needing confirmation, because those are the ones a wrong reading can spoil.
pub async fn create_intent(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Json(payload): Json<CreateIntentRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    if !kinds::ALL.contains(&payload.kind.as_str()) {
        return Err(ApiError::BadRequest(format!(
            "未知的意图类型：{}（可选：{}）",
            payload.kind,
            kinds::ALL.join(", ")
        )));
    }
    payload
        .slots
        .validate_for_kind(&payload.kind)
        .map_err(ApiError::BadRequest)?;
    let raw_input = payload.raw_input.trim();
    if raw_input.is_empty() {
        return Err(ApiError::BadRequest("请说说你想要什么".to_string()));
    }
    if raw_input.chars().count() > 1000 {
        return Err(ApiError::BadRequest("描述请控制在 1000 字以内".to_string()));
    }
    let visibility = match payload.visibility.as_deref() {
        None | Some("campus") => "campus",
        Some("private") => "private",
        Some(other) => {
            return Err(ApiError::BadRequest(format!("未知的可见性：{}", other)));
        }
    };
    // An already-past deadline would create an intent that the expiry sweep
    // retires before anyone sees it — almost certainly a client bug, and
    // silently accepting it makes that bug invisible.
    if payload
        .valid_until
        .is_some_and(|until| until <= chrono::Utc::now())
    {
        return Err(ApiError::BadRequest("有效期需要设在将来".to_string()));
    }

    let specificity = payload.slots.specificity();
    let id = IntentService::new(state.infra.db.clone())
        .create(NewIntent {
            campus_id: tenant.campus_id,
            author_id: &tenant.session.user_id,
            kind: &payload.kind,
            raw_input,
            slots: payload.slots,
            confidence: 1.0,
            status: status::ACTIVE,
            visibility,
            valid_until: payload.valid_until,
        })
        .await
        .map_err(ApiError::Internal)?;

    // Goods offers are mirrored into the listing grid where they can be shown
    // truthfully. An intent with no price is not — see `project_to_listing`.
    let projected = IntentService::new(state.infra.db.clone())
        .project_to_listing(id)
        .await
        .map_err(ApiError::Internal)?;

    Ok(Json(serde_json::json!({
        "id": id,
        "status": status::ACTIVE,
        "projected_listing_id": projected,
        // How much the author pinned down. The client uses this to decide
        // whether one clarifying question is worth asking — never to reject the
        // intent, which would be the form-filling this layer replaces.
        "specificity": specificity,
    })))
}

#[derive(Deserialize)]
pub struct DraftBatchRequest {
    pub kind: String,
    /// The single input all of these were read out of — a photo caption, a
    /// sentence. Kept on every draft so the author can see what they came from.
    pub raw_input: String,
    pub items: Vec<DraftItem>,
}

#[derive(Deserialize)]
pub struct DraftItem {
    #[serde(default)]
    pub slots: Slots,
    /// How sure the reading is. Low-confidence items are still stored — the
    /// author is the one who decides, and hiding a shaky guess also hides the
    /// chance to correct it.
    #[serde(default = "default_confidence")]
    pub confidence: f32,
}

fn default_confidence() -> f32 {
    0.5
}

/// POST /api/intents/draft-batch — record several inferred intents at once.
///
/// The path a photo of a dorm room takes: one input, many items, none of them
/// matchable until the author says so. This is what makes decomposition safe to
/// attempt at all — being wrong costs one dismissal, not rubbish in front of
/// the campus.
pub async fn create_draft_batch(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Json(payload): Json<DraftBatchRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    if !kinds::ALL.contains(&payload.kind.as_str()) {
        return Err(ApiError::BadRequest(format!(
            "未知的意图类型：{}",
            payload.kind
        )));
    }
    if payload.raw_input.trim().is_empty() {
        return Err(ApiError::BadRequest("缺少原始输入".to_string()));
    }
    if payload.items.is_empty() {
        return Err(ApiError::BadRequest("没有可确认的条目".to_string()));
    }
    // A photo of a room yields a handful of items, not hundreds. A large batch
    // is a runaway decomposition, and asking someone to confirm fifty cards is
    // worse than asking them to fill in one form.
    if payload.items.len() > 20 {
        return Err(ApiError::BadRequest(
            "一次最多识别 20 件，请分批确认".to_string(),
        ));
    }
    for item in &payload.items {
        item.slots
            .validate_for_kind(&payload.kind)
            .map_err(ApiError::BadRequest)?;
    }

    let items = payload
        .items
        .into_iter()
        .map(|item| (item.slots, item.confidence))
        .collect();
    let ids = IntentService::new(state.infra.db.clone())
        .create_draft_batch(
            tenant.campus_id,
            &tenant.session.user_id,
            payload.raw_input.trim(),
            &payload.kind,
            items,
        )
        .await
        .map_err(ApiError::Internal)?;

    Ok(Json(serde_json::json!({
        "ids": ids,
        "status": status::DRAFT,
    })))
}

#[derive(Deserialize)]
pub struct DecomposeRequest {
    /// What the author said. May describe one thing or many.
    pub raw_input: String,
    /// Defaults to `goods_offer` — the graduation case this exists for.
    #[serde(default)]
    pub kind: Option<String>,
}

/// POST /api/intents/decompose — read one sentence as possibly several intents.
///
/// "毕业了，宿舍里有台灯、小冰箱、两把椅子、一个书架，都便宜出" is five things,
/// said once. A form asks for that five times and gets it zero times, which is
/// most of why the supply on a campus never reaches the system.
///
/// One sentence stays one intent and goes live directly; several become drafts,
/// because splitting is guesswork and guessing wrong should cost the author one
/// dismissal rather than putting five half-understood things in front of the
/// campus.
///
/// The deterministic splitter runs *first*, not as a fallback. When someone
/// punctuated the list themselves the enumeration is stated rather than
/// inferred, so asking a model to re-derive it would add latency and cost for a
/// possibly worse answer. The model is consulted only for prose, and a failure
/// there degrades to "one thing, as typed" — never to a lost post.
pub async fn decompose_intent(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Json(payload): Json<DecomposeRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    use crate::services::intent::decompose::{
        model_prompt, parse_model_reply, split_deterministically, Decomposition,
    };

    let raw_input = payload.raw_input.trim();
    if raw_input.is_empty() {
        return Err(ApiError::BadRequest("请说说你想出什么".to_string()));
    }
    if raw_input.chars().count() > 1000 {
        return Err(ApiError::BadRequest("描述请控制在 1000 字以内".to_string()));
    }
    let kind = payload.kind.as_deref().unwrap_or(kinds::GOODS_OFFER);
    if !kinds::ALL.contains(&kind) {
        return Err(ApiError::BadRequest(format!("未知的意图类型：{}", kind)));
    }

    let mut decomposition = split_deterministically(raw_input);
    if matches!(decomposition, Decomposition::Single) {
        // Prose rather than a list. Worth one model call, on a short timeout —
        // someone waiting to post should not be held up by a slow provider.
        decomposition = match state
            .agents
            .llm_provider
            .clone()
            .create_reply_assistant()
            .await
        {
            Ok(assistant) => {
                match tokio::time::timeout(
                    std::time::Duration::from_secs(8),
                    assistant.prompt(model_prompt(raw_input)),
                )
                .await
                {
                    Ok(Ok(reply)) => parse_model_reply(&reply, raw_input),
                    Ok(Err(error)) => {
                        tracing::warn!(%error, "decomposition model call failed");
                        Decomposition::Single
                    }
                    Err(_) => {
                        tracing::warn!("decomposition model call timed out");
                        Decomposition::Single
                    }
                }
            }
            Err(error) => {
                tracing::warn!(%error, "decomposition assistant unavailable");
                Decomposition::Single
            }
        };
    }

    let service = IntentService::new(state.infra.db.clone());
    match decomposition {
        // One thing: record it live. Making someone confirm a card for the
        // sentence they just typed is the friction this replaces.
        Decomposition::Single => {
            let id = service
                .create(NewIntent {
                    campus_id: tenant.campus_id,
                    author_id: &tenant.session.user_id,
                    kind,
                    raw_input,
                    slots: Slots::default(),
                    confidence: 1.0,
                    status: status::ACTIVE,
                    visibility: "campus",
                    valid_until: None,
                })
                .await
                .map_err(ApiError::Internal)?;
            let projected = service
                .project_to_listing(id)
                .await
                .map_err(ApiError::Internal)?;
            Ok(Json(serde_json::json!({
                "split": false,
                "ids": [id],
                "status": status::ACTIVE,
                "projected_listing_id": projected,
            })))
        }
        Decomposition::Several(items) => {
            let ids = service
                .create_draft_batch(
                    tenant.campus_id,
                    &tenant.session.user_id,
                    raw_input,
                    kind,
                    items
                        .into_iter()
                        .map(|item| (item.slots, item.confidence))
                        .collect(),
                )
                .await
                .map_err(ApiError::Internal)?;
            Ok(Json(serde_json::json!({
                "split": true,
                "ids": ids,
                "status": status::DRAFT,
            })))
        }
    }
}

#[derive(Deserialize)]
pub struct FeedQuery {
    /// Narrow to one kind; omit for everything, newest first.
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub limit: Option<i64>,
}

/// GET /api/intents/feed — what everyone on this campus is currently after.
///
/// Without this you have to post something before you can see anything: a new
/// student opens the app, has said nothing yet, and finds an empty room. That is
/// the unanswered-post problem from the other side — the demand exists and
/// nobody can see it in order to answer it.
///
/// Author identities are not included. Answering is an action the server
/// performs (see [`respond_to_intent`]), so this surface cannot be scraped into
/// a directory of who wants what.
pub async fn intent_feed(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Query(query): Query<FeedQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    if let Some(kind) = query.kind.as_deref() {
        if !kinds::ALL.contains(&kind) {
            return Err(ApiError::BadRequest(format!("未知的意图类型：{}", kind)));
        }
    }
    let items = IntentService::new(state.infra.db.clone())
        .campus_feed(
            tenant.campus_id,
            &tenant.session.user_id,
            query.kind.as_deref(),
            query.limit.unwrap_or(30),
        )
        .await
        .map_err(ApiError::Internal)?;
    let items: Vec<_> = items
        .into_iter()
        .map(|intent| RankedIntent {
            intent,
            rank_reason: "recent_campus_intent",
            match_summary: vec!["same_campus", "active_intent"],
            source: "campus_recency",
            ranking_version: INTENT_RANKING_VERSION,
        })
        .collect();
    Ok(Json(serde_json::json!({
        "items": items,
        "ranking_version": INTENT_RANKING_VERSION,
    })))
}

#[derive(Deserialize)]
pub struct RespondRequest {
    /// What to say. This is the whole point — a match with no way to reply is a
    /// dead end.
    pub content: String,
    /// Client-supplied so a retried tap cannot open two conversations.
    pub client_request_id: Uuid,
}

/// POST /api/intents/{id}/respond — answer someone.
///
/// The step that was missing. Matching surfaced candidates and offered nothing
/// to do about them, so "posts answered" could only ever be zero: the loop from
/// *someone wants something* to *someone replied* had no last link.
///
/// The author is resolved here rather than returned to the client, which keeps
/// user ids off the matching surface. Campus membership is re-checked for both
/// sides, so this cannot be used to message across campuses.
pub async fn respond_to_intent(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(intent_id): Path<Uuid>,
    Json(payload): Json<RespondRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let content = payload.content.trim();
    if content.is_empty() {
        return Err(ApiError::BadRequest("说点什么再发送".to_string()));
    }
    if content.chars().count() > 1000 {
        return Err(ApiError::BadRequest("消息请控制在 1000 字以内".to_string()));
    }

    let service = IntentService::new(state.infra.db.clone());
    let (author_id, raw_input) = service
        .answerable_author(tenant.campus_id, intent_id)
        .await
        .map_err(ApiError::Internal)?
        // Withdrawn, fulfilled, expired, private or another campus's — one
        // answer for all of them, so this cannot probe what exists.
        .ok_or(ApiError::NotFound)?;

    if author_id == tenant.session.user_id {
        return Err(ApiError::BadRequest("不能回应自己的意图".to_string()));
    }

    // The subject carries the author's own words, so they can tell at a glance
    // which of their intents this is about.
    let subject: String = raw_input.chars().take(60).collect();
    let conversation = crate::api::user_chat::open_conversation_for_intent(
        &state,
        &tenant.session.user_id,
        &author_id,
        tenant.campus_id,
        payload.client_request_id,
        &subject,
        content,
    )
    .await?;

    // Recorded so the health metrics can see it. Without this the dashboard
    // counts only listings and reports nobody answered anything.
    if let Err(error) = service
        .record_response(
            tenant.campus_id,
            intent_id,
            &tenant.session.user_id,
            conversation.parse().ok(),
        )
        .await
    {
        // The answer reached the author; losing the bookkeeping degrades a
        // metric rather than the exchange, so it must not fail the request.
        tracing::warn!(%error, %intent_id, "failed to record intent response");
    }

    Ok(Json(serde_json::json!({
        "conversation_id": conversation,
    })))
}

#[derive(Deserialize)]
pub struct DecomposePhotoRequest {
    /// Base64 image data, no data-URL prefix.
    pub image_base64: String,
    pub mime: String,
    /// Anything the author typed alongside it. Kept as the raw input, so a
    /// failed reading still records what they said rather than losing it.
    #[serde(default)]
    pub raw_input: Option<String>,
}

/// POST /api/intents/decompose-photo — read a photo of a room as a list.
///
/// Graduation is the largest supply event of the year and the listing form is
/// at its worst exactly then: twenty items, twenty forms, so none of it is
/// posted. One photo is the whole inventory in a gesture.
///
/// Absent rather than broken when no vision provider is configured: a campus
/// without a vision budget still gets everything else. And a failed reading
/// records one intent from whatever the author typed, so it never costs them
/// their post.
pub async fn decompose_photo(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Json(payload): Json<DecomposePhotoRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    use crate::services::intent::decompose::Decomposition;
    use crate::services::intent::vision;

    let key = &state.secrets.gemini_api_key;
    if !vision::is_available(key) {
        // 501 rather than 500: this is a capability the deployment does not
        // have, not a fault. The client hides the affordance instead of
        // retrying.
        return Err(ApiError::NotImplemented(
            "这个部署没有开启照片识别".to_string(),
        ));
    }

    let raw_input = payload
        .raw_input
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("（一张照片）");

    let decomposition =
        match vision::decompose_photo(key, &payload.image_base64, &payload.mime).await {
            Ok(decomposition) => decomposition,
            Err(error) => {
                // The photo is not logged, and neither is the provider's body — an
                // error response can echo the request, and the request is somebody's
                // room.
                tracing::warn!(%error, "photo decomposition failed");
                Decomposition::Single
            }
        };

    let service = IntentService::new(state.infra.db.clone());
    match decomposition {
        Decomposition::Single => {
            // Nothing readable. Record what they typed rather than dropping it.
            let id = service
                .create(NewIntent {
                    campus_id: tenant.campus_id,
                    author_id: &tenant.session.user_id,
                    kind: kinds::GOODS_OFFER,
                    raw_input,
                    slots: Slots::default(),
                    confidence: 1.0,
                    status: status::ACTIVE,
                    visibility: "campus",
                    valid_until: None,
                })
                .await
                .map_err(ApiError::Internal)?;
            Ok(Json(serde_json::json!({
                "split": false,
                "ids": [id],
                "status": status::ACTIVE,
            })))
        }
        Decomposition::Several(items) => {
            // Everything read from a photo is a draft — including a single
            // item, unlike the text path, because the author typed nothing for
            // it to be a reading *of*.
            let ids = service
                .create_draft_batch(
                    tenant.campus_id,
                    &tenant.session.user_id,
                    raw_input,
                    kinds::GOODS_OFFER,
                    items
                        .into_iter()
                        .map(|item| (item.slots, item.confidence))
                        .collect(),
                )
                .await
                .map_err(ApiError::Internal)?;
            Ok(Json(serde_json::json!({
                "split": true,
                "ids": ids,
                "status": status::DRAFT,
            })))
        }
    }
}

/// GET /api/intents — the caller's own intents, drafts included.
pub async fn list_intents(
    State(state): State<AppState>,
    Session(session): Session,
) -> Result<Json<serde_json::Value>, ApiError> {
    let items = IntentService::new(state.infra.db.clone())
        .list_mine(&session.user_id, 50)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(serde_json::json!({ "items": items })))
}

/// POST /api/intents/{id}/confirm — accept an inferred intent as真.
pub async fn confirm_intent(
    State(state): State<AppState>,
    Session(session): Session,
    Path(intent_id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let confirmed = IntentService::new(state.infra.db.clone())
        .confirm(&session.user_id, intent_id)
        .await
        .map_err(ApiError::Internal)?;
    if !confirmed {
        return Err(ApiError::NotFound);
    }
    Ok(Json(serde_json::json!({ "status": status::ACTIVE })))
}

/// POST /api/intents/{id}/fulfil — it worked.
///
/// Deliberately not the same as withdrawing. "Someone helped me" and "never
/// mind" look identical in an activity log and are opposite outcomes; keeping
/// them apart is what lets the health metrics distinguish a community where
/// nothing gets answered from one where people change their minds.
pub async fn fulfil_intent(
    State(state): State<AppState>,
    Session(session): Session,
    Path(intent_id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let fulfilled = IntentService::new(state.infra.db.clone())
        .fulfil(&session.user_id, intent_id)
        .await
        .map_err(ApiError::Internal)?;
    if !fulfilled {
        return Err(ApiError::NotFound);
    }
    Ok(Json(serde_json::json!({ "status": status::FULFILLED })))
}

/// DELETE /api/intents/{id} — withdraw it.
pub async fn withdraw_intent(
    State(state): State<AppState>,
    Session(session): Session,
    Path(intent_id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let withdrawn = IntentService::new(state.infra.db.clone())
        .withdraw(&session.user_id, intent_id)
        .await
        .map_err(ApiError::Internal)?;
    if !withdrawn {
        return Err(ApiError::NotFound);
    }
    Ok(Json(serde_json::json!({ "status": status::WITHDRAWN })))
}

#[derive(Deserialize)]
pub struct MatchQuery {
    /// Which pool to look in. Defaults to the natural counterpart of the
    /// intent's own kind.
    #[serde(default)]
    pub against: Option<String>,
}

/// GET /api/intents/{id}/matches — candidates for one of the caller's intents.
///
/// Hard filtering only, and deliberately so: this answers "which of these is
/// not impossible", never "which is best". Ranking is a separate concern, and
/// merging the two is how a similarity score talks its way past someone's
/// stated budget.
pub async fn intent_matches(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(intent_id): Path<Uuid>,
    Query(query): Query<MatchQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let service = IntentService::new(state.infra.db.clone());
    let mine = service
        .get(&tenant.session.user_id, intent_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or(ApiError::NotFound)?;

    let against = match query.against.as_deref() {
        Some(kind) if kinds::ALL.contains(&kind) => kind.to_string(),
        Some(other) => {
            return Err(ApiError::BadRequest(format!("未知的意图类型：{}", other)));
        }
        None => counterpart(&mine.kind).to_string(),
    };

    let pool = service
        .pool(tenant.campus_id, &against, &tenant.session.user_id, 100)
        .await
        .map_err(ApiError::Internal)?;

    let candidates: Vec<_> = pool
        .into_iter()
        .filter_map(|other| {
            let match_summary = {
                let (constraint, offer) = match_roles(&mine.kind, &mine.slots, &other.slots)?;
                if !constraint.compatible_with(offer) {
                    return None;
                }
                deterministic_match_summary(constraint, offer)
            };
            let rank_reason = if match_summary.len() > 1 {
                "known_slots_compatible"
            } else {
                "kind_compatible"
            };
            Some(RankedIntent {
                intent: other,
                rank_reason,
                match_summary,
                source: "hard_constraints",
                ranking_version: INTENT_RANKING_VERSION,
            })
        })
        .collect();

    Ok(Json(serde_json::json!({
        "intent_id": intent_id,
        "against": against,
        "items": candidates,
        "ranking_version": INTENT_RANKING_VERSION,
    })))
}

/// Put the requester's slots first and the provider's second for directional
/// goods matches. Companion and activity intents are symmetric, so their
/// ordering does not affect compatibility.
fn match_roles<'a>(
    mine_kind: &str,
    mine: &'a Slots,
    other: &'a Slots,
) -> Option<(&'a Slots, &'a Slots)> {
    if mine_kind == kinds::GOODS_SEEK {
        Some((mine, other))
    } else {
        Some((other, mine))
    }
}

fn deterministic_match_summary(constraint: &Slots, offer: &Slots) -> Vec<&'static str> {
    let mut summary = vec!["kind_compatible"];
    if constraint.category.is_some() && offer.category.is_some() {
        summary.push("category_match");
    }
    let has_price_bound = constraint.price.as_ref().is_some_and(|price| match price {
        PriceSlot::Exact { .. } | PriceSlot::Free => true,
        PriceSlot::Range {
            min_cents,
            max_cents,
        } => min_cents.is_some() || max_cents.is_some(),
        PriceSlot::Whatever { .. } => false,
    });
    let has_known_offer_price = offer
        .price
        .as_ref()
        .and_then(PriceSlot::nominal_cents)
        .is_some();
    if has_price_bound && has_known_offer_price {
        summary.push("price_within_constraint");
    }
    if constraint.time.is_some() && offer.time.is_some() {
        summary.push("time_overlap");
    }
    if constraint.condition_score.is_some() && offer.condition_score.is_some() {
        summary.push("condition_at_least_requested");
    }
    summary
}

/// The kind an intent naturally pairs with.
///
/// Goods are two-sided, so they cross. Companion and activity intents pair with
/// their own kind: two people each looking for a badminton partner are each
/// other's match. Help uses its own kind as a pool too, but only crosses the
/// `wanted` and `offer` service directions.
fn counterpart(kind: &str) -> &str {
    match kind {
        kinds::GOODS_OFFER => kinds::GOODS_SEEK,
        kinds::GOODS_SEEK => kinds::GOODS_OFFER,
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::intent::slots::TimeSlot;

    #[test]
    fn goods_cross_while_people_and_events_pair_with_their_own_kind() {
        assert_eq!(counterpart(kinds::GOODS_OFFER), kinds::GOODS_SEEK);
        assert_eq!(counterpart(kinds::GOODS_SEEK), kinds::GOODS_OFFER);
        // Two people both wanting a badminton partner are the match. Crossing
        // these would look for a "supplier of partners", which does not exist.
        assert_eq!(counterpart(kinds::COMPANION), kinds::COMPANION);
        assert_eq!(counterpart(kinds::ACTIVITY), kinds::ACTIVITY);
    }

    #[test]
    fn match_explanations_use_only_stated_hard_constraints() {
        let constraint = Slots {
            category: Some("electronics".to_string()),
            price: Some(PriceSlot::Exact { cents: 30_000 }),
            time: Some(TimeSlot::Flexible { hint: None }),
            condition_score: Some(7),
            place: Some("图书馆".to_string()),
            ..Default::default()
        };
        let offer = Slots {
            category: Some("electronics".to_string()),
            price: Some(PriceSlot::Exact { cents: 20_000 }),
            time: Some(TimeSlot::Flexible { hint: None }),
            condition_score: Some(8),
            place: Some("宿舍".to_string()),
            ..Default::default()
        };

        assert_eq!(
            deterministic_match_summary(&constraint, &offer),
            vec![
                "kind_compatible",
                "category_match",
                "price_within_constraint",
                "time_overlap",
                "condition_at_least_requested",
            ],
            "place is not a hard constraint today, so it must not be invented as an explanation",
        );
    }

    #[test]
    fn match_explanations_do_not_claim_an_unknown_price_is_within_budget() {
        let known_offer = Slots {
            price: Some(PriceSlot::Exact { cents: 20_000 }),
            ..Default::default()
        };
        for unknown_constraint in [
            PriceSlot::Whatever { hint: None },
            PriceSlot::Range {
                min_cents: None,
                max_cents: None,
            },
        ] {
            let constraint = Slots {
                price: Some(unknown_constraint),
                ..Default::default()
            };
            assert_eq!(
                deterministic_match_summary(&constraint, &known_offer),
                vec!["kind_compatible"]
            );
        }

        let bounded_constraint = Slots {
            price: Some(PriceSlot::Exact { cents: 30_000 }),
            ..Default::default()
        };
        for unknown_offer in [
            PriceSlot::Whatever { hint: None },
            PriceSlot::Range {
                min_cents: None,
                max_cents: None,
            },
        ] {
            let offer = Slots {
                price: Some(unknown_offer),
                ..Default::default()
            };
            assert_eq!(
                deterministic_match_summary(&bounded_constraint, &offer),
                vec!["kind_compatible"]
            );
        }
    }
}

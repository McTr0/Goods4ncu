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
use serde::Deserialize;
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::session::{Session, VerifiedTenant};
use crate::api::AppState;
use crate::services::intent::{kinds, slots::Slots, status, IntentService, NewIntent};

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

    // Which side is the constraint depends on direction: a seeker's slots
    // constrain an offer, not the other way round.
    let seeking = mine.kind == kinds::GOODS_SEEK;
    let candidates: Vec<_> = pool
        .into_iter()
        .filter(|other| {
            if seeking {
                mine.slots.compatible_with(&other.slots)
            } else {
                other.slots.compatible_with(&mine.slots)
            }
        })
        .collect();

    Ok(Json(serde_json::json!({
        "intent_id": intent_id,
        "against": against,
        "items": candidates,
    })))
}

/// The kind an intent naturally pairs with.
///
/// Goods are two-sided, so they cross. Companion, help and activity intents
/// pair with their own kind: two people each looking for a badminton partner
/// are each other's match.
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

    #[test]
    fn goods_cross_while_people_and_events_pair_with_their_own_kind() {
        assert_eq!(counterpart(kinds::GOODS_OFFER), kinds::GOODS_SEEK);
        assert_eq!(counterpart(kinds::GOODS_SEEK), kinds::GOODS_OFFER);
        // Two people both wanting a badminton partner are the match. Crossing
        // these would look for a "supplier of partners", which does not exist.
        assert_eq!(counterpart(kinds::COMPANION), kinds::COMPANION);
        assert_eq!(counterpart(kinds::ACTIVITY), kinds::ACTIVITY);
        assert_eq!(counterpart(kinds::HELP), kinds::HELP);
    }
}

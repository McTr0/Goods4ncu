//! Intents: the record of what someone wants, before it is forced into a form.
//!
//! See migration 0047 for why this exists and why goods, people and events
//! share one table. [`slots`] holds the part that carries the real design
//! weight — representing "I don't mind" rather than resolving it.
//!
//! Two rules govern the lifecycle here:
//!
//! * **Anything the system inferred starts as a draft.** A photo split into six
//!   items, a sentence read as two intents — none of it enters the matching
//!   pool until the author confirms. A decomposition that guesses wrong should
//!   cost them one dismissal, not put junk in front of the whole campus.
//! * **Expiry is normal, not failure.** "This weekend" is genuinely over on
//!   Monday. Keeping it alive produces matches nobody wants and quietly makes
//!   the pool worse.

pub mod decompose;
pub mod slots;
pub mod vision;

use anyhow::Result;
use slots::Slots;
use sqlx::{PgPool, Row};
use uuid::Uuid;

pub mod kinds {
    pub const GOODS_OFFER: &str = "goods_offer";
    pub const GOODS_SEEK: &str = "goods_seek";
    pub const COMPANION: &str = "companion";
    pub const HELP: &str = "help";
    pub const ACTIVITY: &str = "activity";

    pub const ALL: &[&str] = &[GOODS_OFFER, GOODS_SEEK, COMPANION, HELP, ACTIVITY];

    /// Whether this kind is about a thing changing hands, and so has a listing
    /// projection.
    pub fn is_goods(kind: &str) -> bool {
        kind == GOODS_OFFER || kind == GOODS_SEEK
    }
}

pub mod status {
    /// Inferred, awaiting the author's confirmation. Not matchable.
    pub const DRAFT: &str = "draft";
    pub const ACTIVE: &str = "active";
    pub const FULFILLED: &str = "fulfilled";
    pub const WITHDRAWN: &str = "withdrawn";
    pub const EXPIRED: &str = "expired";
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct Intent {
    pub id: Uuid,
    pub kind: String,
    pub raw_input: String,
    pub slots: Slots,
    pub confidence: f32,
    pub status: String,
    pub visibility: String,
    pub valid_until: Option<chrono::DateTime<chrono::Utc>>,
    pub projected_listing_id: Option<String>,
    pub created_at: chrono::DateTime<chrono::Utc>,
    /// Who wrote it. Never serialised: the matches endpoint returns other
    /// people's intents, and handing their user id to every caller makes
    /// contact details a scraping target. Aggregation needs it internally;
    /// starting a conversation from a match is a server-side action.
    #[serde(skip)]
    pub author_id: Option<String>,
}

/// What to record. `slots` may be entirely empty: an intent is allowed to be
/// vague, and demanding otherwise is the form-filling this design replaces.
pub struct NewIntent<'a> {
    pub campus_id: Uuid,
    pub author_id: &'a str,
    pub kind: &'a str,
    pub raw_input: &'a str,
    pub slots: Slots,
    /// 1.0 when the author stated it themselves; lower when inferred.
    pub confidence: f32,
    /// Inferred intents should arrive as drafts so a wrong reading cannot reach
    /// the pool. Author-stated ones can go straight to active.
    pub status: &'a str,
    pub visibility: &'a str,
    pub valid_until: Option<chrono::DateTime<chrono::Utc>>,
}

pub struct IntentService {
    db: PgPool,
}

impl IntentService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    pub async fn create(&self, intent: NewIntent<'_>) -> Result<Uuid> {
        if !kinds::ALL.contains(&intent.kind) {
            anyhow::bail!("unknown intent kind: {}", intent.kind);
        }
        if intent.raw_input.trim().is_empty() {
            anyhow::bail!("an intent needs the author's own words");
        }

        let id: Uuid = sqlx::query_scalar(
            "INSERT INTO intents (
                 campus_id, author_id, kind, raw_input, slots, confidence,
                 status, visibility, valid_until
             ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
             RETURNING id",
        )
        .bind(intent.campus_id)
        .bind(intent.author_id)
        .bind(intent.kind)
        .bind(intent.raw_input.trim())
        .bind(serde_json::to_value(&intent.slots)?)
        .bind(intent.confidence.clamp(0.0, 1.0))
        .bind(intent.status)
        .bind(intent.visibility)
        .bind(intent.valid_until)
        .fetch_one(&self.db)
        .await?;
        Ok(id)
    }

    /// Record several intents read out of one input, as drafts.
    ///
    /// This is the path a photo of a dorm room takes. All-or-nothing in a
    /// transaction: a partial batch would leave someone confirming half a room
    /// with no way to tell what was lost.
    pub async fn create_draft_batch(
        &self,
        campus_id: Uuid,
        author_id: &str,
        raw_input: &str,
        kind: &str,
        items: Vec<(Slots, f32)>,
    ) -> Result<Vec<Uuid>> {
        if !kinds::ALL.contains(&kind) {
            anyhow::bail!("unknown intent kind: {}", kind);
        }
        let mut tx = self.db.begin().await?;
        let mut ids = Vec::with_capacity(items.len());
        for (slots, confidence) in items {
            let id: Uuid = sqlx::query_scalar(
                "INSERT INTO intents (
                     campus_id, author_id, kind, raw_input, slots, confidence, status
                 ) VALUES ($1, $2, $3, $4, $5, $6, 'draft')
                 RETURNING id",
            )
            .bind(campus_id)
            .bind(author_id)
            .bind(kind)
            .bind(raw_input.trim())
            .bind(serde_json::to_value(&slots)?)
            .bind(confidence.clamp(0.0, 1.0))
            .fetch_one(&mut *tx)
            .await?;
            ids.push(id);
        }
        tx.commit().await?;
        Ok(ids)
    }

    /// Promote a draft the author has confirmed.
    ///
    /// Conditional on it still being a draft, so a double tap cannot re-activate
    /// something withdrawn in between.
    pub async fn confirm(&self, author_id: &str, intent_id: Uuid) -> Result<bool> {
        let updated = sqlx::query(
            "UPDATE intents SET status = 'active', updated_at = NOW()
             WHERE id = $1 AND author_id = $2 AND status = 'draft'",
        )
        .bind(intent_id)
        .bind(author_id)
        .execute(&self.db)
        .await?;
        Ok(updated.rows_affected() > 0)
    }

    /// Withdraw an intent that has not reached a terminal state.
    pub async fn withdraw(&self, author_id: &str, intent_id: Uuid) -> Result<bool> {
        let updated = sqlx::query(
            "UPDATE intents SET status = 'withdrawn', updated_at = NOW()
             WHERE id = $1 AND author_id = $2 AND status IN ('draft', 'active')",
        )
        .bind(intent_id)
        .bind(author_id)
        .execute(&self.db)
        .await?;
        Ok(updated.rows_affected() > 0)
    }

    pub async fn get(&self, author_id: &str, intent_id: Uuid) -> Result<Option<Intent>> {
        let row = sqlx::query(
            "SELECT id, kind, raw_input, slots, confidence, status, visibility,
                    valid_until, projected_listing_id, created_at, author_id
             FROM intents WHERE id = $1 AND author_id = $2",
        )
        .bind(intent_id)
        .bind(author_id)
        .fetch_optional(&self.db)
        .await?;
        row.map(row_to_intent).transpose()
    }

    /// The author's own intents, newest first, drafts included so they can see
    /// what is waiting on them.
    pub async fn list_mine(&self, author_id: &str, limit: i64) -> Result<Vec<Intent>> {
        let rows = sqlx::query(
            "SELECT id, kind, raw_input, slots, confidence, status, visibility,
                    valid_until, projected_listing_id, created_at, author_id
             FROM intents
             WHERE author_id = $1 AND status IN ('draft', 'active')
             ORDER BY created_at DESC
             LIMIT $2",
        )
        .bind(author_id)
        .bind(limit.clamp(1, 100))
        .fetch_all(&self.db)
        .await?;
        rows.into_iter().map(row_to_intent).collect()
    }

    /// The matching pool for a kind: live, campus-visible, unexpired, and not
    /// the caller's own.
    ///
    /// Drafts are excluded by construction — an unconfirmed reading of someone's
    /// words has no business being matched against.
    pub async fn pool(
        &self,
        campus_id: Uuid,
        kind: &str,
        excluding_author: &str,
        limit: i64,
    ) -> Result<Vec<Intent>> {
        let rows = sqlx::query(
            "WITH preferences AS (
                 SELECT COALESCE(pref.personalization_enabled, TRUE) AS enabled,
                        COALESCE(pref.signals_reset_at, '-infinity'::timestamptz) AS reset_at
                 FROM (SELECT 1) seed
                 LEFT JOIN feed_preferences pref
                   ON pref.campus_id = $1 AND pref.user_id = $3
             ), less_like AS (
                 SELECT feedback.signal_key, COUNT(*)::float8 AS weight
                 FROM feed_feedback feedback CROSS JOIN preferences pref
                 WHERE feedback.campus_id = $1 AND feedback.user_id = $3
                   AND feedback.resource_type = 'intent'
                   AND feedback.action = 'less_like_this'
                   AND pref.enabled AND feedback.updated_at >= pref.reset_at
                 GROUP BY feedback.signal_key
             )
             SELECT intent.id, intent.kind, intent.raw_input, intent.slots,
                    intent.confidence, intent.status, intent.visibility,
                    intent.valid_until, intent.projected_listing_id,
                    intent.created_at, intent.author_id
             FROM intents intent
             CROSS JOIN preferences pref
             LEFT JOIN less_like downrank
               ON downrank.signal_key = 'intent:kind:' || LOWER(BTRIM(intent.kind))
             WHERE intent.campus_id = $1
               AND intent.kind = $2
               AND intent.status = 'active'
               AND intent.visibility = 'campus'
               AND intent.author_id <> $3
               AND (intent.valid_until IS NULL OR intent.valid_until > NOW())
               AND NOT EXISTS (
                   SELECT 1 FROM feed_feedback exact_feedback
                   WHERE exact_feedback.campus_id = $1
                     AND exact_feedback.user_id = $3
                     AND exact_feedback.resource_type = 'intent'
                     AND exact_feedback.resource_id = intent.id::text
               )
             ORDER BY CASE WHEN pref.enabled THEN COALESCE(downrank.weight, 0) ELSE 0 END ASC,
                      intent.created_at DESC
             LIMIT $4",
        )
        .bind(campus_id)
        .bind(kind)
        .bind(excluding_author)
        .bind(limit.clamp(1, 200))
        .fetch_all(&self.db)
        .await?;
        rows.into_iter().map(row_to_intent).collect()
    }

    /// Mirror a goods intent into `inventory` so it appears in the existing
    /// browse and search surfaces.
    ///
    /// Returns the listing id, or `None` when the intent cannot be honestly
    /// displayed as a listing.
    ///
    /// That `None` is the interesting case, and it is a deliberate refusal. The
    /// `inventory` schema requires a price; an intent is allowed not to have
    /// one. Projecting "whatever you'll give me" into a grid would force us to
    /// invent a figure — printing ¥0.00, or a guess — which is precisely the
    /// fabrication this layer exists to avoid, and it would misrepresent the
    /// owner to every buyer who saw it.
    ///
    /// So unpriced intents stay intent-only. They are still matched, still
    /// found, still answerable; they simply do not appear in a surface that
    /// cannot show them truthfully. The legacy grid displays what it can
    /// display honestly, and the gap is an argument for the grid to learn about
    /// intents rather than for intents to start lying.
    pub async fn project_to_listing(&self, intent_id: Uuid) -> Result<Option<String>> {
        let row = sqlx::query(
            "SELECT campus_id, author_id, kind, raw_input, slots, projected_listing_id
             FROM intents WHERE id = $1",
        )
        .bind(intent_id)
        .fetch_optional(&self.db)
        .await?;
        let Some(row) = row else {
            return Ok(None);
        };

        // Already mirrored: the unique index makes a second projection an
        // error, and re-projecting would fork the mirror.
        if let Some(existing) = row.get::<Option<String>, _>("projected_listing_id") {
            return Ok(Some(existing));
        }

        let kind: String = row.get("kind");
        if !kinds::is_goods(&kind) || kind == kinds::GOODS_SEEK {
            // Seeking intents have their own surface, and companion/help/
            // activity intents are people and occasions — putting them in a
            // shopping grid would be the category error this design is undoing.
            return Ok(None);
        }

        let slots: Slots = serde_json::from_value(row.get("slots")).unwrap_or_default();
        let Some(cents) = slots.price.as_ref().and_then(|p| p.nominal_cents()) else {
            return Ok(None);
        };
        let raw_input: String = row.get("raw_input");
        let title = slots
            .subject
            .clone()
            .unwrap_or_else(|| raw_input.chars().take(60).collect());

        let listing_id = Uuid::new_v4().to_string();
        let mut tx = self.db.begin().await?;
        sqlx::query(
            "INSERT INTO inventory (id, campus_id, title, category, brand, condition_score,
                                    suggested_price_cny, defects, description, owner_id,
                                    status, direction)
             VALUES ($1, $2, $3, $4, '', $5, $6, '[]', $7, $8, 'active', 'offer')",
        )
        .bind(&listing_id)
        .bind(row.get::<Uuid, _>("campus_id"))
        .bind(&title)
        .bind(
            slots
                .category
                .clone()
                .unwrap_or_else(|| "other".to_string()),
        )
        .bind(slots.condition_score.unwrap_or(8))
        .bind(cents)
        .bind(&raw_input)
        .bind(row.get::<String, _>("author_id"))
        .execute(&mut *tx)
        .await?;

        sqlx::query(
            "UPDATE intents SET projected_listing_id = $2, updated_at = NOW() WHERE id = $1",
        )
        .bind(intent_id)
        .bind(&listing_id)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;

        Ok(Some(listing_id))
    }

    /// Mark an intent as satisfied.
    ///
    /// Distinct from withdrawing it: this one worked. Keeping the two apart is
    /// what lets the health metrics tell "nobody answered" from "changed my
    /// mind", which are different problems with different fixes.
    pub async fn fulfil(&self, author_id: &str, intent_id: Uuid) -> Result<bool> {
        let updated = sqlx::query(
            "UPDATE intents SET status = $3, updated_at = NOW()
             WHERE id = $1 AND author_id = $2 AND status = $4",
        )
        .bind(intent_id)
        .bind(author_id)
        .bind(status::FULFILLED)
        .bind(status::ACTIVE)
        .execute(&self.db)
        .await?;
        Ok(updated.rows_affected() > 0)
    }

    /// The campus intent stream: what everyone is currently after.
    ///
    /// Distinct from [`pool`], which serves matching against one of the
    /// caller's own intents. This one exists because otherwise **you have to
    /// post something before you can see anything** — a new student opens the
    /// app, has said nothing yet, and finds an empty room. That is the
    /// unanswered-post problem from the other side: the demand is there and
    /// nobody can see it to answer it.
    ///
    /// `kind` filters when given; `None` returns every kind interleaved by
    /// recency, which is what a browsing student actually wants.
    ///
    /// Anything the viewer has already answered is left out. The feed is a list
    /// of what you can answer, and something you answered yesterday is not one:
    /// the conversation is already in your inbox. Left in, a week of active
    /// answering fills the feed with your own replies and the campus looks like
    /// it has gone quiet — the exact reading that kills a young community.
    pub async fn campus_feed(
        &self,
        campus_id: Uuid,
        viewer_id: &str,
        kind: Option<&str>,
        limit: i64,
    ) -> Result<Vec<Intent>> {
        let rows = sqlx::query(
            "WITH preferences AS (
                 SELECT COALESCE(pref.personalization_enabled, TRUE) AS enabled,
                        COALESCE(pref.signals_reset_at, '-infinity'::timestamptz) AS reset_at
                 FROM (SELECT 1) seed
                 LEFT JOIN feed_preferences pref
                   ON pref.campus_id = $1 AND pref.user_id = $2
             ), less_like AS (
                 SELECT feedback.signal_key, COUNT(*)::float8 AS weight
                 FROM feed_feedback feedback CROSS JOIN preferences pref
                 WHERE feedback.campus_id = $1 AND feedback.user_id = $2
                   AND feedback.resource_type = 'intent'
                   AND feedback.action = 'less_like_this'
                   AND pref.enabled AND feedback.updated_at >= pref.reset_at
                 GROUP BY feedback.signal_key
             )
             SELECT intent.id, intent.kind, intent.raw_input, intent.slots,
                    intent.confidence, intent.status, intent.visibility,
                    intent.valid_until, intent.projected_listing_id,
                    intent.created_at, intent.author_id
             FROM intents intent
             CROSS JOIN preferences pref
             LEFT JOIN less_like downrank
               ON downrank.signal_key = 'intent:kind:' || LOWER(BTRIM(intent.kind))
             WHERE intent.campus_id = $1
               AND intent.status = 'active'
               AND intent.visibility = 'campus'
               AND intent.author_id <> $2
               AND (intent.valid_until IS NULL OR intent.valid_until > NOW())
               AND ($3::text IS NULL OR intent.kind = $3)
               AND NOT EXISTS (
                   SELECT 1 FROM intent_responses r
                   WHERE r.intent_id = intent.id AND r.responder_id = $2
               )
               AND NOT EXISTS (
                   SELECT 1 FROM feed_feedback exact_feedback
                   WHERE exact_feedback.campus_id = $1
                     AND exact_feedback.user_id = $2
                     AND exact_feedback.resource_type = 'intent'
                     AND exact_feedback.resource_id = intent.id::text
               )
             ORDER BY CASE WHEN pref.enabled THEN COALESCE(downrank.weight, 0) ELSE 0 END ASC,
                      intent.created_at DESC
             LIMIT $4",
        )
        .bind(campus_id)
        .bind(viewer_id)
        .bind(kind)
        .bind(limit.clamp(1, 100))
        .fetch_all(&self.db)
        .await?;
        rows.into_iter().map(row_to_intent).collect()
    }

    /// Who wrote an intent, if it is live and visible on this campus.
    ///
    /// Only ever used server-side to open a conversation. The author id is
    /// deliberately not serialised on [`Intent`], so answering someone is an
    /// action the server performs rather than a user id the client is handed —
    /// otherwise the matching surface becomes a directory to scrape.
    pub async fn answerable_author(
        &self,
        campus_id: Uuid,
        intent_id: Uuid,
    ) -> Result<Option<(String, String)>> {
        let row = sqlx::query(
            "SELECT author_id, raw_input FROM intents
             WHERE id = $1
               AND campus_id = $2
               AND status = 'active'
               AND visibility = 'campus'
               AND (valid_until IS NULL OR valid_until > NOW())",
        )
        .bind(intent_id)
        .bind(campus_id)
        .fetch_optional(&self.db)
        .await?;
        Ok(row.map(|row| (row.get("author_id"), row.get("raw_input"))))
    }

    /// Record that someone answered an intent.
    ///
    /// `ON CONFLICT DO NOTHING`, because a second message from the same person
    /// is the same answer continuing. Counting it again would inflate the answer
    /// rate exactly where a thin community most needs the truth.
    pub async fn record_response(
        &self,
        campus_id: Uuid,
        intent_id: Uuid,
        responder_id: &str,
        conversation_id: Option<Uuid>,
    ) -> Result<()> {
        sqlx::query(
            "INSERT INTO intent_responses (campus_id, intent_id, responder_id, conversation_id)
             VALUES ($1, $2, $3, $4)
             ON CONFLICT (intent_id, responder_id) DO NOTHING",
        )
        .bind(campus_id)
        .bind(intent_id)
        .bind(responder_id)
        .bind(conversation_id)
        .execute(&self.db)
        .await?;
        Ok(())
    }

    /// Retire intents whose moment has passed. Returns how many.
    pub async fn expire_due(&self) -> Result<u64> {
        let updated = sqlx::query(
            "UPDATE intents SET status = $1, updated_at = NOW()
             WHERE status = $2 AND valid_until IS NOT NULL AND valid_until <= NOW()",
        )
        .bind(status::EXPIRED)
        .bind(status::ACTIVE)
        .execute(&self.db)
        .await?;
        Ok(updated.rows_affected())
    }
}

fn row_to_intent(row: sqlx::postgres::PgRow) -> Result<Intent> {
    let slots_json: serde_json::Value = row.get("slots");
    Ok(Intent {
        id: row.get("id"),
        kind: row.get("kind"),
        raw_input: row.get("raw_input"),
        // A slot shape we cannot read must not take the whole list down with
        // it; the author's words are still there and still worth showing.
        slots: serde_json::from_value(slots_json).unwrap_or_default(),
        confidence: row.get("confidence"),
        status: row.get("status"),
        visibility: row.get("visibility"),
        valid_until: row.get("valid_until"),
        projected_listing_id: row.get("projected_listing_id"),
        created_at: row.get("created_at"),
        author_id: row.try_get("author_id").ok(),
    })
}

/// Hourly expiry sweep, on the shutdown-aware ticker.
pub async fn run_expiry_worker(db_pool: PgPool, shutdown: crate::lifecycle::ShutdownSignal) {
    tracing::info!("Intent expiry worker started (interval: 1 h)");
    let mut ticker = tokio::time::interval(std::time::Duration::from_secs(60 * 60));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    let service = IntentService::new(db_pool);
    while crate::lifecycle::tick_or_shutdown(&mut ticker, &shutdown)
        .await
        .should_continue()
    {
        match service.expire_due().await {
            Ok(0) => {}
            Ok(expired) => tracing::debug!(expired, "Retired intents past their moment"),
            Err(e) => tracing::error!(%e, "Intent expiry sweep failed"),
        }
    }

    tracing::info!("Intent expiry worker stopped");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_goods_intents_have_a_listing_projection() {
        assert!(kinds::is_goods(kinds::GOODS_OFFER));
        assert!(kinds::is_goods(kinds::GOODS_SEEK));
        // Finding a badminton partner is not a listing, and projecting it into
        // `inventory` would put people in a shopping grid.
        assert!(!kinds::is_goods(kinds::COMPANION));
        assert!(!kinds::is_goods(kinds::ACTIVITY));
        assert!(!kinds::is_goods(kinds::HELP));
    }
}

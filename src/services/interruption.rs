//! Interruption budget for discretionary outreach.
//!
//! A community that matches people and forms groups has an unbounded supply of
//! things it *could* tell you about. Its likeliest death is not being
//! unintelligent, it is being exhausting: users who mute the app do not come
//! back. So the budget is structural, not a guideline each call site is
//! trusted to remember.
//!
//! Enforcement has two independent layers:
//!
//! 1. **Type system.** Pushing a budgeted notification requires an
//!    [`InterruptionGrant`], whose only constructor is
//!    [`InterruptionService::request`]. Its fields are private, so no code
//!    outside this module can fabricate permission to interrupt.
//! 2. **Runtime.** [`crate::services::notification::NotificationService::
//!    create`] — the unbudgeted door used for directed notifications — refuses
//!    any topic registered here, so the budget cannot be sidestepped by taking
//!    the other route.
//!
//! Being over budget silences the *push*, never the message. A suppressed
//! notification is still written to the inbox, so the user finds it when they
//! next look. Dropping it outright would make a budget indistinguishable from
//! data loss.
//!
//! Every attempt is recorded whether pushed or held, which is what makes both
//! "why am I seeing this?" and "why didn't I hear about that?" answerable, and
//! makes suppression measurable rather than invisible.

use anyhow::Result;
use sqlx::{PgPool, Row};
use uuid::Uuid;

/// Budgeted topics.
///
/// The dividing line is not who pressed send — it is whether the recipient
/// asked for *this particular* message:
///
/// * **Directed** — about something the user owns or is party to, and awaiting
///   their answer: a negotiation on their listing, an order update. Always
///   delivered. Budgeting these would break the product.
/// * **Discretionary** — worth knowing, safely skippable, and available in
///   unbounded quantity. The first is welcome, the twentieth is noise.
///   Budgeted, and listed here.
///
/// Note that `wanted_response` is discretionary despite being sent by a human:
/// posting a wanted listing invites answers, but nothing stops one person
/// recommending fifty different items to it, and the unique constraint only
/// prevents recommending the *same* item twice.
pub mod topics {
    /// Someone recommended an item against the user's wanted listing.
    pub const WANTED_RESPONSE: &str = "wanted_response";
    /// A match was found for one of the user's intents.
    pub const MATCH_FOUND: &str = "match_found";
    /// A group is forming that fits something the user asked for.
    pub const SPACE_FORMED: &str = "space_formed";
    /// A nudge about an agreement the user is party to but has gone quiet on.
    pub const AGREEMENT_STALLED: &str = "agreement_stalled";

    pub const ALL: &[&str] = &[
        WANTED_RESPONSE,
        MATCH_FOUND,
        SPACE_FORMED,
        AGREEMENT_STALLED,
    ];
}

/// Whether a topic is subject to the budget.
pub fn is_budgeted_topic(topic: &str) -> bool {
    topics::ALL.contains(&topic)
}

/// Below this, an interruption is not worth a user's attention at all.
const BASE_VALUE_THRESHOLD: f32 = 0.3;
/// Raised thresholds for topics the user keeps ignoring.
const COOLING_VALUE_THRESHOLD: f32 = 0.6;
const CHILLED_VALUE_THRESHOLD: f32 = 0.85;
/// Don't judge a topic until there is enough evidence to judge it on.
const MIN_OUTCOMES_FOR_STATS: i64 = 3;
/// How far back topic acceptance is measured.
const STATS_WINDOW_DAYS: i64 = 30;

/// The budget window.
///
/// A rolling 24 hours rather than a calendar day: calendar days need a
/// timezone, and a UTC day would reset at 08:00 local time for a Nanchang
/// campus — an arbitrary morning cliff, and one that lets a burst of six
/// interruptions straddle the boundary while nominally respecting a budget of
/// three.
const BUDGET_WINDOW_HOURS: i64 = 24;

/// Permission to push one budgeted notification.
///
/// Constructible only by [`InterruptionService::request`]. Holding one means
/// the budget was checked and the spend recorded.
#[derive(Debug)]
pub struct InterruptionGrant {
    ledger_id: Uuid,
    topic: String,
}

impl InterruptionGrant {
    pub fn ledger_id(&self) -> Uuid {
        self.ledger_id
    }
    pub fn topic(&self) -> &str {
        &self.topic
    }
}

/// Why an interruption was withheld. Recorded and user-visible: suppression
/// that leaves no trace reads as "we had nothing to say".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Suppressed {
    /// The user's daily budget is spent.
    Budget,
    /// The user muted this topic.
    Muted,
    /// The user asked not to be disturbed for now.
    Quiet,
    /// Not worth an interruption, given how this user treats this topic.
    LowValue,
}

impl Suppressed {
    fn as_decision(self) -> &'static str {
        match self {
            Suppressed::Budget => "suppressed_budget",
            Suppressed::Muted => "suppressed_muted",
            Suppressed::Quiet => "suppressed_quiet",
            Suppressed::LowValue => "suppressed_low_value",
        }
    }
}

#[derive(Debug)]
pub enum Decision {
    Granted(InterruptionGrant),
    /// Held back, but still recorded. The ledger id travels with it so a
    /// suppressed notification can still be linked from the inbox: a user who
    /// digs one out and acts on it is the strongest evidence the threshold
    /// should learn from.
    Withheld {
        ledger_id: Uuid,
        reason: Suppressed,
    },
    /// The budget could not be consulted at all — a database error, say.
    ///
    /// Treated as withheld. Failing open would turn an outage into a spam
    /// vector, and the whole point of the budget is that it cannot be lost by
    /// accident; the message still reaches the inbox, so nothing is dropped.
    Unavailable,
}

impl Decision {
    /// The ledger entry recording this decision, if one was written.
    pub fn ledger_id(&self) -> Option<Uuid> {
        match self {
            Decision::Granted(grant) => Some(grant.ledger_id()),
            Decision::Withheld { ledger_id, .. } => Some(*ledger_id),
            Decision::Unavailable => None,
        }
    }

    /// Whether this decision permits a push.
    pub fn may_push(&self) -> bool {
        matches!(self, Decision::Granted(_))
    }
}

/// A user's current interruption settings.
#[derive(Debug, Clone, serde::Serialize)]
pub struct Preferences {
    pub daily_budget: i16,
    pub muted_topics: Vec<String>,
    pub quiet_until: Option<chrono::DateTime<chrono::Utc>>,
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            daily_budget: 3,
            muted_topics: Vec::new(),
            quiet_until: None,
        }
    }
}

/// One recorded outreach attempt, delivered or not.
#[derive(Debug, Clone, serde::Serialize)]
pub struct LedgerEntry {
    pub id: Uuid,
    pub topic: String,
    pub reason: String,
    pub decision: String,
    pub delivered_at: Option<chrono::DateTime<chrono::Utc>>,
    pub accepted_at: Option<chrono::DateTime<chrono::Utc>>,
    pub dismissed_at: Option<chrono::DateTime<chrono::Utc>>,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

/// What to send and why.
pub struct InterruptionRequest<'a> {
    pub campus_id: Uuid,
    pub user_id: &'a str,
    pub channel: &'a str,
    pub topic: &'a str,
    /// Shown to the user under "why am I seeing this". Required, because an
    /// interruption nobody can justify should not be sent.
    pub reason: &'a str,
    /// 0.0–1.0 estimate of how much this is worth the user's attention.
    pub expected_value: f32,
}

pub struct InterruptionService {
    db: PgPool,
}

impl InterruptionService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    /// Ask permission to interrupt.
    ///
    /// Every call is recorded, granted or not. The whole check runs in one
    /// transaction that locks the user's preference row, so concurrent
    /// requests cannot both observe the last unit of budget and both spend it.
    pub async fn request(&self, req: InterruptionRequest<'_>) -> Result<Decision> {
        if !is_budgeted_topic(req.topic) {
            anyhow::bail!(
                "topic '{}' is not budgeted; directed notifications go through \
                 NotificationService::create",
                req.topic
            );
        }

        let mut tx = self.db.begin().await?;

        // Materialise-and-lock: the row must exist to be locked, and creating
        // it here means a first-time user is serialised the same as anyone
        // else rather than racing on an absent row.
        sqlx::query(
            "INSERT INTO interruption_preferences (user_id) VALUES ($1)
             ON CONFLICT (user_id) DO NOTHING",
        )
        .bind(req.user_id)
        .execute(&mut *tx)
        .await?;

        let prefs = sqlx::query(
            "SELECT daily_budget, muted_topics, quiet_until
             FROM interruption_preferences WHERE user_id = $1
             FOR UPDATE",
        )
        .bind(req.user_id)
        .fetch_one(&mut *tx)
        .await?;

        let daily_budget: i16 = prefs.get("daily_budget");
        let muted_topics: Vec<String> = prefs.get("muted_topics");
        let quiet_until: Option<chrono::DateTime<chrono::Utc>> = prefs.get("quiet_until");

        let now = chrono::Utc::now();
        let withheld = if quiet_until.is_some_and(|until| until > now) {
            Some(Suppressed::Quiet)
        } else if muted_topics.iter().any(|t| t == req.topic) {
            Some(Suppressed::Muted)
        } else if req.expected_value < self.threshold_for(&mut tx, req.user_id, req.topic).await? {
            Some(Suppressed::LowValue)
        } else {
            let spent: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM interruption_ledger
                 WHERE user_id = $1
                   AND delivered_at > NOW() - make_interval(hours => $2::int)",
            )
            .bind(req.user_id)
            .bind(BUDGET_WINDOW_HOURS as i32)
            .fetch_one(&mut *tx)
            .await?;
            if spent >= daily_budget as i64 {
                Some(Suppressed::Budget)
            } else {
                None
            }
        };

        let decision = withheld.map_or("delivered", |s| s.as_decision());
        let ledger_id: Uuid = sqlx::query_scalar(
            "INSERT INTO interruption_ledger (
                 campus_id, user_id, channel, topic, reason, expected_value,
                 decision, delivered_at
             ) VALUES ($1, $2, $3, $4, $5, $6, $7,
                       CASE WHEN $7 = 'delivered' THEN NOW() ELSE NULL END)
             RETURNING id",
        )
        .bind(req.campus_id)
        .bind(req.user_id)
        .bind(req.channel)
        .bind(req.topic)
        .bind(req.reason)
        .bind(req.expected_value)
        .bind(decision)
        .fetch_one(&mut *tx)
        .await?;

        tx.commit().await?;

        Ok(match withheld {
            Some(reason) => Decision::Withheld { ledger_id, reason },
            None => Decision::Granted(InterruptionGrant {
                ledger_id,
                topic: req.topic.to_string(),
            }),
        })
    }

    /// The value a topic must clear for this user.
    ///
    /// Topics the user keeps dismissing get harder to send, so an unwanted
    /// category fades on its own instead of requiring the user to find a
    /// settings screen.
    async fn threshold_for(
        &self,
        tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
        user_id: &str,
        topic: &str,
    ) -> Result<f32> {
        let row = sqlx::query(
            "SELECT COUNT(*) FILTER (WHERE accepted_at IS NOT NULL OR dismissed_at IS NOT NULL)
                        AS outcomes,
                    COUNT(*) FILTER (WHERE accepted_at IS NOT NULL) AS accepted
             FROM interruption_ledger
             WHERE user_id = $1 AND topic = $2 AND delivered_at IS NOT NULL
               AND created_at > NOW() - make_interval(days => $3::int)",
        )
        .bind(user_id)
        .bind(topic)
        .bind(STATS_WINDOW_DAYS as i32)
        .fetch_one(&mut **tx)
        .await?;

        let outcomes: i64 = row.get("outcomes");
        let accepted: i64 = row.get("accepted");
        if outcomes < MIN_OUTCOMES_FOR_STATS {
            return Ok(BASE_VALUE_THRESHOLD);
        }

        let acceptance = accepted as f32 / outcomes as f32;
        Ok(if acceptance < 0.2 {
            CHILLED_VALUE_THRESHOLD
        } else if acceptance < 0.4 {
            COOLING_VALUE_THRESHOLD
        } else {
            BASE_VALUE_THRESHOLD
        })
    }

    /// Record that the user engaged with an interruption. Feeds the per-topic
    /// threshold, so paying attention keeps a topic alive.
    pub async fn mark_accepted(&self, user_id: &str, ledger_id: Uuid) -> Result<bool> {
        let updated = sqlx::query(
            "UPDATE interruption_ledger SET accepted_at = NOW()
             WHERE id = $1 AND user_id = $2 AND delivered_at IS NOT NULL
               AND accepted_at IS NULL AND dismissed_at IS NULL",
        )
        .bind(ledger_id)
        .bind(user_id)
        .execute(&self.db)
        .await?;
        Ok(updated.rows_affected() > 0)
    }

    /// Record that the user waved an interruption away.
    pub async fn mark_dismissed(&self, user_id: &str, ledger_id: Uuid) -> Result<bool> {
        let updated = sqlx::query(
            "UPDATE interruption_ledger SET dismissed_at = NOW()
             WHERE id = $1 AND user_id = $2 AND delivered_at IS NOT NULL
               AND accepted_at IS NULL AND dismissed_at IS NULL",
        )
        .bind(ledger_id)
        .bind(user_id)
        .execute(&self.db)
        .await?;
        Ok(updated.rows_affected() > 0)
    }

    /// Recent outreach attempts, delivered and withheld alike, so the user can
    /// see both what reached them and what was held back on their behalf.
    pub async fn recent(&self, user_id: &str, limit: i64) -> Result<Vec<LedgerEntry>> {
        let rows = sqlx::query(
            "SELECT id, topic, reason, decision, delivered_at, accepted_at,
                    dismissed_at, created_at
             FROM interruption_ledger
             WHERE user_id = $1
             ORDER BY created_at DESC
             LIMIT $2",
        )
        .bind(user_id)
        .bind(limit.clamp(1, 100))
        .fetch_all(&self.db)
        .await?;

        Ok(rows
            .into_iter()
            .map(|row| LedgerEntry {
                id: row.get("id"),
                topic: row.get("topic"),
                reason: row.get("reason"),
                decision: row.get("decision"),
                delivered_at: row.get("delivered_at"),
                accepted_at: row.get("accepted_at"),
                dismissed_at: row.get("dismissed_at"),
                created_at: row.get("created_at"),
            })
            .collect())
    }

    pub async fn preferences(&self, user_id: &str) -> Result<Preferences> {
        let row = sqlx::query(
            "SELECT daily_budget, muted_topics, quiet_until
             FROM interruption_preferences WHERE user_id = $1",
        )
        .bind(user_id)
        .fetch_optional(&self.db)
        .await?;

        Ok(row.map_or_else(Preferences::default, |row| Preferences {
            daily_budget: row.get("daily_budget"),
            muted_topics: row.get("muted_topics"),
            quiet_until: row.get("quiet_until"),
        }))
    }

    /// Replace a user's settings. The budget ceiling is enforced by a CHECK
    /// constraint, so a bad value fails rather than silently clamping to
    /// something the user did not choose.
    pub async fn set_preferences(&self, user_id: &str, prefs: &Preferences) -> Result<()> {
        sqlx::query(
            "INSERT INTO interruption_preferences (user_id, daily_budget, muted_topics,
                                                   quiet_until, updated_at)
             VALUES ($1, $2, $3, $4, NOW())
             ON CONFLICT (user_id) DO UPDATE
             SET daily_budget = EXCLUDED.daily_budget,
                 muted_topics = EXCLUDED.muted_topics,
                 quiet_until  = EXCLUDED.quiet_until,
                 updated_at   = NOW()",
        )
        .bind(user_id)
        .bind(prefs.daily_budget)
        .bind(&prefs.muted_topics)
        .bind(prefs.quiet_until)
        .execute(&self.db)
        .await?;
        Ok(())
    }

    /// How much of the budget is left in the current window.
    pub async fn remaining_budget(&self, user_id: &str) -> Result<i64> {
        let budget = self.preferences(user_id).await?.daily_budget as i64;
        let spent: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM interruption_ledger
             WHERE user_id = $1 AND delivered_at > NOW() - make_interval(hours => $2::int)",
        )
        .bind(user_id)
        .bind(BUDGET_WINDOW_HOURS as i32)
        .fetch_one(&self.db)
        .await?;
        Ok((budget - spent).max(0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn directed_topics_are_not_budgeted() {
        assert!(is_budgeted_topic(topics::MATCH_FOUND));
        assert!(is_budgeted_topic(topics::WANTED_RESPONSE));
        // Awaiting the user's answer — suppressing these would break the
        // product, not protect the user.
        assert!(!is_budgeted_topic("negotiation_request"));
        assert!(!is_budgeted_topic("order_created"));
        assert!(!is_budgeted_topic("conversation_created"));
    }

    #[test]
    fn a_grant_cannot_be_built_outside_this_module() {
        // Compile-time property, asserted here as documentation: the fields
        // are private, so `InterruptionGrant { .. }` does not typecheck
        // elsewhere and `request` is the only way to obtain one.
        let grant = InterruptionGrant {
            ledger_id: Uuid::nil(),
            topic: topics::MATCH_FOUND.to_string(),
        };
        assert_eq!(grant.topic(), topics::MATCH_FOUND);
    }
}

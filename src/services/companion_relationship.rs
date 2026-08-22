//! Companion relationship state (master goal §13–15).
//!
//! Explicit numeric state — the model never declares "we're best friends".
//! Gains are event-driven with a daily cap and diminishing returns; the
//! relationship only ever shapes tone/greetings, never manipulates the user.

use anyhow::Result;
use sqlx::PgPool;

pub const DAILY_AFFINITY_CAP: f32 = 0.10;

/// Relationship events that nudge the numbers (§14).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum RelationshipEvent {
    UserReturns,
    LongConversation,
    UserThanks,
    UserSharesPreference,
    UserUsesAgentTool,
    UserCancelsAction,
}

impl RelationshipEvent {
    pub fn from_wire(value: &str) -> Option<Self> {
        match value {
            "user_returns" => Some(Self::UserReturns),
            "long_conversation" => Some(Self::LongConversation),
            "user_thanks" => Some(Self::UserThanks),
            "user_shares_preference" => Some(Self::UserSharesPreference),
            "user_uses_agent_tool" => Some(Self::UserUsesAgentTool),
            "user_cancels_action" => Some(Self::UserCancelsAction),
            _ => None,
        }
    }

    fn gains(self) -> (f32, f32, f32) {
        // (familiarity, trust, affinity) at intensity 1.0
        match self {
            Self::UserReturns => (0.02, 0.0, 0.01),
            Self::LongConversation => (0.04, 0.01, 0.02),
            Self::UserThanks => (0.0, 0.03, 0.05),
            Self::UserSharesPreference => (0.03, 0.04, 0.03),
            Self::UserUsesAgentTool => (0.02, 0.03, 0.01),
            Self::UserCancelsAction => (0.0, -0.02, -0.01),
        }
    }
}

#[derive(Debug, Clone, serde::Serialize, sqlx::FromRow)]
pub struct RelationshipState {
    pub user_id: String,
    pub familiarity: f32,
    pub trust: f32,
    pub affinity: f32,
    pub interaction_count: i32,
    pub relationship_stage: String,
}

/// Pure stage computation — deterministic and unit-testable.
pub fn stage_for(familiarity: f32, trust: f32, affinity: f32) -> &'static str {
    if familiarity > 0.3 && trust > 0.35 && affinity > 0.3 {
        "close"
    } else if familiarity > 0.12 || affinity > 0.1 {
        "familiar"
    } else {
        "new"
    }
}

/// Diminishing returns: each gain shrinks as affinity approaches 1, and the
/// daily cap hard-stops affinity farming (§14).
pub fn clamp_gain(current_affinity: f32, daily_gained: f32, raw_gain: f32) -> f32 {
    let headroom_to_full = (1.0 - current_affinity).max(0.0);
    let headroom_daily = (DAILY_AFFINITY_CAP - daily_gained).max(0.0);
    let scaled = raw_gain * headroom_to_full * 4.0;
    let magnitude = scaled.abs().min(headroom_daily).min(0.05);
    if raw_gain < 0.0 {
        -magnitude
    } else {
        magnitude
    }
}

#[derive(Clone)]
pub struct CompanionRelationshipService {
    db: PgPool,
}

impl CompanionRelationshipService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    /// Fetch current state, creating an empty row on first sight.
    pub async fn get(&self, user_id: &str) -> Result<RelationshipState> {
        sqlx::query(
            "INSERT INTO companion_relationships (user_id) VALUES ($1)
             ON CONFLICT (user_id) DO NOTHING",
        )
        .bind(user_id)
        .execute(&self.db)
        .await?;
        let mut tx = self.db.begin().await?;

        // Roll the daily window forward before reading counters.
        sqlx::query(
            "UPDATE companion_relationships
                SET daily_affinity_gained = 0,
                    daily_window_date = CURRENT_DATE
              WHERE user_id = $1 AND daily_window_date < CURRENT_DATE",
        )
        .bind(user_id)
        .execute(&mut *tx)
        .await?;

        let state = sqlx::query_as::<_, RelationshipState>(
            "SELECT user_id, familiarity, trust, affinity,
                    interaction_count, relationship_stage
               FROM companion_relationships WHERE user_id = $1",
        )
        .bind(user_id)
        .fetch_one(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(state)
    }

    /// Record one interaction event and return the updated state.
    pub async fn record_event(
        &self,
        user_id: &str,
        event: RelationshipEvent,
    ) -> Result<RelationshipState> {
        let current = self.get(user_id).await?;

        // Interaction-count based familiarity bump on every recorded turn.
        let interaction_bump = if current.interaction_count < 20 {
            0.005_f32
        } else {
            0.001
        };

        let (gf, gt, ga) = event.gains();
        let daily = current_daily(&self.db, user_id).await?;
        let applied_affinity = clamp_gain(current.affinity, daily, ga);

        let mut familiarity = (current.familiarity + interaction_bump + gf).clamp(0.0, 1.0);
        let mut trust = (current.trust + gt).clamp(0.0, 1.0);
        let affinity = (current.affinity + applied_affinity).clamp(0.0, 1.0);
        let interaction_count = current.interaction_count + 1;
        let stage = stage_for(familiarity, trust, affinity).to_string();
        familiarity = familiarity.min(1.0);
        trust = trust.min(1.0);

        sqlx::query(
            "UPDATE companion_relationships
                SET familiarity = $2, trust = $3, affinity = $4,
                    interaction_count = $5,
                    last_interaction_at = NOW(),
                    relationship_stage = $6,
                    daily_affinity_gained = daily_affinity_gained + $7,
                    updated_at = NOW()
              WHERE user_id = $1",
        )
        .bind(user_id)
        .bind(familiarity)
        .bind(trust)
        .bind(affinity)
        .bind(interaction_count)
        .bind(&stage)
        .bind(applied_affinity.max(0.0))
        .execute(&self.db)
        .await?;

        self.get(user_id).await
    }

    /// Greeting opener for the current stage + absence gap (goal §61–62).
    /// Wired into the assistant greeting in a later phase; kept public API.
    #[allow(dead_code)]
    pub fn greeting_for(state: &RelationshipState, away_for: std::time::Duration) -> &'static str {
        match state.relationship_stage.as_str() {
            "close" => {
                if away_for.as_secs() > 86_400 {
                    "回来啦！最近怎么样？"
                } else {
                    "来啦，接着看？"
                }
            }
            "familiar" => "又见面啦，今天想找点什么？",
            _ => "你好呀，我是小昌，可以帮你翻翻校园里的好物。",
        }
    }
}

async fn current_daily(db: &PgPool, user_id: &str) -> Result<f32> {
    let v: f32 = sqlx::query_scalar(
        "SELECT COALESCE(daily_affinity_gained, 0)
           FROM companion_relationships WHERE user_id = $1",
    )
    .bind(user_id)
    .fetch_one(db)
    .await
    .unwrap_or(0.0);
    Ok(v)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stage_progression_matches_spec() {
        assert_eq!(stage_for(0.0, 0.0, 0.0), "new");
        assert_eq!(stage_for(0.15, 0.05, 0.12), "familiar");
        assert_eq!(stage_for(0.5, 0.5, 0.4), "close");
        // Trust matters: high affinity without trust never reaches close.
        assert_eq!(stage_for(0.5, 0.1, 0.6), "familiar");
    }

    #[test]
    fn gains_are_event_shaped() {
        let (f, t, a) = RelationshipEvent::UserThanks.gains();
        assert_eq!(f, 0.0);
        assert!(t > 0.0 && a > t);
        let (_, t2, _) = RelationshipEvent::UserCancelsAction.gains();
        assert!(t2 < 0.0, "cancelling erodes trust");
    }

    #[test]
    fn clamp_gain_respects_daily_cap_and_headroom() {
        // Fresh user, generous raw gain → capped per-day slice.
        let g = clamp_gain(0.0, 0.0, 0.5);
        assert!(g <= 0.05, "single event ≤ 0.05, got {g}");
        // Daily budget exhausted → zero.
        assert_eq!(clamp_gain(0.0, DAILY_AFFINITY_CAP, 0.3), 0.0);
        // Near-max affinity → diminishing returns: 0.4 * 0.02 headroom * 4.
        let tiny = clamp_gain(0.98, 0.0, 0.4);
        assert!((tiny - 0.032).abs() < 1e-6, "got {tiny}");
        // Negative gains keep sign.
        let neg = clamp_gain(0.5, 0.0, -0.02);
        assert!(neg < 0.0);
    }
}

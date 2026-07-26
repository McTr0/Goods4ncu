//! Trust built from what actually happened.
//!
//! Star ratings are an e-commerce import and they fail badly on a campus. Where
//! you keep seeing the same people, everyone gives five stars — so the signal is
//! worthless — and anyone who does not is picking a fight with someone they will
//! meet at breakfast. The rating that is safe to give carries no information; the
//! one that carries information is unsafe to give.
//!
//! So nothing subjective is recorded. Two questions with checkable answers: did
//! it happen, and were they on time. "How was it" is not asked, because it
//! cannot be answered honestly without a social cost.
//!
//! What comes out is a sentence a person can check against their own memory —
//! "completed 12 arrangements, on time 11 times" — rather than a score out of
//! five, which can only be resented.
//!
//! Three deliberate absences:
//!
//! * **No comments.** A free-text field is where the social cost comes back in.
//! * **No public negative.** A missed meeting lowers matching weight; it does
//!   not put a mark on someone's profile for the rest of their degree.
//! * **No penalty for being new.** Having no history is the normal state of a
//!   first-year in September, and a system that reads it as risk makes the
//!   community impossible to join.

use anyhow::Result;
use sqlx::{PgPool, Row};
use uuid::Uuid;

/// Below this many completed arrangements, the numbers are not yet evidence of
/// anything and are reported as such.
pub const MIN_FOR_A_TRACK_RECORD: i64 = 3;

/// What is known about someone, in facts.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct Reputation {
    /// Arrangements the other party confirmed happened.
    pub completed: i64,
    /// Of those, the ones they were on time for.
    pub on_time: i64,
    /// Arrangements the other party said did not happen.
    pub missed: i64,
    /// Whether there is enough here to mean anything yet. A newcomer is not
    /// untrustworthy; they are unmeasured, and the interface has to say which.
    pub has_track_record: bool,
}

impl Reputation {
    /// Weight for matching, 0..1.
    ///
    /// Someone with no history sits at neutral rather than at the bottom. A
    /// first-year in September has no track record and must not be sorted below
    /// everyone else for it — that is how a community becomes impossible to
    /// join.
    ///
    /// Missing an arrangement costs more than completing one earns, because
    /// the harm is asymmetric: somebody waited.
    pub fn matching_weight(&self) -> f64 {
        const NEUTRAL: f64 = 0.5;
        if !self.has_track_record {
            return NEUTRAL;
        }
        let total = self.completed + self.missed;
        if total == 0 {
            return NEUTRAL;
        }
        // Missed arrangements count double against the total.
        let good = self.completed as f64;
        let bad = (self.missed * 2) as f64;
        (good / (good + bad)).clamp(0.0, 1.0)
    }
}

pub struct ReputationService {
    db: PgPool,
}

impl ReputationService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    /// Record what happened, from one participant's side.
    ///
    /// Only a participant in a *settled* arrangement may answer, and only about
    /// the other person. Both sides answer independently; neither sees the
    /// other's answer, so nobody is answering in reaction.
    pub async fn confirm(
        &self,
        agreement_id: Uuid,
        confirmer_id: &str,
        happened: bool,
        on_time: Option<bool>,
    ) -> Result<bool> {
        // Punctuality is meaningless when nobody turned up, and demanding an
        // answer would manufacture data.
        let on_time = if happened { on_time } else { None };
        if happened && on_time.is_none() {
            anyhow::bail!("say whether they were on time");
        }

        let row = sqlx::query(
            "SELECT a.campus_id, a.status, c.initiator_id, c.recipient_id
             FROM agreements a
             JOIN chat_conversations c ON c.id = a.conversation_id
             WHERE a.id = $1 AND (c.initiator_id = $2 OR c.recipient_id = $2)",
        )
        .bind(agreement_id)
        .bind(confirmer_id)
        .fetch_optional(&self.db)
        .await?;
        let Some(row) = row else {
            return Ok(false);
        };

        let status: String = row.get("status");
        // Asking before anything was agreed would produce a record of a
        // handoff that was never arranged.
        if status != "settled" {
            return Ok(false);
        }

        let initiator: String = row.get("initiator_id");
        let recipient: String = row.get("recipient_id");
        let subject = if confirmer_id == initiator {
            recipient
        } else {
            initiator
        };

        let inserted = sqlx::query(
            "INSERT INTO handoff_confirmations (
                 campus_id, agreement_id, confirmer_id, subject_id, happened, on_time
             ) VALUES ($1, $2, $3, $4, $5, $6)
             ON CONFLICT (agreement_id, confirmer_id) DO NOTHING",
        )
        .bind(row.get::<Uuid, _>("campus_id"))
        .bind(agreement_id)
        .bind(confirmer_id)
        .bind(&subject)
        .bind(happened)
        .bind(on_time)
        .execute(&self.db)
        .await?;

        // A second answer is refused rather than overwriting: revising your
        // account after a disagreement is exactly what this must not allow.
        Ok(inserted.rows_affected() > 0)
    }

    /// What is known about someone on this campus.
    pub async fn of(&self, campus_id: Uuid, user_id: &str) -> Result<Reputation> {
        let row = sqlx::query(
            "SELECT
                 COUNT(*) FILTER (WHERE happened)                  AS completed,
                 COUNT(*) FILTER (WHERE happened AND on_time)      AS on_time,
                 COUNT(*) FILTER (WHERE NOT happened)              AS missed
             FROM handoff_confirmations
             WHERE campus_id = $1 AND subject_id = $2",
        )
        .bind(campus_id)
        .bind(user_id)
        .fetch_one(&self.db)
        .await?;

        let completed: i64 = row.get("completed");
        Ok(Reputation {
            completed,
            on_time: row.get("on_time"),
            missed: row.get("missed"),
            has_track_record: completed >= MIN_FOR_A_TRACK_RECORD,
        })
    }

    /// Whether this person still owes an answer about an arrangement.
    ///
    /// Used to prompt once, not to nag. The reputation of the other party
    /// depends on someone bothering to say what happened, and the prompt is the
    /// only reason they would.
    pub async fn awaiting_confirmation(&self, user_id: &str) -> Result<Vec<Uuid>> {
        let rows = sqlx::query(
            "SELECT a.id
             FROM agreements a
             JOIN chat_conversations c ON c.id = a.conversation_id
             WHERE a.status = 'settled'
               AND (c.initiator_id = $1 OR c.recipient_id = $1)
               AND NOT EXISTS (
                   SELECT 1 FROM handoff_confirmations h
                   WHERE h.agreement_id = a.id AND h.confirmer_id = $1
               )
             ORDER BY a.updated_at DESC
             LIMIT 20",
        )
        .bind(user_id)
        .fetch_all(&self.db)
        .await?;
        Ok(rows.into_iter().map(|row| row.get("id")).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reputation(completed: i64, on_time: i64, missed: i64) -> Reputation {
        Reputation {
            completed,
            on_time,
            missed,
            has_track_record: completed >= MIN_FOR_A_TRACK_RECORD,
        }
    }

    #[test]
    fn a_newcomer_sits_at_neutral_not_at_the_bottom() {
        // Having no history is the normal state of a first-year in September.
        // Sorting them below everyone would make the community impossible to
        // join, which is the opposite of what a reputation system is for.
        assert_eq!(reputation(0, 0, 0).matching_weight(), 0.5);
        assert!(!reputation(0, 0, 0).has_track_record);

        // And someone with one good handoff is still unmeasured rather than
        // proven.
        assert!(!reputation(1, 1, 0).has_track_record);
        assert_eq!(reputation(1, 1, 0).matching_weight(), 0.5);
    }

    #[test]
    fn a_reliable_record_ranks_above_neutral() {
        assert!(reputation(10, 10, 0).matching_weight() > 0.5);
        assert_eq!(reputation(10, 10, 0).matching_weight(), 1.0);
    }

    #[test]
    fn missing_an_arrangement_costs_more_than_keeping_one_earns() {
        // The harm is asymmetric: somebody waited. Equal weighting would let a
        // frequent no-show stay average by simply being busy.
        let mixed = reputation(8, 8, 2);
        assert!(mixed.matching_weight() < 8.0 / 10.0);

        // Half kept, half missed is well below neutral, not at it.
        assert!(reputation(5, 5, 5).matching_weight() < 0.5);
    }

    #[test]
    fn the_numbers_are_facts_a_person_could_dispute() {
        // "completed 12, on time 11" can be checked against a memory. A score
        // out of five can only be resented.
        let record = reputation(12, 11, 0);
        assert_eq!(record.completed, 12);
        assert_eq!(record.on_time, 11);
        assert!(record.has_track_record);
    }
}

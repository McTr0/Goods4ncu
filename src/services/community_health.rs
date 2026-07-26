//! Community health metrics.
//!
//! Why these and not the usual ones. `GET /api/stats` already reports totals —
//! listings, users, orders — and `DAU`, `messages sent` and `time spent` are
//! the obvious things to add next. They are also the wrong things to optimise:
//! chasing them turns a community into a feed, because a feed is the cheapest
//! way to make those numbers go up. None of them can distinguish a place where
//! people find each other from one where people scroll.
//!
//! So this module measures outcomes instead. A community's product is that
//! **people found each other**; a marketplace's is that **things actually
//! changed hands**. Both are countable:
//!
//! * Did anyone answer? Posting into silence is the first cause of death for a
//!   campus community, and it is invisible in an activity count — an ignored
//!   post and a useful one are both "one post".
//! * How much work was reaching an agreement? Fewer messages to settle
//!   what/when/where is the whole claim behind the assistant.
//! * Did the arrangement actually happen?
//! * Did strangers become people who interact again?
//! * Did newcomers get caught, or drift away?
//! * Is proactive outreach earning its interruptions?
//!
//! Every figure is campus-scoped, and relationship counts are aggregate only:
//! *how many* pairs, never *which*. Who talks to whom on a small campus is
//! sensitive, and an operational dashboard has no business exposing it.
//!
//! These are deliberately expensive, honest queries over the whole window
//! rather than counters, because they are read occasionally by operators, not
//! on every request.

use anyhow::Result;
use sqlx::{PgPool, Row};
use uuid::Uuid;

/// Did what people posted get answered, and how fast?
#[derive(Debug, Clone, serde::Serialize)]
pub struct IntentHealth {
    pub posted: i64,
    pub answered: i64,
    /// Share of posts that drew any response at all. The headline number: a
    /// community where this falls is dying whatever else rises.
    pub answer_rate: f64,
    /// Median wait for the first response, in minutes. Median, not mean, so a
    /// handful of week-old replies cannot flatter the typical experience.
    pub first_answer_p50_minutes: Option<f64>,
}

/// Did arrangements form, and what did they cost to reach?
#[derive(Debug, Clone, serde::Serialize)]
pub struct AgreementHealth {
    pub answered: i64,
    pub confirmed: i64,
    /// Of the posts someone responded to, how many became a real arrangement.
    /// The gap between this and `answer_rate` is where interest dies in
    /// negotiation.
    pub completion_rate: f64,
    /// Median messages exchanged before confirming. Directly measures whether
    /// interacting here is getting easier.
    pub messages_to_agreement_p50: Option<f64>,
}

/// Did strangers turn into people who deal with each other again?
#[derive(Debug, Clone, serde::Serialize)]
pub struct RelationshipHealth {
    /// Pairs whose first interaction fell in the window.
    pub first_met: i64,
    /// Of those, pairs that interacted more than once — the ones where
    /// something stuck. Aggregate only; the pairs themselves are never
    /// returned.
    pub interacted_again: i64,
    pub stickiness: f64,
}

/// Did newcomers get caught?
#[derive(Debug, Clone, serde::Serialize)]
pub struct NewcomerHealth {
    /// Accounts old enough for the question to be answerable.
    pub cohort: i64,
    pub still_active_after_a_week: i64,
    pub day7_retention: f64,
}

/// Is proactive outreach earning its interruptions?
#[derive(Debug, Clone, serde::Serialize)]
pub struct InterruptionHealth {
    pub delivered: i64,
    pub withheld: i64,
    pub accepted: i64,
    pub dismissed: i64,
    /// Accepted over *decided* — ignored ones are not counted as rejections,
    /// since not every notification demands an answer.
    pub acceptance_rate: Option<f64>,
    pub per_reached_user_per_day: Option<f64>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct CommunityHealth {
    pub window_days: i64,
    pub intent: IntentHealth,
    pub agreement: AgreementHealth,
    pub relationships: RelationshipHealth,
    pub newcomers: NewcomerHealth,
    pub interruptions: InterruptionHealth,
}

/// Guards against dividing by an empty window, which would report 0% where the
/// honest answer is "nothing happened yet".
fn rate(numerator: i64, denominator: i64) -> f64 {
    if denominator == 0 {
        0.0
    } else {
        numerator as f64 / denominator as f64
    }
}

pub struct CommunityHealthService {
    db: PgPool,
}

impl CommunityHealthService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    pub async fn measure(&self, campus_id: Uuid, window_days: i64) -> Result<CommunityHealth> {
        let window_days = window_days.clamp(1, 365);
        let (intent, agreement) = self.intent_and_agreement(campus_id, window_days).await?;
        Ok(CommunityHealth {
            window_days,
            intent,
            agreement,
            relationships: self.relationships(campus_id, window_days).await?,
            newcomers: self.newcomers(campus_id, window_days).await?,
            interruptions: self.interruptions(campus_id, window_days).await?,
        })
    }

    /// Answered-ness and agreement share a base — the set of posts and when
    /// each was first responded to — so they are computed together rather than
    /// deriving that set twice.
    async fn intent_and_agreement(
        &self,
        campus_id: Uuid,
        window_days: i64,
    ) -> Result<(IntentHealth, AgreementHealth)> {
        let row = sqlx::query(
            r#"
            WITH posted AS (
                SELECT id, created_at
                FROM inventory
                WHERE campus_id = $1
                  AND created_at >= NOW() - make_interval(days => $2::int)
            ),
            -- Any of the three ways someone can answer a post. A conversation
            -- opened about it, an item offered against a wanted post, or a
            -- price proposed — all are "somebody engaged".
            responses AS (
                SELECT listing_id, created_at FROM chat_conversations WHERE campus_id = $1
                UNION ALL
                SELECT wanted_listing_id, created_at FROM wanted_responses WHERE campus_id = $1
                UNION ALL
                SELECT listing_id, created_at FROM hitl_requests WHERE campus_id = $1
            ),
            first_answer AS (
                SELECT p.id,
                       p.created_at,
                       MIN(r.created_at) AS answered_at
                FROM posted p
                LEFT JOIN responses r
                       ON r.listing_id = p.id
                      AND r.created_at >= p.created_at
                GROUP BY p.id, p.created_at
            ),
            -- Restricted to posts that were answered: completion is about what
            -- happens after contact, so counting posts nobody replied to would
            -- fold the answer rate into it twice.
            settled AS (
                SELECT f.id,
                       EXISTS (
                           SELECT 1 FROM orders o
                           WHERE o.listing_id = f.id
                             AND o.campus_id = $1
                             AND o.status = 'confirmed'
                       ) AS confirmed
                FROM first_answer f
                WHERE f.answered_at IS NOT NULL
            ),
            -- Messages exchanged in the run-up to each confirmed arrangement.
            effort AS (
                SELECT o.listing_id, COUNT(m.id) AS messages
                FROM orders o
                JOIN chat_conversations c
                  ON c.listing_id = o.listing_id AND c.campus_id = $1
                JOIN chat_messages m
                  ON m.direct_conversation_id = c.id
                 AND m.timestamp <= COALESCE(o.confirmed_at, o.updated_at)
                WHERE o.campus_id = $1
                  AND o.status = 'confirmed'
                  AND COALESCE(o.confirmed_at, o.updated_at)
                      >= NOW() - make_interval(days => $2::int)
                GROUP BY o.listing_id
            )
            SELECT
                (SELECT COUNT(*) FROM first_answer)                              AS posted,
                (SELECT COUNT(answered_at) FROM first_answer)                    AS answered,
                (SELECT percentile_cont(0.5) WITHIN GROUP (
                            ORDER BY EXTRACT(EPOCH FROM (answered_at - created_at)) / 60.0)
                   FROM first_answer WHERE answered_at IS NOT NULL)              AS first_answer_p50,
                (SELECT COUNT(*) FILTER (WHERE confirmed) FROM settled)          AS confirmed,
                (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY messages)
                   FROM effort)                                                  AS messages_p50
            "#,
        )
        .bind(campus_id)
        .bind(window_days as i32)
        .fetch_one(&self.db)
        .await?;

        let posted: i64 = row.get("posted");
        let answered: i64 = row.get("answered");
        let confirmed: i64 = row.get("confirmed");

        Ok((
            IntentHealth {
                posted,
                answered,
                answer_rate: rate(answered, posted),
                first_answer_p50_minutes: row.get("first_answer_p50"),
            },
            AgreementHealth {
                answered,
                confirmed,
                completion_rate: rate(confirmed, answered),
                messages_to_agreement_p50: row.get("messages_p50"),
            },
        ))
    }

    async fn relationships(&self, campus_id: Uuid, window_days: i64) -> Result<RelationshipHealth> {
        let row = sqlx::query(
            r#"
            WITH touches AS (
                SELECT initiator_id AS a, recipient_id AS b, created_at
                  FROM chat_conversations WHERE campus_id = $1
                UNION ALL
                SELECT buyer_id, seller_id, created_at
                  FROM orders WHERE campus_id = $1
                UNION ALL
                SELECT responder_id, requester_id, created_at
                  FROM wanted_responses WHERE campus_id = $1
            ),
            -- LEAST/GREATEST makes the pair unordered, so A contacting B and B
            -- contacting A are recognised as the same relationship.
            pairs AS (
                SELECT LEAST(a, b) AS lo, GREATEST(a, b) AS hi, created_at
                FROM touches
                WHERE a IS NOT NULL AND b IS NOT NULL AND a <> b
            ),
            history AS (
                SELECT lo, hi, MIN(created_at) AS first_at, COUNT(*) AS touches
                FROM pairs GROUP BY lo, hi
            )
            SELECT
                COUNT(*) FILTER (
                    WHERE first_at >= NOW() - make_interval(days => $2::int)
                ) AS first_met,
                COUNT(*) FILTER (
                    WHERE first_at >= NOW() - make_interval(days => $2::int)
                      AND touches > 1
                ) AS interacted_again
            FROM history
            "#,
        )
        .bind(campus_id)
        .bind(window_days as i32)
        .fetch_one(&self.db)
        .await?;

        let first_met: i64 = row.get("first_met");
        let interacted_again: i64 = row.get("interacted_again");
        Ok(RelationshipHealth {
            first_met,
            interacted_again,
            stickiness: rate(interacted_again, first_met),
        })
    }

    async fn newcomers(&self, campus_id: Uuid, window_days: i64) -> Result<NewcomerHealth> {
        let row = sqlx::query(
            r#"
            -- Only accounts already older than a week can answer "were they
            -- still here after a week", so younger ones are excluded rather
            -- than counted as churned.
            WITH cohort AS (
                SELECT u.id, u.created_at
                FROM users u
                JOIN campus_memberships cm
                  ON cm.user_id = u.id AND cm.campus_id = $1
                WHERE u.created_at <  NOW() - interval '7 days'
                  AND u.created_at >= NOW() - make_interval(days => $2::int)
            ),
            -- chat_messages carries no campus column, but it is only joined to
            -- an already campus-scoped cohort, so this stays tenant-correct.
            activity AS (
                SELECT user_id, MAX(at) AS last_at FROM (
                    SELECT owner_id AS user_id, created_at AS at
                      FROM inventory WHERE campus_id = $1
                    UNION ALL
                    SELECT sender, timestamp FROM chat_messages
                    UNION ALL
                    SELECT buyer_id, created_at FROM orders WHERE campus_id = $1
                ) s
                WHERE user_id IS NOT NULL
                GROUP BY user_id
            )
            SELECT COUNT(*) AS cohort,
                   COUNT(*) FILTER (
                       WHERE a.last_at >= c.created_at + interval '7 days'
                   ) AS retained
            FROM cohort c
            LEFT JOIN activity a ON a.user_id = c.id
            "#,
        )
        .bind(campus_id)
        .bind(window_days as i32)
        .fetch_one(&self.db)
        .await?;

        let cohort: i64 = row.get("cohort");
        let retained: i64 = row.get("retained");
        Ok(NewcomerHealth {
            cohort,
            still_active_after_a_week: retained,
            day7_retention: rate(retained, cohort),
        })
    }

    async fn interruptions(&self, campus_id: Uuid, window_days: i64) -> Result<InterruptionHealth> {
        let row = sqlx::query(
            r#"
            SELECT
                COUNT(*) FILTER (WHERE delivered_at IS NOT NULL)   AS delivered,
                COUNT(*) FILTER (WHERE delivered_at IS NULL)       AS withheld,
                COUNT(*) FILTER (WHERE accepted_at IS NOT NULL)    AS accepted,
                COUNT(*) FILTER (WHERE dismissed_at IS NOT NULL)   AS dismissed,
                COUNT(DISTINCT user_id) FILTER (WHERE delivered_at IS NOT NULL)
                                                                   AS reached_users
            FROM interruption_ledger
            WHERE campus_id = $1
              AND created_at >= NOW() - make_interval(days => $2::int)
            "#,
        )
        .bind(campus_id)
        .bind(window_days as i32)
        .fetch_one(&self.db)
        .await?;

        let delivered: i64 = row.get("delivered");
        let accepted: i64 = row.get("accepted");
        let dismissed: i64 = row.get("dismissed");
        let reached_users: i64 = row.get("reached_users");

        let decided = accepted + dismissed;
        Ok(InterruptionHealth {
            delivered,
            withheld: row.get("withheld"),
            accepted,
            dismissed,
            acceptance_rate: (decided > 0).then(|| rate(accepted, decided)),
            per_reached_user_per_day: (reached_users > 0)
                .then(|| delivered as f64 / reached_users as f64 / window_days as f64),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_window_reports_zero_rather_than_dividing_by_nothing() {
        assert_eq!(rate(0, 0), 0.0);
        assert_eq!(rate(3, 4), 0.75);
    }
}

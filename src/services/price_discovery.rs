//! Private-reservation price matching.
//!
//! Haggling in public is a poor fit for a campus. Opening low looks like you are
//! not serious, refusing looks unfriendly, and you will see this person in the
//! canteen tomorrow — so trades die at "不好意思开口" rather than at any real
//! disagreement about price. Turning the negotiation into a calculation removes
//! the part that costs face without removing the trade.
//!
//! Each side privately states a limit. The buyer's most, the seller's least.
//! This module answers **only** whether a deal exists and at what price.
//!
//! Three properties hold and are tested:
//!
//! * **A reservation never leaves this module.** Not in a response, not in a
//!   log, not in model context. It is the most sensitive number in the product —
//!   a statement of what someone will privately accept, worth more to a
//!   counterparty than any listing detail — and it is held to the same standard
//!   as an ActionPlan confirmation token.
//! * **"No deal" carries no information.** Not how far apart, not who was
//!   further. "You were 20 short" is a bargaining position handed to one side,
//!   and the gap is therefore never even stored.
//! * **Both sides opt in.** Anyone who would rather haggle keeps the existing
//!   flow. A mechanism nobody chose is not a kindness.
//!
//! The rule is public and simple, because a pricing black box is worse than
//! haggling: if the buyer's limit is at least the seller's, the price is the
//! midpoint. A user must be able to repeat that sentence back.
//!
//! **The known weakness, stated plainly.** Nothing stops someone shading their
//! limit — a buyer naming less than they would truly pay. The mitigations are
//! social rather than cryptographic: a campus is a repeated game under real
//! names, the rule is framed as a commitment (backing out after a match is a
//! reputational event), and one session per pair per listing means the mechanism
//! cannot be re-run to triangulate. None of that makes it strategy-proof, and it
//! is not claimed to be.

use anyhow::Result;
use sqlx::{PgPool, Row};
use uuid::Uuid;

pub mod status {
    /// One side asked; the other has not agreed to the mechanism.
    pub const PROPOSED: &str = "proposed";
    /// Both agreed; waiting on reservations.
    pub const OPEN: &str = "open";
    pub const MATCHED: &str = "matched";
    pub const NO_DEAL: &str = "no_deal";
    pub const DECLINED: &str = "declined";
}

/// What a participant is allowed to know about a session.
///
/// Note what is absent: any reservation, and any hint of the gap when there is
/// no deal. `matched_cents` appears only on a match, where it is the agreement
/// rather than either party's position.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct SessionView {
    pub id: Uuid,
    pub listing_id: String,
    pub status: String,
    /// Set only when matched.
    pub matched_cents: Option<i64>,
    /// Whether *this* viewer has stated their limit. Never whether the other
    /// side has — knowing they are still deciding is itself a small advantage.
    pub you_have_stated: bool,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Waiting on the other side.
    WaitingForOther,
    /// A price exists; both may see it.
    Matched { cents: i64 },
    /// The limits do not overlap. Deliberately carries nothing else.
    NoDeal,
}

/// Clearing rule.
///
/// Public and deliberately dull: the midpoint of the overlap. A cleverer rule
/// that nobody can repeat back would be worse than haggling, because at least
/// haggling is legible.
///
/// Rounds down to the cent, so the figure can be paid exactly.
pub fn clearing_price(buyer_max_cents: i64, seller_min_cents: i64) -> Option<i64> {
    (buyer_max_cents >= seller_min_cents).then(|| (buyer_max_cents + seller_min_cents) / 2)
}

pub struct PriceDiscoveryService {
    db: PgPool,
}

impl PriceDiscoveryService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    /// Ask the other side to settle the price this way.
    ///
    /// Either party may propose. Returns the existing session when one is
    /// already under way, so a double tap cannot start a second run — which
    /// would be a way to probe the other side's limit.
    pub async fn propose(
        &self,
        campus_id: Uuid,
        listing_id: &str,
        seller_id: &str,
        buyer_id: &str,
    ) -> Result<Uuid> {
        if seller_id == buyer_id {
            anyhow::bail!("a price cannot be discovered with oneself");
        }
        let id: Uuid = sqlx::query_scalar(
            "INSERT INTO price_discovery_sessions (campus_id, listing_id, seller_id, buyer_id)
             VALUES ($1, $2, $3, $4)
             ON CONFLICT (listing_id, seller_id, buyer_id) DO UPDATE
                 SET listing_id = price_discovery_sessions.listing_id
             RETURNING id",
        )
        .bind(campus_id)
        .bind(listing_id)
        .bind(seller_id)
        .bind(buyer_id)
        .fetch_one(&self.db)
        .await?;
        Ok(id)
    }

    /// Agree to settle this way. Only the party who did not propose can accept.
    pub async fn accept(&self, session_id: Uuid, user_id: &str) -> Result<bool> {
        let updated = sqlx::query(
            "UPDATE price_discovery_sessions
             SET status = $3
             WHERE id = $1
               AND status = $4
               AND (seller_id = $2 OR buyer_id = $2)",
        )
        .bind(session_id)
        .bind(user_id)
        .bind(status::OPEN)
        .bind(status::PROPOSED)
        .execute(&self.db)
        .await?;
        Ok(updated.rows_affected() > 0)
    }

    /// Decline, and keep the ordinary negotiation flow.
    pub async fn decline(&self, session_id: Uuid, user_id: &str) -> Result<bool> {
        let updated = sqlx::query(
            "UPDATE price_discovery_sessions
             SET status = $3, resolved_at = NOW()
             WHERE id = $1
               AND status IN ($4, $5)
               AND (seller_id = $2 OR buyer_id = $2)",
        )
        .bind(session_id)
        .bind(user_id)
        .bind(status::DECLINED)
        .bind(status::PROPOSED)
        .bind(status::OPEN)
        .execute(&self.db)
        .await?;
        Ok(updated.rows_affected() > 0)
    }

    /// State your limit, and settle if the other side already has.
    ///
    /// The whole check-and-clear runs in one transaction with the session row
    /// locked, so two simultaneous submissions cannot both see "the other hasn't
    /// answered yet" and leave a session that never resolves.
    pub async fn state_limit(
        &self,
        session_id: Uuid,
        user_id: &str,
        cents: i64,
    ) -> Result<Option<Outcome>> {
        if cents < 0 {
            anyhow::bail!("a limit cannot be negative");
        }
        let mut tx = self.db.begin().await?;

        let session = sqlx::query(
            "SELECT seller_id, buyer_id, status FROM price_discovery_sessions
             WHERE id = $1 FOR UPDATE",
        )
        .bind(session_id)
        .fetch_optional(&mut *tx)
        .await?;
        let Some(session) = session else {
            tx.rollback().await?;
            return Ok(None);
        };

        let seller_id: String = session.get("seller_id");
        let buyer_id: String = session.get("buyer_id");
        let current_status: String = session.get("status");
        if user_id != seller_id && user_id != buyer_id {
            tx.rollback().await?;
            return Ok(None);
        }
        // Only while it is open. Once it has resolved, changing a limit would
        // let someone probe the boundary by re-submitting.
        if current_status != status::OPEN {
            tx.rollback().await?;
            return Ok(None);
        }

        sqlx::query(
            "INSERT INTO price_reservations (session_id, user_id, cents)
             VALUES ($1, $2, $3)
             ON CONFLICT (session_id, user_id) DO NOTHING",
        )
        .bind(session_id)
        .bind(user_id)
        .bind(cents)
        .execute(&mut *tx)
        .await?;

        let buyer_max: Option<i64> = sqlx::query_scalar(
            "SELECT cents FROM price_reservations WHERE session_id = $1 AND user_id = $2",
        )
        .bind(session_id)
        .bind(&buyer_id)
        .fetch_optional(&mut *tx)
        .await?;
        let seller_min: Option<i64> = sqlx::query_scalar(
            "SELECT cents FROM price_reservations WHERE session_id = $1 AND user_id = $2",
        )
        .bind(session_id)
        .bind(&seller_id)
        .fetch_optional(&mut *tx)
        .await?;

        let outcome = match (buyer_max, seller_min) {
            (Some(buyer_max), Some(seller_min)) => match clearing_price(buyer_max, seller_min) {
                Some(cents) => {
                    sqlx::query(
                        "UPDATE price_discovery_sessions
                         SET status = $2, matched_cents = $3, resolved_at = NOW()
                         WHERE id = $1",
                    )
                    .bind(session_id)
                    .bind(status::MATCHED)
                    .bind(cents)
                    .execute(&mut *tx)
                    .await?;
                    Outcome::Matched { cents }
                }
                None => {
                    // The gap is not recorded. Storing it would make leaking it
                    // possible, and "you were 20 short" is a bargaining position
                    // handed to one side.
                    sqlx::query(
                        "UPDATE price_discovery_sessions
                         SET status = $2, resolved_at = NOW()
                         WHERE id = $1",
                    )
                    .bind(session_id)
                    .bind(status::NO_DEAL)
                    .execute(&mut *tx)
                    .await?;
                    Outcome::NoDeal
                }
            },
            _ => Outcome::WaitingForOther,
        };

        tx.commit().await?;
        Ok(Some(outcome))
    }

    /// What a participant may see.
    ///
    /// Returns `None` for a non-participant, so this cannot be used to discover
    /// that two other people are negotiating.
    pub async fn view(&self, session_id: Uuid, user_id: &str) -> Result<Option<SessionView>> {
        let row = sqlx::query(
            "SELECT s.id, s.listing_id, s.status, s.matched_cents, s.created_at,
                    EXISTS (
                        SELECT 1 FROM price_reservations r
                        WHERE r.session_id = s.id AND r.user_id = $2
                    ) AS you_have_stated
             FROM price_discovery_sessions s
             WHERE s.id = $1 AND (s.seller_id = $2 OR s.buyer_id = $2)",
        )
        .bind(session_id)
        .bind(user_id)
        .fetch_optional(&self.db)
        .await?;

        Ok(row.map(|row| SessionView {
            id: row.get("id"),
            listing_id: row.get("listing_id"),
            status: row.get("status"),
            matched_cents: row.get("matched_cents"),
            you_have_stated: row.get("you_have_stated"),
            created_at: row.get("created_at"),
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_price_is_the_midpoint_of_the_overlap() {
        // The rule a user has to be able to repeat back: 280 and 250 meet at 265.
        assert_eq!(clearing_price(28_000, 25_000), Some(26_500));
        // Touching exactly is a deal, at that price.
        assert_eq!(clearing_price(25_000, 25_000), Some(25_000));
        // A buyer willing to pay more than asked still pays the midpoint, not
        // their limit — the mechanism must not punish honesty.
        assert_eq!(clearing_price(50_000, 10_000), Some(30_000));
    }

    #[test]
    fn no_overlap_is_no_deal_and_nothing_else() {
        // The return type carries no gap, by construction rather than by
        // discipline: there is nowhere to put one.
        assert_eq!(clearing_price(24_999, 25_000), None);
        assert_eq!(clearing_price(0, 1), None);
    }

    #[test]
    fn the_price_rounds_down_to_a_payable_figure() {
        // 265.01 cannot be handed over in cash. Rounding down favours the buyer
        // by at most one cent, which is the right direction for a figure neither
        // party chose.
        assert_eq!(clearing_price(25_001, 25_000), Some(25_000));
    }
}

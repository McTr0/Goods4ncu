//! The living state of an arrangement.
//!
//! Two people settle a trade over thirty messages, and afterwards "how much,
//! when, where" is scattered through them. IM's data model is a stream; the
//! truth of an arrangement is a consensus that gradually forms. Carrying the
//! second in the first makes every participant run the state machine in their
//! own head and scroll back to check.
//!
//! So the arrangement is the record, and messages annotate it.
//!
//! The safety property, and the reason this is not just a convenience: **an
//! assistant proposal is not the plan until a person adopts it.** A term the
//! model extracted lands with nobody having agreed to it, and it stays that way
//! until someone says yes. An extraction that misreads 周三下午 therefore costs a
//! glance, not a missed meeting — which is what makes it safe to attempt
//! extraction at all.
//!
//! The second rule follows from the first: **changing a term withdraws the
//! agreement to it.** Consent was to the old value. Carrying it forward would
//! let one party edit the price under the other's existing yes, which is worse
//! than any misreading.

use anyhow::Result;
use sqlx::{PgPool, Row};
use uuid::Uuid;

/// Who a term came from, when it was the assistant rather than a person.
pub const ASSISTANT: &str = "assistant";

pub mod slots {
    pub const ITEM: &str = "item";
    pub const PRICE: &str = "price";
    pub const TIME: &str = "time";
    pub const PLACE: &str = "place";
    pub const WHO: &str = "who";
    pub const BRING: &str = "bring";
    pub const CONDITIONS: &str = "conditions";

    /// The slots a trade uses.
    pub const DEAL: &[&str] = &[ITEM, PRICE, TIME, PLACE, CONDITIONS];
    /// The slots a meetup uses. No price: pricing a game of badminton is a
    /// category error.
    pub const MEETUP: &[&str] = &[ITEM, TIME, PLACE, WHO, BRING];

    pub fn valid_for(kind: &str, slot: &str) -> bool {
        match kind {
            "deal" => DEAL.contains(&slot),
            "meetup" => MEETUP.contains(&slot),
            _ => false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct Term {
    pub slot: String,
    pub value: String,
    pub value_cents: Option<i64>,
    pub proposed_by: String,
    pub agreed_by: Vec<String>,
    pub source_message_id: Option<i64>,
    /// An extraction nobody has confirmed. Serialised because the client has to
    /// render it as a suggestion rather than as the arrangement — a proposal
    /// that looks like a decision is the whole failure mode this guards.
    #[serde(rename = "is_suggestion")]
    pub suggestion: bool,
}

impl Term {
    /// Whether everyone in the arrangement has said yes to this value.
    pub fn is_settled(&self, participants: &[String]) -> bool {
        participants.iter().all(|p| self.agreed_by.contains(p))
    }
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct AgreementView {
    pub id: Uuid,
    pub conversation_id: Uuid,
    pub kind: String,
    pub status: String,
    pub terms: Vec<Term>,
    /// Whose agreement counts, so a client can render "waiting on them".
    pub participants: Vec<String>,
}

impl AgreementView {
    /// Whether every term both sides need is agreed by everyone.
    ///
    /// Terms nobody has proposed are not "disagreed"; an arrangement without a
    /// stated `bring` is still complete. Only what is on the card has to be
    /// settled.
    pub fn is_fully_agreed(&self) -> bool {
        !self.terms.is_empty()
            && self
                .terms
                .iter()
                .all(|term| term.is_settled(&self.participants))
    }
}

pub struct AgreementService {
    db: PgPool,
}

impl AgreementService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    pub async fn user_participates_in_conversation(
        &self,
        conversation_id: Uuid,
        campus_id: Uuid,
        user_id: &str,
    ) -> Result<bool> {
        let participates: bool = sqlx::query_scalar(
            "SELECT EXISTS (
                 SELECT 1 FROM chat_conversations
                 WHERE id = $1 AND campus_id = $2 AND (initiator_id = $3 OR recipient_id = $3)
             )",
        )
        .bind(conversation_id)
        .bind(campus_id)
        .bind(user_id)
        .fetch_one(&self.db)
        .await?;
        Ok(participates)
    }

    /// The card for a conversation, creating it on first use.
    ///
    /// Idempotent: two clients opening the same conversation must not produce two
    /// cards, which would recreate the problem of a second place to look.
    pub async fn ensure_for_conversation(
        &self,
        campus_id: Uuid,
        conversation_id: Uuid,
        kind: &str,
    ) -> Result<Uuid> {
        if kind != "deal" && kind != "meetup" {
            anyhow::bail!("unknown agreement kind: {}", kind);
        }
        let id: Uuid = sqlx::query_scalar(
            "INSERT INTO agreements (campus_id, conversation_id, kind)
             VALUES ($1, $2, $3)
             ON CONFLICT (conversation_id) DO UPDATE
                 SET updated_at = agreements.updated_at
             RETURNING id",
        )
        .bind(campus_id)
        .bind(conversation_id)
        .bind(kind)
        .fetch_one(&self.db)
        .await?;
        Ok(id)
    }

    /// Record a term, and who agrees to it so far.
    ///
    /// A person stating a term agrees to it by saying it. The assistant does not:
    /// its proposals land unconfirmed, which is the property that makes
    /// extraction safe to attempt.
    ///
    /// Re-stating a term replaces the value and resets agreement to the proposer
    /// alone, because consent was to the old value.
    pub async fn set_term(
        &self,
        agreement_id: Uuid,
        slot: &str,
        value: &str,
        value_cents: Option<i64>,
        proposed_by: &str,
        source_message_id: Option<i64>,
    ) -> Result<bool> {
        let value = value.trim();
        if value.is_empty() {
            anyhow::bail!("a term needs a value");
        }
        let kind: Option<String> = sqlx::query_scalar("SELECT kind FROM agreements WHERE id = $1")
            .bind(agreement_id)
            .fetch_optional(&self.db)
            .await?;
        let Some(kind) = kind else {
            return Ok(false);
        };
        if !slots::valid_for(&kind, slot) {
            anyhow::bail!("slot '{}' does not apply to a {}", slot, kind);
        }

        // A person agrees to what they themselves proposed; the assistant never
        // does.
        let agreed: Vec<String> = if proposed_by == ASSISTANT {
            Vec::new()
        } else {
            vec![proposed_by.to_string()]
        };

        sqlx::query(
            "INSERT INTO agreement_terms (
                 agreement_id, slot, value, value_cents, proposed_by, agreed_by,
                 source_message_id
             ) VALUES ($1, $2, $3, $4, $5, $6, $7)
             ON CONFLICT (agreement_id, slot) DO UPDATE
                 SET value = EXCLUDED.value,
                     value_cents = EXCLUDED.value_cents,
                     proposed_by = EXCLUDED.proposed_by,
                     -- Reset, not merged: agreement was to the old value.
                     agreed_by = EXCLUDED.agreed_by,
                     source_message_id = EXCLUDED.source_message_id,
                     updated_at = NOW()",
        )
        .bind(agreement_id)
        .bind(slot)
        .bind(value)
        .bind(value_cents)
        .bind(proposed_by)
        .bind(&agreed)
        .bind(source_message_id)
        .execute(&self.db)
        .await?;

        sqlx::query("UPDATE agreements SET updated_at = NOW() WHERE id = $1")
            .bind(agreement_id)
            .execute(&self.db)
            .await?;
        Ok(true)
    }

    /// Say yes to a term as it currently stands.
    ///
    /// The value is passed in and checked, so adopting cannot land on something
    /// that changed while the card was on screen — the classic "I agreed to 300
    /// and it says 350" failure.
    pub async fn adopt_term(
        &self,
        agreement_id: Uuid,
        slot: &str,
        user_id: &str,
        expected_value: &str,
    ) -> Result<bool> {
        let updated = sqlx::query(
            "UPDATE agreement_terms
             SET agreed_by = CASE
                     WHEN $3 = ANY(agreed_by) THEN agreed_by
                     ELSE array_append(agreed_by, $3)
                 END,
                 updated_at = NOW()
             WHERE agreement_id = $1 AND slot = $2 AND value = $4",
        )
        .bind(agreement_id)
        .bind(slot)
        .bind(user_id)
        .bind(expected_value.trim())
        .execute(&self.db)
        .await?;
        Ok(updated.rows_affected() > 0)
    }

    /// The card, as a participant sees it.
    ///
    /// Returns `None` for someone outside the conversation.
    pub async fn view(&self, agreement_id: Uuid, user_id: &str) -> Result<Option<AgreementView>> {
        let row = sqlx::query(
            "SELECT a.id, a.conversation_id, a.kind, a.status,
                    c.initiator_id, c.recipient_id
             FROM agreements a
             JOIN chat_conversations c ON c.id = a.conversation_id
             WHERE a.id = $1 AND (c.initiator_id = $2 OR c.recipient_id = $2)",
        )
        .bind(agreement_id)
        .bind(user_id)
        .fetch_optional(&self.db)
        .await?;
        let Some(row) = row else {
            return Ok(None);
        };

        let terms = sqlx::query(
            "SELECT slot, value, value_cents, proposed_by, agreed_by, source_message_id
             FROM agreement_terms WHERE agreement_id = $1 ORDER BY slot",
        )
        .bind(agreement_id)
        .fetch_all(&self.db)
        .await?;

        Ok(Some(AgreementView {
            id: row.get("id"),
            conversation_id: row.get("conversation_id"),
            kind: row.get("kind"),
            status: row.get("status"),
            participants: vec![row.get("initiator_id"), row.get("recipient_id")],
            terms: terms
                .into_iter()
                .map(|term| {
                    let proposed_by: String = term.get("proposed_by");
                    let agreed_by: Vec<String> = term.get("agreed_by");
                    Term {
                        suggestion: proposed_by == ASSISTANT && agreed_by.is_empty(),
                        proposed_by,
                        agreed_by,
                        slot: term.get("slot"),
                        value: term.get("value"),
                        value_cents: term.get("value_cents"),
                        source_message_id: term.get("source_message_id"),
                    }
                })
                .collect(),
        }))
    }

    /// Mark the arrangement settled.
    ///
    /// Refuses while any term on the card is still unagreed, so "settled" cannot
    /// mean "one of us decided". Returns false rather than erroring, because the
    /// caller's job is to show what is still outstanding.
    pub async fn settle(&self, agreement_id: Uuid, user_id: &str) -> Result<bool> {
        let Some(view) = self.view(agreement_id, user_id).await? else {
            return Ok(false);
        };
        if !view.is_fully_agreed() {
            return Ok(false);
        }
        let updated = sqlx::query(
            "UPDATE agreements SET status = 'settled', updated_at = NOW()
             WHERE id = $1 AND status = 'forming'",
        )
        .bind(agreement_id)
        .execute(&self.db)
        .await?;
        Ok(updated.rows_affected() > 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn term(slot: &str, proposed_by: &str, agreed_by: &[&str]) -> Term {
        Term {
            slot: slot.to_string(),
            value: "周三下午".to_string(),
            value_cents: None,
            suggestion: proposed_by == ASSISTANT && agreed_by.is_empty(),
            proposed_by: proposed_by.to_string(),
            agreed_by: agreed_by.iter().map(|s| s.to_string()).collect(),
            source_message_id: None,
        }
    }

    #[test]
    fn an_assistant_proposal_is_not_the_plan() {
        // The safety property. An extraction that misread the conversation must
        // read as a suggestion, so it costs a glance rather than a missed
        // meeting.
        let proposal = term(slots::TIME, ASSISTANT, &[]);
        assert!(proposal.suggestion);
        assert!(!proposal.is_settled(&["a".to_string(), "b".to_string()]));

        // Once somebody adopts it, it stops being a suggestion.
        assert!(!term(slots::TIME, ASSISTANT, &["a"]).suggestion);
    }

    #[test]
    fn a_term_is_settled_only_when_everyone_has_said_yes() {
        let participants = vec!["a".to_string(), "b".to_string()];
        assert!(!term(slots::PRICE, "a", &["a"]).is_settled(&participants));
        assert!(term(slots::PRICE, "a", &["a", "b"]).is_settled(&participants));
    }

    #[test]
    fn slots_do_not_cross_between_kinds() {
        // Pricing a game of badminton is a category error, and offering the field
        // invites it.
        assert!(slots::valid_for("deal", slots::PRICE));
        assert!(!slots::valid_for("meetup", slots::PRICE));
        assert!(slots::valid_for("meetup", slots::BRING));
        assert!(!slots::valid_for("deal", slots::BRING));
        assert!(!slots::valid_for("gossip", slots::TIME));
    }

    #[test]
    fn an_empty_card_is_not_fully_agreed() {
        // Otherwise a conversation with no terms would report itself settled,
        // which is the opposite of true.
        let view = AgreementView {
            id: Uuid::nil(),
            conversation_id: Uuid::nil(),
            kind: "deal".to_string(),
            status: "forming".to_string(),
            terms: vec![],
            participants: vec!["a".to_string(), "b".to_string()],
        };
        assert!(!view.is_fully_agreed());
    }
}

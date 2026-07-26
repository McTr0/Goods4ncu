//! Forming spaces from intent density, and letting them die.
//!
//! Preset boards assume rooms first and people later. On one campus that
//! cannot work: a niche interest has ten or twenty active people, and spread
//! across rooms nobody enters, every room shows a last message from three weeks
//! ago. Whoever looks in once does not come back, and creating more rooms
//! creates more of that. It is the unanswered-post problem wearing a different
//! hat — the demand is there, the container never finds it.
//!
//! So a space here is a consequence. Enough people want the same thing at the
//! same time, so they are put in a room together, told why, and the room goes
//! away when the thing is over. Nobody has to know which group to join.
//!
//! Three judgements carry the design:
//!
//! * **Too few is worse than none.** Three people who each wanted a badminton
//!   partner is a game; one person in a room is a rejection with extra steps.
//!   Below the floor, nothing forms and the intent keeps waiting.
//! * **Too many is also worse.** Past a dozen, nobody feels responsible for
//!   turning up, which is how group chats become noise.
//! * **Repeatedly grouping the same people is a harm, not an optimisation.**
//!   Similarity-based grouping hands the same clique to each other, and on a
//!   campus that hardens divisions — by department, by home province — that
//!   already exist. Overlap is checked before forming, and refused.
//!
//! Clustering runs on the fast path: shared subject tokens plus slot
//! compatibility, no model call. That is not a placeholder. Formation decides
//! who is put in a room with whom, so it should keep working when the LLM is
//! down, and a rule anyone can read is easier to answer for than an embedding.

use anyhow::Result;
use sqlx::{PgPool, Row};
use uuid::Uuid;

use crate::services::intent::Intent;

/// Below this, a space is a disappointment rather than a group.
pub const MIN_MEMBERS: usize = 3;
/// Past this, nobody feels responsible for showing up.
pub const MAX_MEMBERS: usize = 12;
/// How far back intents are considered together. A need from last month is not
/// the same occasion as one from this morning.
pub const WINDOW_HOURS: i64 = 72;
/// How long a formed space is expected to matter, absent anything keeping it
/// alive.
pub const DEFAULT_LIFESPAN_DAYS: i64 = 14;
/// A pair grouped this often already has whatever connection they were going to
/// get; forming around them again is how a clique hardens.
pub const MAX_REPEAT_PAIRINGS: i64 = 3;
/// Share of a candidate group that may already be well-connected to each other
/// before formation is refused.
pub const MAX_FAMILIAR_PAIR_SHARE: f64 = 0.5;

#[derive(Debug, Clone)]
pub struct FormedSpace {
    pub space_id: Uuid,
    pub name: String,
    pub purpose: String,
    pub formation_reason: String,
    pub members: Vec<String>,
    pub source_intents: Vec<Uuid>,
}

/// Why a candidate group was not turned into a space. Recorded rather than
/// silently dropped: "we found nothing" and "we found something and refused it"
/// are different facts, and only one of them is a reason to change the rules.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Declined {
    /// Fewer than [`MIN_MEMBERS`] distinct people.
    TooFew { found: usize },
    /// Would mostly re-group people already repeatedly grouped together.
    TooFamiliar { familiar_share_percent: u32 },
}

pub struct AggregationService {
    db: PgPool,
}

impl AggregationService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    /// Look for groups worth forming in one intent kind, and form them.
    pub async fn form_spaces(
        &self,
        campus_id: Uuid,
        kind: &str,
    ) -> Result<(Vec<FormedSpace>, Vec<Declined>)> {
        let intents = self.recent_unassigned(campus_id, kind).await?;
        let clusters = cluster_by_subject(&intents);

        let mut formed = Vec::new();
        let mut declined = Vec::new();
        for cluster in clusters {
            match self.try_form(campus_id, kind, &cluster).await? {
                Ok(space) => formed.push(space),
                Err(reason) => declined.push(reason),
            }
        }
        Ok((formed, declined))
    }

    /// Active intents in the window that no space has already been built from.
    ///
    /// Excluding already-used intents is what stops the sweep re-forming the
    /// same room every hour.
    async fn recent_unassigned(&self, campus_id: Uuid, kind: &str) -> Result<Vec<Intent>> {
        let rows = sqlx::query(
            "SELECT i.id, i.kind, i.raw_input, i.slots, i.confidence, i.status,
                    i.visibility, i.valid_until, i.projected_listing_id, i.created_at,
                    i.author_id
             FROM intents i
             WHERE i.campus_id = $1
               AND i.kind = $2
               AND i.status = 'active'
               AND i.visibility = 'campus'
               AND (i.valid_until IS NULL OR i.valid_until > NOW())
               AND i.created_at >= NOW() - make_interval(hours => $3::int)
               AND NOT EXISTS (
                   SELECT 1 FROM space_formation_sources s WHERE s.intent_id = i.id
               )
             ORDER BY i.created_at DESC
             LIMIT 500",
        )
        .bind(campus_id)
        .bind(kind)
        .bind(WINDOW_HOURS as i32)
        .fetch_all(&self.db)
        .await?;

        Ok(rows
            .into_iter()
            .map(|row| Intent {
                id: row.get("id"),
                kind: row.get("kind"),
                raw_input: row.get("raw_input"),
                slots: serde_json::from_value(row.get("slots")).unwrap_or_default(),
                confidence: row.get("confidence"),
                status: row.get("status"),
                visibility: row.get("visibility"),
                valid_until: row.get("valid_until"),
                projected_listing_id: row.get("projected_listing_id"),
                created_at: row.get("created_at"),
                author_id: row.get("author_id"),
            })
            .collect())
    }

    /// Attempt one cluster. `Ok(Err(_))` means "found a group and declined it".
    async fn try_form(
        &self,
        campus_id: Uuid,
        kind: &str,
        cluster: &Cluster,
    ) -> Result<std::result::Result<FormedSpace, Declined>> {
        let mut members: Vec<String> = cluster
            .intents
            .iter()
            .filter_map(|i| i.author_id.clone())
            .collect();
        members.sort();
        members.dedup();

        if members.len() < MIN_MEMBERS {
            return Ok(Err(Declined::TooFew {
                found: members.len(),
            }));
        }
        // A crowd dilutes responsibility, so the earliest askers are taken and
        // the rest keep waiting for the next round rather than being dropped.
        members.truncate(MAX_MEMBERS);

        let familiar_share = self.familiar_share(campus_id, &members).await?;
        if familiar_share > MAX_FAMILIAR_PAIR_SHARE {
            return Ok(Err(Declined::TooFamiliar {
                familiar_share_percent: (familiar_share * 100.0).round() as u32,
            }));
        }

        let subject = cluster.label.clone();
        let name = space_name(&subject);
        let purpose = format!("因为大家都在找「{}」而临时建立", subject);
        let formation_reason = format!(
            "最近 {} 小时里有 {} 位同学提到「{}」，所以把你们放到了一起",
            WINDOW_HOURS,
            members.len(),
            subject
        );

        let mut tx = self.db.begin().await?;
        let space_id: Uuid = sqlx::query_scalar(
            "INSERT INTO chat_spaces (campus_id, kind, name, description, owner_id, status,
                                      origin, purpose, formation_reason, source_intent_kind,
                                      expires_at)
             VALUES ($1, 'group', $2, $3, $4, 'active', 'ai_formed', $3, $5, $6,
                     NOW() + make_interval(days => $7::int))
             RETURNING id",
        )
        .bind(campus_id)
        .bind(&name)
        .bind(&purpose)
        // Owned by the earliest asker rather than nobody: a space with no owner
        // has no one who can rename or close it.
        .bind(&members[0])
        .bind(&formation_reason)
        .bind(kind)
        .bind(DEFAULT_LIFESPAN_DAYS as i32)
        .fetch_one(&mut *tx)
        .await?;

        for member in &members {
            sqlx::query(
                "INSERT INTO chat_space_members (space_id, user_id, role)
                 VALUES ($1, $2, $3)
                 ON CONFLICT DO NOTHING",
            )
            .bind(space_id)
            .bind(member)
            .bind(if member == &members[0] {
                "owner"
            } else {
                "member"
            })
            .execute(&mut *tx)
            .await?;
        }

        let source_intents: Vec<Uuid> = cluster.intents.iter().map(|i| i.id).collect();
        for intent_id in &source_intents {
            sqlx::query(
                "INSERT INTO space_formation_sources (space_id, intent_id)
                 VALUES ($1, $2) ON CONFLICT DO NOTHING",
            )
            .bind(space_id)
            .bind(intent_id)
            .execute(&mut *tx)
            .await?;
        }

        // Record every pairing this formation creates, so the next one can see
        // how much of a clique it would be reinforcing.
        for (index, a) in members.iter().enumerate() {
            for b in members.iter().skip(index + 1) {
                let (lo, hi) = if a < b { (a, b) } else { (b, a) };
                sqlx::query(
                    "INSERT INTO space_formation_pairs (campus_id, lo_user, hi_user)
                     VALUES ($1, $2, $3)
                     ON CONFLICT (campus_id, lo_user, hi_user)
                     DO UPDATE SET times = space_formation_pairs.times + 1, last_at = NOW()",
                )
                .bind(campus_id)
                .bind(lo)
                .bind(hi)
                .execute(&mut *tx)
                .await?;
            }
        }
        tx.commit().await?;

        Ok(Ok(FormedSpace {
            space_id,
            name,
            purpose,
            formation_reason,
            members,
            source_intents,
        }))
    }

    /// Share of pairs in this group that have already been grouped together
    /// [`MAX_REPEAT_PAIRINGS`] times or more.
    async fn familiar_share(&self, campus_id: Uuid, members: &[String]) -> Result<f64> {
        let total_pairs = members.len() * (members.len() - 1) / 2;
        if total_pairs == 0 {
            return Ok(0.0);
        }
        let familiar: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM space_formation_pairs
             WHERE campus_id = $1
               AND lo_user = ANY($2)
               AND hi_user = ANY($2)
               AND times >= $3",
        )
        .bind(campus_id)
        .bind(members)
        .bind(MAX_REPEAT_PAIRINGS)
        .fetch_one(&self.db)
        .await?;
        Ok(familiar as f64 / total_pairs as f64)
    }

    /// Archive spaces whose reason for existing is spent.
    ///
    /// Two ways that happens: the expected lifespan ran out, or every intent
    /// the space was built from is done — fulfilled, withdrawn or expired. The
    /// second is the interesting one: the game was played, so the room for
    /// arranging it has no further job.
    ///
    /// Manually created spaces are never touched. Someone made those on
    /// purpose, and the archive rules here are about cleaning up after
    /// automated guesses.
    pub async fn archive_spent(&self) -> Result<u64> {
        let expired = sqlx::query(
            "UPDATE chat_spaces
             SET status = 'archived', archived_at = NOW(), archive_reason = 'lifespan_elapsed',
                 updated_at = NOW()
             WHERE status = 'active'
               AND origin = 'ai_formed'
               AND expires_at IS NOT NULL
               AND expires_at <= NOW()",
        )
        .execute(&self.db)
        .await?;

        let spent = sqlx::query(
            "UPDATE chat_spaces s
             SET status = 'archived', archived_at = NOW(), archive_reason = 'purpose_served',
                 updated_at = NOW()
             WHERE s.status = 'active'
               AND s.origin = 'ai_formed'
               AND EXISTS (
                   SELECT 1 FROM space_formation_sources src WHERE src.space_id = s.id
               )
               AND NOT EXISTS (
                   SELECT 1
                   FROM space_formation_sources src
                   JOIN intents i ON i.id = src.intent_id
                   WHERE src.space_id = s.id AND i.status = 'active'
               )",
        )
        .execute(&self.db)
        .await?;

        Ok(expired.rows_affected() + spent.rows_affected())
    }

    /// A member's view of why they are in a space.
    pub async fn explain(&self, user_id: &str, space_id: Uuid) -> Result<Option<String>> {
        let reason: Option<String> = sqlx::query_scalar(
            "SELECT s.formation_reason
             FROM chat_spaces s
             JOIN chat_space_members m ON m.space_id = s.id AND m.user_id = $2
             WHERE s.id = $1",
        )
        .bind(space_id)
        .bind(user_id)
        .fetch_optional(&self.db)
        .await?
        .flatten();
        Ok(reason)
    }
}

/// A group of intents that appear to be about the same thing.
#[derive(Debug)]
pub struct Cluster {
    pub label: String,
    pub intents: Vec<Intent>,
}

/// Group intents by shared subject tokens, keeping only mutually compatible
/// ones.
///
/// Deliberately simple and readable. Formation puts named people in a room
/// together, so the rule should survive an LLM outage and should be explainable
/// to whoever asks why they were included.
pub fn cluster_by_subject(intents: &[Intent]) -> Vec<Cluster> {
    use std::collections::BTreeMap;

    let mut buckets: BTreeMap<String, Vec<Intent>> = BTreeMap::new();
    for intent in intents {
        let Some(token) = leading_token(intent) else {
            continue;
        };
        buckets.entry(token).or_default().push(intent.clone());
    }

    buckets
        .into_iter()
        .filter_map(|(label, candidates)| {
            largest_compatible_set(candidates).map(|intents| Cluster { label, intents })
        })
        .collect()
}

/// The biggest subset of a bucket whose members do not contradict each other.
///
/// Same subject is not the same occasion: "any evening this week" and "Tuesday
/// 3pm" belong together, "Saturday morning" and "Sunday night" do not.
///
/// Taking the *largest* subset rather than the first one that fits matters more
/// than it looks. A single greedy pass keeps whichever intent it happens to see
/// first and discards everything that clashes with it, so one outlier — posted
/// most recently, say — can shut out a group of five who all agree with each
/// other. Trying each intent as a seed and keeping the best result costs a
/// quadratic pass over a bucket of a few dozen, and stops the room being
/// decided by posting order.
///
/// Ties go to the earliest asker, so repeated sweeps are stable and someone who
/// spoke up first is not passed over.
fn largest_compatible_set(mut candidates: Vec<Intent>) -> Option<Vec<Intent>> {
    if candidates.is_empty() {
        return None;
    }
    candidates.sort_by_key(|intent| intent.created_at);

    let mut best: Vec<Intent> = Vec::new();
    for seed in 0..candidates.len() {
        let mut kept = vec![candidates[seed].clone()];
        for (index, candidate) in candidates.iter().enumerate() {
            if index == seed {
                continue;
            }
            if kept
                .iter()
                .all(|k| k.slots.compatible_with(&candidate.slots))
            {
                kept.push(candidate.clone());
            }
        }
        // Strictly greater, so the earliest viable seed wins a tie.
        if kept.len() > best.len() {
            best = kept;
        }
    }
    (!best.is_empty()).then_some(best)
}

/// The word a cluster is keyed on.
///
/// The stated subject when there is one, otherwise the longest run of CJK or
/// alphanumeric characters in what they wrote — a crude stand-in for "what this
/// is about" that costs nothing and is wrong in obvious rather than subtle ways.
fn leading_token(intent: &Intent) -> Option<String> {
    if let Some(subject) = intent
        .slots
        .subject
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        return Some(subject.to_string());
    }
    intent
        .raw_input
        .split(|c: char| !c.is_alphanumeric())
        .filter(|s| s.chars().count() >= 2)
        .max_by_key(|s| s.chars().count())
        .map(str::to_string)
}

fn space_name(subject: &str) -> String {
    let trimmed: String = subject.chars().take(60).collect();
    format!("{}·临时", trimmed)
}

/// Tell the members a space formed, through the interruption budget.
///
/// Budgeted deliberately. A formed space is useful but skippable, and formation
/// runs hourly across every kind — exactly the shape of thing that becomes a
/// nuisance if it can notify freely. Over budget the message still reaches the
/// inbox, so nobody is left in a room they were never told about.
///
/// The notification carries `formation_reason` verbatim, because an automated
/// decision that put someone in a room with named people has to be able to say
/// why.
pub async fn notify_members(db_pool: &PgPool, campus_id: Uuid, space: &FormedSpace) {
    use crate::services::interruption::{topics, InterruptionRequest, InterruptionService};
    use crate::services::notification::{NewNotification, NotificationService};

    let interruptions = InterruptionService::new(db_pool.clone());
    let notifications = NotificationService::new(db_pool.clone());
    let space_id = space.space_id.to_string();

    for member in &space.members {
        let decision = match interruptions
            .request(InterruptionRequest {
                campus_id,
                user_id: member,
                channel: "in_app",
                topic: topics::SPACE_FORMED,
                reason: &space.formation_reason,
                // Being introduced to people who want the same thing is close to
                // the most useful unprompted thing this product can say.
                expected_value: 0.75,
            })
            .await
        {
            Ok(decision) => decision,
            Err(e) => {
                tracing::warn!(%e, %space_id, "interruption budget check failed");
                crate::services::interruption::Decision::Unavailable
            }
        };

        if let Err(e) = notifications
            .create_budgeted(
                &decision,
                NewNotification {
                    campus_id,
                    user_id: member,
                    event_type: topics::SPACE_FORMED,
                    title: &space.name,
                    body: &space.purpose,
                    related_order_id: None,
                    related_listing_id: None,
                    related_conversation_id: None,
                    related_space_id: Some(&space_id),
                },
            )
            .await
        {
            tracing::warn!(%e, %space_id, "could not record space formation notice");
        }
    }
}

/// Hourly sweep: form what is worth forming, archive what is spent.
pub async fn run_formation_worker(db_pool: PgPool, shutdown: crate::lifecycle::ShutdownSignal) {
    use crate::services::intent::kinds;

    tracing::info!("Space formation worker started (interval: 1 h)");
    let mut ticker = tokio::time::interval(std::time::Duration::from_secs(60 * 60));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    let service = AggregationService::new(db_pool.clone());
    while crate::lifecycle::tick_or_shutdown(&mut ticker, &shutdown)
        .await
        .should_continue()
    {
        // Archive first: a space whose job is done should not be counted as
        // company for the next formation decision.
        match service.archive_spent().await {
            Ok(0) => {}
            Ok(archived) => tracing::debug!(archived, "Archived spent spaces"),
            Err(e) => tracing::error!(%e, "Space archive sweep failed"),
        }

        let campuses: Vec<Uuid> =
            match sqlx::query_scalar("SELECT id FROM campuses WHERE status = 'active'")
                .fetch_all(&db_pool)
                .await
            {
                Ok(ids) => ids,
                Err(e) => {
                    tracing::error!(%e, "Could not list campuses for space formation");
                    continue;
                }
            };

        // Goods are matched one-to-one, not gathered into rooms; only the kinds
        // where several people want the same thing at once make sense here.
        for campus_id in campuses {
            for kind in [kinds::COMPANION, kinds::ACTIVITY, kinds::HELP] {
                match service.form_spaces(campus_id, kind).await {
                    Ok((formed, declined)) => {
                        for space in &formed {
                            tracing::info!(
                                space_id = %space.space_id,
                                members = space.members.len(),
                                sources = space.source_intents.len(),
                                "Formed a space from intent density",
                            );
                            notify_members(&db_pool, campus_id, space).await;
                        }
                        // Refusals are logged, not swallowed: a run that keeps
                        // declining for TooFamiliar is telling us the campus is
                        // fragmenting, which is exactly what we asked it to
                        // watch for.
                        for reason in &declined {
                            tracing::debug!(?reason, %campus_id, kind, "Declined to form a space");
                        }
                    }
                    Err(e) => tracing::error!(%e, %campus_id, kind, "Space formation failed"),
                }
            }
        }
    }

    tracing::info!("Space formation worker stopped");
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::intent::slots::{Slots, TimeSlot};

    fn intent(id: u128, subject: &str, minutes_old: i64, time: Option<TimeSlot>) -> Intent {
        Intent {
            id: Uuid::from_u128(id),
            kind: "companion".to_string(),
            raw_input: subject.to_string(),
            slots: Slots {
                subject: Some(subject.to_string()),
                time,
                ..Default::default()
            },
            confidence: 1.0,
            status: "active".to_string(),
            visibility: "campus".to_string(),
            valid_until: None,
            projected_listing_id: None,
            created_at: chrono::Utc::now() - chrono::Duration::minutes(minutes_old),
            author_id: Some(format!("user-{id}")),
        }
    }

    /// A shared clock for the fixtures below.
    ///
    /// `TimeSlot::Exact` compares instants exactly, which is correct — "3pm"
    /// and "3:30pm" are different times and a person should settle which.
    /// Vagueness belongs in `Window` or `Flexible`. That does mean two
    /// independently-taken `now()` readings differ by microseconds and read as
    /// a clash, so the base instant is taken once.
    fn base() -> chrono::DateTime<chrono::Utc> {
        chrono::DateTime::parse_from_rfc3339("2026-08-01T15:00:00Z")
            .unwrap()
            .with_timezone(&chrono::Utc)
    }

    fn at(days: i64) -> TimeSlot {
        TimeSlot::Exact {
            at: base() + chrono::Duration::days(days),
        }
    }

    #[test]
    fn one_latecomer_cannot_shut_out_a_group_that_agrees() {
        // The bug this guards against. A single greedy pass keeps whichever
        // intent it sees first, so an outlier posted most recently discarded
        // everyone who agreed with each other. The room must not be decided by
        // posting order.
        let agreeing_then_outlier = vec![
            intent(1, "篮球", 60, Some(at(2))),
            intent(2, "篮球", 50, Some(at(2))),
            intent(3, "篮球", 40, Some(at(2))),
            intent(4, "篮球", 1, Some(at(30))),
        ];
        let clusters = cluster_by_subject(&agreeing_then_outlier);
        assert_eq!(clusters.len(), 1);
        assert_eq!(
            clusters[0].intents.len(),
            3,
            "the three who can actually meet should be the group",
        );
        assert!(
            !clusters[0]
                .intents
                .iter()
                .any(|i| i.id == Uuid::from_u128(4)),
            "the outlier keeps waiting rather than blocking everyone",
        );

        // And the answer does not depend on the order the rows arrive in.
        let mut reversed = agreeing_then_outlier.clone();
        reversed.reverse();
        let from_reversed = cluster_by_subject(&reversed);
        assert_eq!(from_reversed[0].intents.len(), 3);
    }

    #[test]
    fn flexible_people_join_whatever_group_forms() {
        // Someone who said "whenever suits you" should be included, not treated
        // as an unresolved case.
        let intents = vec![
            intent(1, "羽毛球", 60, Some(at(1))),
            intent(2, "羽毛球", 50, Some(at(1))),
            intent(
                3,
                "羽毛球",
                40,
                Some(TimeSlot::Flexible {
                    hint: Some("都行".to_string()),
                }),
            ),
        ];
        let clusters = cluster_by_subject(&intents);
        assert_eq!(clusters[0].intents.len(), 3);
    }

    #[test]
    fn different_subjects_stay_in_different_rooms() {
        let intents = vec![
            intent(1, "羽毛球", 60, None),
            intent(2, "羽毛球", 50, None),
            intent(3, "考研数学", 40, None),
        ];
        let mut clusters = cluster_by_subject(&intents);
        clusters.sort_by(|a, b| a.label.cmp(&b.label));
        assert_eq!(clusters.len(), 2);
        assert_eq!(
            clusters.iter().map(|c| c.intents.len()).sum::<usize>(),
            3,
            "nobody is lost between buckets",
        );
    }

    #[test]
    fn an_intent_with_nothing_to_key_on_is_skipped_not_mis_grouped() {
        // Better to leave someone waiting than to file them under a word that
        // has nothing to do with what they asked for.
        let mut blank = intent(1, "x", 10, None);
        blank.slots.subject = None;
        blank.raw_input = "?".to_string();
        assert!(cluster_by_subject(&[blank]).is_empty());
    }
}

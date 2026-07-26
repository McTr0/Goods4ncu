//! Slot values, including the ones that decline to be specific.
//!
//! The point of this module is that **"I don't mind" is an answer**. A form
//! demands a number and treats its absence as missing data; a person emptying
//! a dorm room says "whatever you'll give me" and means it exactly. If the
//! model has to invent a price to satisfy a schema, it will, and the listing
//! becomes a lie about what its owner wants.
//!
//! So vagueness is represented rather than resolved, and the matching rules
//! are defined over it. The asymmetry that makes this work: a constraint that
//! declines to be specific accepts anything, while an offer that declines to be
//! specific is acceptable to everything. Neither blocks a match, which is the
//! opposite of what a missing field does.
//!
//! Compatibility is deliberately **permissive on ignorance and strict on
//! statements**. If someone said "under 300" then 400 is out, no matter how
//! good the match looks otherwise — quietly relaxing a stated limit is how
//! recommendation systems teach people to stop trusting them.

use serde::{Deserialize, Serialize};

/// A money slot, in cents.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PriceSlot {
    /// A definite figure.
    Exact { cents: i64 },
    /// An acceptable band. Either end may be open.
    Range {
        #[serde(skip_serializing_if = "Option::is_none")]
        min_cents: Option<i64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        max_cents: Option<i64>,
    },
    /// Being given away.
    Free,
    /// "Whatever you'll give me" / "however much". A complete answer, kept with
    /// the words the person used so the interface can show their phrasing back
    /// instead of a number they never said.
    Whatever {
        #[serde(skip_serializing_if = "Option::is_none")]
        hint: Option<String>,
    },
}

impl PriceSlot {
    /// The figure to display and project, when there is one.
    pub fn nominal_cents(&self) -> Option<i64> {
        match self {
            PriceSlot::Exact { cents } => Some(*cents),
            PriceSlot::Free => Some(0),
            // Midpoint of a closed band; a single open end takes that end,
            // since it is the only figure actually stated.
            PriceSlot::Range {
                min_cents,
                max_cents,
            } => match (min_cents, max_cents) {
                (Some(lo), Some(hi)) => Some((lo + hi) / 2),
                (Some(lo), None) => Some(*lo),
                (None, Some(hi)) => Some(*hi),
                (None, None) => None,
            },
            PriceSlot::Whatever { .. } => None,
        }
    }

    /// Whether `self`, read as a *buyer's constraint*, admits `offer`.
    ///
    /// Unstated on either side never blocks: a buyer who did not name a budget
    /// is open to anything, and a seller who did not name a price cannot be
    /// ruled out by one. What is stated is enforced exactly.
    pub fn admits(&self, offer: &PriceSlot) -> bool {
        let Some(asking) = offer.nominal_cents() else {
            return true;
        };
        match self {
            PriceSlot::Whatever { .. } => true,
            PriceSlot::Free => asking == 0,
            // An exact budget is a ceiling, not an equality: someone who says
            // "I'll pay 300" is not refusing to pay 250.
            PriceSlot::Exact { cents } => asking <= *cents,
            PriceSlot::Range {
                min_cents,
                max_cents,
            } => min_cents.is_none_or(|lo| asking >= lo) && max_cents.is_none_or(|hi| asking <= hi),
        }
    }
}

/// A time slot.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TimeSlot {
    /// A specific moment.
    Exact { at: chrono::DateTime<chrono::Utc> },
    /// Any time inside a window. Either end may be open.
    Window {
        #[serde(skip_serializing_if = "Option::is_none")]
        from: Option<chrono::DateTime<chrono::Utc>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        to: Option<chrono::DateTime<chrono::Utc>>,
    },
    /// "Any time this week", "whenever suits you". Complete, not missing.
    Flexible {
        #[serde(skip_serializing_if = "Option::is_none")]
        hint: Option<String>,
    },
}

impl TimeSlot {
    /// Whether these two time slots could describe the same occasion.
    ///
    /// Symmetric, unlike price: neither party is the constraint. Two exact
    /// times must agree; anything flexible fits anything.
    pub fn overlaps(&self, other: &TimeSlot) -> bool {
        // Treat every slot as an interval, with flexibility as "unbounded", and
        // ask whether the intervals meet. Collapsing the cases this way avoids
        // a nine-arm match where the diagonal is easy to get subtly wrong.
        let (a_from, a_to) = self.bounds();
        let (b_from, b_to) = other.bounds();
        let starts_before_other_ends = match (a_from, b_to) {
            (Some(from), Some(to)) => from <= to,
            _ => true,
        };
        let ends_after_other_starts = match (a_to, b_from) {
            (Some(to), Some(from)) => to >= from,
            _ => true,
        };
        starts_before_other_ends && ends_after_other_starts
    }

    fn bounds(
        &self,
    ) -> (
        Option<chrono::DateTime<chrono::Utc>>,
        Option<chrono::DateTime<chrono::Utc>>,
    ) {
        match self {
            TimeSlot::Exact { at } => (Some(*at), Some(*at)),
            TimeSlot::Window { from, to } => (*from, *to),
            TimeSlot::Flexible { .. } => (None, None),
        }
    }
}

/// The structured reading of an intent.
///
/// Every field is optional because an intent is allowed to be partial. "I want
/// to get rid of the stuff in my dorm" carries almost nothing and is still a
/// real, actionable intent — it just needs a person to narrow it before it
/// matches well.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Slots {
    /// What it is about, in the author's words where possible.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub price: Option<PriceSlot>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub time: Option<TimeSlot>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub place: Option<String>,
    /// 1–10, for goods.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub condition_score: Option<i32>,
    /// How many people, for companion/activity intents.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub party_size: Option<i32>,
    /// Free-form extras the author mentioned that do not fit a slot. Preserved
    /// rather than dropped, because a detail we have no field for today is
    /// still the difference between a good and a bad match.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub notes: Vec<String>,
}

impl Slots {
    /// Whether a seeking intent's slots could be satisfied by an offering
    /// intent's slots.
    ///
    /// This is a **hard filter only** — it answers "is this impossible?", not
    /// "is this good?". Ranking is a separate concern; conflating them lets a
    /// high similarity score talk its way past a stated budget.
    pub fn compatible_with(&self, offer: &Slots) -> bool {
        if let (Some(budget), Some(asking)) = (&self.price, &offer.price) {
            if !budget.admits(asking) {
                return false;
            }
        }
        if let (Some(mine), Some(theirs)) = (&self.time, &offer.time) {
            if !mine.overlaps(theirs) {
                return false;
            }
        }
        // A stated minimum condition is a statement; anything below it is out.
        if let (Some(wanted), Some(actual)) = (self.condition_score, offer.condition_score) {
            if actual < wanted {
                return false;
            }
        }
        // Categories only rule out when both sides named one and they differ.
        if let (Some(mine), Some(theirs)) = (&self.category, &offer.category) {
            if !mine.eq_ignore_ascii_case(theirs) {
                return false;
            }
        }
        true
    }

    /// How much of this intent is pinned down, 0..1.
    ///
    /// Used to decide whether to ask a clarifying question, *not* to reject an
    /// intent: a vague intent is a real one, and pestering someone into filling
    /// slots is the form-filling this design exists to avoid.
    pub fn specificity(&self) -> f32 {
        let mut stated = 0u32;
        if self.subject.is_some() {
            stated += 1;
        }
        if self.category.is_some() {
            stated += 1;
        }
        // A deliberate "whatever" counts as answered. It is a decision, and
        // treating it as a gap would make the interface nag someone who has
        // already told us what they want.
        if self.price.is_some() {
            stated += 1;
        }
        if self.time.is_some() {
            stated += 1;
        }
        if self.place.is_some() {
            stated += 1;
        }
        if self.condition_score.is_some() {
            stated += 1;
        }
        stated as f32 / 6.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(hour: u32) -> chrono::DateTime<chrono::Utc> {
        chrono::DateTime::parse_from_rfc3339(&format!("2026-08-01T{hour:02}:00:00Z"))
            .unwrap()
            .with_timezone(&chrono::Utc)
    }

    #[test]
    fn whatever_is_an_answer_not_a_gap() {
        // The core claim of this module. Someone clearing a dorm says "whatever
        // you'll give me"; that must survive round-tripping, must not block a
        // match, and must not be treated as an unanswered question.
        let whatever = PriceSlot::Whatever {
            hint: Some("能卖就行".to_string()),
        };
        let json = serde_json::to_string(&whatever).unwrap();
        assert_eq!(
            serde_json::from_str::<PriceSlot>(&json).unwrap(),
            whatever,
            "the author's own words survive the round trip",
        );

        assert!(whatever.admits(&PriceSlot::Exact { cents: 999_999 }));
        assert!(whatever.nominal_cents().is_none(), "no invented figure");

        let slots = Slots {
            price: Some(whatever),
            ..Default::default()
        };
        assert!(
            slots.specificity() > 0.0,
            "a deliberate 'whatever' is answered, so nothing should nag about it",
        );
    }

    #[test]
    fn an_unpriced_offer_is_never_ruled_out_by_a_budget() {
        // The asymmetry that makes vagueness safe: not naming a price cannot
        // exclude you from someone's search, which is exactly what a missing
        // required field would do.
        let budget = PriceSlot::Range {
            min_cents: None,
            max_cents: Some(30_000),
        };
        assert!(budget.admits(&PriceSlot::Whatever { hint: None }));
        assert!(budget.admits(&PriceSlot::Range {
            min_cents: None,
            max_cents: None
        }));
    }

    #[test]
    fn a_stated_budget_is_enforced_exactly() {
        // The other half: what someone did say is obeyed. Relaxing a stated
        // limit because the match looks good is how people learn to distrust
        // recommendations.
        let budget = PriceSlot::Range {
            min_cents: None,
            max_cents: Some(30_000),
        };
        assert!(
            budget.admits(&PriceSlot::Exact { cents: 30_000 }),
            "the limit is inclusive"
        );
        assert!(!budget.admits(&PriceSlot::Exact { cents: 30_001 }));

        // "I'll pay 300" is a ceiling, not an insistence on paying exactly 300.
        let willing = PriceSlot::Exact { cents: 30_000 };
        assert!(willing.admits(&PriceSlot::Exact { cents: 25_000 }));
        assert!(!willing.admits(&PriceSlot::Exact { cents: 35_000 }));

        // Someone looking for a giveaway means it.
        assert!(PriceSlot::Free.admits(&PriceSlot::Free));
        assert!(!PriceSlot::Free.admits(&PriceSlot::Exact { cents: 100 }));
    }

    #[test]
    fn a_minimum_price_rules_out_cheaper_offers() {
        let band = PriceSlot::Range {
            min_cents: Some(10_000),
            max_cents: Some(20_000),
        };
        assert!(!band.admits(&PriceSlot::Exact { cents: 9_999 }));
        assert!(band.admits(&PriceSlot::Exact { cents: 10_000 }));
        assert!(band.admits(&PriceSlot::Exact { cents: 20_000 }));
        assert!(!band.admits(&PriceSlot::Exact { cents: 20_001 }));
    }

    #[test]
    fn flexible_time_fits_anything_and_windows_must_actually_meet() {
        let flexible = TimeSlot::Flexible {
            hint: Some("这周都行".to_string()),
        };
        assert!(flexible.overlaps(&TimeSlot::Exact { at: at(15) }));
        assert!(TimeSlot::Exact { at: at(15) }.overlaps(&flexible));

        // Touching at an endpoint counts: 15:00–17:00 and 17:00–19:00 can both
        // be "meet at five".
        let afternoon = TimeSlot::Window {
            from: Some(at(15)),
            to: Some(at(17)),
        };
        let evening = TimeSlot::Window {
            from: Some(at(17)),
            to: Some(at(19)),
        };
        assert!(afternoon.overlaps(&evening));

        let morning = TimeSlot::Window {
            from: Some(at(8)),
            to: Some(at(10)),
        };
        assert!(!morning.overlaps(&evening));
        assert!(!evening.overlaps(&morning), "and it is symmetric");

        // Two different exact times do not.
        assert!(!TimeSlot::Exact { at: at(15) }.overlaps(&TimeSlot::Exact { at: at(16) }));
        assert!(TimeSlot::Exact { at: at(15) }.overlaps(&TimeSlot::Exact { at: at(15) }));

        // A half-open window is open on that side.
        let after_five = TimeSlot::Window {
            from: Some(at(17)),
            to: None,
        };
        assert!(after_five.overlaps(&TimeSlot::Exact { at: at(23) }));
        assert!(!after_five.overlaps(&TimeSlot::Exact { at: at(9) }));
    }

    #[test]
    fn compatibility_is_a_hard_filter_not_a_score() {
        // Everything unstated on both sides: nothing is impossible yet.
        assert!(Slots::default().compatible_with(&Slots::default()));

        let seek = Slots {
            category: Some("electronics".to_string()),
            price: Some(PriceSlot::Range {
                min_cents: None,
                max_cents: Some(30_000),
            }),
            condition_score: Some(7),
            ..Default::default()
        };

        let good = Slots {
            category: Some("Electronics".to_string()),
            price: Some(PriceSlot::Exact { cents: 25_000 }),
            condition_score: Some(8),
            ..Default::default()
        };
        assert!(
            seek.compatible_with(&good),
            "category match is case-insensitive"
        );

        let too_dear = Slots {
            price: Some(PriceSlot::Exact { cents: 40_000 }),
            ..good.clone()
        };
        assert!(!seek.compatible_with(&too_dear));

        let too_worn = Slots {
            condition_score: Some(5),
            ..good.clone()
        };
        assert!(!seek.compatible_with(&too_worn));

        let wrong_category = Slots {
            category: Some("books".to_string()),
            ..good.clone()
        };
        assert!(!seek.compatible_with(&wrong_category));

        // A category stated on only one side cannot rule anything out.
        let uncategorised = Slots {
            category: None,
            ..good
        };
        assert!(seek.compatible_with(&uncategorised));
    }

    #[test]
    fn an_almost_empty_intent_is_still_valid() {
        // "I'm clearing out my dorm" is a real intent. It should be storable,
        // matchable in principle, and merely *low* on specificity — never
        // rejected.
        let vague = Slots {
            subject: Some("宿舍要清空了".to_string()),
            ..Default::default()
        };
        assert!(vague.compatible_with(&Slots::default()));
        let specificity = vague.specificity();
        assert!(
            specificity > 0.0 && specificity < 0.5,
            "vague but real, got {specificity}",
        );
    }

    #[test]
    fn slots_omit_what_was_never_said() {
        // Serialised intents are stored and re-read. Emitting nulls for unasked
        // questions would make "not mentioned" indistinguishable from "answered
        // with nothing" on the way back in.
        let json = serde_json::to_value(Slots {
            subject: Some("台灯".to_string()),
            ..Default::default()
        })
        .unwrap();
        let object = json.as_object().unwrap();
        assert_eq!(object.len(), 1, "only the stated slot is present: {json}");
        assert!(object.contains_key("subject"));
    }
}

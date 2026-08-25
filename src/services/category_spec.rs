//! Category specifications: invariant + schema + state machine.
//!
//! Taxonomy v4 principle: a category exists only when it brings new
//! structured fields, a lifecycle, a relationship invariant, or actions.
//! Everything system-critical lives here / in structured columns — tags stay
//! weak descriptive metadata.

use crate::api::error::ApiError;
use serde_json::Value;

const MAX_ATTRIBUTES_CHARS: usize = 2_000;

#[derive(Debug, Clone, Copy)]
pub enum FieldKind {
    /// Bounded free text.
    Text(usize),
    /// RFC3339 timestamp.
    DateTime,
    /// Integer > min (exclusive).
    PositiveInt,
    /// http(s) URL.
    Url,
}

#[derive(Debug, Clone, Copy)]
pub enum Requirement {
    Always,
    Optional,
    /// Required iff another attribute equals this value.
    WhenOtherIs(&'static str, &'static str),
}

#[derive(Debug, Clone, Copy)]
pub struct FieldSpec {
    pub key: &'static str,
    pub kind: FieldKind,
    pub requirement: Requirement,
}

#[derive(Debug, Clone, Copy)]
#[allow(dead_code)]
pub struct LifecycleSpec {
    pub initial: &'static str,
    /// Values that close the story (still storable/reopenable per graph).
    pub terminal: &'static [&'static str],
    /// Allowed (from -> targets[]) moves; targets may be terminal values.
    pub transitions: &'static [(&'static str, &'static [&'static str])],
}

impl LifecycleSpec {
    fn initial(&self) -> &'static str {
        self.initial
    }

    fn known_state(&self, state: &str) -> bool {
        state == self.initial || self.transitions.iter().any(|(from, _)| *from == state)
    }

    fn allows(&self, from: Option<&str>, to: &str) -> bool {
        let current = from.unwrap_or(self.initial);
        // Re-writing the current state (or initial over NULL) is a no-op.
        if current == to && self.known_state(to) {
            return true;
        }
        self.transitions
            .iter()
            .any(|(from_allowed, targets)| *from_allowed == current && targets.contains(&to))
    }

    #[allow(dead_code)]
    pub fn is_terminal(&self, state: &str) -> bool {
        self.terminal.contains(&state)
    }
}

#[derive(Debug, Clone, Copy)]
#[allow(dead_code)]
pub struct CategorySpec {
    pub key: &'static str,
    pub attributes: &'static [FieldSpec],
    /// category=offer ⇒ a linked listing row must exist.
    pub requires_listing: bool,
    /// Only operator+/platform-admin may publish.
    pub operator_only_publish: bool,
    pub lifecycle: Option<LifecycleSpec>,
}

const NO_ATTRIBUTES: &[FieldSpec] = &[];

const EVENT_ATTRIBUTES: &[FieldSpec] = &[
    FieldSpec {
        key: "starts_at",
        kind: FieldKind::DateTime,
        requirement: Requirement::Always,
    },
    FieldSpec {
        key: "location_type",
        kind: FieldKind::Text(16),
        requirement: Requirement::Always,
    },
    FieldSpec {
        key: "place",
        kind: FieldKind::Text(120),
        requirement: Requirement::WhenOtherIs("location_type", "offline"),
    },
    FieldSpec {
        key: "online_url",
        kind: FieldKind::Url,
        requirement: Requirement::WhenOtherIs("location_type", "online"),
    },
    FieldSpec {
        key: "end_at",
        kind: FieldKind::DateTime,
        requirement: Requirement::Optional,
    },
    FieldSpec {
        key: "organizer",
        kind: FieldKind::Text(60),
        requirement: Requirement::Optional,
    },
    FieldSpec {
        key: "capacity",
        kind: FieldKind::PositiveInt,
        requirement: Requirement::Optional,
    },
    FieldSpec {
        key: "signup_url",
        kind: FieldKind::Url,
        requirement: Requirement::Optional,
    },
];

const RECRUIT_ATTRIBUTES: &[FieldSpec] = &[
    FieldSpec {
        key: "target_count",
        kind: FieldKind::PositiveInt,
        requirement: Requirement::Optional,
    },
    FieldSpec {
        key: "deadline",
        kind: FieldKind::DateTime,
        requirement: Requirement::Optional,
    },
    FieldSpec {
        key: "place",
        kind: FieldKind::Text(120),
        requirement: Requirement::Optional,
    },
    FieldSpec {
        key: "starts_at",
        kind: FieldKind::DateTime,
        requirement: Requirement::Optional,
    },
];

const HELP_ATTRIBUTES: &[FieldSpec] = &[
    FieldSpec {
        key: "deadline",
        kind: FieldKind::DateTime,
        requirement: Requirement::Optional,
    },
    FieldSpec {
        key: "place",
        kind: FieldKind::Text(120),
        requirement: Requirement::Optional,
    },
];

const LOST_ATTRIBUTES: &[FieldSpec] = &[
    FieldSpec {
        key: "item_name",
        kind: FieldKind::Text(80),
        requirement: Requirement::Always,
    },
    FieldSpec {
        key: "lost_at",
        kind: FieldKind::DateTime,
        requirement: Requirement::Always,
    },
    FieldSpec {
        key: "lost_place",
        kind: FieldKind::Text(120),
        requirement: Requirement::Always,
    },
    FieldSpec {
        key: "features",
        kind: FieldKind::Text(200),
        requirement: Requirement::Optional,
    },
];

const FOUND_ATTRIBUTES: &[FieldSpec] = &[
    FieldSpec {
        key: "item_name",
        kind: FieldKind::Text(80),
        requirement: Requirement::Always,
    },
    FieldSpec {
        key: "found_at",
        kind: FieldKind::DateTime,
        requirement: Requirement::Always,
    },
    FieldSpec {
        key: "found_place",
        kind: FieldKind::Text(120),
        requirement: Requirement::Always,
    },
    FieldSpec {
        key: "claim_hint",
        kind: FieldKind::Text(120),
        requirement: Requirement::Optional,
    },
];

const ANNOUNCEMENT_ATTRIBUTES: &[FieldSpec] = &[
    FieldSpec {
        key: "effective_at",
        kind: FieldKind::DateTime,
        requirement: Requirement::Optional,
    },
    FieldSpec {
        key: "expires_at",
        kind: FieldKind::DateTime,
        requirement: Requirement::Optional,
    },
];

/// Macro-free static registry; lookup is a linear scan over 9 entries.
pub fn spec(category: &str) -> Option<CategorySpec> {
    match category {
        "offer" => Some(CategorySpec {
            key: "offer",
            attributes: &[FieldSpec {
                key: "delivery_note",
                kind: FieldKind::Text(120),
                requirement: Requirement::Optional,
            }],
            requires_listing: true,
            operator_only_publish: false,
            lifecycle: Some(LifecycleSpec {
                initial: "available",
                terminal: &["sold", "closed"],
                transitions: &[
                    ("available", &["reserved", "sold", "closed"]),
                    ("reserved", &["available", "sold", "closed"]),
                    ("sold", &["available"]),
                    ("closed", &["available"]),
                ],
            }),
        }),
        "wanted" => Some(CategorySpec {
            key: "wanted",
            attributes: &[
                FieldSpec {
                    key: "deadline",
                    kind: FieldKind::DateTime,
                    requirement: Requirement::Optional,
                },
                FieldSpec {
                    key: "note",
                    kind: FieldKind::Text(120),
                    requirement: Requirement::Optional,
                },
            ],
            requires_listing: false,
            operator_only_publish: false,
            lifecycle: Some(LifecycleSpec {
                initial: "open",
                terminal: &["fulfilled", "closed"],
                transitions: &[
                    ("open", &["fulfilled", "closed"]),
                    ("fulfilled", &["open"]),
                    ("closed", &["open"]),
                ],
            }),
        }),
        "event" => Some(CategorySpec {
            key: "event",
            attributes: EVENT_ATTRIBUTES,
            requires_listing: false,
            operator_only_publish: false,
            lifecycle: Some(LifecycleSpec {
                initial: "scheduled",
                terminal: &["cancelled"],
                transitions: &[("scheduled", &["cancelled"]), ("cancelled", &["scheduled"])],
            }),
        }),
        "recruit" => Some(CategorySpec {
            key: "recruit",
            attributes: RECRUIT_ATTRIBUTES,
            requires_listing: false,
            operator_only_publish: false,
            lifecycle: Some(LifecycleSpec {
                initial: "recruiting",
                terminal: &["full", "closed"],
                transitions: &[
                    ("recruiting", &["full", "closed"]),
                    ("full", &["recruiting", "closed"]),
                    ("closed", &[]),
                ],
            }),
        }),
        "help" => Some(CategorySpec {
            key: "help",
            attributes: HELP_ATTRIBUTES,
            requires_listing: false,
            operator_only_publish: false,
            lifecycle: Some(LifecycleSpec {
                initial: "open",
                terminal: &["resolved", "closed"],
                transitions: &[
                    ("open", &["resolved", "closed"]),
                    ("resolved", &["open"]),
                    ("closed", &[]),
                ],
            }),
        }),
        "lost" => Some(CategorySpec {
            key: "lost",
            attributes: LOST_ATTRIBUTES,
            requires_listing: false,
            operator_only_publish: false,
            lifecycle: Some(LifecycleSpec {
                initial: "searching",
                terminal: &["reunited"],
                transitions: &[("searching", &["reunited"])],
            }),
        }),
        "found" => Some(CategorySpec {
            key: "found",
            attributes: FOUND_ATTRIBUTES,
            requires_listing: false,
            operator_only_publish: false,
            lifecycle: Some(LifecycleSpec {
                initial: "unclaimed",
                terminal: &["claimed"],
                transitions: &[("unclaimed", &["claimed"])],
            }),
        }),
        "discussion" => Some(CategorySpec {
            key: "discussion",
            attributes: NO_ATTRIBUTES,
            requires_listing: false,
            operator_only_publish: false,
            lifecycle: None,
        }),
        "announcement" => Some(CategorySpec {
            key: "announcement",
            attributes: ANNOUNCEMENT_ATTRIBUTES,
            requires_listing: false,
            operator_only_publish: true,
            lifecycle: Some(LifecycleSpec {
                initial: "live",
                terminal: &["withdrawn"],
                transitions: &[("live", &["withdrawn"]), ("withdrawn", &["live"])],
            }),
        }),
        _ => None,
    }
}

fn bad(message: String) -> ApiError {
    ApiError::BadRequest(message)
}

/// Validate + normalize one attribute payload against the category spec.
/// Missing optional fields are dropped; ordering follows the spec.
pub fn validate_attributes(category: &str, raw: &Value) -> Result<Value, ApiError> {
    let Some(spec) = spec(category) else {
        if raw.as_object().is_some_and(|object| !object.is_empty()) {
            return Err(bad(format!("{category} 帖子不支持附加属性")));
        }
        return Ok(serde_json::json!({}));
    };

    let value = if raw.is_null() {
        &serde_json::json!({})
    } else {
        raw
    };
    let Some(object) = value.as_object() else {
        return Err(bad("attributes 必须是对象".to_string()));
    };
    if object.is_empty() {
        // Required fields still have to be present somewhere upstream; an
        // empty payload fails the required scan below.
    }
    if serde_json::to_string(value)
        .map(|text| text.chars().count())
        .unwrap_or(usize::MAX)
        > MAX_ATTRIBUTES_CHARS
    {
        return Err(bad("attributes 过长".to_string()));
    }

    for field in spec.attributes {
        if let Requirement::WhenOtherIs(other_key, expected) = field.requirement {
            let trigger_matches = object
                .get(other_key)
                .and_then(Value::as_str)
                .is_some_and(|actual| actual == expected);
            if !trigger_matches {
                continue;
            }
        }
        let required_now = match field.requirement {
            Requirement::Always => true,
            Requirement::Optional => false,
            Requirement::WhenOtherIs(other_key, expected) => object
                .get(other_key)
                .and_then(Value::as_str)
                .is_some_and(|actual| actual == expected),
        };
        let missing = object.get(field.key).is_none();
        if missing {
            if required_now {
                return Err(bad(format!("{} 缺少必填字段 {}", category, field.key)));
            }
            continue;
        }
    }

    for key in object.keys() {
        if !spec.attributes.iter().any(|field| field.key == key) {
            return Err(bad(format!("attributes 含未知字段：{key}")));
        }
    }

    let mut out = serde_json::Map::new();
    let mut start_at: Option<chrono::DateTime<chrono::FixedOffset>> = None;
    let mut end_at: Option<chrono::DateTime<chrono::FixedOffset>> = None;

    for field in spec.attributes {
        let Some(raw_field) = object.get(field.key) else {
            continue;
        };
        let normalized: Value = match field.kind {
            FieldKind::Text(max) => {
                let text = raw_field
                    .as_str()
                    .ok_or_else(|| bad(format!("{} 必须是文本", field.key)))?;
                let trimmed = text.trim();
                if trimmed.is_empty() {
                    if matches!(field.requirement, Requirement::Always)
                        || matches!(field.requirement, Requirement::WhenOtherIs(_, _))
                    {
                        return Err(bad(format!("{} 不能为空", field.key)));
                    }
                    continue;
                }
                if trimmed.chars().count() > max {
                    return Err(bad(format!("{} 过长（≤{max} 字）", field.key)));
                }
                serde_json::json!(trimmed)
            }
            FieldKind::DateTime => {
                let text = raw_field
                    .as_str()
                    .ok_or_else(|| bad(format!("{} 必须是 RFC3339 时间", field.key)))?;
                let parsed = chrono::DateTime::parse_from_rfc3339(text)
                    .map_err(|_| bad(format!("{} 必须是合法的 RFC3339 时间", field.key)))?;
                if (field.key == "lost_at" || field.key == "found_at")
                    && parsed > chrono::Utc::now()
                {
                    return Err(bad(format!("{} 不能是未来时间", field.key)));
                }
                if field.key == "deadline" {
                    let earliest = chrono::Utc::now() - chrono::Duration::minutes(5);
                    if parsed < earliest {
                        return Err(bad(format!("{} 已经过期", field.key)));
                    }
                }
                if field.key == "starts_at" {
                    start_at = Some(parsed);
                }
                if field.key == "end_at" {
                    end_at = Some(parsed);
                }
                serde_json::json!(text)
            }
            FieldKind::PositiveInt => {
                let number = raw_field
                    .as_i64()
                    .ok_or_else(|| bad(format!("{} 必须是正整数", field.key)))?;
                if number <= 0 {
                    return Err(bad(format!("{} 必须大于 0", field.key)));
                }
                serde_json::json!(number)
            }
            FieldKind::Url => {
                let text = raw_field.as_str().unwrap_or_default().trim();
                if !(text.starts_with("http://") || text.starts_with("https://")) {
                    return Err(bad(format!("{} 必须是 http(s) 链接", field.key)));
                }
                if text.chars().count() > 300 {
                    return Err(bad(format!("{} 过长", field.key)));
                }
                serde_json::json!(text)
            }
        };
        out.insert(field.key.to_string(), normalized);
    }

    // Cross-field rules.
    if let (Some(start), Some(end)) = (start_at, end_at) {
        if end < start {
            return Err(bad("结束时间不能早于开始时间".to_string()));
        }
    }
    if category == "event" {
        let location_type = out
            .get("location_type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if !["offline", "online"].contains(&location_type) {
            return Err(bad("location_type 仅支持 offline / online".to_string()));
        }
    }
    if category == "announcement" {
        if let (Some(effective), Some(expires)) = (
            out.get("effective_at").and_then(Value::as_str),
            out.get("expires_at").and_then(Value::as_str),
        ) {
            let effective = chrono::DateTime::parse_from_rfc3339(effective)
                .map_err(|_| bad("effective_at 不合法".to_string()))?;
            let expires = chrono::DateTime::parse_from_rfc3339(expires)
                .map_err(|_| bad("expires_at 不合法".to_string()))?;
            if expires < effective {
                return Err(bad("expires_at 不能早于 effective_at".to_string()));
            }
        }
    }

    if std::env::var("CATSPEC_DEBUG").is_ok() {
        eprintln!("[catspec] {category} -> {out:?}");
    }
    Ok(Value::Object(out))
}

/// Validate a lifecycle move along the category's transition graph.
pub fn validate_lifecycle(
    category: &str,
    current: Option<&str>,
    next: &str,
) -> Result<(), ApiError> {
    let Some(spec) = spec(category) else {
        return Err(bad(format!("{category} 帖子没有生命周期")));
    };
    let Some(lifecycle) = spec.lifecycle else {
        return Err(bad(format!("{category} 帖子没有生命周期")));
    };
    if !lifecycle.allows(current, next) {
        return Err(ApiError::BadRequest(format!(
            "不允许从 {} 切换到 {next}",
            current.unwrap_or(lifecycle.initial())
        )));
    }
    Ok(())
}

/// Terminal states for the category (feed downranking helper).
#[allow(dead_code)]
pub fn terminal_states(category: &str) -> &'static [&'static str] {
    match spec(category).and_then(|spec| spec.lifecycle) {
        Some(lifecycle) => lifecycle.terminal,
        None => &[],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn event_requires_starts_at_and_location_pairing() {
        // Missing starts_at entirely.
        let err = validate_attributes("event", &json!({"place": "线上"})).unwrap_err();
        assert!(err.to_string().contains("starts_at"));

        // Online without a URL.
        let err = validate_attributes(
            "event",
            &json!({"starts_at": "2026-09-01T10:00:00Z", "location_type": "online"}),
        )
        .unwrap_err();
        assert!(err.to_string().contains("online_url"));

        // Valid online form.
        let ok = validate_attributes(
            "event",
            &json!({
                "starts_at": "2026-09-01T10:00:00Z",
                "location_type": "online",
                "online_url": "https://meet.example.com/x"
            }),
        )
        .unwrap();
        assert_eq!(ok["location_type"], "online");
    }

    #[test]
    fn cross_field_time_rules_apply() {
        let err = validate_attributes(
            "event",
            &json!({
                "starts_at": "2026-09-01T10:00:00Z",
                "end_at": "2026-08-31T10:00:00Z",
                "location_type": "offline",
                "place": "图书馆201"
            }),
        )
        .unwrap_err();
        assert!(err.to_string().contains("结束时间"));

        let err = validate_attributes("recruit", &json!({"target_count": 0})).unwrap_err();
        println!("DBG3 {err}");
        assert!(err.to_string().contains("大于 0"));
    }

    #[test]
    fn lost_requires_past_discovery_fields() {
        let err = validate_attributes("lost", &json!({"item_name": "耳机"})).unwrap_err();
        assert!(err.to_string().contains("lost_at") || err.to_string().contains("lost_place"));

        let err = validate_attributes(
            "lost",
            &json!({
                "item_name": "耳机",
                "lost_at": "2030-01-01T00:00:00Z",
                "lost_place": "图书馆"
            }),
        )
        .unwrap_err();
        assert!(err.to_string().contains("未来"));
    }

    #[test]
    fn lifecycle_moves_follow_the_transition_graph() {
        // offer: available -> reserved -> sold -> available (reopen), sold -> closed rejected
        validate_lifecycle("offer", None, "available").unwrap();
        validate_lifecycle("offer", Some("available"), "reserved").unwrap();
        validate_lifecycle("offer", Some("reserved"), "sold").unwrap();
        assert!(validate_lifecycle("offer", Some("sold"), "closed").is_err());
        validate_lifecycle("offer", Some("sold"), "available").unwrap();

        // recruit: closed absorbs; full can reopen
        validate_lifecycle("recruit", None, "recruiting").unwrap();
        validate_lifecycle("recruit", Some("recruiting"), "full").unwrap();
        validate_lifecycle("recruit", Some("full"), "closed").unwrap();
        assert!(validate_lifecycle("recruit", Some("closed"), "full").is_err());

        // discussion has none
        assert!(validate_lifecycle("discussion", None, "anything").is_err());
    }

    #[test]
    fn offer_invariant_is_declared_in_spec() {
        assert!(spec("offer").unwrap().requires_listing);
        assert!(!spec("wanted").unwrap().requires_listing);
        assert!(spec("announcement").unwrap().operator_only_publish);
    }
}

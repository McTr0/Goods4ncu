//! Unified route taxonomy shared by Router, AgentRun, DB constraints,
//! and metrics. Single source of truth — no more stringly-typed routes.

/// The canonical set of agent routes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AgentRoute {
    /// User is offering something (sell/give).
    Offer,
    /// User is looking for something (buy/want).
    Wanted,
    /// General companion conversation.
    Companion,
}

impl AgentRoute {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Offer => "offer",
            Self::Wanted => "wanted",
            Self::Companion => "companion",
        }
    }

    pub fn all() -> &'static [&'static str] {
        &["offer", "wanted", "companion"]
    }

    /// Parse from a string; unknown values map to Companion.
    pub fn parse(value: &str) -> Self {
        match value {
            "offer" => Self::Offer,
            "wanted" => Self::Wanted,
            _ => Self::Companion,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips() {
        for route in [AgentRoute::Offer, AgentRoute::Wanted, AgentRoute::Companion] {
            assert_eq!(AgentRoute::parse(route.as_str()), route);
        }
        // Unknown maps to Companion.
        assert_eq!(AgentRoute::parse("help"), AgentRoute::Companion);
        assert_eq!(AgentRoute::parse(""), AgentRoute::Companion);
    }

    #[test]
    fn all_routes_have_unique_names() {
        let names: Vec<&str> = AgentRoute::all().to_vec();
        let mut sorted = names.clone();
        sorted.sort();
        let count = sorted.len();
        sorted.dedup();
        assert_eq!(sorted.len(), count);
    }
}

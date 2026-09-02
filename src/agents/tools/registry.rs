//! ToolRegistry: single registration point for all agent tools.
//!
//! Each tool declares metadata (risk, parallel safety, timeout) alongside
//! its implementation. Providers consume the registry to build their
//! tool schemas; the runtime consumes it for execution and budgeting.

use std::time::Duration;

/// Risk level determines whether ActionPlan is required.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[allow(dead_code)]
pub enum RiskLevel {
    /// Read-only queries; safe to execute without user confirmation.
    ReadOnly,
    /// Reversible writes; execute + undo available.
    Recoverable,
    /// Irreversible or sensitive writes; requires ActionPlan.
    RequiresConfirmation,
}

/// How a tool executes relative to others in the same step.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[allow(dead_code)]
pub enum ExecutionClass {
    /// Read-only, no side effects; may run in parallel with other read-onlys.
    ReadOnlyParallel,
    /// Must run sequentially (writes or ordering-dependent).
    Sequential,
    /// Generates an ActionPlan for user confirmation.
    RequiresActionPlan,
    /// Interactive: requires real-time user input mid-execution.
    Interactive,
}

/// Metadata every registered tool must declare.
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct ToolSpec {
    pub name: &'static str,
    pub schema_version: &'static str,
    pub risk: RiskLevel,
    pub execution: ExecutionClass,
    pub timeout: Duration,
    pub max_output_bytes: usize,
    /// Brief description shown to the model.
    pub description: &'static str,
}

#[allow(dead_code)]
impl ToolSpec {
    pub fn is_parallel_safe(&self) -> bool {
        self.execution == ExecutionClass::ReadOnlyParallel
    }

    pub fn timeout(&self) -> Duration {
        self.timeout
    }
}

/// Registry holding all registered tools with uniqueness enforcement.
#[allow(dead_code)]
pub struct ToolRegistry {
    specs: Vec<ToolSpec>,
}

#[allow(dead_code)]
impl ToolRegistry {
    pub fn builder() -> ToolRegistryBuilder {
        ToolRegistryBuilder { specs: vec![] }
    }

    pub fn specs(&self) -> &[ToolSpec] {
        &self.specs
    }

    pub fn find(&self, name: &str) -> Option<&ToolSpec> {
        self.specs.iter().find(|spec| spec.name == name)
    }

    /// Names of all tools safe to run in parallel.
    pub fn parallel_tools(&self) -> Vec<&str> {
        self.specs
            .iter()
            .filter(|spec| spec.is_parallel_safe())
            .map(|spec| spec.name)
            .collect()
    }

    /// Metadata for the exact tool set installed on marketplace agents.
    pub fn marketplace() -> Self {
        let readonly = [
            ("search_inventory", "Search visible marketplace posts"),
            ("get_listing_details", "Read one visible post"),
            ("get_my_listings", "Read the current user's posts"),
            ("get_user_posts", "Read a user's visible posts"),
            ("find_related_posts", "Find related visible posts"),
            ("get_comments", "Read visible post comments"),
            ("draft_message", "Draft a private message for confirmation"),
            ("draft_comment", "Draft a public reply for confirmation"),
        ];
        let mut builder = Self::builder();
        for (name, description) in readonly {
            builder = builder.register(ToolSpec {
                name,
                schema_version: "1.0",
                risk: RiskLevel::ReadOnly,
                execution: ExecutionClass::ReadOnlyParallel,
                timeout: timeouts::readonly(),
                max_output_bytes: 16 * 1024,
                description,
            });
        }
        builder = builder.register(ToolSpec {
            name: "create_listing",
            schema_version: "1.0",
            risk: RiskLevel::Recoverable,
            execution: ExecutionClass::Sequential,
            timeout: timeouts::write(),
            max_output_bytes: 8 * 1024,
            description: "Publish a recoverable marketplace post",
        });
        for (name, description) in [
            (
                "update_listing",
                "Update the current user's marketplace post",
            ),
            (
                "delete_listing",
                "Retract the current user's marketplace post",
            ),
            ("purchase_item", "Create a purchase intent"),
            ("negotiate_item", "Create a negotiation proposal"),
        ] {
            builder = builder.register(ToolSpec {
                name,
                schema_version: "1.0",
                risk: RiskLevel::RequiresConfirmation,
                execution: ExecutionClass::RequiresActionPlan,
                timeout: timeouts::action_plan(),
                max_output_bytes: 8 * 1024,
                description,
            });
        }
        builder.build()
    }
}

#[allow(dead_code)]
pub struct ToolRegistryBuilder {
    specs: Vec<ToolSpec>,
}

#[allow(dead_code)]
impl ToolRegistryBuilder {
    pub fn register(mut self, spec: ToolSpec) -> Self {
        // Uniqueness check at registration time.
        assert!(
            !self.specs.iter().any(|existing| existing.name == spec.name),
            "duplicate tool name: {}",
            spec.name
        );
        self.specs.push(spec);
        self
    }

    pub fn build(self) -> ToolRegistry {
        ToolRegistry { specs: self.specs }
    }
}

/// Default timeout helpers matching ExecutionBudget defaults.
#[allow(dead_code)]
pub mod timeouts {
    use std::time::Duration;

    pub fn readonly() -> Duration {
        Duration::from_secs(10)
    }

    pub fn write() -> Duration {
        Duration::from_secs(15)
    }

    pub fn action_plan() -> Duration {
        Duration::from_secs(30)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_spec(name: &'static str) -> ToolSpec {
        ToolSpec {
            name,
            schema_version: "1.0",
            risk: RiskLevel::ReadOnly,
            execution: ExecutionClass::ReadOnlyParallel,
            timeout: timeouts::readonly(),
            max_output_bytes: 16 * 1024,
            description: "test tool",
        }
    }

    #[test]
    fn rejects_duplicate_names() {
        let result = std::panic::catch_unwind(|| {
            ToolRegistry::builder()
                .register(sample_spec("search"))
                .register(sample_spec("search"))
                .build();
        });
        assert!(result.is_err());
    }

    #[test]
    fn finds_registered_tool() {
        let registry = ToolRegistry::builder()
            .register(sample_spec("search"))
            .register(ToolSpec {
                risk: RiskLevel::RequiresConfirmation,
                execution: ExecutionClass::RequiresActionPlan,
                timeout: timeouts::action_plan(),
                ..sample_spec("purchase")
            })
            .build();

        assert!(registry.find("search").is_some());
        assert!(registry.find("purchase").is_some());
        assert!(registry.find("nonexistent").is_none());

        let purchase = registry.find("purchase").unwrap();
        assert_eq!(purchase.risk, RiskLevel::RequiresConfirmation);
    }

    #[test]
    fn parallel_tools_excludes_sequential() {
        let registry = ToolRegistry::builder()
            .register(sample_spec("read_only"))
            .register(ToolSpec {
                execution: ExecutionClass::Sequential,
                ..sample_spec("write")
            })
            .build();

        let parallel = registry.parallel_tools();
        assert!(parallel.contains(&"read_only"));
        assert!(!parallel.contains(&"write"));
    }

    #[test]
    fn marketplace_registry_matches_installed_agent_tools() {
        let registry = ToolRegistry::marketplace();
        for name in [
            "create_listing",
            "search_inventory",
            "get_listing_details",
            "update_listing",
            "delete_listing",
            "purchase_item",
            "negotiate_item",
            "get_my_listings",
            "get_user_posts",
            "find_related_posts",
            "get_comments",
            "draft_message",
            "draft_comment",
        ] {
            assert!(registry.find(name).is_some(), "missing {name}");
        }
        assert_eq!(registry.specs().len(), 13);
        assert_eq!(
            registry.find("create_listing").unwrap().risk,
            RiskLevel::Recoverable
        );
        for name in [
            "update_listing",
            "delete_listing",
            "purchase_item",
            "negotiate_item",
        ] {
            let spec = registry.find(name).unwrap();
            assert_eq!(spec.risk, RiskLevel::RequiresConfirmation, "{name}");
            assert_eq!(spec.execution, ExecutionClass::RequiresActionPlan, "{name}");
        }
    }
}

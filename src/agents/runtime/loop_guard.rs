//! Loop detection: prevents the agent from calling the same tool with the
//! same arguments repeatedly without progress.

use std::collections::HashMap;

/// Tracks consecutive identical tool calls by canonical digest.
#[derive(Debug)]
pub struct LoopGuard {
    /// digest -> consecutive count
    counts: HashMap<String, u32>,
    last_digest: Option<String>,
    warn_threshold: u32,
    hard_stop_threshold: u32,
}

impl LoopGuard {
    pub fn new(warn_at: u32, stop_at: u32) -> Self {
        Self {
            counts: HashMap::new(),
            last_digest: None,
            warn_threshold: warn_at,
            hard_stop_threshold: stop_at,
        }
    }

    /// Record a tool call. Returns Ok(()) or an error message if the
    /// loop guard should fire.
    pub fn check(
        &mut self,
        tool_name: &str,
        args: &serde_json::Value,
        outcome: &str,
    ) -> Result<(), String> {
        let digest = Self::digest(tool_name, args, outcome);

        // Reset non-consecutive counters.
        if self.last_digest.as_deref() != Some(&digest) {
            if let Some(last) = &self.last_digest {
                self.counts.remove(last);
            }
        }

        self.last_digest = Some(digest.clone());
        let count = self.counts.entry(digest).or_insert(0);
        *count += 1;

        if *count >= self.hard_stop_threshold {
            Err(format!(
                "loop detected: same tool call repeated {} times",
                count
            ))
        } else if *count >= self.warn_threshold {
            Err(format!(
                "loop warning: same tool call repeated {} times",
                count
            ))
        } else {
            Ok(())
        }
    }

    fn digest(tool_name: &str, args: &serde_json::Value, _outcome: &str) -> String {
        use std::fmt::Write;
        let mut combined = String::with_capacity(128);
        let _ = write!(combined, "{}:", tool_name);
        let _ = write!(
            combined,
            "{}",
            serde_json::to_string(args).unwrap_or_default()
        );
        let hash = simple_hash(combined.as_bytes());
        format!("{:x}", hash)
    }
}

/// Simple FNV-1a hash (no external dependency).
fn simple_hash(data: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for &byte in data {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x01000193);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn allows_distinct_calls() {
        let mut guard = LoopGuard::new(2, 3);
        assert!(guard.check("search", &json!({"q": "a"}), "ok").is_ok());
        assert!(guard.check("search", &json!({"q": "b"}), "ok").is_ok());
        assert!(guard.check("list", &json!({}), "ok").is_ok());
    }

    #[test]
    fn warns_then_stops_on_repeats() {
        let mut guard = LoopGuard::new(2, 3);
        let args = json!({"q": "same"});
        assert!(guard.check("search", &args, "ok").is_ok()); // 1st ok
        assert!(guard.check("search", &args, "ok").is_err()); // 2nd warns
        assert!(guard.check("search", &args, "ok").is_err()); // 3rd hard stop
    }

    #[test]
    fn resets_on_different_call() {
        let mut guard = LoopGuard::new(2, 3);
        let args = json!({"q": "same"});
        assert!(guard.check("search", &args, "ok").is_ok());
        assert!(guard.check("search", &args, "ok").is_err());
        // Different tool resets counter.
        assert!(guard.check("other_tool", &json!({}), "ok").is_ok());
        // Same original tool is fresh again.
        assert!(guard.check("search", &args, "ok").is_ok());
    }
}

//! Loop detection: prevents the agent from calling the same tool with the
//! same arguments repeatedly without progress, including alternating cycles.

const HISTORY_CAPACITY: usize = 8;

/// Tracks tool calls and detects consecutive identical calls or alternating loops.
///
/// Uses a fixed-size stack ring buffer of 64-bit digests to ensure zero heap allocations
/// during loop checking.
#[derive(Debug)]
pub struct LoopGuard {
    history: [u64; HISTORY_CAPACITY],
    head: usize,
    count: usize,
    consecutive_count: u32,
    warn_threshold: u32,
    hard_stop_threshold: u32,
}

impl LoopGuard {
    pub fn new(warn_at: u32, stop_at: u32) -> Self {
        Self {
            history: [0; HISTORY_CAPACITY],
            head: 0,
            count: 0,
            consecutive_count: 0,
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

        // Update consecutive count for identical sequential calls
        if self.count > 0 && self.get_recent(0) == digest {
            self.consecutive_count += 1;
        } else {
            self.consecutive_count = 1;
        }

        // Push into ring buffer
        self.history[self.head] = digest;
        self.head = (self.head + 1) % HISTORY_CAPACITY;
        self.count = self.count.saturating_add(1);

        // Check for alternating/repeating patterns (periods 2..=len/2)
        let len = self.count.min(HISTORY_CAPACITY);
        let mut max_cycle_repeats: u32 = 1;

        for p in 2..=(len / 2) {
            // Ignore trivial cycles where all elements are identical (handled by consecutive_count)
            let is_trivial = (1..p).all(|i| self.get_recent(i) == self.get_recent(0));
            if is_trivial {
                continue;
            }

            let mut repeats: u32 = 1;
            while ((repeats + 1) as usize) * p <= len {
                let matches = (0..p)
                    .all(|i| self.get_recent(i) == self.get_recent((repeats as usize) * p + i));
                if matches {
                    repeats += 1;
                } else {
                    break;
                }
            }
            if repeats > max_cycle_repeats {
                max_cycle_repeats = repeats;
            }
        }

        if self.consecutive_count >= self.hard_stop_threshold {
            Err(format!(
                "loop detected: same tool call repeated {} times",
                self.consecutive_count
            ))
        } else if max_cycle_repeats >= self.hard_stop_threshold {
            Err(format!(
                "loop detected: alternating tool call cycle repeated {} times",
                max_cycle_repeats
            ))
        } else if self.consecutive_count >= self.warn_threshold {
            tracing::warn!(
                "loop warning: same call repeated {}",
                self.consecutive_count
            );
            Ok(())
        } else if max_cycle_repeats >= self.warn_threshold {
            tracing::warn!(
                "loop warning: alternating tool call cycle repeated {}",
                max_cycle_repeats
            );
            Ok(())
        } else {
            Ok(())
        }
    }

    #[inline]
    fn get_recent(&self, steps_ago: usize) -> u64 {
        let offset =
            (self.head + HISTORY_CAPACITY - 1 - (steps_ago % HISTORY_CAPACITY)) % HISTORY_CAPACITY;
        self.history[offset]
    }

    fn digest(tool_name: &str, args: &serde_json::Value, _outcome: &str) -> u64 {
        let mut hasher = Fnv1aHasher::new();
        hasher.update(tool_name.as_bytes());
        hasher.update(b":");
        let _ = serde_json::to_writer(&mut hasher, args);
        hasher.finish()
    }
}

impl Default for LoopGuard {
    fn default() -> Self {
        Self::new(2, 3)
    }
}

/// FNV-1a hasher implementing `std::io::Write` for zero-allocation JSON streaming.
struct Fnv1aHasher {
    hash: u64,
}

impl Fnv1aHasher {
    const OFFSET_BASIS: u64 = 0xcbf29ce484222325;
    const PRIME: u64 = 0x01000193;

    #[inline]
    fn new() -> Self {
        Self {
            hash: Self::OFFSET_BASIS,
        }
    }

    #[inline]
    fn update(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            self.hash ^= byte as u64;
            self.hash = self.hash.wrapping_mul(Self::PRIME);
        }
    }

    #[inline]
    fn finish(self) -> u64 {
        self.hash
    }
}

impl std::io::Write for Fnv1aHasher {
    #[inline]
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.update(buf);
        Ok(buf.len())
    }

    #[inline]
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
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
        assert!(guard.check("search", &args, "ok").is_ok()); // 2nd warns but continues
        assert!(guard.check("search", &args, "ok").is_err()); // 3rd hard stop
    }

    #[test]
    fn resets_on_different_call() {
        let mut guard = LoopGuard::new(2, 3);
        let args = json!({"q": "same"});
        assert!(guard.check("search", &args, "ok").is_ok());
        assert!(guard.check("search", &args, "ok").is_ok()); // warn at threshold
                                                             // Different tool resets counter.
        assert!(guard.check("other_tool", &json!({}), "ok").is_ok());
        // Same original tool is fresh again.
        assert!(guard.check("search", &args, "ok").is_ok());
    }

    #[test]
    fn intercepts_oscillating_loop_ab_ab() {
        let mut guard = LoopGuard::new(2, 2);
        let args_a = json!({"query": "A"});
        let args_b = json!({"query": "B"});

        assert!(guard.check("tool_a", &args_a, "ok").is_ok()); // A (1)
        assert!(guard.check("tool_b", &args_b, "ok").is_ok()); // B (1)
        assert!(guard.check("tool_a", &args_a, "ok").is_ok()); // A (2)
                                                               // 2nd cycle of (A -> B) hits stop threshold = 2
        let err = guard.check("tool_b", &args_b, "ok");
        assert!(err.is_err());
        assert!(err.unwrap_err().contains("alternating tool call cycle"));
    }

    #[test]
    fn warns_then_stops_on_oscillating_cycle() {
        let mut guard = LoopGuard::new(2, 3);
        let args_a = json!({"action": "read"});
        let args_b = json!({"action": "write"});

        assert!(guard.check("tool_a", &args_a, "").is_ok()); // A
        assert!(guard.check("tool_b", &args_b, "").is_ok()); // B
        assert!(guard.check("tool_a", &args_a, "").is_ok()); // A
        assert!(guard.check("tool_b", &args_b, "").is_ok()); // B (warns at 2 cycles)
        assert!(guard.check("tool_a", &args_a, "").is_ok()); // A
        let err = guard.check("tool_b", &args_b, ""); // B (stops at 3 cycles)
        assert!(err.is_err());
        assert!(err
            .unwrap_err()
            .contains("alternating tool call cycle repeated 3 times"));
    }

    #[test]
    fn digest_deterministic_and_sensitive_to_args() {
        let d1 = LoopGuard::digest("search", &json!({"q": "foo"}), "");
        let d2 = LoopGuard::digest("search", &json!({"q": "foo"}), "");
        let d3 = LoopGuard::digest("search", &json!({"q": "bar"}), "");
        let d4 = LoopGuard::digest("other", &json!({"q": "foo"}), "");

        assert_eq!(d1, d2);
        assert_ne!(d1, d3);
        assert_ne!(d1, d4);
    }
}

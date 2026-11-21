> last-verified: 2026-11-21

# Memory System

Prompt-memory layers (§16), injected per request between page context and
episodic recall:

* **Working** — client `WorkingMemory`: topic, filters, recent post ids
  (newest-first, cap 8; only the 4 newest ride `toPromptFragment`), pending
  draft flag. Rides `page_context` into every chat request; dies with the
  session.
* **Session** — server `agent_session_memory` (migration `0093`): tool runs
  record session search/view lines (`record_session_search` /
  `record_session_view` in `src/agents/tools/listing.rs`), injected via
  `session_context_lines`; clearable through `DELETE` session-memory route.
* **User skills** — server `user_agent_skills` (migration `0098`) surfaced in
  `agent_memory.rs` prompt assembly.
* **Episodic** — server `agent_memories` rows (summary + importance +
  embedding), written via the manual API `POST /api/agent/memories`
  (`src/api/agent_memory.rs`); vector recall picks ≤3 and fires only at
  `privacy_level == "standard"`.
* **Profile** — server `user_agent_profiles` (locations/categories/budget/
  custom instructions) with explicit privacy levels.

Retrieval (§20): memory context is composed per request from page context +
session lines + skills + recalled episodes — never the full chat log (history
window is last 10 messages). Raw audio/transcripts are not persisted (§75).

Prompt-injection defence (§76): tool results are fenced as untrusted data at
the provider boundary and persona/system rules forbid executing their content
(see tests `injected_listing_instructions_stay_inert_data`).

> last-verified: 2026-08-23

# Memory System

Three layers (§16):

* **Working** — client `WorkingMemory`: topic, filters, recent post ids
  (newest-first, cap 8), pending draft flag. Rides `page_context` into every
  chat request; dies with the session.
* **Episodic** — server `agent_memories` rows (summary + importance +
  embedding), written only for memorable turns; vector recall picks ≤3.
* **Profile** — server `user_agent_profiles` (locations/categories/budget/
  custom instructions) with explicit privacy levels.

Retrieval (§20): memory context is composed per request from page context +
session row + recalled episodes — never the full chat log (history window is
last 10 messages). Raw audio/transcripts are not persisted (§75).

Prompt-injection defence (§76): tool results are fenced as untrusted data at
the provider boundary and persona/system rules forbid executing their content
(see tests `injected_listing_instructions_stay_inert_data`).

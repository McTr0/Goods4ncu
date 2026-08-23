> last-verified: 2026-08-23

# Proactive System

The engine decides *whether* to react, never what to say (§36). Triggers:
post_opened, search_results, message_received, tool_completed.

Reactions are levelled (§38): 0 gesture-only, 1 micro reaction, 2 brief
comment, 3 suggestion. Defaults stay at 0/1; speech-grade levels respect a
90 s global spoken cooldown, degrading to a silent micro reaction instead of
talking more (§39, §79).

Per-trigger cooldowns suppress repeats (post 45 s, results 30 s, messages
60 s, tools 20 s). A busy user caps any reaction at gesture-only. Every
trigger carries a gaze target so attention moves even when speech does not.

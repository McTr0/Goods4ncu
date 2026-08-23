> last-verified: 2026-08-23

# Attention System

`AttentionController` holds primary/secondary targets (user, chat, post,
postList, notification, message, none) with optional locks (§40). Locks stop
weaker stimuli from stealing focus; `focusUser()` overrides any lock — the
barge-in path depends on it.

Gaze flows through `GazeSmoother` (exponential approach, snap-on-settle) so
the eyes glide instead of teleporting (§42). The host ticker publishes
smoothed values to the body every frame.

Attention changes are announced on the bus (`ATTENTION_CHANGED`) and rendered
live in the debug console.

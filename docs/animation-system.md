> last-verified: 2026-08-23

# Animation System

## Motion library & mapping (§27–28)

Semantic tags (`greeting`, `thinking`, `toolWorking`, …) map to executable
steps in `motion_library.dart`. A step is either an OpenRig clip name or a
procedural gesture (gaze shift / head tilt / hold). Replacing the body means
replacing this one table — runtime code never references clips.

Current OpenRig inventory: idle(loop)/pressed/selected/wave/poke/high_five/
encourage/acknowledge on bones root/head/left_action/right_action.

## Scheduler guarantees (§29–31)

* Strict-priority preemption; generation token discards stale steps after
  cancellation so no old gesture can resurrect.
* Micro-motion (blink/sway in Live2DController) runs as an independent base
  layer and must never suspend during plans.
* Idle tiers: micro (<30 s, blink/sway), short (30–120 s, idleShift), long
  (>120 s, stretch / gaze drift / SLEEPING after ~6 min).

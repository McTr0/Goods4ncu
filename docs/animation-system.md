> last-verified: 2026-08-23

# Animation System

## Motion library & mapping (§27–28)

Semantic tags (`greeting`, `thinking`, `toolWorking`, …) map to executable
steps in `motion_library.dart`. A step is either a Cubism gesture (nod /
shake) or a procedural one (gaze shift / head tilt / hold) written as raw
parameter ramps. Replacing the body means replacing this one table — runtime
code never references model assets.

Clip-style steps map to Cubism gestures (nod/shake) or degrade to procedural
gaze/tilt choreography — the real body is the Doro.moc3 model driven by raw
parameter writes (AngleX/Y/Z, BodyAngleZ, Breath, EyeL/R, MouthOpenY/Form).
The former OpenRig sprite clip set was removed with that engine.

## Scheduler guarantees (§29–31)

* Strict-priority preemption; generation token discards stale steps after
  cancellation so no old gesture can resurrect.
* Micro-motion (blink/sway in Live2DController) runs as an independent base
  layer and must never suspend during plans.
* Idle tiers: micro (<30 s, blink/sway), short (30–120 s, idleShift), long
  (>120 s, stretch / gaze drift / SLEEPING after ~6 min).

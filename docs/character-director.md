> last-verified: 2026-08-23

# Character Director

The director converts *why* into *what*: states, signals and emotions become
semantic motion plans; nothing above the library knows clip names (§25–26).

Pipeline: event → BehaviorPlanner.planForState/planForSignal → MotionPlan →
AnimationScheduler.request → renderer hooks (clip / gaze / tilt).

Priority arbitration (§29): INTERRUPT=100, USER_INTERACTION=90,
SPEECH_GESTURE=70, EMOTION=60, IDLE=10. Higher preempts instantly (first step
applies synchronously); equal priority is rejected unless the caller marks
the request as a sequential successor of its own kind (state transitions do).

Functional states (listening/thinking/toolUsing/speaking) ride SPEECH_GESTURE
so they always outrank affective overlays; INTERRUPTED plans always play at
100 and resolve into LISTENING or user-floor (barge-in contract).

> last-verified: 2026-08-23

# Realtime Voice

## Input path (§5, §87)

microphone → platform recognizer (`speech_dictation_{native,web}`) → interim
results drive USER_SPEECH_START / partial transcripts → recognizer end (or
final result) closes the turn → transcript handed to the agent SSE flow.

No fixed "N seconds of silence" rule: interim results keep the turn open so
> 我想找一个……(停顿)……二手显示器。
stays one turn.

## Output path (§46–47)

`VoiceProvider.speak(text, style)` returns a stream of started/boundary/ended
events. Web implements it over SpeechSynthesis (js_interop); other platforms
get `UnsupportedVoiceProvider` (degrade to text, Level 2). Mouth opening is
pulsed on boundaries plus a sine micro-loop while speaking — amplitude-grade,
phoneme mapping reserved for a future provider (§44).

## Barge-in (§8, §48)

Any partial transcript while `assistantSpeaking` fires `TurnTakingEngine.
bargeIn()`: TTS `stop()` first (provider contract), mouth closed, gesture
cancelled by scheduler INTERRUPT priority, eyes to user, state INTERRUPTED→
userSpeaking. Latency is recorded on the bus as `interruptLatencyMs`; target
< 300 ms.

## Degradation ladder (§74)

L4 realtime voice + body → L3 TTS + body (web) → L2 text + body (today's
default everywhere) → L1 text agent → L0 marketplace only.

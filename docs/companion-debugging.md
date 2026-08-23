# Companion Debugging

> last-verified: 2026-08-23


Two surfaces, both gated by COMPANION_ENABLED:

* **Debug console** — route `/companion/debug`: live state pill, emotion
  vector bars, attention (with lock badge), harness button driving
  LISTENING→THINKING→SPEAKING→IDLE with zero LLM.
* **Timeline debugger** — route `/companion/timeline`: rolling timestamped
  event log (bus-wide) for latency analysis, e.g.

```text
12:01:03.102 userSpeechStart
12:01:03.110 characterStateChanged thinking
12:01:03.524 toolStarted search_inventory
12:01:03.811 toolFinished
12:01:04.021 ttsStart
12:01:04.023 characterStateChanged speaking
```

Latency metrics: firstToken/turn totals also land in the server's structured
per-stream log line and agent_runs; interrupt latency rides the INTERRUPTED
event payload (`interruptLatencyMs`).

Enable with `COMPANION_ENABLED=true` (default) and open
`http://localhost:3001/companion/debug`.

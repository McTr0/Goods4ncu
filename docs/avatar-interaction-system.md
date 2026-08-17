# Avatar interaction system

## Product contract

Avatar actions are explicit presentation feedback, not presence facts. The UI
may play an action after a local tap, character selection, publish success, or
another user-visible event. It must not turn `online`, `read`, `typing`, push
delivery, or inferred emotion into character motion.

Callers send semantic cues (`wave`, `celebrate`, `thinking`) through
`AvatarActionController`. Each call carries a monotonically increasing local
revision, so the same action can be replayed without briefly switching to an
unrelated state. Renderers map those cues to their own frames, bones, or
parameters; feature pages never address animation frames directly.

## Progressive rendering stack

1. **Poster and transform layer (shipped baseline).** Every character has a
   512 px transparent WebP poster. Lists at 24/48 px stay static. Large previews
   use translate, rotate, and scale only, within a `RepaintBoundary`.
2. **Authored sprite layer.** Frequently used actions can add a versioned sprite
   atlas and manifest while keeping the same semantic cue API. This is the
   default upgrade for broad Android, iOS, and Web coverage.
3. **Rigged flagship layer.** A small number of detail/relationship surfaces may
   lazy-load Rive or an approved Live2D Cubism runtime. The locally supplied
   `Doro/` source is a Cubism 3 model with physics, expressions, and an idle
   motion. It should only be bundled after its redistribution/runtime licences
   are recorded; unsupported devices fall back to the same poster.

The feature layer therefore remains independent of Rive, Live2D, or a future
3D renderer. A renderer only needs to implement the cue contract and provide a
poster fallback.

## Interaction mapping

| User-visible event | Cue | Default rendering |
| --- | --- | --- |
| Tap or press | `pressed` | quick squash |
| Choose character | `selected` | short lift |
| Tap “打招呼” | `wave` | side-to-side greeting |
| Publish or finish a task | `celebrate` | jump and bounce |
| Tap “思考” or assistant is locally composing | `thinking` | slow tilted bob |
| User confirms an action | `confirmedByUser` | small affirmative lift |

Actions should run once and return visually to a neutral poster. Continuous
idle is allowed only on a focused large surface and must respect reduced-motion
settings.

## Performance budgets

- Poster: 512×512 WebP with alpha, normally under 50 KB.
- Decode buckets: 96 px for list/profile tokens, 320 px for 160 px previews,
  and 512 px only for large detail surfaces.
- At most one continuously animated avatar per screen; off-screen and route
  background avatars stop ticking.
- Sprite atlases are lazy-loaded and cached by manifest version. Rigged models
  are never loaded by list cells and should be released when the detail route
  is disposed.
- `MediaQuery.disableAnimations` always selects a static frame. Battery saver
  and low-memory hooks can force the same poster-only path later.

## Doro model integration gate

The supplied `Doro/` directory contains `Doro.moc3`, one 2048 texture, physics,
eleven expressions, and an idle motion. Before shipping the rigged runtime:

1. record the model redistribution licence and the Cubism SDK/runtime terms;
2. export a deterministic poster and small action regression set;
3. prototype lazy loading on Android, iOS, CanvasKit, and HTML renderers;
4. measure first-frame time, resident texture memory, GPU time, and battery;
5. retain poster fallback for Web, reduced motion, and failed model loads.

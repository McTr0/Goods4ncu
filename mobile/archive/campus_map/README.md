# campus map chat rooms (archived)

Removed from the app on 2026-08-23; to be revisited later.

## What lives here

- `pages/campus_map_page.dart` — interactive campus map with per-location
  chat-room directory, route planner, and enter-chat flow.
- `models/location_space.dart` — CampusLocationSpace / Recommendation /
  Presence models (`/api/chat/location-spaces/*` wire shapes).
- `services/campus_location_service.dart` — one-shot coarse geolocation.
- `test/` — the page and model test suites as they were when archived.

## Restore checklist

1. Move `pages/`, `models/`, `services/` back under `mobile/lib/…`
   (paths are preserved) and `test/` back under `mobile/test/`.
2. Re-add the `/campus-map` route in `lib/router/app_router.dart`.
3. Re-add the location-space section in `conversation_list_page.dart`
   (state fields, `_loadLocationSpaces`, `_enterLocationSpace`,
   `_locateAndEnter`, `_LocationSpaceSection`) — see git history at
   commit a3eab5b for the exact code.
4. Re-add `ChatService.getLocationSpaces / recommendLocationSpace /
   setLocationSpacePresence / enterLocationSpace / joinLocationSpace /
   createLocationChild`.
5. Restore l10n keys `campusMap*` and `location*` from git history
   (app_zh.arb / app_en.arb at a3eab5b) and run `flutter gen-l10n`.
6. Remove this directory from the `exclude` list in
   `analysis_options.yaml`.

The backend endpoints (`/api/chat/location-spaces/*`) were kept; only
the frontend was archived.

# Repository Guidelines

## Project Structure & Module Organization

`src/` contains the Rust backend. Keep HTTP handlers in `src/api/`, business logic in `src/services/`, data access in `src/repositories/`, agent logic in `src/agents/`, middleware in `src/middleware/`, and provider integrations in `src/llm/`. Put schema changes in numbered files under `migrations/` such as `0017_add_feature.sql`.

`tests/` holds Rust integration and regression suites like `chat_integration.rs` and `admin_auth_regression.rs`. The Flutter app lives in `mobile/`: feature code is under `mobile/lib/`, and Dart tests live in `mobile/test/`. Longer design notes and setup references are in `docs/`.

## Build, Test, and Development Commands

Use `cargo check --locked` for a fast backend compile check. Run `cargo run` to start the backend locally. Before merging, CI expects `cargo fmt -- --check`, `cargo clippy --all-targets -- -D warnings`, and `cargo test -- --nocapture --test-threads=1`.

For quicker backend validation, `cargo test --lib` runs library tests only. For mobile work, run `cd mobile && flutter pub get`, then `flutter analyze` and `flutter test`.

DB-backed backend tests need PostgreSQL with `pgvector` plus local secrets such as `DATABASE_URL`, `TEST_DATABASE_URL`, `JWT_SECRET`, and an LLM key. Sample config lives in `docs/.env.example` and `docs/config.toml.example`.

If the user says Codex was restarted, assume local long-running processes may have been killed. Before continuing GUI work or integration validation, check and restart the relevant services, typically the Rust backend on `127.0.0.1:3000` and the Flutter Web/static frontend on `127.0.0.1:3001`.

For Codex Browser GUI validation after a restart, do not trust port listeners alone. A stale process can still appear in `lsof` while returning `Empty reply from server` or failing inside the in-app browser. Always verify the backend with a real health/login request such as `GET /api/health` and, when auth matters, `POST /api/auth/login`; verify the frontend by actually loading `http://localhost:3001` in Codex Browser. If either service gives an empty response, stop the stale process and restart from the current workspace code. For Flutter Web static validation, rebuild `mobile/build/web` after UI edits and serve it with a host binding that Codex Browser can reach, for example `python3 -m http.server 3001 --bind 0.0.0.0` from `mobile/build/web`.

### Flutter Web stale-bundle trap (learned twice, 2026-08-23)

The Dart web compiler emits Chinese (and other non-BMP) string literals as `\uXXXX` escapes inside `main.dart.js`. Plain `grep '中文' mobile/build/web/main.dart.js` therefore always reports 0 matches and falsely "proves" the bundle is clean or current — it proves nothing. This hid two stale-bundle incidents in one day.

After any frontend change, before claiming the served UI is updated:

1. Rebuild: `flutter build web --dart-define=COMPANION_ENABLED=true`.
2. Decode before searching — e.g. Python:
   `re.sub(r'\\u([0-9a-fA-F]{4})', lambda m: chr(int(m.group(1),16)), js)` — then assert expected strings are present and removed strings are gone.
3. Compare hashes between the local `build/web/main.dart.js` and what `http://127.0.0.1:3001/main.dart.js` actually serves (`sha256sum` both). A mismatch means :3001 is serving a stale build; rebuild or restart the server.
4. Remember `python3 -m http.server` serves live from disk, but browsers cache aggressively — tell the user to hard-reload (Cmd+Shift+R) after bundle swaps.

Never report frontend verification based on undecoded greps of compiled JS.

## Coding Style & Naming Conventions

Rust uses the default `rustfmt` style with 4-space indentation. Follow standard naming: modules and functions in `snake_case`, types in `PascalCase`, constants in `SCREAMING_SNAKE_CASE`. Existing patterns matter: services use names like `OrderService`, tools use names like `CreateListingTool`.

Keep the current layering intact: handlers should call services and repositories instead of embedding ad hoc SQL. In Flutter, follow `flutter_lints`, keep pages/services/providers split by responsibility, and route new user-facing strings through `mobile/lib/l10n/`.

## Companion Runtime (小昌)

Live2D AI companion. Runtime lives in `mobile/lib/companion/`; persona layers in `/persona/*.md` (loaded server-side via `src/agents/persona.rs`); journey script at `scripts/agent_journey.sh`.

- Flags: `AGENT_ENABLED` (server AI endpoints), `COMPANION_ENABLED` (dart-define, runtime shell). Both off ⇒ plain marketplace.
- Tests: `flutter test test/companion` (unit) — full gates per repo rules.
- Architecture and subsystem docs: see **docs/companion-architecture.md** and the linked companion-* documents. (Frontend debug surfaces — `/companion/debug`, `/companion/timeline`, `?agentDebug=true` overlay — were removed 2026-08-24; debug via server structured logs / agent_runs.)
- Rule of thumb: when touching `mobile/lib/companion/**` or agent prompt assembly, update the matching companion doc and refresh its `last-verified:` line.

## Testing Guidelines

Name Rust tests by behavior and purpose, using suffixes like `_integration.rs` and `_regression.rs`. Keep Dart tests under `mobile/test/` with `_test.dart` names. Add or update tests for new endpoints, auth changes, moderation paths, and bug fixes; there is no stated coverage target, but PRs are expected to prove the changed path.

After adding any feature, also verify the affected user journey manually with Codex Browser. Simulate realistic user operations in the UI, not only API calls or scripted tests, and record what path was checked in the final summary or PR test plan.

## Commit & Pull Request Guidelines

Use Conventional Commits, typically with a scope: `fix(auth): block refresh replay`, `feat(mobile): add watchlist badge`. Feature branches usually follow `feat/<description>` or `fix/<description>`.

PRs should be rebased onto the current mainline branch, include a short summary and test plan, and call out migrations, config changes, or follow-up risks. Include screenshots for visible mobile UI changes and link the relevant issue when one exists.

## Commit and Push Cadence

- Commit at each independently verifiable milestone, or roughly every 15–30 minutes during a longer task; do not accumulate an entire feature into one oversized commit.
- Keep commits granular: one behavior change, focused refactor, test update, documentation update, or migration per commit. Do not mix unrelated work, drive-by formatting, generated artifacts, or pre-existing user changes.
- Every commit message must use Conventional Commits with an appropriate scope and imperative summary, for example `fix(mobile): keep chat navigation visible` or `test(chat): cover stale refresh responses`.
- Run the relevant formatter, analyzer, and focused tests before committing. Before pushing, inspect `git status`, the staged diff, the commit contents, and the target branch/remote.
- After a milestone passes its checks, push the commit to the current branch's configured remote. Use normal `git push`; never force-push or rewrite shared history unless the user explicitly authorizes it.
- Never commit or push secrets, local environment files, credentials, temporary build output, or unrelated changes. If the worktree already contains user changes, isolate the agent's files and call out anything that cannot be safely separated.
- Report each commit hash, the pushed branch/remote, and the validation completed; if commit or push is blocked, state the exact blocker instead of silently deferring it.

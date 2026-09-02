# Copilot Instructions for Good4NCU

Good4NCU is a campus marketplace platform with AI-powered features including semantic search, real-time chat, and negotiation assistance. The backend is Rust (Axum + PostgreSQL + pgvector), and the mobile app is Flutter.

## Build, Test, and Lint Commands

### Backend (Rust)

```bash
# Fast compile check
cargo check --locked

# Run backend locally
cargo run

# Format check (required for CI)
cargo fmt -- --check

# Linting (required for CI, no warnings allowed)
cargo clippy --all-targets -- -D warnings

# Run all tests (requires PostgreSQL with pgvector)
cargo test -- --nocapture --test-threads=1

# Run only library tests (faster, skips integration tests)
cargo test --lib

# Run a single test
cargo test test_name -- --nocapture --test-threads=1

# Build release binary
cargo build --release --locked
```

**Test environment requirements:**
- PostgreSQL with `pgvector` extension
- Environment variables: `DATABASE_URL`, `TEST_DATABASE_URL`, `JWT_SECRET`, `GEMINI_API_KEY` (or test key)
- Sample configs: `docs/.env.example`, `docs/config.toml.example`

### Mobile (Flutter)

```bash
cd mobile

# Install dependencies
flutter pub get

# Analyze code (required for CI)
flutter analyze

# Run tests
flutter test

# Run a single test file
flutter test test/path/to/test_file.dart

# Run the app
flutter run
```

### Docker

```bash
# Build backend image
docker build -t goods4ncu:dev .
```

## High-Level Architecture

### Layered Architecture

The backend follows a strict layered architecture:

```
API Handlers (src/api/)
    ↓
Services (src/services/)
    ↓
Repositories (src/repositories/)
    ↓
Database (PostgreSQL + pgvector)
```

**Key principle:** Handlers should call services; services orchestrate business logic and call repositories. Never embed ad hoc SQL in handlers or services—use repository methods.

### Service Manager & Event Loop

The `ServiceManager` (in `src/services/mod.rs`) is the central orchestrator:
- Manages shared state (database pool, LLM provider, repositories)
- Runs a background event loop that processes `BusinessEvent`s
- Spawns worker tasks: `OrderWorker` (payment timeouts, auto-confirm), `HitlExpireWorker` (negotiation expiry)

Services emit events to the event loop for async operations (e.g., sending notifications, updating order status).

### AI Agent System

Located in `src/agents/`:
- **router.rs**: Lightweight decision tree for intent classification
- **tools.rs**: Agent tool implementations (SearchListingsTool, CreateListingTool, etc.)
- **negotiate.rs**: Negotiation agent using the HITL (Human-in-the-Loop) pattern with `HumanApprovalTool`
- Uses the Rig framework for agent orchestration

LLM providers (Gemini, MiniMax) are in `src/llm/` and implement the `LlmProvider` trait.

### Database Schema Patterns

- **Money storage**: All prices stored as `i32` in cents. Use `utils::yuan_to_cents()` and `cents_to_yuan()` for conversion.
- **Vector embeddings**: The `documents` table stores pgvector embeddings for semantic search of listings.
- **State machines**: Orders use a state machine: `pending → paid → shipped → completed/cancelled`
- **Chat connections**: Buyer-seller connections follow a handshake flow: `pending → connected/rejected`

### Mobile Architecture

Flutter app structure (`mobile/lib/`):
- **pages/**: UI screens (17 pages including home, login, chat, listing_detail)
- **services/**: API clients organized by domain (13 services, e.g., `auth_service.dart`, `listings_service.dart`)
- **providers/**: State management using Provider pattern (e.g., `ChatNotifier`)
- **l10n/**: Internationalization (ARB → Dart generation)
- **theme/**: Centralized theme colors and dimensions

## Key Conventions

### Project Structure

- **Backend modules**:
  - `src/api/`: HTTP handlers (Axum routes)
  - `src/services/`: Business logic and background workers
  - `src/repositories/`: Data access layer (traits + Postgres implementations)
  - `src/agents/`: AI agent logic
  - `src/middleware/`: Axum middleware (rate limiting, etc.)
  - `src/llm/`: LLM provider integrations

- **Migrations**: Numbered SQL files in `migrations/` (e.g., `0017_add_feature.sql`). Applied automatically by `sqlx` on startup.

- **Tests**: 
  - `tests/`: Integration and regression tests with suffixes like `_integration.rs`, `_regression.rs`, `_e2e.rs`
  - Mobile tests: `mobile/test/` with `_test.dart` suffix

### Naming Conventions

**Rust:**
- Modules and functions: `snake_case`
- Types: `PascalCase`
- Constants: `SCREAMING_SNAKE_CASE`
- Services: `*Service` (e.g., `OrderService`)
- Tools: `*Tool` (e.g., `CreateListingTool`)

**Flutter:**
- Follow `flutter_lints`
- Split code by responsibility: pages/services/providers
- Route user-facing strings through `mobile/lib/l10n/`

### Coding Patterns

**Repository pattern:**
```rust
// Define trait in src/repositories/traits.rs
#[async_trait]
pub trait ListingRepository: Send + Sync {
    async fn create(&self, listing: NewListing) -> Result<Listing>;
}

// Implement for Postgres in src/repositories/listing_repo.rs
pub struct PostgresListingRepository { /* ... */ }
```

**Service pattern:**
```rust
// Services coordinate business logic
pub struct OrderService {
    repo: Arc<dyn OrderRepository>,
    event_tx: mpsc::Sender<BusinessEvent>,
}
```

**Event-driven operations:**
```rust
// Emit events for async processing
self.event_tx.send(BusinessEvent::OrderCreated { order_id }).await?;
```

### Testing Guidelines

- Name tests by behavior, not implementation (e.g., `test_expired_jwt_returns_401`)
- Integration tests need running PostgreSQL with `pgvector`
- Tests run with `--test-threads=1` to avoid database conflicts
- Add tests for: new endpoints, auth changes, moderation paths, bug fixes
- No specific coverage target, but PRs should prove changed paths work

### Commit & PR Guidelines

**Commit format:**
```
<type>(<scope>): <description>

Examples:
- feat(auth): add refresh token rotation
- fix(chat): prevent message replay attacks
- refactor(api): extract middleware to separate module
- docs(readme): update installation steps
```

**Common scopes:** `auth`, `api`, `llm`, `db`, `cli`, `mobile`, `ci`

**PR requirements:**
1. Rebase onto latest `main`
2. All tests pass: `cargo test --lib` minimum
3. Linting clean: `cargo clippy --all-targets -- -D warnings`
4. Formatted: `cargo fmt -- --check`
5. Include test plan in PR description
6. Call out migrations, config changes, or follow-up risks
7. Screenshots for mobile UI changes

### Configuration Management

**Priority order:**
1. Environment variables (highest)
2. `CONFIG_FILE` environment variable path
3. `./goods4ncu.toml`
4. `./config/goods4ncu.toml`

**Required environment variables:**
- `DATABASE_URL`: PostgreSQL connection string
- `JWT_SECRET`: JWT signing key (minimum 32 characters)
- `GEMINI_API_KEY` or `MINIMAX_API_KEY`: LLM provider key

**Optional TOML config:** See `docs/config.toml.example` for server, LLM, rate limiting, marketplace, and auth settings.

### Security & Moderation

- All user input should go through content moderation
- Handlers accepting user content must test for `422 ContentViolation` responses
- Use parameterized queries (never string concatenation for SQL)
- Admin actions are logged to `admin_audit_logs` table
- JWT tokens: Access tokens expire in 24h, refresh tokens in 7 days

### CLI Admin Commands

```bash
# Promote user to admin
cargo run admin promote <username>
```

## Documentation References

For deeper technical details:
- **AGENTS.md**: This file (duplicated in `docs/AGENTS.md`) - repository guidelines summary
- **docs/README.md**: Full project overview, features, quick start
- **docs/DEVELOPER.md**: Development workflow, agent team coordination, architecture decisions
- **docs/CONTRIBUTING.md**: Branch strategy, conventional commits, PR process
- **docs/ARCHITECTURE_AUDIT.md**: Architecture diagnostics and evolution direction
- **docs/chat_system.md**: Detailed chat system design and WebSocket protocol
- **docs/API_CHAT.md**: Chat API documentation

Priority reading order:
1. docs/PLAN.md (current execution plan)
2. docs/ARCHITECTURE_AUDIT.md (architecture overview)
3. docs/SPEC_PLANS.md (subsystem plans)
4. docs/DEVELOPER.md / docs/CONTRIBUTING.md (development workflow)

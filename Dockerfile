# =============================================================================
# Goods4ncu Backend Dockerfile
# Multi-stage build for Rust backend with minimal runtime image
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Build
# -----------------------------------------------------------------------------
FROM rust:1-slim-bookworm AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy manifests first for dependency caching
COPY Cargo.toml Cargo.lock ./

# Create dummy main.rs for dependency compilation
RUN mkdir -p src && echo "fn main() {}" > src/main.rs

# Build dependencies only (this layer will be cached)
RUN cargo build --release && rm -rf src

# Copy build-time resources required by compile-time macros.
COPY migrations ./migrations
COPY persona ./persona

# Copy actual source code
COPY src ./src

# Build the application
RUN touch src/main.rs && cargo build --release

# -----------------------------------------------------------------------------
# Stage 2: Runtime
# -----------------------------------------------------------------------------
FROM gcr.io/distroless/cc-debian12:nonroot AS runtime

# Set labels
LABEL org.opencontainers.image.title="Goods4ncu Backend"
LABEL org.opencontainers.image.description="Agentic secondhand marketplace for Chinese university campuses"
LABEL org.opencontainers.image.source="https://github.com/McTr0/Goods4ncu"

# Copy the binary from builder
COPY --from=builder /app/target/release/goods4ncu /usr/local/bin/goods4ncu

USER nonroot:nonroot

# Set working directory
WORKDIR /home/nonroot

# Expose port
EXPOSE 3000

# Set environment
ENV RUST_LOG=info
ENV RUST_BACKTRACE=1

# Health check — readiness, so a draining container is marked unhealthy and
# stops receiving traffic before its listener closes.
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD ["/usr/local/bin/goods4ncu", "--health-check"]

# The app drains on SIGTERM. Make it explicit so the signal is never swapped
# for SIGKILL, which would truncate in-flight responses on every deploy.
# Runtime grace period must exceed SHUTDOWN_DRAIN_SECS + SHUTDOWN_TIMEOUT_SECS
# (default 5 + 25 = 30s); see docs/operations.md.
STOPSIGNAL SIGTERM

# Run the application. ENTRYPOINT exec form means the binary is PID 1 and
# receives STOPSIGNAL directly, with no shell to swallow it.
ENTRYPOINT ["/usr/local/bin/goods4ncu"]

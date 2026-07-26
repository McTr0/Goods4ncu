#!/usr/bin/env bash
# Load smoke against the SLO targets (roadmap: 普通 API p95 < 300ms,
# Feed/Search p95 < 500ms).
#
# Fires N requests at concurrency C against a running instance and computes
# p50/p95 per endpoint, failing when an SLO is exceeded. This is a smoke, not
# a capacity test: it proves the SLO measurement harness and catches gross
# latency regressions; production capacity validation (10万注册/数百 RPS) needs
# production-shaped data and hardware.
#
# The target instance must run with an elevated rate limit for the drill
# (all traffic comes from one IP), e.g.:
#   RATE_LIMIT_MAX_REQUESTS=100000 SERVER_PORT=3999 ./goods4ncu
#
# Usage: BASE_URL=http://127.0.0.1:3999 ./scripts/load_smoke.sh [requests] [concurrency]

set -euo pipefail

# Local drills must not route through any HTTP(S) proxy: proxied loopback
# requests fail or return proxy errors (502) that masquerade as app failures.
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY 2>/dev/null || true
export NO_PROXY='*' no_proxy='*'

BASE_URL="${BASE_URL:-http://127.0.0.1:3999}"
REQUESTS="${1:-200}"
CONCURRENCY="${2:-16}"

if ! curl -sf -o /dev/null "$BASE_URL/api/readyz"; then
    echo "[load] $BASE_URL is not ready" >&2
    exit 2
fi

run_endpoint() {
    local name="$1" path="$2" slo_ms="$3"
    local out
    out="$(mktemp)"
    seq "$REQUESTS" | xargs -P "$CONCURRENCY" -I{} \
        curl -s -o /dev/null -w '%{http_code} %{time_total}\n' "$BASE_URL$path" >> "$out"

    local failures
    failures=$(awk '$1 !~ /^2/ { n++ } END { print n+0 }' "$out")
    # p50/p95 over successful requests, milliseconds.
    local stats
    stats=$(awk '$1 ~ /^2/ { print $2 * 1000 }' "$out" | sort -n | awk -v total="$REQUESTS" '
        { v[NR] = $1 }
        END {
            if (NR == 0) { print "0 0 0"; exit }
            p50 = v[int(NR * 0.50) == 0 ? 1 : int(NR * 0.50)]
            p95 = v[int(NR * 0.95) == 0 ? 1 : int(NR * 0.95)]
            print NR, p50, p95
        }')
    rm -f "$out"
    local ok p50 p95
    read -r ok p50 p95 <<< "$stats"

    printf '[load] %-28s ok=%s fail=%s p50=%.1fms p95=%.1fms (SLO %sms)\n' \
        "$name" "$ok" "$failures" "$p50" "$p95" "$slo_ms"

    if [ "$failures" -gt 0 ]; then
        echo "[load] FAIL: $name had $failures non-2xx responses" >&2
        return 1
    fi
    if awk -v p95="$p95" -v slo="$slo_ms" 'BEGIN { exit !(p95 > slo) }'; then
        echo "[load] FAIL: $name p95 ${p95}ms exceeds SLO ${slo_ms}ms" >&2
        return 1
    fi
}

status=0
run_endpoint "listings (普通 API)"        "/api/listings?limit=20"                    300 || status=1
run_endpoint "listing categories"         "/api/categories"                            300 || status=1
run_endpoint "recommendations feed"       "/api/recommendations/feed?direction=offer" 500 || status=1
run_endpoint "public campuses"            "/api/campuses"                              300 || status=1

if [ "$status" -eq 0 ]; then
    echo "[load] SMOKE PASSED — all endpoints within SLO at ${CONCURRENCY}-way concurrency"
else
    echo "[load] SMOKE FAILED" >&2
fi
exit "$status"

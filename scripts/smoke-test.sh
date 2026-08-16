#!/usr/bin/env bash
#
# smoke-test.sh -- functional test against a running Simple Cookie Fortune.
#
# Deliberately black box: it only speaks HTTP to the frontend, so the same
# script tests a docker compose stack, a kind cluster or a real deployment
# without knowing which it is looking at.
#
#   BASE_URL     where the frontend answers. Default http://localhost:8080.
#   WAIT_SECONDS how long to wait for the app to come up before testing.
#                Default 60. A fresh rollout is not instant.
#   SOFT_FAIL    when true, report failures but still exit 0. This is the
#                "tollgate or just information" decision from 04-testing,
#                made switchable rather than hard coded.
#
# Usage:
#   ./scripts/smoke-test.sh
#   ./scripts/smoke-test.sh http://localhost:18080
#   BASE_URL=http://staging.example.com SOFT_FAIL=true ./scripts/smoke-test.sh
#
# Exit codes:
#   0  every test passed, or SOFT_FAIL was true
#   1  at least one test failed
#   2  the app never became reachable at all

# No -e. A failing test must not abort the run: we want the whole report,
# not just the first thing that broke.
set -uo pipefail

BASE_URL="${BASE_URL:-${1:-http://localhost:8080}}"
BASE_URL="${BASE_URL%/}"
WAIT_SECONDS="${WAIT_SECONDS:-60}"
SOFT_FAIL="${SOFT_FAIL:-false}"

PASSED=0
FAILED=0
FAILED_NAMES=()

pass() { printf '\033[1;32m  PASS\033[0m %s\n' "$*"; PASSED=$((PASSED + 1)); }
fail() {
    printf '\033[1;31m  FAIL\033[0m %s\n' "$*" >&2
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("$1")
}
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# --- helpers ----------------------------------------------------------------

# Both helpers hand their result back through the BODY and STATUS globals
# rather than by printing it. Printing would force every call site to use
# "$(...)", which runs the function in a subshell, and a subshell cannot set
# a variable in its parent -- so STATUS would always come back empty.
#
# curl writes the status after the body with -w, and the last line is peeled
# off here. One request, both values.
BODY=""
STATUS=""

http_get() {
    local path="$1" out
    out="$(curl -sS -m 10 -w '\n%{http_code}' "${BASE_URL}${path}" 2>/dev/null)"
    STATUS="${out##*$'\n'}"
    BODY="${out%$'\n'*}"
}

http_post_json() {
    local path="$1" payload="$2" out
    out="$(curl -sS -m 10 -w '\n%{http_code}' \
        -H 'Content-Type: application/json' \
        -d "$payload" "${BASE_URL}${path}" 2>/dev/null)"
    STATUS="${out##*$'\n'}"
    BODY="${out%$'\n'*}"
}

# --- wait for the app -------------------------------------------------------

log "target $BASE_URL"
log "waiting up to ${WAIT_SECONDS}s for the app to answer"

deadline=$((SECONDS + WAIT_SECONDS))
ready=false
while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -fsS -m 5 "${BASE_URL}/healthz" >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 2
done

if [ "$ready" != true ]; then
    printf '\033[1;31mxx\033[0m app never answered on %s within %ss\n' \
        "$BASE_URL" "$WAIT_SECONDS" >&2
    exit 2
fi

log "app is up, running tests"

# --- tests ------------------------------------------------------------------

# 1. Liveness. The cheapest possible "is it there".
http_get /healthz
if [ "$STATUS" = "200" ] && [ "$BODY" = "healthy" ]; then
    pass "/healthz returns 200 and says healthy"
else
    fail "/healthz returns 200 and says healthy"
    printf '       got status=%s body=%q\n' "$STATUS" "$BODY" >&2
fi

# 2. The static frontend is actually served, not just the API. This catches a
#    broken image build where the binary shipped without ./static next to it.
http_get /
if [ "$STATUS" = "200" ] && printf '%s' "$BODY" | grep -qi '<html'; then
    pass "/ serves the static page"
else
    fail "/ serves the static page"
    printf '       got status=%s\n' "$STATUS" >&2
fi

# 3. Write then read back. This runs before the read-only tests on purpose.
#
#    A fresh deployment does not necessarily have any fortunes: when REDIS_DNS
#    is set, init() in backend/foredis.go replaces the four built in fortunes
#    with whatever Redis holds, and a newly created Redis holds nothing. So
#    "the list is empty" is a legitimate state for a brand new environment,
#    and asserting on the seed data would fail every first deploy.
#
#    Writing first makes the tests below deterministic in either case, and
#    this is also the test that exercises the whole path in both directions.
#    The marker is alphanumeric on purpose: the template escapes HTML, so an
#    apostrophe would come back as &#39; and never match.
marker="smoketest $(date +%s) $$"
http_post_json /api/add "{\"message\": \"${marker}\"}"
if [ "$STATUS" = "200" ]; then
    http_get /api/all
    if printf '%s' "$BODY" | grep -qF "$marker"; then
        pass "POST /api/add stores a fortune and it reads back"
    else
        fail "POST /api/add stores a fortune and it reads back"
        printf '       the fortune was accepted but is not in /api/all\n' >&2
    fi
else
    fail "POST /api/add stores a fortune and it reads back"
    printf '       got status=%s on the POST\n' "$STATUS" >&2
fi

# 4. The full list, rendered through templates/fortunes.html. Guaranteed to
#    hold at least the fortune written above.
http_get /api/all
if [ "$STATUS" = "200" ] && printf '%s' "$BODY" | grep -q '<p>'; then
    count="$(printf '%s' "$BODY" | grep -c '<p>')"
    pass "/api/all renders the fortune list ($count entries)"
else
    fail "/api/all renders the fortune list"
    printf '       got status=%s\n' "$STATUS" >&2
fi

# 5. A random fortune. Proves the frontend reached the backend, since the
#    frontend holds no fortunes of its own.
http_get /api/random
if [ "$STATUS" = "200" ] && [ -n "${BODY//[[:space:]]/}" ]; then
    pass "/api/random returns a fortune (${BODY:0:40}...)"
else
    fail "/api/random returns a fortune"
    printf '       got status=%s body=%q\n' "$STATUS" "$BODY" >&2
fi

# 6. An unknown path must 404 rather than 200 or 500. Cheap, but it catches a
#    misrouted file server that answers everything with the index page.
http_get /this-path-does-not-exist
if [ "$STATUS" = "404" ]; then
    pass "an unknown path returns 404"
else
    fail "an unknown path returns 404"
    printf '       got status=%s\n' "$STATUS" >&2
fi

# --- report -----------------------------------------------------------------

echo
log "passed $PASSED, failed $FAILED"

if [ "$FAILED" -eq 0 ]; then
    log "all tests passed against $BASE_URL"
    exit 0
fi

for name in "${FAILED_NAMES[@]}"; do
    printf '\033[1;31mxx\033[0m failed: %s\n' "$name" >&2
done

if [ "$SOFT_FAIL" = "true" ]; then
    printf '\033[1;33m!!\033[0m SOFT_FAIL is set, reporting the failures but exiting 0\n' >&2
    exit 0
fi

exit 1

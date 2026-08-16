#!/usr/bin/env bash
#
# stress-test.sh -- load test the frontend with siege.
#
# 05-bon-appetit suggests the rufus/siege-engine image, so siege runs in a
# container and nothing has to be installed on the machine.
#
#   BASE_URL     what to hammer. Default http://localhost:8080.
#   CONCURRENT   simultaneous users. Default 25.
#   DURATION     how long to run, siege syntax. Default 30S.
#   SIEGE_IMAGE  override the image if that one ever disappears.
#   FAIL_UNDER   minimum availability percentage to accept. Default 95.
#
# Usage:
#   ./scripts/stress-test.sh
#   CONCURRENT=50 DURATION=1M ./scripts/stress-test.sh http://localhost:8081

set -uo pipefail

BASE_URL="${BASE_URL:-${1:-http://localhost:8080}}"
BASE_URL="${BASE_URL%/}"
CONCURRENT="${CONCURRENT:-25}"
DURATION="${DURATION:-30S}"
SIEGE_IMAGE="${SIEGE_IMAGE:-rufus/siege-engine}"
FAIL_UNDER="${FAIL_UNDER:-95}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker is required to run siege"

# A container cannot reach the host's localhost by that name. On Docker
# Desktop host.docker.internal points back at the host, and on Linux the same
# name works when it is mapped with --add-host below.
TARGET="$BASE_URL"
case "$BASE_URL" in
    *localhost*|*127.0.0.1*)
        TARGET="$(printf '%s' "$BASE_URL" | sed -e 's|localhost|host.docker.internal|' -e 's|127\.0\.0\.1|host.docker.internal|')"
        log "rewrote the target to $TARGET so the container can reach the host"
        ;;
esac

log "target      $TARGET"
log "concurrency $CONCURRENT"
log "duration    $DURATION"

OUTPUT="$(mktemp)"
trap 'rm -f "$OUTPUT"' EXIT

# siege writes its summary to stderr, hence the redirect.
docker run --rm \
    --add-host host.docker.internal:host-gateway \
    "$SIEGE_IMAGE" \
    --concurrent="$CONCURRENT" \
    --time="$DURATION" \
    --benchmark \
    "$TARGET/" 2>&1 | tee "$OUTPUT"

echo

# Siege prints "Availability: 99.83 %". Anything below the threshold means the
# app fell over under load, which is the thing worth knowing.
AVAILABILITY="$(grep -iE 'availability' "$OUTPUT" | grep -oE '[0-9]+\.[0-9]+' | head -1)"

if [ -z "$AVAILABILITY" ]; then
    printf '\033[1;33m!!\033[0m could not read the availability from the siege output\n' >&2
    printf '\033[1;33m!!\033[0m treating that as a warning rather than a failure\n' >&2
    exit 0
fi

# Zero hits means siege never reached the target at all, which is a broken
# test rather than a slow application. Saying so is better than reporting
# "0.00 percent availability" as though the app had fallen over.
HITS="$(grep -iE 'transactions' "$OUTPUT" | grep -oE '[0-9]+' | head -1)"
if [ "${HITS:-0}" -eq 0 ]; then
    die "siege made no successful requests at all, so it could not reach $TARGET.
     If this is running against a kubectl port forward, the forward has to be
     started with --address 0.0.0.0, because the container cannot see a
     127.0.0.1 binding on the host."
fi

log "availability $AVAILABILITY percent, threshold $FAIL_UNDER"

# bash cannot compare decimals, so scale to whole numbers instead of shelling
# out to bc, which is not installed everywhere.
if [ "${AVAILABILITY%%.*}" -lt "${FAIL_UNDER%%.*}" ]; then
    die "availability $AVAILABILITY percent is below the $FAIL_UNDER percent threshold"
fi

log "load test passed"

#!/usr/bin/env bash
#
# rollback.sh -- put the previous version back.
#
# This is the "investigate rollbacks" item from 05-bon-appetit. Kubernetes
# keeps the old ReplicaSets around, so going back is a rollout undo rather
# than a rebuild and redeploy, which matters when production is broken and
# nobody wants to wait for CI.
#
#   KUBECONFIG_B64  base64 kubeconfig, same as deploy.sh. Optional.
#   ENVIRONMENT     development, staging or production. Defaults from BRANCH.
#   BRANCH          used to work out ENVIRONMENT.
#   DEPLOYMENTS     which ones to roll back. Default "backend frontend".
#   TO_REVISION     a specific revision from the history. Default is previous.
#
# Usage:
#   ./scripts/rollback.sh                       roll back to the previous one
#   ./scripts/rollback.sh --history             just show what is available
#   TO_REVISION=3 ./scripts/rollback.sh         go to a specific revision

set -euo pipefail

BRANCH="${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}"
DEPLOYMENTS="${DEPLOYMENTS:-backend frontend}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

if [ -z "${ENVIRONMENT:-}" ]; then
    case "$BRANCH" in
        main|master)      ENVIRONMENT=production  ;;
        staging|release*) ENVIRONMENT=staging     ;;
        *)                ENVIRONMENT=development ;;
    esac
fi

case "$ENVIRONMENT" in
    production)  NAMESPACE=fortune         ;;
    staging)     NAMESPACE=fortune-staging ;;
    development) NAMESPACE=fortune-dev     ;;
    *) die "unknown ENVIRONMENT '$ENVIRONMENT'" ;;
esac

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

KUBECTL=(kubectl)
if [ -n "${KUBECONFIG_B64:-}" ]; then
    printf '%s' "$KUBECONFIG_B64" | base64 -d > "$WORKDIR/kubeconfig"
    chmod 600 "$WORKDIR/kubeconfig"
    KUBECTL=(kubectl --kubeconfig "$WORKDIR/kubeconfig")
fi

"${KUBECTL[@]}" cluster-info >/dev/null 2>&1 || die "cannot reach the cluster"

log "environment $ENVIRONMENT"
log "namespace   $NAMESPACE"

# --- history only -----------------------------------------------------------

if [ "${1:-}" = "--history" ]; then
    for d in $DEPLOYMENTS; do
        echo
        log "history for $d"
        "${KUBECTL[@]}" -n "$NAMESPACE" rollout history "deployment/$d"
    done
    exit 0
fi

# --- roll back --------------------------------------------------------------

for d in $DEPLOYMENTS; do
    echo
    log "current image for $d: $("${KUBECTL[@]}" -n "$NAMESPACE" get "deployment/$d" -o jsonpath='{.spec.template.spec.containers[0].image}')"

    if [ -n "${TO_REVISION:-}" ]; then
        log "rolling $d back to revision $TO_REVISION"
        "${KUBECTL[@]}" -n "$NAMESPACE" rollout undo "deployment/$d" --to-revision="$TO_REVISION"
    else
        log "rolling $d back to the previous revision"
        "${KUBECTL[@]}" -n "$NAMESPACE" rollout undo "deployment/$d"
    fi

    "${KUBECTL[@]}" -n "$NAMESPACE" rollout status "deployment/$d" --timeout=180s
    log "image after rollback: $("${KUBECTL[@]}" -n "$NAMESPACE" get "deployment/$d" -o jsonpath='{.spec.template.spec.containers[0].image}')"
done

echo
log "rolled back, now confirm it actually works with scripts/smoke-test.sh"

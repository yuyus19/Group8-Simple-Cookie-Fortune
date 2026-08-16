#!/usr/bin/env bash
#
# deploy.sh -- persist the kubeconfig to disk and deploy to Kubernetes.
#
# Everything is driven by environment variables so the same script works from
# a laptop and from GitHub Actions with no changes.
#
#   KUBECONFIG_B64  base64 of a kubeconfig file. When set it is written to
#                   disk and used. When empty the ambient kubectl context is
#                   used, which is what you want when running this by hand.
#   BRANCH          branch name. Decides the environment when ENVIRONMENT is
#                   not given. Defaults to the current git branch.
#   ENVIRONMENT     development, staging or production. Overrides BRANCH.
#   IMAGE_TAG       image tag to deploy. Defaults to latest.
#   MANIFEST_DIR    where the manifests live. Defaults to k8s.
#
# Usage:
#   ./scripts/deploy.sh
#   ENVIRONMENT=staging IMAGE_TAG=sha-1a2b3c4 ./scripts/deploy.sh

set -euo pipefail

MANIFEST_DIR="${MANIFEST_DIR:-k8s}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
BRANCH="${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# --- which environment are we deploying ------------------------------------

# The optional task in 04-cd asks for several versions selected by branch.
# main is the only branch that reaches production.
if [ -z "${ENVIRONMENT:-}" ]; then
    case "$BRANCH" in
        main|master)      ENVIRONMENT=production  ;;
        staging|release*) ENVIRONMENT=staging     ;;
        *)                ENVIRONMENT=development ;;
    esac
fi

case "$ENVIRONMENT" in
    production)  NAMESPACE=fortune            ;;
    staging)     NAMESPACE=fortune-staging    ;;
    development) NAMESPACE=fortune-dev        ;;
    *) die "unknown ENVIRONMENT '$ENVIRONMENT', expected development, staging or production" ;;
esac

log "branch      $BRANCH"
log "environment $ENVIRONMENT"
log "namespace   $NAMESPACE"
log "image tag   $IMAGE_TAG"

# --- persist the kubeconfig -------------------------------------------------

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

KUBECTL=(kubectl)
if [ -n "${KUBECONFIG_B64:-}" ]; then
    KUBECONFIG_FILE="$WORKDIR/kubeconfig"
    printf '%s' "$KUBECONFIG_B64" | base64 -d > "$KUBECONFIG_FILE"
    # Readable only by us. A kubeconfig is a credential.
    chmod 600 "$KUBECONFIG_FILE"
    KUBECTL=(kubectl --kubeconfig "$KUBECONFIG_FILE")
    log "wrote kubeconfig from KUBECONFIG_B64"
else
    log "no KUBECONFIG_B64 given, using the current kubectl context"
fi

"${KUBECTL[@]}" cluster-info >/dev/null 2>&1 || die "cannot reach the cluster"
log "cluster: $("${KUBECTL[@]}" config current-context 2>/dev/null || echo unknown)"

# --- render the manifests ---------------------------------------------------

# The manifests hard code "namespace: fortune". Rewriting it here is what lets
# one set of files serve all three environments, which is the alternative the
# orchestration exercise suggested when separate namespaces are awkward.
RENDER="$WORKDIR/manifests"
mkdir -p "$RENDER"

for f in "$MANIFEST_DIR"/*.yaml; do
    base="$(basename "$f")"
    # kind-cluster.yaml is a kind config, not a Kubernetes object.
    [ "$base" = "kind-cluster.yaml" ] && continue

    sed -E \
        -e "s|^([[:space:]]*namespace:[[:space:]]*)fortune[[:space:]]*$|\1${NAMESPACE}|" \
        -e "s|^([[:space:]]*name:[[:space:]]*)fortune[[:space:]]*$|\1${NAMESPACE}|" \
        -e "s|(image:[[:space:]]*docker\.io/jimdaf/cookie-fortune-group08-[a-z]+):[^[:space:]]+|\1:${IMAGE_TAG}|" \
        "$f" > "$RENDER/$base"
done

# A nodePort is claimed cluster wide, so only one environment can own 30080.
# Production keeps it, the others let Kubernetes pick a free port.
if [ "$ENVIRONMENT" != "production" ] && [ -f "$RENDER/frontend.yaml" ]; then
    sed -i -E '/^[[:space:]]*nodePort:[[:space:]]*[0-9]+[[:space:]]*$/d' "$RENDER/frontend.yaml"
    log "dropped the fixed nodePort, $ENVIRONMENT gets an assigned one"
fi

# --- apply ------------------------------------------------------------------

# The namespace has to exist before anything can be put in it. "apply -f dir"
# works through the files alphabetically, so backend.yaml would be attempted
# before namespace.yaml and fail with "namespaces not found".
if [ -f "$RENDER/namespace.yaml" ]; then
    log "creating the namespace first"
    "${KUBECTL[@]}" apply -f "$RENDER/namespace.yaml"
    "${KUBECTL[@]}" wait --for=jsonpath='{.status.phase}'=Active \
        "namespace/$NAMESPACE" --timeout=60s
fi

log "applying manifests"
"${KUBECTL[@]}" apply -f "$RENDER/"

log "waiting for the rollouts"
# redis first. The backend has an init container that blocks until Redis
# answers, so checking Redis first turns "backend timed out" into the more
# useful "redis never became ready".
for d in redis backend frontend; do
    if "${KUBECTL[@]}" -n "$NAMESPACE" get "deployment/$d" >/dev/null 2>&1; then
        "${KUBECTL[@]}" -n "$NAMESPACE" rollout status "deployment/$d" --timeout=180s
    fi
done

log "deployed"
"${KUBECTL[@]}" -n "$NAMESPACE" get deployments,services,pods

# Hand the values back when we are running inside GitHub Actions, so later
# steps do not have to repeat the branch to namespace logic above.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "namespace=$NAMESPACE"
        echo "environment=$ENVIRONMENT"
    } >> "$GITHUB_OUTPUT"
fi

#!/usr/bin/env bash
#
# set-kubeconfig-secret.sh -- put a kubeconfig into the repository as the
# KUBECONFIG secret, which is the first task in 04-cd.
#
# This is the safe way to do it. The kubeconfig itself never enters the
# repository, only an encrypted secret that GitHub Actions can read.
#
# Usage:
#   ./scripts/set-kubeconfig-secret.sh                  uses ~/.kube/config
#   ./scripts/set-kubeconfig-secret.sh path/to/config   uses that file
#
# Needs the gh CLI, logged in as someone with access to the repository.

set -euo pipefail

REPO="${REPO:-yuyus19/Group8-Simple-Cookie-Fortune}"
KUBECONFIG_PATH="${1:-$HOME/.kube/config}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "the gh CLI is required"
[ -f "$KUBECONFIG_PATH" ] || die "no kubeconfig at $KUBECONFIG_PATH"

log "repo       $REPO"
log "kubeconfig $KUBECONFIG_PATH"
log "gh account $(gh api user --jq .login)"

# A cluster the runner cannot reach makes the whole pipeline red, so say so
# before uploading rather than after the first failed deploy.
SERVER="$(grep -oE 'server:[[:space:]]*https?://[^[:space:]]+' "$KUBECONFIG_PATH" | head -1 | sed 's/server:[[:space:]]*//')"
log "server     ${SERVER:-unknown}"

case "$SERVER" in
    *localhost*|*127.0.0.1*|*kubernetes.docker.internal*|*0.0.0.0*)
        warn "That address only resolves on this machine."
        warn "A GitHub runner will not be able to reach it, so the CD job will fail."
        warn "Use a cluster with a public address instead."
        printf 'Upload it anyway? [y/N] '
        read -r reply
        case "$reply" in
            [yY]*) ;;
            *) die "stopped" ;;
        esac
        ;;
esac

# -w0 keeps it on one line. base64 wraps at 76 characters by default, and the
# newlines break the decode on the other side.
log "uploading as the KUBECONFIG secret"
base64 -w0 < "$KUBECONFIG_PATH" | gh secret set KUBECONFIG --repo "$REPO"

log "done, secrets on the repo are now:"
gh secret list --repo "$REPO"

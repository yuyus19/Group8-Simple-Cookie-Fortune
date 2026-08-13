
set -euo pipefail

# We should install a version that is between 1.18 and 1.21 based on the readme in the frontend. 
# This works for both Windows and Linux/Mac OS since me and Dimitrios have Windows and Yusuf has Linux that's convenient for us
GO_VERSION="1.20.14"
BASE_URL="https://go.dev/dl"

# SHA256 sums as published by https://go.dev/dl/?mode=json&include=all
SHA_WINDOWS_AMD64="b5744647c778436e11517ab7d7ab09f07505b654f1d6699a826be9d3eaa552f3"
SHA_LINUX_AMD64="ff445e48af27f93f66bd949ae060d97991c83e11289009d311f25426258f9c44"
SHA_LINUX_ARM64="2096507509a98782850d1f0669786c09727053e9fe3c92b03c0d96f48700282b"
SHA_DARWIN_AMD64="754363489e2244e72cb49b4ec6ddfd6a2c60b0700f8c4876e11befb1913b11c5"
SHA_DARWIN_ARM64="6da3f76164b215053daf730a9b8f1d673dbbaa4c61031374a6744b75cb728641"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }


detect_platform() {
    local os arch
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) os="windows" ;;
        Linux)                os="linux"   ;;
        Darwin)               os="darwin"  ;;
        *) die "unsupported OS: $(uname -s)" ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac

    [ "$os" = "windows" ] && [ "$arch" != "amd64" ] && die "only windows/amd64 is handled here"

    echo "${os}_${arch}"
}

expected_sha() {
    case "$1" in
        windows_amd64) echo "$SHA_WINDOWS_AMD64" ;;
        linux_amd64)   echo "$SHA_LINUX_AMD64"   ;;
        linux_arm64)   echo "$SHA_LINUX_ARM64"   ;;
        darwin_amd64)  echo "$SHA_DARWIN_AMD64"  ;;
        darwin_arm64)  echo "$SHA_DARWIN_ARM64"  ;;
        *) die "no checksum pinned for $1" ;;
    esac
}

verify_sha() {
    local file="$1" want="$2" got

    if command -v sha256sum >/dev/null 2>&1; then
        got="$(sha256sum "$file" | cut -d' ' -f1)"
    elif command -v shasum >/dev/null 2>&1; then
        got="$(shasum -a 256 "$file" | cut -d' ' -f1)"
    else
        die "no sha256sum or shasum available -- refusing to install unverified"
    fi

    if [ "$got" != "$want" ]; then
        rm -f "$file"
        die "checksum mismatch!
  expected: $want
  got:      $got"
    fi
    log "checksum OK"
}

# --- windows ----------------------------------------------------------------

install_windows() {
    local tmp msi msi_win ps1 ps1_win
    tmp="$(mktemp -d)"
    msi="${tmp}/go${GO_VERSION}.windows-amd64.msi"

    log "downloading go${GO_VERSION}.windows-amd64.msi"
    curl -fsSL -o "$msi" "${BASE_URL}/go${GO_VERSION}.windows-amd64.msi"
    verify_sha "$msi" "$(expected_sha windows_amd64)"

    msi_win="$(cygpath -w "$msi")"
    ps1="${tmp}/install-go.ps1"
    ps1_win="$(cygpath -w "$ps1")"

    # Everything that needs admin goes into one script, so the user sees a
    # single UAC prompt rather than one per msiexec call.
    cat > "$ps1" <<PSEOF
\$ErrorActionPreference = 'Stop'

# Any Go MSI already registered? Product codes differ per version, so find it
# by name rather than hardcoding a GUID.
\$installed = Get-ItemProperty \`
    HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*, \`
    HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* \`
    -ErrorAction SilentlyContinue |
    Where-Object { \$_.DisplayName -like 'Go Programming Language*' }

foreach (\$go in \$installed) {
    Write-Host "removing \$(\$go.DisplayName)"
    \$p = Start-Process msiexec.exe -ArgumentList '/x', \$go.PSChildName, '/qn', '/norestart' -Wait -PassThru
    if (\$p.ExitCode -ne 0) { throw "uninstall failed with \$(\$p.ExitCode)" }
}

Write-Host "installing go${GO_VERSION}"
\$p = Start-Process msiexec.exe -ArgumentList '/i', '"${msi_win}"', '/qn', '/norestart' -Wait -PassThru
if (\$p.ExitCode -ne 0) { throw "install failed with \$(\$p.ExitCode)" }
PSEOF

    log "running installer elevated -- approve the UAC prompt"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
        "\$p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','${ps1_win}'; exit \$p.ExitCode" \
        || die "elevated install failed (UAC declined?)"

    rm -rf "$tmp"
    GO_BIN="/c/Program Files/Go/bin/go"
}

# --- linux / macos ----------------------------------------------------------

install_unix() {
    local platform="$1" tmp tarball os arch
    os="${platform%_*}"
    arch="${platform#*_}"

    tmp="$(mktemp -d)"
    tarball="${tmp}/go${GO_VERSION}.${os}-${arch}.tar.gz"

    log "downloading go${GO_VERSION}.${os}-${arch}.tar.gz"
    curl -fsSL -o "$tarball" "${BASE_URL}/go${GO_VERSION}.${os}-${arch}.tar.gz"
    verify_sha "$tarball" "$(expected_sha "$platform")"

    # The official instructions are explicit that the old tree must be deleted
    # rather than extracted over -- leftover files from another version break
    # the toolchain in confusing ways.
    log "removing any existing /usr/local/go and extracting"
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "$tarball"

    rm -rf "$tmp"
    GO_BIN="/usr/local/go/bin/go"

    if ! echo "$PATH" | grep -q '/usr/local/go/bin'; then
        warn "/usr/local/go/bin is not on your PATH. Add it with:"
        warn "  echo 'export PATH=\$PATH:/usr/local/go/bin' >> ~/.profile"
    fi
}

# --- main -------------------------------------------------------------------

main() {
    local platform
    platform="$(detect_platform)"
    log "target: go${GO_VERSION} on ${platform}"

    command -v curl >/dev/null 2>&1 || die "curl is required"

    case "$platform" in
        windows_amd64) install_windows ;;
        *)             install_unix "$platform" ;;
    esac

    log "verifying"
    "$GO_BIN" version || die "install finished but $GO_BIN does not run"

    cat <<EOF

Done. $("$GO_BIN" version)

Note: already-open shells still hold the old PATH. On Windows that includes
VS Code -- its integrated terminals inherit the environment from the VS Code
process, so a new terminal tab is not enough; quit and reopen VS Code.

To fix the current Git Bash session without restarting:
  export PATH="\$PATH:/c/Program Files/Go/bin"

Then, from the repo root:
  (cd backend  && go build)
  (cd frontend && go build)
EOF
}

# Only install when the script is executed. Sourcing it just defines the
# functions, so `source ./scripts/install-go.sh` cannot kick off an install
# behind your back.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi

#!/usr/bin/env bash
set -euo pipefail

# Automated script to install or update Rust-based Tor software (arti and oniux)
# - Ensures Rust and cargo are installed (via rustup or Homebrew)
# - Clones the arti and oniux repositories from the Tor Project GitLab
# - Determines the latest release tags for each project
# - Installs or updates the crates via cargo with appropriate features
# - Installs the resulting binaries into /usr/local/bin (requires root)
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

REPO_ARTI="https://gitlab.torproject.org/tpo/core/arti.git"
REPO_ONIUX="https://gitlab.torproject.org/tpo/core/oniux.git"

CARGO_BIN_DIR="${CARGO_HOME:-$HOME/.cargo}/bin"
ROOT_CMD=""

GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

log()   { printf '%b[INFO]%b ✅ %s\n' "$GREEN" "$RESET" "$*" >&2; }
warn()  { printf '%b[WARN]%b ⚠️ %s\n' "$YELLOW" "$RESET" "$*" >&2; }
error() { printf '%b[ERROR]%b ❌ %s\n' "$RED" "$RESET" "$*" >&2; }

detect_root_cmd() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    ROOT_CMD=""
    log "Running as root; no run0 needed for privileged operations."
  elif command -v run0 >/dev/null 2>&1; then
    ROOT_CMD="run0"
    log "Using run0 for privileged operations."
  else
    error "run0 not found. Run this script as root or install run0."
    exit 1
  fi
}

run_root() {
  if [ -n "$ROOT_CMD" ]; then
    "$ROOT_CMD" "$@"
  else
    "$@"
  fi
}

ensure_rust() {
  if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
    log "Rust and cargo are already installed."
    return
  fi

  if command -v brew >/dev/null 2>&1; then
    log "Homebrew detected, installing Rust via brew..."
    if brew list rust >/dev/null 2>&1; then
      log "Rust already installed with Homebrew, attempting upgrade..."
      brew upgrade rust || log "brew upgrade rust failed or was not needed."
    else
      brew install rust
    fi
  else
    log "No Homebrew detected, installing Rust via rustup..."
    if ! command -v curl >/dev/null 2>&1; then
      error "curl is required to install rustup but is not installed."
      exit 1
    fi
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

    if [ -f "$HOME/.cargo/env" ]; then
      # shellcheck source=/dev/null
      . "$HOME/.cargo/env"
    else
      export PATH="$HOME/.cargo/bin:$PATH"
    fi
  fi

  if ! command -v cargo >/dev/null 2>&1; then
    error "Rust installation seems to have failed (cargo not found in PATH)."
    exit 1
  fi

  log "Using cargo at: $(command -v cargo)"
}

ensure_git() {
  if ! command -v git >/dev/null 2>&1; then
    error "git is required but not installed. Please install git (e.g. 'apt install git', 'dnf install git', etc.) and rerun."
    exit 1
  fi
}

get_installed_cargo_version() {
  # Extract installed crate version from `cargo install --list`
  # Example line: "arti v1.4.6:"
  local crate="$1"
  cargo install --list 2>/dev/null \
    | awk -v crate="$crate" '$1==crate {print $2}' \
    | sed -E 's/^v//; s/:$//' \
    | head -n1
}

cargo_np() {
  env -u LD_PRELOAD cargo "$@"
}

latest_git_tag() {
  # Get the latest tag from a git repo, optionally filtered by a ref pattern.
  # $1 = repo URL
  # $2 = optional pattern, e.g. 'refs/tags/arti-v*' (default: 'refs/tags/*')
  local repo="$1"
  local pattern="${2:-refs/tags/*}"

  git ls-remote --tags --sort="version:refname" "$repo" "$pattern" 2>/dev/null \
    | awk '{print $2}' \
    | sed 's#refs/tags/##; s#\^{}##' \
    | uniq \
    | tail -n1
}

install_or_update_arti() {
  local crate="arti"
  local updated=0
  log "Checking $crate version (git tags from $REPO_ARTI)..."

  local installed latest_tag latest_ver
  installed="$(get_installed_cargo_version "$crate" || true)"
  # arti uses tags like "arti-v1.4.6"
  latest_tag="$(latest_git_tag "$REPO_ARTI" 'refs/tags/arti-v*' || true)"

  if [[ -z "$latest_tag" ]]; then
    error "Could not determine latest arti tag; installing from repo without explicit tag."
    cargo_np install --locked --features=full --git "$REPO_ARTI" "$crate"
    updated=1
  else
    latest_ver="${latest_tag#arti-v}"
    if [[ "$installed" == "$latest_ver" ]]; then
      log "arti is already at the latest version ($installed, tag $latest_tag). Skipping reinstall."
      updated=0
    else
      log "Installing/updating arti to version $latest_ver (tag $latest_tag) with --features=full..."
      cargo_np install --locked --features=full --git "$REPO_ARTI" --tag "$latest_tag" "$crate"
      updated=1
    fi
  fi

  if [[ "$updated" -eq 1 ]]; then
    if [[ -x "$CARGO_BIN_DIR/arti" ]]; then
      log "Installing arti binary into /usr/local/bin (may require root)..."
      run_root install -m 0755 "$CARGO_BIN_DIR/arti" /usr/local/bin/
    else
      error "arti binary not found at $CARGO_BIN_DIR/arti. Check previous error messages."
      return 1
    fi
  else
    log "arti already up to date; skipping install to /usr/local/bin."
  fi
}

install_or_update_oniux() {
  local crate="oniux"
  local updated=0
  log "Checking $crate version (git tags from $REPO_ONIUX)..."

  local installed latest_tag latest_ver
  installed="$(get_installed_cargo_version "$crate" || true)"
  # oniux uses tags like "v0.5.0"
  latest_tag="$(latest_git_tag "$REPO_ONIUX" 'refs/tags/v*' || true)"

  if [[ -z "$latest_tag" ]]; then
    error "Could not determine latest oniux tag; installing from repo without explicit tag."
    cargo_np install --locked --git "$REPO_ONIUX" "$crate"
    updated=1
  else
    latest_ver="${latest_tag#v}"
    if [[ "$installed" == "$latest_ver" ]]; then
      log "oniux is already at the latest version ($installed, tag $latest_tag). Skipping reinstall."
      updated=0
    else
      log "Installing/updating oniux to version $latest_ver (tag $latest_tag)..."
      cargo_np install --locked --git "$REPO_ONIUX" --tag "$latest_tag" "$crate"
      updated=1
    fi
  fi

  if [[ "$updated" -eq 1 ]]; then
    if [[ -x "$CARGO_BIN_DIR/oniux" ]]; then
      log "Installing oniux binary into /usr/local/bin (may require root)..."
      run_root install -m 0755 "$CARGO_BIN_DIR/oniux" /usr/local/bin/
    else
      error "oniux binary not found at $CARGO_BIN_DIR/oniux. Check previous error messages."
      return 1
    fi
  else
    log "oniux already up to date; skipping install to /usr/local/bin."
  fi
}

main() {
  detect_root_cmd
  ensure_rust
  ensure_git

  mkdir -p "$CARGO_BIN_DIR"

  install_or_update_arti
  install_or_update_oniux

  log "Done. Make sure /usr/local/bin is in your PATH."
}

main "$@"

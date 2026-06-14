#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# lib.sh — shared helpers for the installer modules
# Sourced by void-linux-install.sh and each sub‑module.
# ──────────────────────────────────────────────────────────────────────────────

# ── Logging ─────────────────────────────────────────────
_log() { printf "[%-5s] %s\n" "$1" "$2"; }
info()  { _log "INFO" "$*"; }
warn()  { _log "WARN" "$*"; }
ok()    { _log "OK"   "$*"; }
step()  { echo -e "\n==> $*\n--------------------------------"; }
die()   { _log "FATAL" "$*"; exit 1; }

# ── Safety ──────────────────────────────────────────────
set -euo pipefail
trap 'die "Error on line ${LINENO}: ${BASH_COMMAND}"' ERR
trap 'warn "Interrupted"; exit 130' INT TERM

# ── Helpers ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

enable_service() {
	local svc="$1"
	[[ -d "/etc/sv/$svc" && ! -e "/var/service/$svc" ]] && {
		ln -s "/etc/sv/$svc" "/var/service/"
		ok "Enabled $svc"
	} || true
}

pkg_install() {
	xbps-install -y "$@"
}

run_as_user() {
	su - "$USERNAME" -c "$*"
}

require_root() {
	[[ $EUID -ne 0 ]] && die "Run as root"
}

require_username() {
	[[ -z "$USERNAME" ]] && die "Usage: $0 <username>"
	id "$USERNAME" &>/dev/null || die "User '$USERNAME' not found"
}

# ── Derived paths ───────────────────────────────────────
USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"

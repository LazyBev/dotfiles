#!/usr/bin/env bash

set -euo pipefail

# ── Args ────────────────────────────────────────────────
USERNAME="${1:-}"
[[ -z "$USERNAME" ]] && die "Usage: $0 <username>"
[[ $EUID -ne 0 ]] && die "Run as root"

id "$USERNAME" &>/dev/null || die "User '$USERNAME' not found"

USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
HOME=$USER_HOME
DOTFILES="$USER_HOME/dotfiles"

[[ -z "$USER_HOME" || ! -d "$USER_HOME" ]] && die "Invalid home directory for $USERNAME"

# ── Logging ─────────────────────────────────────────────
_log() { printf "[%-5s] %s\n" "$1" "$2"; }
info()  { _log "INFO" "$*"; }
warn()  { _log "WARN" "$*"; }
ok()    { _log "OK"   "$*"; }
step()  { echo -e "\n==> $*\n--------------------------------"; }
die()   { _log "FATAL" "$*"; exit 1; }
skip()  { _log "SKIP" "$*"; }

trap 'die "Error on line ${LINENO}: ${BASH_COMMAND}"' ERR
trap 'warn "Interrupted"; exit 130' INT TERM

# ──────────────────────── extra  ─────────────────────────────
step "Extras"

mv "$USER_HOME/.config/nvim{,.bak}" || true
mv "$USER_HOME/.local/share/nvim{,.bak}" || true
mv "$USER_HOME/.local/state/nvim{,.bak}" || true
mv "$USER_HOME/.cache/nvim{,.bak}" || true

git clone https://github.com/LazyVim/starter "$USER_HOME/.config/nvim"

rm -rf "$USER_HOME/.config/nvim/.git"

VESKTOP_FILE="$USER_HOME/.local/share/applications/vesktop.desktop"
mkdir -p "$USER_HOME/.local/bin"
mkdir -p "$USER_HOME/.local/share/applications"
rm -f "$USER_HOME/.local/bin/vesktop"
rm -f "$VESKTOP_FILE"
curl -fL https://vencord.dev/download/vesktop/amd64/appimage \
  -o "$USER_HOME/.local/bin/vesktop"
[[ -s "$USER_HOME/.local/bin/vesktop" ]] || die "Vesktop download failed"
chmod +x "$USER_HOME/.local/bin/vesktop"

cat > "$VESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Vesktop
Exec=vesktop --ozone-platform=wayland --enable-features=UseOzonePlatform &
Icon=vesktop
Type=Application
Categories=Network;InstantMessaging;
Terminal=false
EOF

# ── GRUB Hatsune Miku theme ─────────────────────────────

step "GRUB Hatsune Miku theme"

REPO="https://github.com/yorunoken/HatsuneMiku.git"
TMP="/tmp/miku-grub"
THEMES_DIR="/usr/share/grub/themes"
THEME_NAME="4k-HatsuneMiku"   # or 1080-HatsuneMiku
GRUB_CFG="/etc/default/grub"
THEME_PATH="$THEMES_DIR/$THEME_NAME/theme.txt"

mkdir -p "$TMP"

# Clone repo
if ! git clone --depth=1 "$REPO" "$TMP"; then
    warn "Failed to clone repo — skipping"
else
    mkdir -p "$THEMES_DIR"
    rm -rf "$THEMES_DIR/$THEME_NAME"

    if [[ -d "$TMP/$THEME_NAME" ]]; then
        cp -r "$TMP/$THEME_NAME" "$THEMES_DIR/"
        chmod -R 755 "$THEMES_DIR/$THEME_NAME"
        ok "Theme copied"
    else
        warn "Theme folder '$THEME_NAME' not found — skipping"
    fi

    # Apply GRUB theme
    if [[ -f "$THEME_PATH" ]]; then
        if grep -q "^GRUB_THEME=" "$GRUB_CFG"; then
            sed -i "s|^GRUB_THEME=.*|GRUB_THEME=\"$THEME_PATH\"|" "$GRUB_CFG"
        else
            echo "GRUB_THEME=\"$THEME_PATH\"" >> "$GRUB_CFG"
        fi
    else
        warn "theme.txt missing — skipping GRUB config"
    fi
fi

#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# optional.sh — fonts & source builds (non-essential extras)
# ──────────────────────────────────────────────────────────────────────────────
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

install_fonts() {
	step "Fonts"

	xbps-reconfigure -f fontconfig

	if [[ ! -d /usr/share/fonts/truetype/pragmasevka ]]; then
		info "Installing Pragmasevka Nerd Font..."
		local FONT_URL="https://github.com/shytikov/pragmasevka/releases/download/v1.7.0/Pragmasevka_NF.zip"
		if wget -qO /tmp/pragmasevka.zip "$FONT_URL"; then
			mkdir -p /usr/share/fonts/truetype/pragmasevka
			unzip -qo /tmp/pragmasevka.zip -d /usr/share/fonts/truetype/pragmasevka/
			fc-cache -f
			rm /tmp/pragmasevka.zip
			ok "Pragmasevka installed"
		else
			warn "Failed to download Pragmasevka"
		fi
	fi
}

build_sources() {
	step "Building from source"

	if ! command -v beaker &>/dev/null; then
		info "Building beaker..."
		pkg_install git curl openssl pkg-config libxml2
		if git clone --depth=1 https://git.bwaaa.monster/beaker /tmp/beaker-build; then
			( cd /tmp/beaker-build && make PREFIX=/usr/local LDCONFIG=true && make install PREFIX=/usr/local )
			rm -rf /tmp/beaker-build
			ok "Beaker built"
		else
			warn "beaker clone failed — skipping"
		fi
	fi

	if ! command -v omnisearch &>/dev/null; then
		info "Building omnisearch..."
		if git clone --depth=1 https://git.bwaaa.monster/omnisearch /tmp/omnisearch-build; then
			( cd /tmp/omnisearch-build && make PREFIX=/usr/local && make install PREFIX=/usr/local )
			rm -rf /tmp/omnisearch-build
			ok "Omnisearch built"
		else
			warn "omnisearch clone failed — skipping"
		fi
	fi
}

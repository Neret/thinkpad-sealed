#!/usr/bin/env bash
set -euo pipefail

printf 'Running %s\n' "$0"

STARSHIP_VER="v1.27.0"
STARSHIP_ASSET="starship-x86_64-unknown-linux-musl.tar.gz"
STARSHIP_URL="https://github.com/starship/starship/releases/download/${STARSHIP_VER}/${STARSHIP_ASSET}"
STARSHIP_SHA256_URL="${STARSHIP_URL}.sha256"
STARSHIP_INSTALL_DIR="/usr/local/bin"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

printf 'Downloading %s\n' "$STARSHIP_URL"
curl -fsSL "$STARSHIP_URL" -o "$tmp/starship.tar.gz"

printf 'Downloading %s\n' "$STARSHIP_SHA256_URL"
curl -fsSL "$STARSHIP_SHA256_URL" -o "$tmp/starship.sha256"

printf 'Verifying checksum\n'
sha256sum -c "$tmp/starship.sha256"

printf 'Extracting archive\n'
tar -xzf "$tmp/starship.tar.gz" -C "$tmp"

if [[ ! -f "$tmp/starship" ]]; then
    printf 'Error: extracted Starship binary not found\n' >&2
    exit 1
fi

printf 'Installing Starship to %s\n' "$STARSHIP_INSTALL_DIR"

if (( EUID == 0 )); then
    install -m 0755 "$tmp/starship" "$STARSHIP_INSTALL_DIR/starship"
else
    sudo install -m 0755 "$tmp/starship" "$STARSHIP_INSTALL_DIR/starship"
fi

printf 'Installed Starship %s\n' "$("$STARSHIP_INSTALL_DIR/starship" --version)"

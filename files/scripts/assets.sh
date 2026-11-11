#!/usr/bin/env bash
set -euo pipefail

printf 'Running %s\n' "$0"

STARSHIP_VER="1.27.0"
STARSHIP_ASSET="starship-x86_64-unknown-linux-musl.tar.gz"
STARSHIP_BASE="https://github.com/starship/starship/releases/download/v${STARSHIP_VER}"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

printf 'Downloading Starship %s\n' "$STARSHIP_VER"
curl -fsSL "${STARSHIP_BASE}/${STARSHIP_ASSET}" \
    -o "$tmp/$STARSHIP_ASSET"

printf 'Downloading checksum\n'
curl -fsSL "${STARSHIP_BASE}/${STARSHIP_ASSET}.sha256" \
    -o "$tmp/starship.sha256"

printf 'Verifying checksum\n'
checksum="$(tr -d '[:space:]' < "$tmp/starship.sha256")"

if [[ ! "$checksum" =~ ^[[:xdigit:]]{64}$ ]]; then
    printf 'Error: invalid SHA-256 checksum format\n' >&2
    exit 1
fi

(
    cd "$tmp"
    printf '%s  %s\n' "$checksum" "$STARSHIP_ASSET" | sha256sum -c -
)

printf 'Extracting archive\n'
tar -xzf "$tmp/$STARSHIP_ASSET" -C "$tmp"

printf 'Installing Starship to /usr/bin/starship\n'
install -m 0755 "$tmp/starship" /usr/bin/starship

/usr/bin/starship --version

#!/usr/bin/env bash
set -euo pipefail

sed -i "s/grep -q runc/grep -q 'name: runc'/" /usr/bin/distrobox-create
STARSHIP_VER="1.27.0"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

base="https://github.com/starship/starship/releases/download/v${STARSHIP_VER}"

curl -fsSL "$base/starship-x86_64-unknown-linux-musl.tar.gz" -o "$tmp/starship.tar.gz"
curl -fsSL "$base/starship-x86_64-unknown-linux-musl.tar.gz.sha256" -o "$tmp/starship.sha256"

starship_checksum="$(awk 'NR == 1 { print $1 }' "$tmp/starship.sha256")"
printf '%s  %s\n' "$starship_checksum" "$tmp/starship.tar.gz" | sha256sum -c -
tar -xzf "$tmp/starship.tar.gz" -C /usr/local/bin

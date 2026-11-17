#!/usr/bin/env bash
set -euo pipefail

STARSHIP_VER="1.27.0"
ZED_VER="1.27.0"
ZED_CKSUM="719f6bf649ea8d87961adbf728e178561bac3f598d72d7949558d1150cfc43dd"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

base="https://github.com/starship/starship/releases/download/v${STARSHIP_VER}"

curl -fsSL "$base/starship-x86_64-unknown-linux-musl.tar.gz" -o "$tmp/starship.tar.gz"
curl -fsSL "$base/starship-x86_64-unknown-linux-musl.tar.gz.sha256" -o "$tmp/starship.sha256"

starship_checksum="$(awk 'NR == 1 { print $1 }' "$tmp/starship.sha256")"
printf '%s  %s\n' "$starship_checksum" "$tmp/starship.tar.gz" | sha256sum -c -
tar -xzf "$tmp/starship.tar.gz" -C /usr/local/bin

base="https://github.com/zed-industries/zed/releases/download/v${ZED_VER}"

curl -fsSL "$base/zed-linux-x86_64.tar.gz" -o "$tmp/zed.tar.gz"
printf '%s  %s\n' "$ZED_CKSUM" "$tmp/zed.tar.gz" | sha256sum -c -

mkdir -p ~/.local/bin
tar -xzf "$tmp/zed.tar.gz" -C ~/.local/bin

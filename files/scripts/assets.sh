#!/usr/bin/env bash
set -euo pipefail

STARSHIP_VER="1.27.0"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

base="https://github.com/starship/starship/releases/download/v${STARSHIP_VER}"

curl -fsSL "$base/starship-x86_64-unknown-linux-musl.tar.gz" -o "$tmp/starship.tar.gz"
curl -fsSL "$base/starship-x86_64-unknown-linux-musl.tar.gz.sha256" -o "$tmp/starship.sha256"

echo "$(tr -d ' \n' < "$tmp/starship.sha256")  $tmp/starship.tar.gz" | sha256sum -c -


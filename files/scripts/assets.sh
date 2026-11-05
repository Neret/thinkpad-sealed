#!/usr/bin/env bash
set -euo pipefail

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

STARSHIP_VER="1.27.0"
BIBATA_VER="v2.0.7"
BIBATA_SHA="a68cae60c4dc706350e194ebc91c5fe48bc7bc9d59e119555834a2a7ee5078ef"

# Starship: binario in /usr/bin, hash dal file .sha256 della release
base="https://github.com/starship/starship/releases/download/v${STARSHIP_VER}"
curl -fsSL "$base/starship-x86_64-unknown-linux-gnu.tar.gz" -o "$tmp/starship.tar.gz"
curl -fsSL "$base/starship-x86_64-unknown-linux-gnu.tar.gz.sha256" -o "$tmp/starship.sha256"
echo "$(tr -d ' \n' < "$tmp/starship.sha256")  $tmp/starship.tar.gz" | sha256sum -c -
tar -xzf "$tmp/starship.tar.gz" -C /usr/bin starship

# Bibata Modern Ice: hash fissato da te
curl -fsSL "https://github.com/ful1e5/Bibata_Cursor/releases/download/${BIBATA_VER}/Bibata-Modern-Ice.tar.xz" \
  -o "$tmp/bibata.tar.xz"
echo "$BIBATA_SHA  $tmp/bibata.tar.xz" | sha256sum -c -
tar -xJf "$tmp/bibata.tar.xz" -C /usr/share/icons

# Nerd Font: FiraCode
NF_VER="v3.5.1"
NF_SHA="68e3bd6164864b8b514605bc34e3a87ac401c8c48682fcce6478c70263340207"
curl -fsSL "https://github.com/ryanoasis/nerd-fonts/releases/download/${NF_VER}/FiraCode.tar.xz" -o "$tmp/firacode.tar.xz"
echo "$NF_SHA  $tmp/firacode.tar.xz" | sha256sum -c -
mkdir -p /usr/share/fonts/firacode-nerd
tar -xJf "$tmp/firacode.tar.xz" -C /usr/share/fonts/firacode-nerd
if command -v fc-cache >/dev/null; then fc-cache -f /usr/share/fonts; fi

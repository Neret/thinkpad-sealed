#!/usr/bin/env bash
set -euo pipefail

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ── Versioni e hash verificati ───────────────────────────────
STARSHIP_VER="1.27.0"

BIBATA_VER="v2.0.7"
BIBATA_SHA="a68cae60c4dc706350e194ebc91c5fe48bc7bc9d59e119555834a2a7ee5078ef"

PAPIRUS_VER="20260801"
PAPIRUS_SHA="646f622e9e7e9e65eef9d0ab58999d4920ddb33d98e6a75232627cfe3bd508f9"

INTER_VER="v4.1"
INTER_SHA="9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e"

NF_VER="v3.5.1"
NF_SHA="68e3bd6164864b8b514605bc34e3a87ac401c8c48682fcce6478c70263340207"

# ── Directory di destinazione ────────────────────────────────
ICONS_DIR="/var/home/user/.local/share/icons"
FONTS_DIR="/var/home/user/.local/share/fonts"
FONTS_INTER_DIR="$FONTS_DIR/inter"
FONTS_FIRACODE_DIR="$FONTS_DIR/firacode-nerd"
BIN_DIR="/var/home/user/.local/bin"

mkdir -p \
  "$BIN_DIR" \
  "$ICONS_DIR" \
  "$FONTS_DIR" \
  "$FONTS_INTER_DIR" \
  "$FONTS_FIRACODE_DIR"

# ── Starship ─────────────────────────────────────────────────
base="https://github.com/starship/starship/releases/download/v${STARSHIP_VER}"

curl -fsSL \
  "$base/starship-x86_64-unknown-linux-gnu.tar.gz" \
  -o "$tmp/starship.tar.gz"

curl -fsSL \
  "$base/starship-x86_64-unknown-linux-gnu.tar.gz.sha256" \
  -o "$tmp/starship.sha256"

echo "$(tr -d ' \n' < "$tmp/starship.sha256")  $tmp/starship.tar.gz" \
  | sha256sum -c -

tar -xzf "$tmp/starship.tar.gz" -C "$tmp"

install -m 0755 "$tmp/starship" "$BIN_DIR/starship"

# ── Bibata Modern Ice ────────────────────────────────────────
curl -fsSL \
  "https://github.com/ful1e5/Bibata_Cursor/releases/download/${BIBATA_VER}/Bibata-Modern-Ice.tar.xz" \
  -o "$tmp/bibata.tar.xz"

echo "$BIBATA_SHA  $tmp/bibata.tar.xz" | sha256sum -c -

tar -xJf "$tmp/bibata.tar.xz" -C "$ICONS_DIR"

# ── Papirus Icon Theme ───────────────────────────────────────
# La release non pubblica asset: usiamo l'archivio del tag GitHub,
# il cui SHA256 è stato verificato localmente.
PAPIRUS_URL="https://github.com/PapirusDevelopmentTeam/papirus-icon-theme/archive/refs/tags/${PAPIRUS_VER}.tar.gz"

curl -fsSL "$PAPIRUS_URL" -o "$tmp/papirus.tar.gz"

echo "$PAPIRUS_SHA  $tmp/papirus.tar.gz" | sha256sum -c -

mkdir -p "$tmp/papirus-extract"
tar -xzf "$tmp/papirus.tar.gz" -C "$tmp/papirus-extract"

papirus_dir="$(
  find "$tmp/papirus-extract" -mindepth 2 -maxdepth 2 -type d -name 'Papirus' \
    | head -n1
)"

if [[ -z "$papirus_dir" ]]; then
  echo "Impossibile individuare la cartella del tema Papirus." >&2
  exit 1
fi

cp -a "$papirus_dir" "$ICONS_DIR/"

# ── Inter font ───────────────────────────────────────────────
INTER_URL="https://github.com/rsms/inter/releases/download/${INTER_VER}/Inter-${INTER_VER#v}.zip"

curl -fsSL "$INTER_URL" -o "$tmp/inter.zip"

echo "$INTER_SHA  $tmp/inter.zip" | sha256sum -c -

mkdir -p "$tmp/inter-extract"
unzip -q "$tmp/inter.zip" -d "$tmp/inter-extract"

find "$tmp/inter-extract" -type f \( \
  -iname '*.ttf' -o \
  -iname '*.otf' -o \
  -iname '*.woff2' \
\) -exec cp -a {} "$FONTS_INTER_DIR" \;

# ── FiraCode Nerd Font ───────────────────────────────────────
curl -fsSL \
  "https://github.com/ryanoasis/nerd-fonts/releases/download/${NF_VER}/FiraCode.tar.xz" \
  -o "$tmp/firacode.tar.xz"

echo "$NF_SHA  $tmp/firacode.tar.xz" | sha256sum -c -

tar -xJf "$tmp/firacode.tar.xz" -C "$FONTS_FIRACODE_DIR"

# ── Cache font ───────────────────────────────────────────────
if command -v fc-cache >/dev/null; then
  fc-cache -f "$FONTS_DIR"
fi

echo "Installazione asset completata."
echo "Starship: $BIN_DIR/starship"
echo "Temi cursore/icone: $ICONS_DIR"
echo "Font: $FONTS_DIR"

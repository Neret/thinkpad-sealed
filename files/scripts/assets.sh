#!/usr/bin/env bash
set -euo pipefail

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ── Versioni e hash fissati ──────────────────────────────────
STARSHIP_VER="1.27.0"

BIBATA_VER="v2.0.7"
BIBATA_SHA="a68cae60c4dc706350e194ebc91c5fe48bc7bc9d59e119555834a2a7ee5078ef"

PAPIRUS_VER="20260801"
PAPIRUS_SHA="646f622e9e7e9e65eef9d0ab58999d4920ddb33d98e6a75232627cfe3bd508f9"

INTER_VER="v4.1"
INTER_SHA="9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e"

NF_VER="v3.5.1"
NF_SHA="68e3bd6164864b8b514605bc34e3a87ac401c8c48682fcce6478c70263340207"

# ── Directory utente ─────────────────────────────────────────
mkdir -p \
  "$HOME/.local/bin" \
  "$HOME/.local/share/icons" \
  "$HOME/.local/share/fonts/firacode-nerd" \
  "$HOME/.local/share/fonts/inter"

# ── Starship ─────────────────────────────────────────────────
# Binario installato in ~/.local/bin, hash dalla release ufficiale.
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

install -m 0755 "$tmp/starship" "$HOME/.local/bin/starship"

# ── Bibata Modern Ice ────────────────────────────────────────
# Cursore installato in ~/.local/share/icons.
curl -fsSL \
  "https://github.com/ful1e5/Bibata_Cursor/releases/download/${BIBATA_VER}/Bibata-Modern-Ice.tar.xz" \
  -o "$tmp/bibata.tar.xz"

echo "$BIBATA_SHA  $tmp/bibata.tar.xz" | sha256sum -c -

tar -xJf "$tmp/bibata.tar.xz" -C "$HOME/.local/share/icons"

# ── Papirus Icon Theme ───────────────────────────────────────
# Recupera automaticamente l'URL dell'asset .tar.gz dalla release.
PAPIRUS_URL="$(
  curl -fsSL \
    "https://github.com/PapirusDevelopmentTeam/papirus-icon-theme/archive/refs/tags/$PAPIRUS_VER.tar.gz" \
    | grep -o '"browser_download_url": *"[^"]*\.tar\.gz"' \
    | head -n1 \
    | cut -d'"' -f4
)"

if [[ -z "$PAPIRUS_URL" ]]; then
  echo "Impossibile trovare l'asset Papirus per la release ${PAPIRUS_VER}." >&2
  exit 1
fi

curl -fsSL "$PAPIRUS_URL" -o "$tmp/papirus.tar.gz"

echo "$PAPIRUS_SHA  $tmp/papirus.tar.gz" | sha256sum -c -

tar -xzf "$tmp/papirus.tar.gz" -C "$tmp/papirus-extract"
mkdir -p "$tmp/papirus-extract"

# L'archivio può contenere una cartella principale; normalizziamo il tema.
tar -xzf "$tmp/papirus.tar.gz" -C "$tmp/papirus-extract"

if [[ -d "$tmp/papirus-extract/Papirus" ]]; then
  rm -rf "$HOME/.local/share/icons/Papirus"
  cp -a "$tmp/papirus-extract/Papirus" "$HOME/.local/share/icons/Papirus"
else
  papirus_dir="$(find "$tmp/papirus-extract" -mindepth 1 -maxdepth 2 -type d -name 'Papirus' | head -n1)"

  if [[ -z "$papirus_dir" ]]; then
    echo "Impossibile individuare la cartella del tema Papirus." >&2
    exit 1
  fi

  rm -rf "$HOME/.local/share/icons/Papirus"
  cp -a "$papirus_dir" "$HOME/.local/share/icons/Papirus"
fi

# ── Inter font ───────────────────────────────────────────────
# Recupera automaticamente l'URL dell'asset .zip dalla release.
INTER_URL="$(
  curl -fsSL \
    "https://github.com/rsms/inter/releases/download/${INTER_VER}/Inter-${INTER_VER}.zip" \
    | grep -o '"browser_download_url": *"[^"]*\.zip"' \
    | head -n1 \
    | cut -d'"' -f4
)"

if [[ -z "$INTER_URL" ]]; then
  echo "Impossibile trovare l'asset Inter per la release ${INTER_VER}." >&2
  exit 1
fi

curl -fsSL "$INTER_URL" -o "$tmp/inter.zip"

echo "$INTER_SHA  $tmp/inter.zip" | sha256sum -c -

unzip -q "$tmp/inter.zip" -d "$tmp/inter-extract"

# Copia i file font, evitando di duplicare documentazione e metadati.
find "$tmp/inter-extract" -type f \( \
  -iname '*.ttf' -o \
  -iname '*.otf' -o \
  -iname '*.woff2' \
\) -exec cp -a {} "$HOME/.local/share/fonts/inter/" \;

# ── FiraCode Nerd Font ───────────────────────────────────────
curl -fsSL \
  "https://github.com/ryanoasis/nerd-fonts/releases/download/${NF_VER}/FiraCode.tar.xz" \
  -o "$tmp/firacode.tar.xz"

echo "$NF_SHA  $tmp/firacode.tar.xz" | sha256sum -c -

tar -xJf "$tmp/firacode.tar.xz" -C "$HOME/.local/share/fonts/firacode-nerd"

# ── Aggiorna la cache dei font ───────────────────────────────
if command -v fc-cache >/dev/null; then
  fc-cache -f "$HOME/.local/share/fonts"
fi

echo "Installazione completata."
echo "Starship: $HOME/.local/bin/starship"
echo "Temi cursore/icona: $HOME/.local/share/icons"
echo "Font: $HOME/.local/share/fonts"

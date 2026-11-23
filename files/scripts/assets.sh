#!/usr/bin/env bash
set -euo pipefail


sed -i "s/grep -q runc/grep -q 'name: runc'/" /usr/bin/distrobox-create
if ! grep -q "grep -q 'name: runc'" /usr/bin/distrobox-create; then
  echo "::warning::patch distrobox-create non applicata (script cambiato a monte?)"
  grep -n runc /usr/bin/distrobox-create || true
fi

STARSHIP_VER="1.27.0"
STARSHIP_SHA256="10c8eb4cb3b761d9bf59ea828444c2dab36c900b7d69a69e08814b286969df89"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL --proto '=https' --tlsv1.2 \
  "https://github.com/starship/starship/releases/download/v${STARSHIP_VER}/starship-x86_64-unknown-linux-musl.tar.gz" \
  -o "$tmp/starship.tar.gz"
printf '%s  %s\n' "$STARSHIP_SHA256" "$tmp/starship.tar.gz" | sha256sum -c -

tar -xzf "$tmp/starship.tar.gz" -C "$tmp" starship

install -m 0755 "$tmp/starship" /usr/bin/starship
[[ "$(/usr/bin/starship --version)" == *"$STARSHIP_VER"* ]]

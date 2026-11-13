#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT="$(basename "$0")"
STEP="init"

log()   { printf '[%s] %s\n' "$SCRIPT" "$*"; }
group() { STEP="$1"; printf '::group::%s\n' "$1"; }
endgroup() { printf '::endgroup::\n'; }
die()   { printf '::error title=%s::%s\n' "$SCRIPT" "$*" >&2; exit 1; }

on_error() {
    local code=$? line=$1 cmd=$2
    printf '::endgroup::\n'
    printf '::error title=%s failed::step "%s" | line %s | exit %s | command: %s\n' \
        "$SCRIPT" "$STEP" "$line" "$code" "$cmd" >&2
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

download() {
    local url="$1" out="$2"
    log "GET $url"
    curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors "$url" -o "$out" \
        || die "download failed: $url"
    log "saved $(wc -c < "$out") bytes to $out"
}

verify_sha256() {
    local file="$1" expected="$2" actual
    actual="$(sha256sum "$file" | cut -d' ' -f1)"
    log "expected sha256: $expected"
    log "actual   sha256: $actual"
    [[ "$actual" == "$expected" ]] || die "sha256 mismatch for $(basename "$file")"
}

STARSHIP_VER="1.27.0"
STARSHIP_ASSET="starship-x86_64-unknown-linux-musl.tar.gz"
STARSHIP_SHA256="10c8eb4cb3b761d9bf59ea828444c2dab36c900b7d69a69e08814b286969df89"
STARSHIP_URL="https://github.com/starship/starship/releases/download/v${STARSHIP_VER}/${STARSHIP_ASSET}"

group "Starship ${STARSHIP_VER}: download and verify"
download "$STARSHIP_URL" "$tmp/$STARSHIP_ASSET"
verify_sha256 "$tmp/$STARSHIP_ASSET" "$STARSHIP_SHA256"
endgroup

group "Starship ${STARSHIP_VER}: install"
tar -xzf "$tmp/$STARSHIP_ASSET" -C "$tmp"
[[ -f "$tmp/starship" ]] || die "archive does not contain 'starship' binary"
install -m 0755 "$tmp/starship" /usr/bin/starship
log "installed /usr/bin/starship"
/usr/bin/starship --version
endgroup

BITWARDEN_POLICY_URL="https://raw.githubusercontent.com/bitwarden/clients/main/apps/desktop/resources/com.bitwarden.desktop.policy"
BITWARDEN_POLICY_SHA256="e0e0be0cb7ead0007baff1ca6eace2906047e1bc9ab799854e72425b9d177577"
BITWARDEN_POLICY_DEST="/usr/share/polkit-1/actions/com.bitwarden.Bitwarden.policy"

group "Bitwarden polkit policy: download and verify"
download "$BITWARDEN_POLICY_URL" "$tmp/com.bitwarden.Bitwarden.policy"
verify_sha256 "$tmp/com.bitwarden.Bitwarden.policy" "$BITWARDEN_POLICY_SHA256"
grep -q '<policyconfig' "$tmp/com.bitwarden.Bitwarden.policy" \
    || die "downloaded file is not a polkit policy (no <policyconfig> found)"
log "policy action ids:"
grep -o 'action id="[^"]*"' "$tmp/com.bitwarden.Bitwarden.policy" | sed 's/^/    /'
endgroup

group "Bitwarden polkit policy: install"
install -D -m 0644 -o root -g root \
    "$tmp/com.bitwarden.Bitwarden.policy" "$BITWARDEN_POLICY_DEST"
log "installed $BITWARDEN_POLICY_DEST"
ls -lZ "$BITWARDEN_POLICY_DEST"
endgroup

log "done"

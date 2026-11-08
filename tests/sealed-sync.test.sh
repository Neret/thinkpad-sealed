#!/usr/bin/env bash
# Tests for sealed-sync with REAL sbsigntools (sbsign / sbattach / sbverify) and throw-away
# EFI binaries signed with throw-away EC keys (EC signatures differ at every run, like in CI).
# No root, no real ESP: uses the SEALED_ROOT / SEALED_ESP_DIR / SEALED_LIBEXEC test hooks.
#
# Repo path : tests/sealed-sync.test.sh
# Usage     : bash tests/sealed-sync.test.sh        (needs: sbsigntools openssl python3)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBEXEC="$REPO/files/system/usr/libexec"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
OUT=""
RC=0

ok()    { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
ko()    { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; printf '%s\n' "$OUT" | sed 's/^/        | /'; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else ko "$d"; fi; }
has()   { grep -qF -- "$1" <<<"$OUT"; }
hasnt() { ! grep -qF -- "$1" <<<"$OUT"; }
rc_is() { [[ "$RC" == "$1" ]]; }
same()  { [[ "$(sha256sum <"$1")" == "$(sha256sum <"$2")" ]]; }
unsigned_same() { # two PE files, signatures ignored
  local a b
  a="$(mktemp -p "$T")"; b="$(mktemp -p "$T")"
  cp "$1" "$a"; cp "$2" "$b"
  sbattach --remove "$a" >/dev/null 2>&1; sbattach --remove "$b" >/dev/null 2>&1
  cmp -s "$a" "$b"
}
esp_hash() { find "$T/esp" -type f -exec sha256sum {} + | sort | sha256sum; }

# ---------------------------------------------------------------- fixtures
cat > "$T/mkpe.py" <<'EOF'
import struct, sys
out, marker = sys.argv[1], sys.argv[2].encode()
sect_data = marker.ljust(0x200, b'\0')
dos = bytearray(0x80); dos[0:2] = b'MZ'; struct.pack_into('<I', dos, 0x3c, 0x80)
coff = struct.pack('<HHIIIHH', 0x8664, 1, 0, 0, 0, 0xF0, 0x0022)
opt = struct.pack('<HBBIIIIIQIIHHHHHHIIIIHHQQQQII',
    0x20b, 0, 0, 0x200, 0, 0, 0x1000, 0x1000, 0x140000000, 0x1000, 0x200,
    0, 0, 0, 0, 6, 0, 0, 0x2000, 0x200, 0, 10, 0, 0x100000, 0x1000, 0x100000, 0x1000, 0, 16)
opt += b'\0' * (16 * 8)
sect = struct.pack('<8sIIIIIIHHI', b'.text', len(sect_data), 0x1000, 0x200, 0x200, 0, 0, 0, 0, 0x60000020)
open(out, 'wb').write((bytes(dos) + b'PE\0\0' + coff + opt + sect).ljust(0x200, b'\0') + sect_data)
EOF

mkcert() { # name CN
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$T/$1.key" -out "$T/$1.crt" -subj "/CN=$2" -days 2 2>/dev/null
}
mkcert mok "Test MOK"
mkcert other "Other MOK"
mkcert msft "Microsoft Corporation UEFI CA 2011"
mkcert vendor "Test Vendor CA"

# signed_pe OUT MARKER SIGNER
signed_pe() {
  python3 "$T/mkpe.py" "$T/unsigned.efi" "$2"
  sbsign --key "$T/$3.key" --cert "$T/$3.crt" --output "$1" "$T/unsigned.efi" >/dev/null 2>&1
}

# mk_image SDB_VERSION SHIM_VERSION [SDB_SIGNER]
mk_image() {
  local sdb="$1" shim="$2" signer="${3:-mok}"
  rm -rf "$T/root"
  mkdir -p "$T/root/usr/lib/systemd/boot/efi" "$T/root/usr/lib/efi/shim/$shim/EFI/fedora" "$T/root/usr/share/sealed"
  signed_pe "$T/root/usr/lib/systemd/boot/efi/systemd-bootx64.efi" "LoaderInfo: systemd-boot $sdb ####" "$signer"
  signed_pe "$T/root/usr/lib/efi/shim/$shim/EFI/fedora/shimx64.efi" "shim $shim" msft
  signed_pe "$T/root/usr/lib/efi/shim/$shim/EFI/fedora/mmx64.efi" "mm $shim" vendor
  cp "$T/mok.crt" "$T/root/usr/share/sealed/MOK.crt"
}
mk_esp() {
  rm -rf "$T/esp"
  mkdir -p "$T/esp/EFI/BOOT" "$T/esp/EFI/systemd" "$T/esp/EFI/Linux"
}
SDB_IMG() { echo "$T/root/usr/lib/systemd/boot/efi/systemd-bootx64.efi"; }
run() {
  OUT="$(SEALED_ROOT="$T/root" SEALED_ESP_DIR="$T/esp" SEALED_LIBEXEC="$LIBEXEC" "$LIBEXEC/sealed-sync" "$@" 2>&1)"
  RC=$?
}

echo "== prerequisites"
for c in sbsign sbattach sbverify openssl python3; do check "tool: $c" command -v "$c"; done
for f in "$LIBEXEC/sealed-sync" "$LIBEXEC"/sealed-sync.d/*; do check "executable: ${f#"$REPO"/}" test -x "$f"; done

echo "== first install on an empty ESP"
mk_image 259.1 16.1-7; mk_esp
run
check "exit 0"                                   rc_is 0
check "systemd-boot copied"                      same "$(SDB_IMG)" "$T/esp/EFI/systemd/systemd-bootx64.efi"
check "grubx64.efi copied"                       same "$(SDB_IMG)" "$T/esp/EFI/BOOT/grubx64.efi"
check "shim copied"                              same "$T/root/usr/lib/efi/shim/16.1-7/EFI/fedora/shimx64.efi" "$T/esp/EFI/BOOT/BOOTX64.EFI"
check "MokManager copied"                        same "$T/root/usr/lib/efi/shim/16.1-7/EFI/fedora/mmx64.efi" "$T/esp/EFI/BOOT/mmx64.efi"
check "shim version recorded"                    test "$(cat "$T/esp/EFI/BOOT/shim-version.txt")" = "16.1-7"
check "MOK.cer written as DER"                   openssl x509 -inform DER -in "$T/esp/EFI/BOOT/MOK.cer" -noout

echo "== second run: nothing to do"
before="$(esp_hash)"
run
check "exit 0"                                   rc_is 0
check "nothing updated"                          hasnt "updated:"
check "ESP untouched"                            test "$before" = "$(esp_hash)"

echo "== same binary, only the signature changed (the case you asked about)"
sbattach --remove "$T/unsigned.efi" >/dev/null 2>&1
python3 "$T/mkpe.py" "$T/unsigned.efi" "LoaderInfo: systemd-boot 259.1 ####"
sbsign --key "$T/mok.key" --cert "$T/mok.crt" --output "$(SDB_IMG)" "$T/unsigned.efi" >/dev/null 2>&1
differs() { ! cmp -s "$1" "$2"; }
check "image binary has a DIFFERENT signature"   differs "$(SDB_IMG)" "$T/esp/EFI/systemd/systemd-bootx64.efi"
check "...but is the SAME binary"                unsigned_same "$(SDB_IMG)" "$T/esp/EFI/systemd/systemd-bootx64.efi"
before="$(esp_hash)"
run
check "exit 0"                                   rc_is 0
check "reported as already aligned"              has "same binary, valid signature"
check "ESP NOT rewritten"                        test "$before" = "$(esp_hash)"
check "no .prev created by a re-sign"            test ! -e "$T/esp/EFI/systemd/systemd-bootx64.efi.prev"

echo "== new systemd-boot version: copy + backup of the previous binary"
old_hash="$(sha256sum <"$T/esp/EFI/systemd/systemd-bootx64.efi")"
mk_image 259.2 16.1-7
run
check "exit 0"                                   rc_is 0
check "systemd-boot updated"                     same "$(SDB_IMG)" "$T/esp/EFI/systemd/systemd-bootx64.efi"
check "grubx64.efi updated"                      same "$(SDB_IMG)" "$T/esp/EFI/BOOT/grubx64.efi"
check ".prev holds the previous binary"          test "$(sha256sum <"$T/esp/EFI/systemd/systemd-bootx64.efi.prev")" = "$old_hash"

echo "== a re-sign after that must NOT overwrite .prev"
prev_before="$(sha256sum <"$T/esp/EFI/systemd/systemd-bootx64.efi.prev")"
python3 "$T/mkpe.py" "$T/unsigned.efi" "LoaderInfo: systemd-boot 259.2 ####"
sbsign --key "$T/mok.key" --cert "$T/mok.crt" --output "$(SDB_IMG)" "$T/unsigned.efi" >/dev/null 2>&1
run
check "exit 0"                                   rc_is 0
check ".prev unchanged"                          test "$(sha256sum <"$T/esp/EFI/systemd/systemd-bootx64.efi.prev")" = "$prev_before"

echo "== same binary but the ESP copy is signed by another key: replaced"
signed_pe "$T/esp/EFI/BOOT/grubx64.efi" "LoaderInfo: systemd-boot 259.2 ####" other
run
check "exit 0"                                   rc_is 0
check "warns about the invalid signature"        has "same binary but signature not valid"
check "grubx64.efi now signed by the MOK"        sbverify --cert "$T/mok.crt" "$T/esp/EFI/BOOT/grubx64.efi"

echo "== image systemd-boot older than the ESP one: no downgrade"
mk_image 258 16.1-7
before="$(sha256sum "$T"/esp/EFI/systemd/systemd-bootx64.efi "$T"/esp/EFI/BOOT/grubx64.efi)"
run
check "exit 0"                                   rc_is 0
check "downgrade refused"                        has "refusing to downgrade"
check "systemd-boot copies untouched"            test "$before" = "$(sha256sum "$T"/esp/EFI/systemd/systemd-bootx64.efi "$T"/esp/EFI/BOOT/grubx64.efi)"

echo "== image systemd-boot not signed by the MOK: refuse, other components still run"
mk_image 260 16.1-7 other
before="$(sha256sum <"$T/esp/EFI/BOOT/grubx64.efi")"
run
check "exit 1"                                   rc_is 1
check "bootloader reported as failed"            has "failed components: bootloader"
check "grubx64.efi untouched"                    test "$before" = "$(sha256sum <"$T/esp/EFI/BOOT/grubx64.efi")"
check "other components ran"                     has "starting component: shim"

echo "== dry-run never writes"
mk_image 261 16.1-7
before="$(esp_hash)"
run --dry-run
check "exit 0"                                   rc_is 0
check "reports what it would do"                 has "would update"
check "ESP untouched"                            test "$before" = "$(esp_hash)"

echo "== shim / MokManager: a lower image version is not installed"
mk_image 261 15.0
before="$(sha256sum <"$T/esp/EFI/BOOT/BOOTX64.EFI")"
run shim mokmanager
check "exit 0"                                   rc_is 0
check "shim downgrade refused"                   has "refusing to downgrade"
check "BOOTX64.EFI untouched"                    test "$before" = "$(sha256sum <"$T/esp/EFI/BOOT/BOOTX64.EFI")"

echo "== shim not signed by Microsoft: refuse"
mk_image 261 16.1-8
signed_pe "$T/root/usr/lib/efi/shim/16.1-8/EFI/fedora/shimx64.efi" "shim x" other
run shim
check "exit 1"                                   rc_is 1
check "refused"                                  has "does not have a Microsoft signature"

echo "== leftovers and arguments"
mk_image 261 16.1-7; mk_esp
touch "$T/esp/EFI/BOOT/BOOTX64.EFI.new" "$T/esp/EFI/systemd/x.efi.new"
run mokmanager
check "*.new files removed"                      test ! -e "$T/esp/EFI/BOOT/BOOTX64.EFI.new" -a ! -e "$T/esp/EFI/systemd/x.efi.new"
run nonsense
check "unknown component: exit 1"                rc_is 1

echo "== logs under systemd carry a syslog priority prefix"
OUT="$(JOURNAL_STREAM=1:1 SEALED_ROOT="$T/root" SEALED_ESP_DIR="$T/esp" SEALED_LIBEXEC="$LIBEXEC" "$LIBEXEC/sealed-sync" --dry-run 2>&1)"
check "<6> for info"                             has "<6>bootloader:"
mk_image 259 16.1-7; mk_esp; run >/dev/null
mk_image 258 16.1-7
OUT="$(JOURNAL_STREAM=1:1 SEALED_ROOT="$T/root" SEALED_ESP_DIR="$T/esp" SEALED_LIBEXEC="$LIBEXEC" "$LIBEXEC/sealed-sync" bootloader 2>&1)"
check "<4> for warnings"                         has "<4>bootloader:"

echo "== a component cannot be run directly"
OUT="$(SEALED_ROOT="$T/root" SEALED_LIBEXEC="$LIBEXEC" "$LIBEXEC/sealed-sync.d/20-shim" 2>&1)"; RC=$?
check "refused with exit 1"                      rc_is 1

echo
printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
(( FAIL == 0 ))

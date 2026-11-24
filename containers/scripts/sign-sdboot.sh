#!/usr/bin/env bash
set -euo pipefail
src=/target/usr/lib/systemd/boot/efi/systemd-bootx64.efi
test -f "$src"
mkdir -p /out
sbsign --key /run/secrets/key --cert /run/secrets/cert \
  --output /out/systemd-bootx64.efi "$src"
sbverify --cert /run/secrets/cert /out/systemd-bootx64.efi

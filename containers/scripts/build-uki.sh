#!/usr/bin/env bash
set -euo pipefail
STRICT_BOOTC="${STRICT_BOOTC:-0}"

kver=$(ls /kernel)
test -n "${kver}"
test -d "/kernel/${kver}"

tools_v="$(bootc --version | head -n1)"
os_v="$(chroot /target /usr/bin/bootc --version 2>/dev/null | head -n1 || true)"
if [ "${tools_v}" != "${os_v}" ]; then
  msg="bootc diverso: tools='${tools_v}' immagine='${os_v:-non determinabile}'"
  if [ "${STRICT_BOOTC}" = "1" ]; then echo "ERRORE: ${msg}"; exit 1; fi
  echo "::warning::${msg}"
fi

initrd="/kernel/${kver}/initramfs.img"
test -f "${initrd}"
lst="$(mktemp)"
lsinitrd "${initrd}" > "${lst}" 2>/dev/null
missing=0
for pat in bootc-root-setup.service systemd-cryptsetup libtss2 plymouth; do
  if ! grep -q "${pat}" "${lst}"; then
    echo "ERRORE: initramfs senza '${pat}' (rigenerala nella recipe)"
    missing=1
  fi
done
for pat in amdgpu AuthenticAMD; do
  grep -q "${pat}" "${lst}" || echo "::warning::initramfs senza ${pat}"
done
[ "${missing}" -eq 0 ] || exit 1

stub="/target/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
if [ ! -f "${stub}" ]; then
  echo "stub non nella rootfs, uso quello dei tools"
  stub="/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
fi
test -f "${stub}"

mkdir -p /out
bootc container ukify \
  --rootfs /target \
  --kernel-dir "/kernel/${kver}" \
  -- \
  --output "/out/${kver}.efi" \
  --signtool sbsign \
  --secureboot-private-key /run/secrets/key \
  --secureboot-certificate /run/secrets/cert \
  --stub "${stub}"

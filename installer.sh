#!/usr/bin/env bash
set -euo pipefail

# Pacchetti necessari sull'host:
# sfdisk wipefs blkid lsblk mount findmnt cryptsetup podman oppure docker
# file udevadm blockdev

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERR]\033[0m %s\n' "$*"; }
die()  { err "$*"; exit 1; }

ask() {
  local prompt="$1" default="$2" value
  read -rp "$prompt [$default]: " value
  printf '%s' "${value:-$default}"
}

DISK=""
IMAGE=""
MOK_CERT=""
SCR=/run/sealed-scratch
KEY=/run/sealed-luks.key
TOOLS=sealed-tools
TOOLS_BASE=quay.io/fedora/fedora:45
SCRATCH_G=20
FINISH="${FINISH:-0}"
TOOLS_BUILT=0

cleanup() {
  if [[ -n "${DISK:-}" ]]; then
    while findmnt -n -o SOURCE --target /var/tmp 2>/dev/null | grep -q "${DISK}p3"; do
      umount /var/tmp 2>/dev/null || break
    done
  fi

  umount "$SCR" 2>/dev/null || true
  umount /mnt/boot 2>/dev/null || true
  umount /mnt 2>/dev/null || true
  cryptsetup close cryptroot 2>/dev/null || true
  rm -f "$KEY"

  if [[ "$TOOLS_BUILT" == 1 ]]; then
    "$RUNTIME" rmi -f "$TOOLS" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ $EUID -eq 0 ]] || die "Esegui lo script come root (sudo)."
[[ "$(uname -m)" == "x86_64" ]] || die "Supportato solo UEFI x86_64."

if command -v podman >/dev/null 2>&1; then
  RUNTIME=podman
elif command -v docker >/dev/null 2>&1; then
  RUNTIME=docker
else
  die "Comando mancante: podman oppure docker"
fi

DISK="$(ask 'Disco target (verra cancellato)' '/dev/nvme0n1')"
IMAGE="$(ask 'Immagine bootc' 'ghcr.io/neret/fedora-bootc-sealed-os:sealed')"
MOK_CERT="$(ask 'Certificato MOK DER' './secureboot/MOK.cer')"

[[ -b "$DISK" ]] || die "Disco non trovato: $DISK"
[[ -f "$MOK_CERT" ]] || die "Certificato MOK non trovato: $MOK_CERT"

for cmd in sfdisk wipefs blkid lsblk mount findmnt cryptsetup file udevadm blockdev; do
  command -v "$cmd" >/dev/null 2>&1 || die "Comando mancante: $cmd"
done

if file -b "$MOK_CERT" | grep -qi 'PEM'; then
  die "$MOK_CERT e' in formato PEM: MokManager vuole DER (.cer binario)."
fi

[[ -d /mnt ]] || mkdir -p "$(readlink -m /mnt)"

DISK_G=$(( $(blockdev --getsize64 "$DISK") / 1073741824 ))
ROOT_G=$(( DISK_G - 2 - SCRATCH_G - 1 ))
(( ROOT_G >= 20 )) || die "Disco troppo piccolo ($DISK_G GiB) per ESP + root + scratch"

log "Preparo container strumenti con $RUNTIME"
BUILD_DIR="$(mktemp -d)"
cat > "$BUILD_DIR/Containerfile" <<EOF
FROM ${TOOLS_BASE}
RUN dnf install -y dosfstools btrfs-progs sbsigntools openssl \
    && dnf clean all
EOF
"$RUNTIME" build -q -t "$TOOLS" "$BUILD_DIR" >/dev/null
rm -rf "$BUILD_DIR"
TOOLS_BUILT=1
ok "container strumenti pronto"

tool() {
  "$RUNTIME" run --rm --privileged --security-opt label=disable \
    -v /dev:/dev "$TOOLS" "$@"
}

log "Disco target"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL "$DISK"

if [[ "$FINISH" == 1 ]]; then
  read -rsp "Passphrase LUKS gia' impostata: " P1; echo
else
  read -rp "Questo cancellera TUTTO su $DISK. Scrivi il nome completo del device per confermare: " confirm
  [[ "$confirm" == "$DISK" ]] || die "Conferma non corrispondente: installazione annullata."

  read -rsp "Scegli la passphrase LUKS: " P1; echo
  read -rsp "Ripeti la passphrase LUKS: " P2; echo
  [[ -n "$P1" && "$P1" == "$P2" ]] || die "Le passphrase non coincidono (o sono vuote)."
fi

( umask 077; printf '%s' "$P1" > "$KEY" )
unset P1 P2

if [[ "$FINISH" != 1 ]]; then

log "Pulizia di mount, LUKS e firme residue"
umount -R /mnt 2>/dev/null || true

while findmnt -n -o SOURCE --target /var/tmp 2>/dev/null | grep -q "${DISK}p3"; do
  umount /var/tmp 2>/dev/null || break
done

umount "$SCR" 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true
wipefs -af "${DISK}"p* 2>/dev/null || true
wipefs -af "$DISK"

log "Creo layout: ESP 2 GiB + root LUKS2 (${ROOT_G} GiB) + scratch ${SCRATCH_G} GiB"
sfdisk "$DISK" <<EOT
label: gpt
size=2GiB, type=U, name="ESP"
size=${ROOT_G}GiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name="root"
type=L, name="scratch"
EOT
udevadm settle
sleep 2

ESP="${DISK}p1"
ROOT="${DISK}p2"
SCRATCH="${DISK}p3"
[[ -b "$ESP" && -b "$ROOT" && -b "$SCRATCH" ]] || die "Partizioni non create"

log "Formatto ESP e scratch"
tool mkfs.vfat -F32 "$ESP"
tool mkfs.btrfs -f -L scratch "$SCRATCH"

mkdir -p "$SCR"
mount "$SCRATCH" "$SCR"
chmod 1777 "$SCR"
chcon -t tmp_t "$SCR" 2>/dev/null || true

mount --bind "$SCR" /var/tmp
log "Spazio libero su /var/tmp (ora sull'NVMe)"
df -h /var/tmp

log "Creo LUKS2"
cryptsetup luksFormat --type luks2 --pbkdf argon2id --batch-mode --key-file "$KEY" "$ROOT"

log "Apro il container LUKS"
cryptsetup open --key-file "$KEY" "$ROOT" cryptroot

log "Formatto btrfs dentro LUKS"
tool mkfs.btrfs -f -L sealed-root /dev/mapper/cryptroot

log "Monto root e ESP"
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot
mount "$ESP" /mnt/boot

LUKS_UUID="$(cryptsetup luksUUID "$ROOT")"
ROOT_UUID="$(blkid -s UUID -o value /dev/mapper/cryptroot)"
ESP_UUID="$(blkid -s UUID -o value "$ESP")"

echo "LUKS UUID:  $LUKS_UUID"
echo "btrfs UUID: $ROOT_UUID"
echo "ESP UUID:   $ESP_UUID"

log "Installo immagine sealed: $IMAGE"

BOOTC_MOUNTS=(-v /dev:/dev -v "$SCR":/var/tmp -v /mnt:/target)

if [[ -d /var/lib/containers ]]; then
  BOOTC_MOUNTS+=(-v /var/lib/containers:/var/lib/containers)
fi

"$RUNTIME" run --rm --privileged --pid=host --ipc=host \
  --security-opt label=disable \
  "${BOOTC_MOUNTS[@]}" \
  "$IMAGE" \
  bootc install to-filesystem \
  --composefs-backend \
  --bootloader systemd \
  --boot-mount-spec "UUID=$ESP_UUID" \
  /target

sync

else
  ESP="${DISK}p1"
  ROOT="${DISK}p2"
  SCRATCH="${DISK}p3"

  [[ -b /dev/mapper/cryptroot ]] && mountpoint -q /mnt \
    || die "FINISH=1: LUKS aperto o /mnt non montato. Rilancia senza FINISH."

  mountpoint -q /mnt/boot || mount "$ESP" /mnt/boot

  LUKS_UUID="$(cryptsetup luksUUID "$ROOT")"
  ROOT_UUID="$(blkid -s UUID -o value /dev/mapper/cryptroot)"
  ESP_UUID="$(blkid -s UUID -o value "$ESP")"
fi

log "Rimonto la ESP in scrittura"
mount -o remount,rw /mnt/boot 2>/dev/null \
  || { umount /mnt/boot && mount "$ESP" /mnt/boot; }

touch /mnt/boot/.rwtest 2>/dev/null && rm -f /mnt/boot/.rwtest \
  || { dmesg | tail -n 15; die "ESP ancora in sola lettura (vedi dmesg sopra)"; }
ok "ESP scrivibile"

log "Popolo la ESP con lo stesso sealed-sync che girera' a ogni boot"

SDB="/mnt/boot/EFI/systemd/systemd-bootx64.efi"
[[ -f "$SDB" ]] || die "systemd-bootx64.efi non trovato in /mnt/boot/EFI/systemd (bootc non l'ha installato)"

# Una sola fonte di verita': bootloader, shim, MokManager, MOK.cer e versione di shim
# vengono scritti dagli script dell'immagine (con le stesse verifiche di firma del sistema installato).
"$RUNTIME" run --rm --security-opt label=disable \
  -e SEALED_ESP_DIR=/esp -v /mnt/boot:/esp \
  "$IMAGE" sh -c 'test -x /usr/libexec/sealed-sync || { echo "l immagine non contiene /usr/libexec/sealed-sync" >&2; exit 1; }
                  exec /usr/libexec/sealed-sync' \
  || die "sealed-sync dell'immagine fallito: la ESP non e' pronta"
ok "ESP popolata da sealed-sync"

log "Audit della ESP"

ESP_MNT=/mnt/boot
FAIL=0

check_file() {
  [[ -f "$1" ]] && ok "presente: $1" || { err "manca: $1"; FAIL=1; }
}

verify_mok_signature() {
  local rel="${1#$ESP_MNT/}"
  if "$RUNTIME" run --rm --security-opt label=disable \
       -v "$ESP_MNT":/esp:ro -v "$(readlink -f "$MOK_CERT")":/mok.cer:ro "$TOOLS" sh -c '
         openssl x509 -inform DER -in /mok.cer -out /tmp/mok.pem &&
         sbverify --cert /tmp/mok.pem "/esp/$1"' _ "$rel" >/dev/null 2>&1; then
    ok "firma MOK valida: $rel"
  else
    err "firma MOK non valida o assente: $rel"
    FAIL=1
  fi
}

check_file "$ESP_MNT/EFI/BOOT/BOOTX64.EFI"
check_file "$ESP_MNT/EFI/BOOT/grubx64.efi"
check_file "$ESP_MNT/EFI/BOOT/mmx64.efi"
check_file "$ESP_MNT/EFI/BOOT/MOK.cer"
check_file "$ESP_MNT/EFI/BOOT/shim-version.txt"
check_file "$ESP_MNT/EFI/systemd/systemd-bootx64.efi"

mapfile -t UKIS < <(find "$ESP_MNT/EFI/Linux" -type f -name '*.efi' 2>/dev/null | sort)
(( ${#UKIS[@]} > 0 )) || { err "nessuna UKI in $ESP_MNT/EFI/Linux"; FAIL=1; }
UKI="${UKIS[0]:-}"

verify_mok_signature "$ESP_MNT/EFI/systemd/systemd-bootx64.efi"
verify_mok_signature "$ESP_MNT/EFI/BOOT/grubx64.efi"
for u in "${UKIS[@]}"; do
  verify_mok_signature "$u"
done

# shim firmato Microsoft, MokManager firmato dal vendor
out="$("$RUNTIME" run --rm --security-opt label=disable -v "$ESP_MNT":/esp:ro "$TOOLS" \
      sbverify --list /esp/EFI/BOOT/BOOTX64.EFI 2>&1)" || true
if grep -qi 'Microsoft' <<<"$out"; then ok "shim firmato Microsoft"; else err "shim: firma Microsoft non trovata"; FAIL=1; fi
out="$("$RUNTIME" run --rm --security-opt label=disable -v "$ESP_MNT":/esp:ro "$TOOLS" \
      sbverify --list /esp/EFI/BOOT/mmx64.efi 2>&1)" || true
if grep -q 'image signature' <<<"$out"; then ok "MokManager firmato (chiave vendor)"; else err "MokManager non firmato"; FAIL=1; fi

# il MOK.cer sulla ESP (scritto da sealed-sync dal certificato dell'immagine) deve essere
# lo stesso che hai fornito tu: si confronta l'impronta, non i byte
fp() { "$RUNTIME" run --rm --security-opt label=disable -v "$1":/c:ro "$TOOLS" \
         openssl x509 -inform DER -in /c -noout -fingerprint -sha256 2>/dev/null; }
fp_given="$(fp "$(readlink -f "$MOK_CERT")")"
fp_esp="$(fp "$ESP_MNT/EFI/BOOT/MOK.cer")"
if [[ -n "$fp_given" && "$fp_given" == "$fp_esp" ]]; then
  ok "MOK.cer sulla ESP == certificato fornito (${fp_given#*=})"
else
  err "MOK.cer sulla ESP diverso dal certificato fornito: l'immagine e il tuo MOK.cer non coincidono"
  FAIL=1
fi

if cmp -s "$ESP_MNT/EFI/systemd/systemd-bootx64.efi" "$ESP_MNT/EFI/BOOT/grubx64.efi"; then
  ok "systemd-boot coerente tra EFI/systemd e EFI/BOOT"
else
  err "EFI/BOOT/grubx64.efi diverso da EFI/systemd/systemd-bootx64.efi"
  FAIL=1
fi

log "Altri file presenti nella ESP (solo informativo)"
while IFS= read -r -d '' f; do
  rel="${f#$ESP_MNT/}"
  case "$rel" in
    EFI/BOOT/*|EFI/systemd/*|EFI/Linux/*|loader/*) ;;
    *) warn "extra: $rel" ;;
  esac
done < <(find "$ESP_MNT" -type f -print0)

log "Riepilogo"
echo "Runtime:    $RUNTIME"
echo "ESP UUID:   $ESP_UUID"
echo "btrfs UUID: $ROOT_UUID"
echo "LUKS UUID:  $LUKS_UUID"
echo "UKI:        ${UKI:-non trovata}"

if [[ $FAIL -ne 0 ]]; then
  die "Audit fallito: NON riavviare finche' non e' risolto."
fi
ok "TUTTO OK"

log "Smonto e chiudo LUKS"
umount /mnt/boot
umount /mnt
cryptsetup close cryptroot

log "Restituisco lo spazio di scratch alla root"
if sfdisk --delete "$DISK" 3 \
   && echo ',+' | sfdisk --no-reread -N 2 "$DISK" \
   && { blockdev --rereadpt "$DISK" || true; } \
   && udevadm settle \
   && cryptsetup open --key-file "$KEY" "$ROOT" cryptroot \
   && mount /dev/mapper/cryptroot /mnt \
   && "$RUNTIME" run --rm --privileged --security-opt label=disable \
        -v /dev:/dev -v /mnt:/mnt "$TOOLS" btrfs filesystem resize max /mnt; then
  ok "root estesa a tutto il disco"
else
  warn "ridimensionamento non riuscito: il sistema funziona comunque, la root resta di ${ROOT_G} GiB"
fi

log "Installazione completata"
echo "Al primo boot:"
echo "1. Se la MOK non e' enrollata, MokManager parte da solo:"
echo "   Enroll key from disk -> EFI/BOOT/MOK.cer -> Continue -> Yes"
echo "2. Poi inserisci la passphrase LUKS."

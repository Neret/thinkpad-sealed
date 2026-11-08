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

# Nome della partizione N del disco: nvme0n1 -> nvme0n1p1, mmcblk0 -> mmcblk0p1, sda -> sda1
part() {
  case "$DISK" in
    *[0-9]) printf '%sp%s' "$DISK" "$1" ;;
    *)      printf '%s%s' "$DISK" "$1" ;;
  esac
}

cleanup() {
  if [[ -n "${DISK:-}" ]]; then
    while findmnt -n -o SOURCE --target /var/tmp 2>/dev/null | grep -q "$(part 3)"; do
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
[[ "$(lsblk -ndo TYPE "$DISK" 2>/dev/null)" == "disk" ]] \
  || die "$DISK non e' un disco intero (e' una partizione o un altro tipo di device)"
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
RUN dnf install -y dosfstools e2fsprogs sbsigntools openssl \
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

# Rende il disco libero: swap spento, mount smontati (i piu' profondi per primi),
# mapping LUKS/LVM chiusi (i figli per primi). Si rifiuta se il sistema in uso sta sul disco.
# A fine corsa verifica che non resti nulla di attivo: meglio fermarsi qui che far fallire wipefs/sfdisk.
release_disk() {
  local disk="$1" dev type t
  local -a devs targets

  mapfile -t devs < <(lsblk -nrpo NAME "$disk")

  # 1. il sistema in uso (o la USB live) non deve stare sul disco che stiamo per cancellare
  for dev in "${devs[@]}"; do
    while IFS= read -r t; do
      case "$t" in
        /|/usr|/sysroot|/run/initramfs/live|/run/rootfsbase|/run/live/medium)
          die "$dev e' montato su $t: il disco target contiene il sistema in uso. Avvia da una USB live ed esegui l'installer da li." ;;
      esac
    done < <(findmnt -rn -o TARGET -S "$dev" 2>/dev/null)
  done

  # 2. swap
  for dev in "${devs[@]}"; do
    if swapon --noheadings --show=NAME 2>/dev/null | grep -qxF "$dev"; then
      swapoff "$dev" || die "swapoff fallito su $dev"
    fi
  done

  # 3. mount: percorsi piu' lunghi (piu' profondi) per primi
  mapfile -t targets < <(
    for dev in "${devs[@]}"; do findmnt -rn -o TARGET -S "$dev" 2>/dev/null; done \
      | sort -u | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-
  )
  for t in "${targets[@]}"; do
    [[ -n "$t" ]] || continue
    umount "$t" 2>/dev/null || die "impossibile smontare $t (qualcosa lo sta usando: chiudi shell e programmi aperti li')"
  done

  # 4. mapping LUKS/LVM: i figli vengono dopo i genitori in lsblk, quindi si legge al contrario
  while read -r dev type; do
    case "$type" in
      disk|part) ;;
      crypt) cryptsetup close "$dev" || die "cryptsetup close fallito su $dev" ;;
      *)
        command -v dmsetup >/dev/null 2>&1 || die "$dev ($type) attivo ma dmsetup non e' installato"
        dmsetup remove "$dev" || die "dmsetup remove fallito su $dev"
        ;;
    esac
  done < <(lsblk -nrpo NAME,TYPE "$disk" | tac)

  udevadm settle

  # 5. controllo finale
  if lsblk -nr -o TYPE "$disk" | grep -qvE '^(disk|part)$'; then
    die "su $disk restano mapping attivi: chiudili a mano e rilancia"
  fi
  if [[ -n "$(lsblk -nr -o MOUNTPOINTS "$disk" | tr -d '[:space:]')" ]]; then
    die "su $disk restano mount o swap attivi: smontali a mano e rilancia"
  fi
}

# 0 se il filesystem ext4 sul device ha la feature verity (letta da tune2fs).
# L'output va in una variabile: con "pipefail" grep -q chiuderebbe la pipe in anticipo.
root_has_verity() {
  local info
  info="$(tool tune2fs -l "$1" 2>/dev/null)" || return 1
  grep -Eq '^Filesystem features:.*[[:space:]]verity([[:space:]]|$)' <<<"$info"
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

log "Libero il disco: swap, mount, LUKS/LVM aperti"
umount -R /mnt 2>/dev/null || true

while findmnt -n -o SOURCE --target /var/tmp 2>/dev/null | grep -q "$(part 3)"; do
  umount /var/tmp 2>/dev/null || break
done

release_disk "$DISK"
ok "nessun mount, swap o mapping attivo su $DISK"

log "Cancello le firme (LUKS, filesystem, tabella delle partizioni)"
while read -r p; do
  wipefs -af "$p" >/dev/null || die "wipefs fallito su $p"
done < <(lsblk -nrpo NAME,TYPE "$DISK" | awk '$2=="part"{print $1}')
wipefs -af "$DISK" >/dev/null || die "wipefs fallito su $DISK"

log "Creo layout: ESP 2 GiB + root LUKS2 (${ROOT_G} GiB) + scratch ${SCRATCH_G} GiB"
sfdisk "$DISK" <<EOT
label: gpt
size=2GiB, type=U, name="ESP"
size=${ROOT_G}GiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name="root"
type=L, name="scratch"
EOT
udevadm settle
sleep 2

ESP="$(part 1)"
ROOT="$(part 2)"
SCRATCH="$(part 3)"
[[ -b "$ESP" && -b "$ROOT" && -b "$SCRATCH" ]] || die "Partizioni non create"

log "Formatto ESP e scratch"
tool mkfs.vfat -F32 "$ESP"
tool mkfs.ext4 -F -q -L scratch "$SCRATCH"

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

log "Formatto ext4 (con fs-verity) dentro LUKS"
# fs-verity e' obbligatorio per l'immagine sigillata (verity=require): su ext4 va attivato
# al mkfs. Blocchi da 4 KiB = dimensione di pagina, requisito di fs-verity.
tool mkfs.ext4 -F -q -b 4096 -O verity -L sealed-root /dev/mapper/cryptroot
root_has_verity /dev/mapper/cryptroot \
  || die "ext4 creato senza la feature verity: l'immagine sigillata non potrebbe avviarsi"
ok "ext4 con feature verity"

log "Monto root e ESP"
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot
mount "$ESP" /mnt/boot

LUKS_UUID="$(cryptsetup luksUUID "$ROOT")"
ROOT_UUID="$(blkid -s UUID -o value /dev/mapper/cryptroot)"
ESP_UUID="$(blkid -s UUID -o value "$ESP")"

echo "LUKS UUID:  $LUKS_UUID"
echo "root UUID:  $ROOT_UUID"
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
  ESP="$(part 1)"
  ROOT="$(part 2)"
  SCRATCH="$(part 3)"

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

# La root deve essere ext4 con fs-verity (vale anche per FINISH=1, dove il mkfs e' gia' stato fatto)
ROOT_FSTYPE="$(blkid -s TYPE -o value /dev/mapper/cryptroot 2>/dev/null || true)"
if [[ "$ROOT_FSTYPE" == "ext4" ]] && root_has_verity /dev/mapper/cryptroot; then
  ok "root ext4 con fs-verity"
else
  err "root non ext4 o senza fs-verity (tipo: ${ROOT_FSTYPE:-sconosciuto}): l'immagine sigillata non si avvierebbe"
  FAIL=1
fi

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
echo "root UUID:  $ROOT_UUID"
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

# Ridimensionamento a freddo (filesystem non montato): e2fsck forzato, poi resize2fs.
# e2fsck esce con 0 (pulito) o 1 (corretto qualcosa); da 2 in su e' un errore.
grow_root() {
  local rc=0
  tool e2fsck -f -p /dev/mapper/cryptroot || rc=$?
  (( rc <= 1 )) || return 1
  tool resize2fs /dev/mapper/cryptroot
}

if sfdisk --delete "$DISK" 3 \
   && echo ',+' | sfdisk --no-reread -N 2 "$DISK" \
   && { blockdev --rereadpt "$DISK" || true; } \
   && udevadm settle \
   && cryptsetup open --key-file "$KEY" "$ROOT" cryptroot \
   && grow_root; then
  ok "root estesa a tutto il disco"
else
  warn "ridimensionamento non riuscito: il sistema funziona comunque, la root resta di ${ROOT_G} GiB"
fi

log "Installazione completata"
echo "Al primo boot:"
echo "1. Se la MOK non e' enrollata, MokManager parte da solo:"
echo "   Enroll key from disk -> EFI/BOOT/MOK.cer -> Continue -> Yes"
echo "2. Poi inserisci la passphrase LUKS."

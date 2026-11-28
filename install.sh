#!/usr/bin/env bash
# install.sh - installazione pulita da live CD Fedora (UEFI)
#
# Usa una partizione SCRATCH temporanea a fine disco (non la RAM) per lo storage
# di podman. A fine installazione la elimina e la riassorbe nella root.
#
# Serve cosign.pub accanto allo script (oppure COSIGN_PUB=/percorso).
#
# Uso, con la chiavetta contenente MOK.cer (DER) e MOK.crt (PEM) montata:
#   MOK_CER=/run/media/liveuser/USB/MOK.cer \
#   MOK_CRT=/run/media/liveuser/USB/MOK.crt \
#   bash install.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || exec sudo -E bash "$0" "$@"

# ---------------- CONFIGURAZIONE ----------------
DISK="${DISK:-/dev/nvme0n1}"
IMAGE="${IMAGE:-ghcr.io/neret/fedora-bootc-sealed-os:sealed}"
ESP_PARTUUID="${ESP_PARTUUID:-210ebd50-ef82-4686-8cea-81d42a396772}"
SCRATCH_SIZE="${SCRATCH_SIZE:-64G}"
MOK_CER="${MOK_CER:-}"
MOK_CRT="${MOK_CRT:-}"
COSIGN_PUB="${COSIGN_PUB:-$(dirname "$(readlink -f "$0")")/cosign.pub}"
ASSUME_YES="${ASSUME_YES:-0}"

LUKS_NAME="cryptroot"
SCRATCH_MAP="scratchtmp"
MNT="/mnt/target"
SCR="/mnt/scratch"
GPT_BACKUP="/root/gpt-prima-del-grow.bak"
BOOTC_LOG="/root/bootc-install.log"

ESP_TYPE="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
ROOT_TYPE="4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709"

if [[ "$DISK" =~ [0-9]$ ]]; then PFX="${DISK}p"; else PFX="$DISK"; fi
ESP="${PFX}1"
ROOT="${PFX}2"
SCRATCH="${PFX}3"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'ATTENZIONE: %s\n' "$*" >&2; }
die()  { printf '\nERRORE: %s\n' "$*" >&2; exit 1; }

KEYFILE=""
STAGE=""
ROOT_START=""
ROOT_GUID=""

unmount_all() {
  set +e
  mountpoint -q "$MNT/boot/efi" && umount "$MNT/boot/efi"
  mountpoint -q "$MNT/boot" && umount "$MNT/boot"
  mountpoint -q "$MNT" && umount "$MNT"
  cryptsetup status "$LUKS_NAME" >/dev/null 2>&1 && cryptsetup close "$LUKS_NAME"
  mountpoint -q /var/tmp && umount /var/tmp
  mountpoint -q /var/lib/containers && umount /var/lib/containers
  mountpoint -q "$SCR" && umount "$SCR"
  cryptsetup status "$SCRATCH_MAP" >/dev/null 2>&1 && cryptsetup close "$SCRATCH_MAP"
  return 0
}

cleanup() {
  set +e
  unmount_all
  [[ -n "$KEYFILE" ]] && shred -u "$KEYFILE" 2>/dev/null
  [[ -n "$STAGE" ]] && rm -rf "$STAGE"
  return 0
}
trap cleanup EXIT

require_signed() {
  if sbverify --list "$1" 2>&1 | grep -q 'No signature table'; then
    die "non firmato: $1"
  fi
  sbverify --cert "$MOK_CRT" "$1" >/dev/null 2>&1 \
    || die "firma non valida con $MOK_CRT: $1"
}

require_signed_shim() {
  local out
  out="$(LC_ALL=C sbverify --list "$1" 2>&1 || true)"
  grep -q 'image signature issuers' <<<"$out" \
    || die "shim non firmato o firme illeggibili: $1"
}

# ---------------- 1. PREREQUISITI ----------------
log "[1/11] Prerequisiti"
[[ -d /sys/firmware/efi/efivars ]] || die "la live non e' avviata in UEFI"
grep -qw rd.live.image /proc/cmdline || die "eseguire solo da una live Fedora"
dnf install -y --setopt=install_weak_deps=False \
  podman cryptsetup gdisk dosfstools e2fsprogs efibootmgr sbsigntools mokutil util-linux parted openssl skopeo cosign

[[ -r "$MOK_CRT" ]] || die "MOK_CRT obbligatorio e leggibile (certificato PEM con cui sono firmati sd-boot e UKI)"
[[ -r "$MOK_CER" ]] || die "MOK_CER obbligatorio e leggibile (certificato DER da registrare nel firmware)"
fp_crt="$(openssl x509 -in "$MOK_CRT" -noout -fingerprint -sha256)"
fp_cer="$(openssl x509 -inform DER -in "$MOK_CER" -noout -fingerprint -sha256)"
[[ "$fp_crt" == "$fp_cer" ]] || die "MOK_CRT e MOK_CER non sono lo stesso certificato"

# Risolve il digest e verifica la firma PRIMA di toccare il disco.
[[ -r "$COSIGN_PUB" ]] || die "cosign.pub non leggibile: $COSIGN_PUB"
repo="${IMAGE%@*}"
[[ "${repo##*/}" == *:* ]] && repo="${repo%:*}"
if [[ "$IMAGE" == *@* ]]; then
  digest="${IMAGE##*@}"
else
  digest="$(skopeo inspect --format '{{.Digest}}' "docker://$IMAGE")" || die "digest non risolto: $IMAGE"
fi
IMAGE="${repo}@${digest}"
# Verifica la firma legacy (.sig), non i bundle delle attestazioni GitHub.
cosign_args=(--key "$COSIGN_PUB")
cosign_help="$(cosign verify --help 2>&1)"
if grep -q -- '--new-bundle-format' <<<"$cosign_help"; then
  cosign_args+=(--new-bundle-format=false)
fi
cosign verify "${cosign_args[@]}" "$IMAGE" >/dev/null || die "verifica cosign fallita: $IMAGE"

# Controlli sul contenuto dell'immagine prima di toccare il disco. La scratch non
# esiste ancora, quindi serve un tmpfs: solo con abbastanza RAM. L'immagine viene
# poi riscaricata. I controlli successivi restano comunque attivi.
precheck_image() {
  local avail_kb tmp f
  avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
  if (( avail_kb < 20*1024*1024 )) || mountpoint -q /var/lib/containers; then
    warn "controllo preliminare saltato (servono 20 GiB di RAM disponibile)"
    return 0
  fi
  mkdir -p /var/lib/containers
  mount -t tmpfs -o size=16G tmpfs /var/lib/containers
  command -v restorecon >/dev/null 2>&1 && restorecon -R /var/lib/containers 2>/dev/null || true
  podman pull -q "$IMAGE" >/dev/null || die "pull preliminare fallito: disco non toccato"
  tmp="$(mktemp -d /run/precheck.XXXXXX)"
  podman run --rm --security-opt label=disable -v "$tmp":/stage "$IMAGE" sh -ec '
    cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi /stage/sdboot.efi
    cp /boot/EFI/Linux/*.efi /stage/
    cp /etc/fstab /stage/fstab
  ' || die "file di boot mancanti nell'immagine: disco non toccato"
  for f in "$tmp"/*.efi; do require_signed "$f"; done
  grep -qi "PARTUUID=${ESP_PARTUUID}" "$tmp/fstab" \
    || die "ESP_PARTUUID assente nell'fstab dell'immagine: disco non toccato"
  rm -rf "$tmp"
  podman system reset -f >/dev/null 2>&1 || true
  umount /var/lib/containers || die "impossibile smontare il tmpfs del controllo preliminare"
  echo "OK: controllo preliminare superato"
}
precheck_image

# ---------------- 2. CONFERMA E PASSPHRASE ----------------
log "[2/11] Conferma"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL "$DISK"
if [[ "$ASSUME_YES" != 1 ]]; then
  read -rp "Questo CANCELLA tutto su $DISK. Scrivi 'cancella' per continuare: " ans
  [[ "$ans" == "cancella" ]] || die "annullato"
fi

IFS= read -rsp "Nuova passphrase LUKS: " P1; echo
IFS= read -rsp "Ripeti passphrase: " P2; echo
[[ -n "$P1" && "$P1" == "$P2" ]] || die "passphrase vuote o diverse"

KEYFILE="$(mktemp /dev/shm/luks.XXXXXX)"
chmod 600 "$KEYFILE"
printf '%s' "$P1" > "$KEYFILE"
unset P1 P2

# ---------------- 3. PARTIZIONI ----------------
log "[3/11] Partizionamento GPT: ESP + root + scratch temporanea ($SCRATCH_SIZE)"
unmount_all
cryptsetup close "$LUKS_NAME" 2>/dev/null || true

if lsblk -nrpo MOUNTPOINTS "$DISK" | grep -q .; then
  die "partizioni di $DISK ancora montate (e' il disco della live?)"
fi

blkdiscard -f "$DISK" \
  || warn "blkdiscard non riuscito: dati precedenti potrebbero restare sui blocchi"
wipefs -a -f "$DISK"
sgdisk --zap-all "$DISK"

sgdisk -n1:0:+2G -t1:"$ESP_TYPE" -c1:EFI-SYSTEM -u1:"$ESP_PARTUUID" "$DISK"
sgdisk -n3:-"$SCRATCH_SIZE":0 -t3:8300 -c3:scratch "$DISK"
sgdisk -n2:0:0 -t2:"$ROOT_TYPE" -c2:root "$DISK"

partprobe "$DISK" || true
udevadm settle
sleep 1

[[ -b "$ESP" && -b "$ROOT" && -b "$SCRATCH" ]] \
  || die "partizioni non create: $ESP $ROOT $SCRATCH"

ROOT_START="$(sgdisk -i2 "$DISK" | awk '/^First sector:/ {print $3}')"
ROOT_GUID="$(sgdisk -i2 "$DISK" | awk '/^Partition unique GUID:/ {print $4}')"
[[ -n "$ROOT_START" && -n "$ROOT_GUID" ]] \
  || die "impossibile leggere inizio/GUID della root"

(( $(sgdisk -i3 "$DISK" | awk '/^First sector:/ {print $3}') > ROOT_START )) \
  || die "la scratch non e' dopo la root: layout inatteso"

# ---------------- 4. SCRATCH ----------------
log "[4/11] Scratch cifrata e storage di podman"
cryptsetup open --type plain --cipher aes-xts-plain64 --key-size 512 \
  --key-file /dev/urandom --batch-mode "$SCRATCH" "$SCRATCH_MAP"

mkfs.ext4 -F -q -L scratch "/dev/mapper/$SCRATCH_MAP"
mkdir -p "$SCR" /var/lib/containers
mount "/dev/mapper/$SCRATCH_MAP" "$SCR"
mkdir -p "$SCR/containers" "$SCR/runroot" "$SCR/tmp"
chmod 1777 "$SCR/tmp"

mount --bind "$SCR/tmp" /var/tmp
mount --bind "$SCR/containers" /var/lib/containers

command -v restorecon >/dev/null 2>&1 && restorecon -R "$SCR/containers" 2>/dev/null || true
command -v restorecon >/dev/null 2>&1 && restorecon -R /var/tmp 2>/dev/null || true

findmnt -no SOURCE /var/tmp | grep -q 'scratchtmp' \
  || die "/var/tmp dell'host non punta alla scratch"

mkdir -p /etc/containers
cat >/etc/containers/storage.conf <<EOF
[storage]
driver="overlay"
graphroot="/var/lib/containers/storage"
runroot="/run/containers/storage"
EOF

podman system reset -f || true

export TMPDIR="/var/tmp"
export TEMP="/var/tmp"
export TMP="/var/tmp"

log "Verifica configurazione Podman storage:"
groot="$(podman info --format '{{ .Store.GraphRoot }}')"
rroot="$(podman info --format '{{ .Store.RunRoot }}')"
echo "GraphRoot = $groot"
echo "RunRoot   = $rroot"

[[ "$groot" == "/var/lib/containers/storage" ]] \
  || die "GraphRoot errato: $groot (atteso /var/lib/containers/storage)"

findmnt -no SOURCE /var/lib/containers | grep -q '/dev/mapper/scratchtmp' \
  || die "/var/lib/containers non punta alla scratch (/dev/mapper/scratchtmp)"
df -h /var/lib/containers

avail_kb="$(df --output=avail -k "$SCR" | tail -n1)"
(( avail_kb > 12*1024*1024 )) || die "scratch troppo piccola: aumenta SCRATCH_SIZE"

echo "Spazio disponibile sulla scratch:"
df -h "$SCR"

# ---------------- 5. IMMAGINE E FILE DI BOOT ----------------
log "[5/11] Immagine e file di boot ($IMAGE)"
podman pull "$IMAGE" || die "pull fallito (se l'immagine e' privata: podman login ghcr.io)"

STAGE="$(mktemp -d /run/esp-stage.XXXXXX)"
podman run --rm --security-opt label=disable -v "$STAGE":/stage "$IMAGE" sh -c '
  set -e
  shim=$(ls -d /usr/lib/efi/shim/*/EFI | sort -V | tail -n1)
  cp "$shim/BOOT/BOOTX64.EFI"   /stage/BOOTX64.EFI
  cp "$shim/fedora/mmx64.efi"   /stage/mmx64.efi
  cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi /stage/systemd-bootx64.efi
'

for f in BOOTX64.EFI mmx64.efi systemd-bootx64.efi; do
  [[ -s "$STAGE/$f" ]] || die "manca nell'immagine: $f"
done

require_signed "$STAGE/systemd-bootx64.efi"
require_signed_shim "$STAGE/BOOTX64.EFI"

image_fstab="$(podman run --rm --security-opt label=disable "$IMAGE" cat /etc/fstab)"
grep -qi "PARTUUID=${ESP_PARTUUID}" <<<"$image_fstab" \
  || die "ESP_PARTUUID ($ESP_PARTUUID) assente nell'fstab dell'immagine: /efi non si monterebbe"

# ---------------- 6. FILESYSTEM ----------------
log "[6/11] ESP, LUKS2 e root ext4 (fs-verity)"
mkfs.fat -F32 -n ESP "$ESP"

cryptsetup luksFormat --batch-mode --type luks2 \
  --cipher aes-xts-plain64 --key-size 512 --hash sha512 --pbkdf argon2id \
  --sector-size 4096 \
  --key-file "$KEYFILE" "$ROOT"

# --persistent salva le opzioni di performance nell'header LUKS.
# Niente --allow-discards: il TRIM sul volume cifrato rivela i pattern d'uso.
cryptsetup open --key-file "$KEYFILE" \
  --perf-no_read_workqueue --perf-no_write_workqueue --persistent \
  "$ROOT" "$LUKS_NAME"
mkfs.ext4 -F -m 1 -L root -O verity "/dev/mapper/$LUKS_NAME"

# ---------------- 7. BOOTC ----------------
log "[7/11] Installazione bootc (composefs, UKI)"
mkdir -p "$MNT"
mount "/dev/mapper/$LUKS_NAME" "$MNT"

mkdir -p "$MNT/boot/efi"
mount -o fmask=0077,dmask=0077 "$ESP" "$MNT/boot/efi"

set +e
podman run --rm --privileged --pid=host --security-opt label=disable \
  -v /dev:/dev \
  -v /var/lib/containers:/var/lib/containers \
  -v "$SCR":/scratch \
  -v /var/tmp:/var/tmp \
  -e TMPDIR=/var/tmp \
  -e TEMP=/var/tmp \
  -e TMP=/var/tmp \
  -e CONTAINER_TMPDIR=/var/tmp \
  -v "$MNT":/target \
  "$IMAGE" \
  bash -ec '
    set -euo pipefail
    export TMPDIR=/var/tmp
    export TEMP=/var/tmp
    export TMP=/var/tmp
    export CONTAINER_TMPDIR=/var/tmp


    bootc install to-filesystem \
      --composefs-backend \
      --target-imgref ghcr.io/neret/fedora-bootc-sealed-os:sealed \
      --bootloader systemd \
      --root-mount-spec="" \
      --skip-finalize \
      /target
  ' 2>&1 | tee "$BOOTC_LOG"

rc=${PIPESTATUS[0]}
set -e
(( rc == 0 )) || die "bootc install fallito (vedi $BOOTC_LOG)"

mount -o remount,ro "$MNT"

# ---------------- 8. CATENA SHIM -> SD-BOOT -> UKI ----------------
log "[8/11] Catena di boot sull'ESP"
E="$MNT/boot/efi/EFI"

install -d "$E/BOOT" "$E/systemd"

install -m 0755 "$STAGE/BOOTX64.EFI"         "$E/BOOT/BOOTX64.EFI"
install -m 0755 "$STAGE/mmx64.efi"           "$E/BOOT/mmx64.efi"
install -m 0755 "$STAGE/systemd-bootx64.efi" "$E/BOOT/grubx64.efi"
install -m 0755 "$STAGE/systemd-bootx64.efi" "$E/systemd/systemd-bootx64.efi"

rm -f "$E/BOOT/fbx64.efi" "$E/BOOT/BOOTX64.CSV"

install -m 0644 "$MOK_CER" "$E/BOOT/MOK.cer"
sync

# ---------------- 9. VERIFICHE ----------------
log "[9/11] Verifiche (se falliscono NON riavviare)"
for f in BOOT/BOOTX64.EFI BOOT/mmx64.efi BOOT/grubx64.efi systemd/systemd-bootx64.efi; do
  [[ -s "$E/$f" ]] || die "manca sull'ESP: EFI/$f"
done

cmp -s "$E/BOOT/grubx64.efi" "$STAGE/systemd-bootx64.efi" \
  || die "grubx64.efi diverso dall'immagine"

require_signed "$E/BOOT/grubx64.efi"

mapfile -t UKIS < <(find "$E/Linux" -type f -name '*.efi' 2>/dev/null)

if (( ${#UKIS[@]} == 0 )); then
  warn "nessuna UKI sull'ESP. Diagnostica:"
  echo "--- ESP:"
  find "$MNT/boot/efi" -maxdepth 5 2>/dev/null | head -60

  mkdir -p /mnt/rootview
  mount --bind "$MNT" /mnt/rootview
  echo "--- /boot nella root:"
  find /mnt/rootview/boot -maxdepth 5 2>/dev/null | head -60
  umount /mnt/rootview

  echo "--- ultime righe di bootc:"
  tail -n 40 "$BOOTC_LOG"

  die "nessuna UKI in EFI/Linux"
fi

for u in "${UKIS[@]}"; do
  require_signed "$u"
done

[[ -d "$MNT/composefs" || -d "$MNT/ostree" ]] \
  || die "repository composefs/ostree assente nella root"

printf 'OK: shim, sd-boot e %d UKI firmati\n' "${#UKIS[@]}"

# ---------------- 10. UEFI E MOK ----------------
log "[10/11] Voce UEFI e chiave MOK"

while read -r num; do
  [[ -n "$num" ]] && efibootmgr -b "$num" -B >/dev/null || true
done < <(efibootmgr | sed -nE 's/^Boot([0-9A-Fa-f]{4})\*? +(Sealed OS|Linux Boot Manager|Fallback Linux Boot Manager|Fedora)([[:space:]].*)?$/\1/p')

efibootmgr -c -d "$DISK" -p 1 -L "Sealed OS" -l '\EFI\BOOT\BOOTX64.EFI' >/dev/null

NEW_ENTRY="$(efibootmgr | sed -nE 's/^Boot([0-9A-Fa-f]{4})\*? +Sealed OS([[:space:]].*)?$/\1/p' | head -n1)"
[[ -n "$NEW_ENTRY" ]] || die "voce 'Sealed OS' non creata"

CUR_ORDER="$(efibootmgr | sed -n 's/^BootOrder: //p')"
REST="$(printf '%s' "$CUR_ORDER" | tr ',' '\n' | awk -v n="${NEW_ENTRY^^}" 'toupper($0) != n' | paste -sd, -)"
efibootmgr -o "${NEW_ENTRY}${REST:+,${REST}}" >/dev/null

first="$(efibootmgr | sed -n 's/^BootOrder: \([^,]*\).*/\1/p')"
[[ "${first^^}" == "${NEW_ENTRY^^}" ]] \
  || die "BootOrder non impostato: prima c'e' Boot${first}, non Boot${NEW_ENTRY}"

if mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
  if [[ -n "$MOK_CER" ]]; then
    if mokutil --test-key "$MOK_CER" 2>&1 | grep -qi 'already enrolled'; then
      echo "MOK gia' registrata nel firmware."
    elif ! mokutil --import "$MOK_CER"; then
      warn "import MOK non riuscito: al primo avvio usa MokManager -> Enroll key from disk -> EFI/BOOT/MOK.cer"
    fi
  else
    warn "MOK_CER non indicato: se la chiave non e' registrata, shim aprira' MokManager."
  fi
else
  warn "Secure Boot disattivato o stato non leggibile: MOK NON importata."
  warn "Prima di riattivarlo registra la chiave: sudo mokutil --import $MOK_CER"
fi

# ---------------- 11. SCRATCH -> ROOT ----------------
log "[11/11] Elimino la scratch e riassorbo lo spazio nella root"
sync
unmount_all

grow_root() {
  local start_now guid_now rc=0

  sgdisk --backup="$GPT_BACKUP" "$DISK" >/dev/null || return 1

  sgdisk -d3 -d2 \
    -n2:"${ROOT_START}":0 \
    -t2:"$ROOT_TYPE" \
    -c2:root \
    -u2:"$ROOT_GUID" \
    "$DISK" >/dev/null || return 1

  start_now="$(sgdisk -i2 "$DISK" | awk '/^First sector:/ {print $3}')"
  guid_now="$(sgdisk -i2 "$DISK" | awk '/^Partition unique GUID:/ {print $4}')"

  if [[ "$start_now" != "$ROOT_START" || "${guid_now^^}" != "${ROOT_GUID^^}" ]]; then
    sgdisk --load-backup="$GPT_BACKUP" "$DISK" >/dev/null
    echo "la root e' cambiata: ripristinata la tabella originale" >&2
    return 1
  fi

  partprobe "$DISK" || true
  udevadm settle

  # Se il kernel usa ancora la vecchia tabella, il resize non allarga nulla.
  if [[ -b "$SCRATCH" ]]; then
    echo "tabella gia' aggiornata ma non riletta: dopo il riavvio esegui cryptsetup resize e resize2fs" >&2
    return 1
  fi

  cryptsetup open --key-file "$KEYFILE" "$ROOT" "$LUKS_NAME" || return 1
  cryptsetup resize --key-file "$KEYFILE" "$LUKS_NAME" || return 1

  e2fsck -f -y "/dev/mapper/$LUKS_NAME" || rc=$?
  (( rc <= 1 )) || return 1

  resize2fs "/dev/mapper/$LUKS_NAME" || return 1
  cryptsetup close "$LUKS_NAME" || return 1
}

if grow_root; then
  echo "Root allargata: scratch riassorbita."
else
  cryptsetup close "$LUKS_NAME" 2>/dev/null || true
  warn "allargamento non completato. L'installazione e' valida e avviabile."
  warn "Per riassorbire lo spazio dopo il primo avvio: elimina la partizione 3, estendi la 2,"
  warn "poi: cryptsetup resize <mapper> && resize2fs <mapper>"
  warn "Tabella GPT di backup: $GPT_BACKUP"
  warn "Per i comandi manuali serve la passphrase LUKS: il keyfile temporaneo viene rimosso a fine script."
fi

sync

echo
echo "=================================================="
echo " INSTALLAZIONE COMPLETATA E VERIFICATA"
echo " Immagine: $IMAGE"
echo " ESP:      $ESP (PARTUUID $ESP_PARTUUID)"
echo " Voce:     Boot${first} 'Sealed OS'"
echo
echo " Controlla con: sudo bootc status (deve mostrare :sealed; se vedi un tag con timestamp: sudo bootc switch ghcr.io/neret/fedora-bootc-sealed-os:sealed)"
echo " Primo avvio: passphrase LUKS."
echo " Se compare MokManager: 'Enroll key from disk' -> EFI/BOOT/MOK.cer"
echo " Dopo il primo avvio (con la MOK gia' registrata) registra il TPM con PIN:"
echo "   sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7+12 --tpm2-with-pin=yes $ROOT"
echo "=================================================="

lsblk -f "$DISK"
efibootmgr

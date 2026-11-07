#!/usr/bin/env bash
set -uo pipefail

# Pacchetti necessari sull'host:
# lsblk blkid cryptsetup podman oppure docker file find util-linux

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; WARNS=$((WARNS+1)); }
err()  {
  printf '\033[1;31m[ERR]\033[0m %s\n' "$*"
  FAIL=$((FAIL+1))
  FAILED+=("$*")
}

ask() {
  local prompt="$1" default="$2" value
  read -rp "$prompt [$default]: " value
  printf '%s' "${value:-$default}"
}

M=/run/sealed-check
TOOLS=sealed-tools
TOOLS_BASE=quay.io/fedora/fedora:45
FAIL=0
WARNS=0
FAILED=()
ROOT_MNT=""
ESP_MNT=""
ROOT_OPENED=0
ESP_MOUNTED=0

cleanup() {
  if [[ -n "$ESP_MNT" && "$ESP_MOUNTED" == 1 ]]; then
    umount "$ESP_MNT" 2>/dev/null || true
  fi

  if [[ -n "$ROOT_MNT" && "$ROOT_OPENED" == 1 ]]; then
    umount "$ROOT_MNT" 2>/dev/null || true
    cryptsetup close cryptcheck 2>/dev/null || true
  fi
}

trap cleanup EXIT INT TERM

[[ $EUID -eq 0 ]] || { err "Esegui come root (sudo)."; exit 1; }
[[ "$(uname -m)" == "x86_64" ]] || { err "Supportato solo UEFI x86_64."; exit 1; }

if command -v podman >/dev/null 2>&1; then
  RUNTIME=podman
elif command -v docker >/dev/null 2>&1; then
  RUNTIME=docker
else
  err "Comando mancante: podman oppure docker"
  exit 1
fi

DISK="$(ask 'Disco da verificare' '/dev/nvme0n1')"
MOK_CERT="$(ask 'Certificato MOK DER' './MOK.cer')"

ESP="${DISK}p1"
ROOT="${DISK}p2"

[[ -b "$DISK" ]] || { err "Disco non trovato: $DISK"; exit 1; }
[[ -f "$MOK_CERT" ]] || { err "MOK.cer non trovato: $MOK_CERT"; exit 1; }

if ! "$RUNTIME" image inspect "$TOOLS" >/dev/null 2>&1; then
  log "Container strumenti '$TOOLS' non trovato: lo creo"
  BUILD_DIR="$(mktemp -d)"
  cat > "$BUILD_DIR/Containerfile" <<EOF
FROM ${TOOLS_BASE}
RUN dnf install -y dosfstools btrfs-progs sbsigntools openssl shim-x64 \
    && dnf clean all
EOF
  "$RUNTIME" build -q -t "$TOOLS" "$BUILD_DIR" >/dev/null
  rm -rf "$BUILD_DIR"
  ok "container strumenti pronto"
else
  ok "container strumenti trovato: $TOOLS"
fi

get_part_type() {
  local dev="$1" value

  value="$(blkid -p -s PART_ENTRY_TYPE -o value "$dev" 2>/dev/null || true)"

  if [[ -z "$value" ]]; then
    value="$(lsblk -no PARTTYPE "$dev" 2>/dev/null || true)"
  fi

  printf '%s' "${value,,}"
}

get_fs_type() {
  local dev="$1" value

  value="$(blkid -p -s TYPE -o value "$dev" 2>/dev/null || true)"

  if [[ -z "$value" ]]; then
    value="$(lsblk -no FSTYPE "$dev" 2>/dev/null || true)"
  fi

  printf '%s' "${value,,}"
}

find_luks_mapping() {
  local part="$1"
  local dir name slave

  for dir in /sys/block/dm-*; do
    [[ -d "$dir" ]] || continue
    name="$(cat "$dir/dm/name" 2>/dev/null || true)"
    [[ -n "$name" ]] || continue

    for slave in "$dir"/slaves/*; do
      [[ -e "$slave" ]] || continue
      if [[ "$(basename "$slave")" == "$(basename "$part")" ]]; then
        printf '%s' "$name"
        return 0
      fi
    done
  done

  return 1
}

find_mount_by_device() {
  local dev="$1"
  local target source

  dev="$(readlink -f "$dev" 2>/dev/null || true)"
  [[ -n "$dev" ]] || return 1

  while read -r target source; do
    [[ -n "$target" && -n "$source" ]] || continue
    source="$(readlink -f "$source" 2>/dev/null || true)"

    if [[ "$source" == "$dev" ]]; then
      printf '%s' "$target"
      return 0
    fi
  done < <(findmnt -rn -o TARGET,SOURCE 2>/dev/null)

  return 1
}

log "1. Tabella delle partizioni"
lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,PARTLABEL "$DISK"

ESP_TYPE="$(get_part_type "$ESP")"
ROOT_TYPE="$(get_part_type "$ROOT")"
ESP_FS="$(get_fs_type "$ESP")"

[[ "$ESP_FS" == "vfat" ]] && ok "p1 e' vfat" || err "p1 non e' vfat"
[[ "$ESP_TYPE" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] \
  && ok "p1 ha tipo EFI System" || err "p1 non ha tipo EFI System"

if cryptsetup isLuks "$ROOT" 2>/dev/null; then
  ok "p2 e' LUKS"
else
  err "p2 non e' LUKS"
fi

[[ "$ROOT_TYPE" == "4f68bce3-e8cd-4db1-96e7-fbcaf984b709" ]] \
  && ok "p2 ha tipo 'Linux root x86-64' (sblocco LUKS automatico)" \
  || err "p2 senza tipo 'Linux root x86-64': l'initrd non trovera' la root"

if [[ -b "${DISK}p3" ]]; then
  warn "scratch (p3) ancora presente: lo spazio non e' stato restituito alla root (il sistema funziona comunque)"
else
  ok "scratch rimossa, root estesa"
fi

log "2. LUKS"
cryptsetup isLuks "$ROOT" && ok "intestazione LUKS valida" || err "intestazione LUKS non valida"
cryptsetup luksDump "$ROOT" 2>/dev/null | grep -E '^Version|PBKDF:' | head -n 3 | sed 's/^/    /'

ROOT_MAPPING="$(find_luks_mapping "$ROOT" || true)"

if [[ -n "$ROOT_MAPPING" ]]; then
  ROOT_MNT="$(find_mount_by_device "/dev/mapper/$ROOT_MAPPING" || true)"
fi

if [[ -n "$ROOT_MNT" ]]; then
  ok "root LUKS gia' aperta e montata: $ROOT_MNT"
  ok "uso il mount esistente senza chiuderlo"
else
  if [[ -n "$ROOT_MAPPING" ]]; then
    log "root LUKS aperta ma non montata: chiudo il mapping '$ROOT_MAPPING'"
    cryptsetup close "$ROOT_MAPPING" 2>/dev/null || true
  fi

  echo "Apro la root in sola lettura (serve la passphrase LUKS):"
  if cryptsetup open --readonly "$ROOT" cryptcheck; then
    ROOT_OPENED=1
    ok "passphrase corretta, LUKS aperto"
  else
    err "impossibile aprire LUKS: passphrase errata o dispositivo occupato"
    exit 1
  fi

  mkdir -p "$M/root"
  mount -o ro /dev/mapper/cryptcheck "$M/root" \
    && ROOT_MNT="$M/root" \
    || { err "mount root fallito"; exit 1; }
fi

ESP_MNT="$(find_mount_by_device "$ESP" || true)"

if [[ -n "$ESP_MNT" ]]; then
  ok "ESP gia' montata: $ESP_MNT"
else
  mkdir -p "$M/esp"
  mount -o ro "$ESP" "$M/esp" \
    && ESP_MNT="$M/esp" \
    && ESP_MOUNTED=1 \
    || { err "mount ESP fallito"; exit 1; }
fi

df -h "$ROOT_MNT" "$ESP_MNT" | sed 's/^/    /'

log "3. File nella ESP"
for f in EFI/BOOT/BOOTX64.EFI EFI/BOOT/grubx64.efi EFI/BOOT/mmx64.efi EFI/BOOT/MOK.cer \
         EFI/systemd/systemd-bootx64.efi; do
  [[ -f "$ESP_MNT/$f" ]] && ok "presente: $f" || err "manca: $f"
done

mapfile -t UKIS < <(find "$ESP_MNT/EFI/Linux" -type f -name '*.efi' 2>/dev/null | sort)
if (( ${#UKIS[@]} > 0 )); then
  ok "UKI trovate: ${#UKIS[@]}"
  for u in "${UKIS[@]}"; do echo "    ${u#$ESP_MNT/}  ($(du -h "$u" | cut -f1))"; done
  UKI="${UKIS[0]}"
else
  err "nessuna UKI in EFI/Linux"
  UKI=""
fi

cmp -s "$ESP_MNT/EFI/systemd/systemd-bootx64.efi" "$ESP_MNT/EFI/BOOT/grubx64.efi" \
  && ok "grubx64.efi == systemd-bootx64.efi" || err "grubx64.efi diverso da systemd-bootx64.efi"

if file -b "$MOK_CERT" | grep -qi PEM; then
  err "il MOK.cer fornito e' PEM (serve DER)"
else
  ok "MOK.cer in formato DER"
fi
cmp -s "$MOK_CERT" "$ESP_MNT/EFI/BOOT/MOK.cer" \
  && ok "MOK.cer sulla ESP == quello fornito" || err "MOK.cer sulla ESP diverso da quello fornito"

log "4. Firme (verificate nel container strumenti)"
verify_mok() {
  local rel="$1"
  if "$RUNTIME" run --rm --security-opt label=disable \
       -v "$ESP_MNT":/esp:ro -v "$(readlink -f "$MOK_CERT")":/mok.cer:ro "$TOOLS" sh -c '
         openssl x509 -inform DER -in /mok.cer -out /tmp/mok.pem &&
         sbverify --cert /tmp/mok.pem "/esp/$1"' _ "$rel" >/dev/null 2>&1; then
    ok "firmato con la tua MOK: $rel"
  else
    err "NON firmato con la tua MOK: $rel"
  fi
}
verify_mok EFI/systemd/systemd-bootx64.efi
verify_mok EFI/BOOT/grubx64.efi
[[ -n "$UKI" ]] && verify_mok "${UKI#$ESP_MNT/}"

out="$("$RUNTIME" run --rm --security-opt label=disable -v "$ESP_MNT":/esp:ro "$TOOLS" \
      sbverify --list /esp/EFI/BOOT/BOOTX64.EFI 2>&1)"
grep -qi 'Microsoft' <<<"$out" && ok "shim firmato Microsoft" || err "shim: firma Microsoft non trovata"
out="$("$RUNTIME" run --rm --security-opt label=disable -v "$ESP_MNT":/esp:ro "$TOOLS" \
      sbverify --list /esp/EFI/BOOT/mmx64.efi 2>&1)"
grep -q 'image signature' <<<"$out" && ok "MokManager firmato (chiave vendor)" || err "MokManager non firmato"

log "5. Command line della UKI"
DIG=""
if [[ -n "$UKI" ]]; then
  DIG="$(grep -aoE 'composefs=[0-9a-f]+' "$UKI" | head -n1 | cut -d= -f2 || true)"
  [[ -n "$DIG" ]] && ok "composefs=${DIG:0:16}... presente" || err "composefs= assente nella UKI"
  grep -aqE 'composefs\.digest=v1-sha512-12:[0-9a-f]+' "$UKI" \
    && ok "composefs.digest=v1-... presente" || warn "composefs.digest=v1-... assente"
  grep -aq 'rd.luks.options=tpm2-device=auto' "$UKI" \
    && ok "rd.luks.options=tpm2-device=auto presente" || warn "rd.luks.options assente"
  grep -aq 'root=' "$UKI" \
    && warn "la UKI contiene root=: con root autodiscovery di solito non serve" \
    || ok "nessun root= (autodiscovery dal tipo di partizione)"
fi

log "6. Contenuto della root"
ls -A "$ROOT_MNT" | sed 's/^/    /'
[[ -n "$(ls -A "$ROOT_MNT")" ]] && ok "la root contiene dati" || err "la root e' vuota"
if [[ -n "$DIG" ]]; then
  hit="$(find "$ROOT_MNT" -maxdepth 5 -name "*${DIG}*" 2>/dev/null | head -n 3)"
  if [[ -n "$hit" ]]; then
    ok "il digest della UKI corrisponde a un deployment installato:"
    sed "s|$ROOT_MNT|    <root>|" <<<"$hit"
  else
    warn "non trovo il digest della UKI tra i deployment (controlla a mano sotto)"
    find "$ROOT_MNT" -maxdepth 3 \( -path '*/state/*' -o -path '*/composefs/*' \) 2>/dev/null | head -n 12 | sed 's/^/    /'
  fi
fi

log "7. Firmware (stato di QUESTO avvio)"
if [[ -d /sys/firmware/efi ]]; then
  ok "avviato in modalita' UEFI"
  SB="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  if [[ -r "$SB" ]]; then
    case "$(tail -c1 "$SB" | od -An -t u1 | tr -d ' ')" in
      1) ok "Secure Boot attivo adesso" ;;
      0) warn "Secure Boot DISATTIVO adesso: nel BIOS attivalo prima di avviare il nuovo sistema" ;;
    esac
  fi
else
  err "avvio non UEFI"
fi

log "Riepilogo"
echo "Runtime:    $RUNTIME"
echo "Root mount: $ROOT_MNT"
echo "ESP mount:  $ESP_MNT"
echo "Errori: $FAIL   Avvisi: $WARNS"

if (( ${#FAILED[@]} > 0 )); then
  log "Controlli falliti"
  for i in "${!FAILED[@]}"; do
    echo "  $((i+1)). ${FAILED[$i]}"
  done
fi

if (( FAIL == 0 )); then
  ok "Tutto a posto: puoi riavviare."
  echo "Nel BIOS: Secure Boot attivo e 'Allow Microsoft 3rd Party UEFI CA' abilitato."
  echo "Al primo boot: MokManager -> Enroll key from disk -> EFI/BOOT/MOK.cer -> Continue -> Yes."
else
  err "Ci sono errori: NON riavviare finche' non sono risolti."
  exit 1
fi

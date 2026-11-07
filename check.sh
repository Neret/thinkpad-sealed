#!/usr/bin/env bash
set -uo pipefail

# Pacchetti necessari sull'host:
# lsblk cryptsetup podman oppure docker file find util-linux

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; WARNS=$((WARNS+1)); }
err()  { printf '\033[1;31m[ERR]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

ask() {
  local prompt="$1" default="$2" value
  read -rp "$prompt [$default]: " value
  printf '%s' "${value:-$default}"
}

cleanup() {
  umount "$M/esp"  2>/dev/null || true
  umount "$M/root" 2>/dev/null || true
  cryptsetup close cryptcheck 2>/dev/null || true
}
trap cleanup EXIT

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
TOOLS="$(ask 'Container strumenti' 'sealed-tools')"

ESP="${DISK}p1"
ROOT="${DISK}p2"
M=/run/sealed-check
FAIL=0
WARNS=0

[[ -f "$MOK_CERT" ]] || { err "MOK.cer non trovato: $MOK_CERT"; exit 1; }
"$RUNTIME" image inspect "$TOOLS" >/dev/null 2>&1 \
  || { err "Container '$TOOLS' mancante: rilancia prima installer.sh"; exit 1; }

umount -R /mnt 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true

log "1. Tabella delle partizioni"
lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,PARTLABEL "$DISK"

[[ "$(lsblk -no FSTYPE "$ESP" 2>/dev/null)" == "vfat" ]] && ok "p1 e' vfat" || err "p1 non e' vfat"
[[ "$(lsblk -no PARTTYPE "$ESP" 2>/dev/null)" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] \
  && ok "p1 ha tipo EFI System" || err "p1 non ha tipo EFI System"
[[ "$(lsblk -no FSTYPE "$ROOT" 2>/dev/null)" == "crypto_LUKS" ]] && ok "p2 e' LUKS" || err "p2 non e' LUKS"
[[ "$(lsblk -no PARTTYPE "$ROOT" 2>/dev/null)" == "4f68bce3-e8cd-4db1-96e7-fbcaf984b709" ]] \
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

echo "Apro la root in sola lettura (serve la passphrase LUKS):"
if cryptsetup open --readonly "$ROOT" cryptcheck; then
  ok "passphrase corretta, LUKS aperto"
else
  err "impossibile aprire LUKS: passphrase errata?"
  exit 1
fi

mkdir -p "$M/esp" "$M/root"
mount -o ro /dev/mapper/cryptcheck "$M/root" && ok "root btrfs montata (ro)" || err "mount root fallito"
mount -o ro "$ESP" "$M/esp"                  && ok "ESP montata (ro)"        || err "mount ESP fallito"
df -h "$M/root" "$M/esp" | sed 's/^/    /'

log "3. File nella ESP"
for f in EFI/BOOT/BOOTX64.EFI EFI/BOOT/grubx64.efi EFI/BOOT/mmx64.efi EFI/BOOT/MOK.cer \
         EFI/systemd/systemd-bootx64.efi; do
  [[ -f "$M/esp/$f" ]] && ok "presente: $f" || err "manca: $f"
done

mapfile -t UKIS < <(find "$M/esp/EFI/Linux" -type f -name '*.efi' 2>/dev/null | sort)
if (( ${#UKIS[@]} > 0 )); then
  ok "UKI trovate: ${#UKIS[@]}"
  for u in "${UKIS[@]}"; do echo "    ${u#$M/esp/}  ($(du -h "$u" | cut -f1))"; done
  UKI="${UKIS[0]}"
else
  err "nessuna UKI in EFI/Linux"
  UKI=""
fi

cmp -s "$M/esp/EFI/systemd/systemd-bootx64.efi" "$M/esp/EFI/BOOT/grubx64.efi" \
  && ok "grubx64.efi == systemd-bootx64.efi" || err "grubx64.efi diverso da systemd-bootx64.efi"

if file -b "$MOK_CERT" | grep -qi PEM; then
  err "il MOK.cer fornito e' PEM (serve DER)"
else
  ok "MOK.cer in formato DER"
fi
cmp -s "$MOK_CERT" "$M/esp/EFI/BOOT/MOK.cer" \
  && ok "MOK.cer sulla ESP == quello fornito" || err "MOK.cer sulla ESP diverso da quello fornito"

log "4. Firme (verificate nel container strumenti)"
verify_mok() {
  local rel="$1"
  if "$RUNTIME" run --rm --security-opt label=disable \
       -v "$M/esp":/esp:ro -v "$(readlink -f "$MOK_CERT")":/mok.cer:ro "$TOOLS" sh -c '
         openssl x509 -inform DER -in /mok.cer -out /tmp/mok.pem &&
         sbverify --cert /tmp/mok.pem "/esp/$1"' _ "$rel" >/dev/null 2>&1; then
    ok "firmato con la tua MOK: $rel"
  else
    err "NON firmato con la tua MOK: $rel"
  fi
}
verify_mok EFI/systemd/systemd-bootx64.efi
verify_mok EFI/BOOT/grubx64.efi
[[ -n "$UKI" ]] && verify_mok "${UKI#$M/esp/}"

out="$("$RUNTIME" run --rm --security-opt label=disable -v "$M/esp":/esp:ro "$TOOLS" \
      sbverify --list /esp/EFI/BOOT/BOOTX64.EFI 2>&1)"
grep -qi 'Microsoft' <<<"$out" && ok "shim firmato Microsoft" || err "shim: firma Microsoft non trovata"
out="$("$RUNTIME" run --rm --security-opt label=disable -v "$M/esp":/esp:ro "$TOOLS" \
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
ls -A "$M/root" | sed 's/^/    /'
[[ -n "$(ls -A "$M/root")" ]] && ok "la root contiene dati" || err "la root e' vuota"
if [[ -n "$DIG" ]]; then
  hit="$(find "$M/root" -maxdepth 5 -name "*${DIG}*" 2>/dev/null | head -n 3)"
  if [[ -n "$hit" ]]; then
    ok "il digest della UKI corrisponde a un deployment installato:"
    sed "s|$M/root|    <root>|" <<<"$hit"
  else
    warn "non trovo il digest della UKI tra i deployment (controlla a mano sotto)"
    find "$M/root" -maxdepth 3 \( -path '*/state/*' -o -path '*/composefs/*' \) 2>/dev/null | head -n 12 | sed 's/^/    /'
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
echo "Errori: $FAIL   Avvisi: $WARNS"
if (( FAIL == 0 )); then
  ok "Tutto a posto: puoi riavviare."
  echo "Nel BIOS: Secure Boot attivo e 'Allow Microsoft 3rd Party UEFI CA' abilitato."
  echo "Al primo boot: MokManager -> Enroll key from disk -> EFI/BOOT/MOK.cer -> Continue -> Yes."
else
  err "Ci sono errori: NON riavviare finche' non sono risolti."
  exit 1
fi

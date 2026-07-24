#!/usr/bin/env bash
# Shared helpers for build-template.sh and deploy-vm.sh

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH. Install it first."
}

# gzip + base64 encode a file to a single line (the encoding vSphere guestinfo wants).
gzb64() { gzip -c "$1" | base64 | tr -d '\n'; }

# Return a VM's power state string (poweredOn / poweredOff / suspended).
vm_power_state() {
  govc vm.info "$1" 2>/dev/null | awk -F': +' '/Power state/{print $2; exit}'
}

# make_iso SRC_DIR OUT_ISO VOLUME_LABEL — build a plain ISO9660+Joliet image from
# a directory, with whichever tool the host has (Linux: xorriso/genisoimage/
# mkisofs; macOS: hdiutil).
make_iso() {
  local src="$1" out="$2" label="$3"
  rm -f "$out"
  if command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs -J -R -V "$label" -o "$out" "$src" >/dev/null 2>&1
  elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage -J -R -V "$label" -o "$out" "$src" >/dev/null 2>&1
  elif command -v mkisofs >/dev/null 2>&1; then
    mkisofs -J -R -V "$label" -o "$out" "$src" >/dev/null 2>&1
  elif command -v hdiutil >/dev/null 2>&1; then
    hdiutil makehybrid -iso -joliet -default-volume-name "$label" -o "$out" "$src" >/dev/null
    [ -f "$out" ] || mv "${out}.cdr" "$out"   # hdiutil sometimes appends .cdr
  else
    die "No ISO tool found (need xorriso, genisoimage, mkisofs, or hdiutil)."
  fi
  [ -f "$out" ] || die "ISO build failed ($out)"
}

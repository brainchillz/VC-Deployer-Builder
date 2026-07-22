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

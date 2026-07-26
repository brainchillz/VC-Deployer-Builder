#!/usr/bin/env bash
#
# build-template.sh [PROFILE] — Build a reusable template for the given OS
# profile (default: ubuntu-2604). Profiles live in profiles/<name>.env.
#
# Works against vCenter OR a standalone ESXi host (auto-detected): on vCenter
# the finished VM is converted to a template object; on ESXi (which has no
# template type) it is left as a powered-off VM and stamped role=template.
#
#   ./build-template.sh ubuntu-2604
#   ./build-template.sh ubuntu-2404
#   ./build-template.sh rocky-10
#
# OVA profiles are imported directly. qcow2 profiles (Rocky) are converted to a
# streamOptimized VMDK with qemu-img, uploaded, and wrapped in a VM shell; their
# first-boot prep is delivered via a NoCloud seed ISO (because the stock image
# has no open-vm-tools yet, so guestinfo can't be read until we install it).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# BUILDER_CONFIG overrides which config file is sourced — handy when the same
# builder targets both a vCenter and a standalone ESXi host.
CONFIG_FILE="${BUILDER_CONFIG:-$SCRIPT_DIR/config.env}"
[ -f "$CONFIG_FILE" ] || die "$CONFIG_FILE not found. Run: cp config.env.example config.env  (then edit it)"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

PROFILE="${1:-${DEFAULT_PROFILE:-ubuntu-2604}}"
PROFILE_FILE="$SCRIPT_DIR/profiles/${PROFILE}.env"
[ -f "$PROFILE_FILE" ] || die "Unknown profile '$PROFILE'. Available: $(cd "$SCRIPT_DIR/profiles" && ls *.env | sed 's/.env//' | tr '\n' ' ')"
# shellcheck source=/dev/null
source "$PROFILE_FILE"

require govc; require gzip; require base64; require curl

: "${TEMPLATE_CPUS:=2}"
: "${TEMPLATE_MEMORY_MB:=2048}"
: "${TEMPLATE_DISK_GB:=}"
# IMAGE_FILE overrides the local filename (needed when IMAGE_URL is a redirect
# link with no usable basename, e.g. Microsoft fwlink).
IMAGE_PATH="$SCRIPT_DIR/${IMAGE_FILE:-$(basename "$IMAGE_URL")}"

log "Profile '$PROFILE' -> template '$TEMPLATE_NAME' (format: $IMAGE_FORMAT)"
log "Checking vSphere connectivity"
govc about >/dev/null || die "Cannot reach vCenter/ESXi. Check GOVC_URL / credentials in config.env."
# "VirtualCenter" or "HostAgent" (standalone ESXi) — decides the templatize step.
API_TYPE="$(govc about | awk -F': *' '/^API type/{print $2}')"
log "Endpoint type: ${API_TYPE:-unknown}"
if govc vm.info "$TEMPLATE_NAME" 2>/dev/null | grep -q "Name:"; then
  die "A VM/template named '$TEMPLATE_NAME' already exists. Delete it or change TEMPLATE_NAME in the profile."
fi

download_image() {
  if [ ! -f "$IMAGE_PATH" ]; then
    log "Downloading $IMAGE_URL"
    curl -fL --progress-bar -o "$IMAGE_PATH" "$IMAGE_URL"
  else
    log "Using existing image: $IMAGE_PATH"
  fi
}

# Wait until the VM powers itself off (the prep ends with a shutdown).
# Optional arg: max seconds to wait (default 600; Windows prep needs much more).
wait_for_poweroff() {
  local max="${1:-600}"
  log "Waiting for prep to finish (VM powers itself off; up to ~$((max / 60)) min)..."
  for _ in $(seq 1 $((max / 5))); do
    [ "$(vm_power_state "$TEMPLATE_NAME")" = "poweredOff" ] && return 0
    sleep 5
  done
  die "VM did not power off in time. Inspect the console; the prep may have failed."
}

# ---------------------------------------------------------------------------
# Path A: OVA image (Ubuntu) — import, prep via guestinfo, templatize.
# ---------------------------------------------------------------------------
build_from_ova() {
  download_image

  log "Importing OVA as '$TEMPLATE_NAME'"
  govc import.ova -name="$TEMPLATE_NAME" "$IMAGE_PATH"

  log "Setting ${TEMPLATE_CPUS} vCPU / ${TEMPLATE_MEMORY_MB} MB RAM"
  govc vm.change -vm "$TEMPLATE_NAME" -c "$TEMPLATE_CPUS" -m "$TEMPLATE_MEMORY_MB"
  [ -n "$TEMPLATE_DISK_GB" ] && govc vm.disk.change -vm "$TEMPLATE_NAME" -disk.label "Hard disk 1" -size "${TEMPLATE_DISK_GB}G"

  log "Injecting first-boot prep cloud-init via guestinfo"
  local prep_ud prep_md_file prep_md
  prep_ud="$(gzb64 "$SCRIPT_DIR/cloud-init/prep-userdata.yaml")"
  prep_md_file="$(mktemp)"
  printf 'instance-id: prep-%s\nlocal-hostname: %s\n' "$TEMPLATE_NAME" "$TEMPLATE_NAME" > "$prep_md_file"
  prep_md="$(gzb64 "$prep_md_file")"; rm -f "$prep_md_file"
  govc vm.change -vm "$TEMPLATE_NAME" \
    -e guestinfo.metadata="$prep_md" -e guestinfo.metadata.encoding="gzip+base64" \
    -e guestinfo.userdata="$prep_ud" -e guestinfo.userdata.encoding="gzip+base64"

  log "Powering on for first-boot prep"
  govc vm.power -on "$TEMPLATE_NAME"
  wait_for_poweroff

  log "Clearing prep guestinfo"
  govc vm.change -vm "$TEMPLATE_NAME" \
    -e guestinfo.metadata="" -e guestinfo.metadata.encoding="" \
    -e guestinfo.userdata="" -e guestinfo.userdata.encoding=""
}

# ---------------------------------------------------------------------------
# Path B: qcow2 image (Rocky) — convert, upload, build VM shell, prep via seed ISO.
# ---------------------------------------------------------------------------
build_from_qcow2() {
  require qemu-img
  : "${GUEST_ID:?profile must set GUEST_ID}"; : "${FIRMWARE:?profile must set FIRMWARE}"
  : "${DISK_CONTROLLER:?profile must set DISK_CONTROLLER}"
  download_image

  # 1. Convert qcow2 -> streamOptimized VMDK (the format vSphere ingests).
  local vmdk="$SCRIPT_DIR/${TEMPLATE_NAME}.vmdk"
  if [ ! -f "$vmdk" ]; then
    log "Converting qcow2 -> VMDK (streamOptimized) with qemu-img"
    qemu-img convert -f qcow2 -O vmdk -o subformat=streamOptimized "$IMAGE_PATH" "$vmdk"
  fi

  # 2. Upload+convert the VMDK into the datastore under a folder named after the template.
  log "Uploading VMDK into datastore folder '$TEMPLATE_NAME'"
  govc datastore.rm -f "$TEMPLATE_NAME" >/dev/null 2>&1 || true
  govc import.vmdk "$vmdk" "$TEMPLATE_NAME"
  local ds_disk="$TEMPLATE_NAME/${TEMPLATE_NAME}.vmdk"

  # 3. Build a VM shell around the imported disk.
  log "Creating VM shell (guest=$GUEST_ID firmware=$FIRMWARE ctrl=$DISK_CONTROLLER)"
  govc vm.create -on=false \
    -g "$GUEST_ID" -c "$TEMPLATE_CPUS" -m "$TEMPLATE_MEMORY_MB" -firmware "$FIRMWARE" \
    -net "$GOVC_NETWORK" -net.adapter vmxnet3 \
    -disk "$ds_disk" -disk.controller "$DISK_CONTROLLER" -link=false \
    "$TEMPLATE_NAME"

  # 4. Build a NoCloud seed ISO carrying the prep cloud-init, upload + attach it.
  log "Building NoCloud seed ISO for first-boot prep"
  local seed_dir seed_iso; seed_dir="$(mktemp -d)"; seed_iso="$SCRIPT_DIR/${TEMPLATE_NAME}-seed.iso"
  printf 'instance-id: prep-%s\nlocal-hostname: %s\n' "$TEMPLATE_NAME" "$TEMPLATE_NAME" > "$seed_dir/meta-data"
  cp "$SCRIPT_DIR/cloud-init/prep-userdata.yaml" "$seed_dir/user-data"
  make_iso "$seed_dir" "$seed_iso" CIDATA
  rm -rf "$seed_dir"

  log "Uploading + attaching seed ISO"
  govc datastore.upload "$seed_iso" "$TEMPLATE_NAME/seed.iso"
  local cdrom; cdrom="$(govc device.cdrom.add -vm "$TEMPLATE_NAME")"
  govc device.cdrom.insert -vm "$TEMPLATE_NAME" -device "$cdrom" "$TEMPLATE_NAME/seed.iso"

  # 5. Boot once so prep installs open-vm-tools + enables the VMware datasource.
  log "Powering on for first-boot prep (installs open-vm-tools, enables guestinfo)"
  govc vm.power -on "$TEMPLATE_NAME"
  wait_for_poweroff

  # 6. Detach + delete the seed ISO so clones don't re-read it.
  log "Detaching seed ISO"
  govc device.cdrom.eject -vm "$TEMPLATE_NAME" -device "$cdrom" >/dev/null 2>&1 || true
  govc device.remove -vm "$TEMPLATE_NAME" "$cdrom" >/dev/null 2>&1 || true
  govc datastore.rm -f "$TEMPLATE_NAME/seed.iso" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Path C: Windows eval VHD/VHDX — inject prep into the image, convert, upload,
# build VM shell, boot once (OOBE answers + first-logon prep.ps1 that installs
# VMware Tools + Cloudbase-Init, then sysprep /generalize /shutdown).
#
# The answer file is injected INTO the image at C:\Windows\Panther\unattend.xml
# via qemu-nbd + the kernel ntfs3 driver (needs root, Linux). A seed-ISO copy
# is NOT reliably consumed at the OOBE stage of a pre-installed image —
# verified live on Server 2025.
# ---------------------------------------------------------------------------
inject_windows_prep() {
  require qemu-nbd; require partprobe
  [ "$(id -u)" = 0 ] || die "Windows builds need root (qemu-nbd + ntfs3 mount)."
  local marker="$SCRIPT_DIR/.$(basename "$IMAGE_PATH").injected"
  if [ -f "$marker" ]; then
    log "Prep already injected into $(basename "$IMAGE_PATH") (rm '$marker' to redo)"
    return 0
  fi
  log "Injecting unattend answers + prep script into the image (Windows\\Panther)"
  modprobe nbd max_part=16
  qemu-nbd --connect=/dev/nbd0 "$IMAGE_PATH"
  # nbd needs a beat before partitions appear
  sleep 2; partprobe /dev/nbd0 2>/dev/null || true; sleep 1
  local win_part="/dev/nbd0p${WINDOWS_PARTITION:-3}"
  [ -b "$win_part" ] || { qemu-nbd --disconnect /dev/nbd0 >/dev/null; die "Windows partition $win_part not found"; }
  local mnt; mnt="$(mktemp -d)"
  if ! mount -t ntfs3 "$win_part" "$mnt" 2>/dev/null; then
    qemu-nbd --disconnect /dev/nbd0 >/dev/null
    die "Could not mount $win_part with ntfs3 (kernel driver missing?)"
  fi
  mkdir -p "$mnt/Windows/Panther" "$mnt/Windows/Setup/Scripts"
  sed -e "s|@PREP_ADMIN_PASSWORD@|$PREP_ADMIN_PASSWORD|g" \
      "$SCRIPT_DIR/windows/autounattend.xml" > "$mnt/Windows/Panther/unattend.xml"
  sed -e "s|@DEFAULT_USERNAME@|$DEFAULT_USERNAME|g" \
      -e "s|@ADMIN_GROUP@|$ADMIN_GROUP|g" \
      "$SCRIPT_DIR/windows/prep.ps1" > "$mnt/Windows/Setup/Scripts/prep.ps1"
  umount "$mnt"; rmdir "$mnt"
  qemu-nbd --disconnect /dev/nbd0 >/dev/null
  touch "$marker"
}

build_from_vhd() {
  require qemu-img; require sed
  : "${GUEST_ID:?profile must set GUEST_ID}"; : "${FIRMWARE:?profile must set FIRMWARE}"
  : "${DISK_CONTROLLER:?profile must set DISK_CONTROLLER}"
  : "${PREP_ADMIN_PASSWORD:?profile must set PREP_ADMIN_PASSWORD}"
  download_image

  # 1. Inject the OOBE answers + prep script, then convert to streamOptimized
  #    VMDK (qemu-img probes VHD vs VHDX on its own).
  inject_windows_prep
  local vmdk="$SCRIPT_DIR/${TEMPLATE_NAME}.vmdk"
  if [ ! -f "$vmdk" ] || [ "$IMAGE_PATH" -nt "$vmdk" ]; then
    log "Converting VHD -> VMDK (streamOptimized) with qemu-img"
    qemu-img convert -O vmdk -o subformat=streamOptimized "$IMAGE_PATH" "$vmdk"
  fi

  # 2. Upload+convert the VMDK into the datastore.
  log "Uploading VMDK into datastore folder '$TEMPLATE_NAME'"
  govc datastore.rm -f "$TEMPLATE_NAME" >/dev/null 2>&1 || true
  govc import.vmdk "$vmdk" "$TEMPLATE_NAME"
  local ds_disk="$TEMPLATE_NAME/${TEMPLATE_NAME}.vmdk"

  # 3. VM shell. Everything must work with Windows' IN-BOX drivers (no VMware
  #    Tools yet): lsilogic-sas disk + e1000e NIC, per the profile.
  log "Creating VM shell (guest=$GUEST_ID firmware=$FIRMWARE ctrl=$DISK_CONTROLLER net=${NET_ADAPTER:-vmxnet3})"
  govc vm.create -on=false \
    -g "$GUEST_ID" -c "$TEMPLATE_CPUS" -m "$TEMPLATE_MEMORY_MB" -firmware "$FIRMWARE" \
    -net "$GOVC_NETWORK" -net.adapter "${NET_ADAPTER:-vmxnet3}" \
    -disk "$ds_disk" -disk.controller "$DISK_CONTROLLER" -link=false \
    "$TEMPLATE_NAME"
  # Boot from the disk before PXE — otherwise a netboot server on the LAN
  # (e.g. netboot.xyz) catches the fresh-NVRAM EFI boot and parks at its menu.
  govc device.boot -vm "$TEMPLATE_NAME" -order disk,ethernet
  [ -n "$TEMPLATE_DISK_GB" ] && govc vm.disk.change -vm "$TEMPLATE_NAME" -disk.label "Hard disk 1" -size "${TEMPLATE_DISK_GB}G"

  # 4. Boot once: injected answers drive OOBE -> first logon -> prep.ps1 ->
  #    sysprep /generalize /shutdown. Windows takes far longer than cloud-init.
  #    (prep.ps1 deletes Panther\unattend.xml before sysprep so clones never
  #    re-read the prep answers.)
  log "Powering on for first-boot prep (OOBE + VMware Tools + Cloudbase-Init + sysprep)"
  govc vm.power -on "$TEMPLATE_NAME"
  wait_for_poweroff 3600
}

case "$IMAGE_FORMAT" in
  ova)      build_from_ova ;;
  qcow2)    build_from_qcow2 ;;
  vhd|vhdx) build_from_vhd ;;
  *) die "Unknown IMAGE_FORMAT '$IMAGE_FORMAT' in profile" ;;
esac

# Stamp profile metadata into the VM annotation so control tools (CLI / web UI)
# can discover deployable templates and how to configure them, without guessing
# from the name. Parsed as key=value lines.
log "Stamping template annotation with profile metadata"
govc vm.change -vm "$TEMPLATE_NAME" -annotation "managed-by=vmware-template-toolkit
role=template
profile=$PROFILE
os_id=$OS_ID
os_family=${OS_FAMILY:-linux}
default_username=$DEFAULT_USERNAME
admin_group=$ADMIN_GROUP
ssh_service=$SSH_SERVICE
iface=$DEFAULT_IFACE
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "$API_TYPE" = "HostAgent" ]; then
  # Standalone ESXi has no template object type: the powered-off, annotated VM
  # IS the template. Deployers copy its disk and never power it on.
  log "Standalone ESXi host: leaving '$TEMPLATE_NAME' as a powered-off VM"
else
  log "Converting '$TEMPLATE_NAME' to a vCenter template"
  govc vm.markastemplate "$TEMPLATE_NAME"
fi

log "Done. Template ready: $TEMPLATE_NAME"
log "Deploy with: ./deploy-vm.sh --profile $PROFILE --name host01 --ip <IP> --gateway <GW> --cidr <N> --wait"

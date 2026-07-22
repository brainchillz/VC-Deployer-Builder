#!/usr/bin/env bash
#
# build-template.sh [PROFILE] — Build a reusable vCenter template for the given OS
# profile (default: ubuntu-2604). Profiles live in profiles/<name>.env.
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
[ -f "$SCRIPT_DIR/config.env" ] || die "config.env not found. Run: cp config.env.example config.env  (then edit it)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.env"

PROFILE="${1:-${DEFAULT_PROFILE:-ubuntu-2604}}"
PROFILE_FILE="$SCRIPT_DIR/profiles/${PROFILE}.env"
[ -f "$PROFILE_FILE" ] || die "Unknown profile '$PROFILE'. Available: $(cd "$SCRIPT_DIR/profiles" && ls *.env | sed 's/.env//' | tr '\n' ' ')"
# shellcheck source=/dev/null
source "$PROFILE_FILE"

require govc; require gzip; require base64; require curl

: "${TEMPLATE_CPUS:=2}"
: "${TEMPLATE_MEMORY_MB:=2048}"
: "${TEMPLATE_DISK_GB:=}"
IMAGE_PATH="$SCRIPT_DIR/$(basename "$IMAGE_URL")"

log "Profile '$PROFILE' -> template '$TEMPLATE_NAME' (format: $IMAGE_FORMAT)"
log "Checking vCenter connectivity"
govc about >/dev/null || die "Cannot reach vCenter. Check GOVC_URL / credentials in config.env."
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

# Wait until the VM powers itself off (the prep cloud-init ends with 'shutdown').
wait_for_poweroff() {
  log "Waiting for prep to finish (VM powers itself off; up to ~10 min)..."
  for _ in $(seq 1 120); do
    [ "$(vm_power_state "$TEMPLATE_NAME")" = "poweredOff" ] && return 0
    sleep 5
  done
  die "VM did not power off in time. Inspect the console; prep cloud-init may have failed."
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
  require qemu-img; require hdiutil
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
  rm -f "$seed_iso"
  hdiutil makehybrid -iso -joliet -default-volume-name CIDATA -o "$seed_iso" "$seed_dir" >/dev/null
  [ -f "$seed_iso" ] || seed_iso="${seed_iso}.cdr"   # hdiutil sometimes appends .cdr
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

case "$IMAGE_FORMAT" in
  ova)   build_from_ova ;;
  qcow2) build_from_qcow2 ;;
  *) die "Unknown IMAGE_FORMAT '$IMAGE_FORMAT' in profile" ;;
esac

# Stamp profile metadata into the VM annotation so control tools (CLI / web UI)
# can discover deployable templates and how to configure them, without guessing
# from the name. Parsed as key=value lines.
log "Stamping template annotation with profile metadata"
govc vm.change -vm "$TEMPLATE_NAME" -annotation "managed-by=vmware-template-toolkit
profile=$PROFILE
os_id=$OS_ID
default_username=$DEFAULT_USERNAME
admin_group=$ADMIN_GROUP
ssh_service=$SSH_SERVICE
iface=$DEFAULT_IFACE
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log "Converting '$TEMPLATE_NAME' to a vCenter template"
govc vm.markastemplate "$TEMPLATE_NAME"

log "Done. Template ready: $TEMPLATE_NAME"
log "Deploy with: ./deploy-vm.sh --profile $PROFILE --name host01 --ip <IP> --gateway <GW> --cidr <N> --wait"

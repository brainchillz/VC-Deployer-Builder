# VC-Deployer — Template Builder

Turn a Linux **cloud image** into a reusable **vCenter template** that the
VC-Deployer clients can deploy VMs from. This is the "build once" half of the
toolkit; deploying is done by **VC-Deployer-Python** or **VC-Deployer-Shell**.

Each template is stamped with a vCenter annotation describing its profile, so
the clients can discover it and configure VMs without any shared files. See
[`PROTOCOL.md`](PROTOCOL.md) for that contract.

## What it does

For each OS profile, `build-template.sh`:

1. Downloads the cloud image (OVA or qcow2).
2. Imports it into vCenter (`govc import.ova`, or `qemu-img` → VMDK → `govc import.vmdk`).
3. Runs a one-time **prep** in the guest (enable the VMware cloud-init datasource,
   install `open-vm-tools`, generalize) via `guestinfo` — or, for images without
   `open-vm-tools`, via a NoCloud seed ISO.
4. Stamps the profile annotation and marks the VM as a template.

## Requirements

- [`govc`](https://github.com/vmware/govmomi) — the vCenter CLI
- `qemu-img` — only for qcow2 / EL-family images (e.g. Rocky)
- `bash`, and a host that can create the seed ISO for qcow2 images
- vCenter credentials + placement (datacenter, datastore, resource pool, network)

## Configure

```bash
cp config.env.example config.env      # then edit — or keep real values elsewhere
```

`config.env` holds the `GOVC_*` connection + placement, global template sizing
(`TEMPLATE_CPUS`, `TEMPLATE_MEMORY_MB`, `TEMPLATE_DISK_GB`), and the default
profile. OS specifics live in `profiles/*.env`.

## Build

```bash
./build-template.sh                 # default profile (ubuntu-2604)
./build-template.sh ubuntu-2404
./build-template.sh rocky-10        # needs qemu-img
```

## Profiles

| Profile | OS | Image | Notes |
|---|---|---|---|
| `ubuntu-2604` (default) | Ubuntu 26.04 LTS | OVA | trivial import |
| `ubuntu-2404` | Ubuntu 24.04 LTS | OVA | trivial import |
| `rocky-10` | Rocky Linux 10 | qcow2 | qcow2→VMDK convert; seed-ISO prep |
| `windows-2025` | Windows Server 2025 (eval) | VHDX | see below — needs root + `qemu-nbd` + ntfs3 |

Add an OS by copying a `profiles/*.env` and running `./build-template.sh <name>`.
Each profile sets the template name, image URL/format, login user, admin group,
ssh unit, and NIC name (plus, for qcow2, guest id / firmware / disk controller).

### Windows (yes, really)

`windows-2025` builds a template from Microsoft's **evaluation VHDX** (no
installer pass). The flow: inject an OOBE answer file + prep script directly
into the image's NTFS (`qemu-nbd` + the kernel `ntfs3` driver — hence root, and
a Linux build host), convert/import like the qcow2 path, then boot once: OOBE
completes unattended and the prep script installs **VMware Tools**, the
**OpenSSH Server** capability, and **Cloudbase-Init** configured for the
**VMware guestinfo datasource** — so Windows clones consume the *same*
`guestinfo.*` transport the Linux templates use with cloud-init — and ends with
`sysprep /generalize`. Hardware is EFI + `lsilogic-sas` + `e1000e` (the eval
image is Generation 2, and everything must boot on in-box drivers).

Hard-won notes, so nobody relearns them: the answer file **must** be injected at
`C:\Windows\Panther\unattend.xml` (a seed-ISO copy is not reliably consumed at
the OOBE stage of a pre-installed image), it must **not** contain a `specialize`
pass (a `ComputerName` there loops the setup engine — clones are named by
Cloudbase-Init anyway), and the licensing is Microsoft's 180-day eval.
Deploy-side, Windows is **DHCP-only** for now.

## More

[`DETAILS.md`](DETAILS.md) is a command-by-command walkthrough of the whole
build, including every `govc` call and the hard-won cross-distro fixes.

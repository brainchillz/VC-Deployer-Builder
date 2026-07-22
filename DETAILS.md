# Painfully detailed instructions

How the Ubuntu 26.04 template was **injected into vCenter**, and exactly how a new
VM gets its **static IP, username, and password** — every command, every flag,
every file that changes inside the guest, in order.

Real environment used throughout:

| Thing | Value |
|---|---|
| vCenter | `https://vcenter.example.com` (vCenter 8.0.3) |
| Login | `administrator@vsphere.local` |
| Datacenter | `Datacenter` |
| Cluster / resource pool | `Cluster` → `/Datacenter/host/Cluster/Resources` |
| Datastore | `datastore1` |
| Portgroup | `VM Network` |
| Subnet | `10.0.0.0/23`, gateway `10.0.0.1` |
| Template name | `ubuntu-2604-template` |
| Guest NIC name | `ens192` |

---

## The one idea everything is built on

cloud-init is already inside the Ubuntu cloud image. On boot it looks for a
"datasource" — a place to read configuration from. On VMware, that datasource is
**`DataSourceVMware`**, and it reads configuration out of **VMware `guestinfo`
variables** using `vmware-rpctool "info-get guestinfo.<key>"` (a channel provided
by open-vm-tools straight through the hypervisor, no network required).

There are exactly three data channels:

| guestinfo key | contains | cloud-init calls it |
|---|---|---|
| `guestinfo.metadata` | identity + **network** (static IP) | metadata |
| `guestinfo.userdata` | `#cloud-config`: **users, sudo, password, ssh, runcmd** | user-data |
| `guestinfo.vendordata` | (unused here) | vendor-data |

Each has a companion `<key>.encoding` telling cloud-init how to decode the value.
We always use `gzip+base64` (gzip the YAML, then base64 it). So the entire job is:

> **set `guestinfo.metadata` and `guestinfo.userdata` on a VM, power it on, and
> cloud-init does the rest.** `govc vm.change -e <key>=<value>` is how you set them
> from your Mac.

---

# Part 0 — govc setup and a flag glossary

Every command below assumes these environment variables are exported (govc reads
them so you don't repeat `-u`, `-dc`, `-ds`, etc. on every call):

```bash
export GOVC_URL="https://vcenter.example.com"          # vCenter endpoint
export GOVC_USERNAME="administrator@vsphere.local"
export GOVC_PASSWORD="********"                   # taken from ../vcenter
export GOVC_INSECURE="1"                          # accept the self-signed TLS cert
export GOVC_DATACENTER="Datacenter"               # which DC inventory to act in
export GOVC_DATASTORE="datastore1"           # where VM disks land
export GOVC_RESOURCE_POOL="/Datacenter/host/Cluster/Resources"  # compute placement
export GOVC_FOLDER="vm"                           # VM-and-Templates folder
export GOVC_NETWORK="VM Network"                  # portgroup NICs attach to
```

Glossary of the govc verbs used:

| Command | What it does |
|---|---|
| `govc about` | one round-trip to prove creds/URL work |
| `govc import.ova` | parse an OVA, create a VM, upload its disks, map its network |
| `govc vm.change` | edit a VM's config; `-c`/`-m` = cpu/mem; `-e K=V` = set an ExtraConfig/guestinfo var |
| `govc vm.power` | `-on` / `-off` / `-s` (shutdown) a VM |
| `govc vm.info` | human-readable VM summary; `-json` machine-readable; `-e` shows ExtraConfig |
| `govc vm.clone` | copy a VM/template into a new VM |
| `govc vm.markastemplate` | flip a powered-off VM to "template" |
| `govc guest.run` | run a program **inside** the guest via VMware Tools (needs guest login) |
| `govc object.collect -s <moref> <prop>` | read one property value straight from vCenter |
| `govc find -type m -name X` | resolve a name to its inventory path |

---

# Part 1 — Injecting the template into vCenter (painful detail)

## Step 1.1 — Download Canonical's official VMware cloud image

```bash
curl -fL -o ubuntu-26.04-server-cloudimg-amd64.ova \
  https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.ova
```

- `-f` = fail (non-zero exit) on an HTTP 4xx/5xx instead of saving an error page.
- `-L` = follow redirects (the mirror redirects).
- `-o <file>` = output filename.

Why this image and not the server ISO: this `.ova` already contains **cloud-init**
and **open-vm-tools**, boots headless, and has **no installer** to click through.
The OVA is a tar of an OVF descriptor (hardware definition), a manifest, and a
compressed VMDK disk.

## Step 1.2 — Import the OVA  ← the literal "inject into vCenter" step

```bash
govc import.ova -name=ubuntu-2604-template ubuntu-26.04-server-cloudimg-amd64.ova
```

What govc does internally, in order:
1. Opens the OVA (tar), reads the **OVF descriptor** (`.ovf`) — CPU, memory, disk
   controller, one NIC, and any OVF **properties** the image publishes.
2. Creates a new VM named `ubuntu-2604-template` in `GOVC_FOLDER`, on
   `GOVC_RESOURCE_POOL`, storing disks on `GOVC_DATASTORE`.
3. Maps the OVF's network to `GOVC_NETWORK` (`VM Network`).
4. Opens an **HttpNfcLease** and streams/uploads the VMDK to the datastore
   (this is the slow part — the disk copy).
5. Leaves the VM **powered off**.

`-name=` overrides the name from the OVF. (For images that *require* OVF property
values you'd pass `-options=spec.json`, produced by `govc import.spec ...ova`;
the Ubuntu image's properties all have defaults, so a bare import works.)

## Step 1.3 — Right-size the hardware

```bash
govc vm.change -vm ubuntu-2604-template -c 2 -m 2048
```

- `-c 2` = 2 vCPUs.
- `-m 2048` = 2048 MB RAM.

(Optional root-disk growth would be `govc vm.disk.change -vm ubuntu-2604-template
-disk.label "Hard disk 1" -size 40G`.)

## Step 1.4 — First-boot "prep", delivered through the *same* guestinfo channel

The stock image isn't yet a good template. Two problems to fix **before** it's
cloned:

1. cloud-init must be told to **prefer `DataSourceVMware`** so future clones read
   guestinfo (rather than probing for a cloud/NoCloud source and possibly falling
   back to DHCP).
2. The image must be **generalized** — a template that keeps its machine-id and
   SSH host keys would stamp identical identities into every clone.

We fix both by booting the VM once with a prep cloud-config, injected exactly the
way real deploys inject config. The prep user-data (`cloud-init/prep-userdata.yaml`)
does, line by line:

```yaml
#cloud-config
package_update: true          # apt-get update
packages:
  - open-vm-tools             # the CORRECT guest agent for VMware (provides vmware-rpctool)
  - cloud-init                # ensure it's current
write_files:
  - path: /etc/cloud/cloud.cfg.d/99-vmware-datasource.cfg
    content: |
      datasource_list: [ VMware, OVF, NoCloud, None ]   # search VMware first
      datasource:
        VMware:
          allow_raw_data: true                          # accept metadata/userdata blobs
runcmd:
  - rm -f /etc/ssh/ssh_host_*                # drop host keys -> regenerated per clone
  - truncate -s 0 /etc/machine-id            # blank machine-id -> unique per clone
  - rm -f /var/lib/dbus/machine-id
  - ln -sf /etc/machine-id /var/lib/dbus/machine-id
  - cloud-init clean --logs --seed           # wipe cloud-init state so it RE-RUNS on next boot
  - shutdown -h now                          # power off; the build script waits for this
```

### The encoding pipeline (byte level)

guestinfo values are plain strings stored in the VM's config. cloud-init wants
them decoded per the `.encoding` hint. We use `gzip+base64`:

```bash
# metadata for the prep boot: just an identity
printf 'instance-id: prep-ubuntu-2604-template\nlocal-hostname: ubuntu-2604-template\n' \
  | gzip -c \        # compress -> raw gzip bytes on stdout
  | base64  \        # encode those bytes to ASCII (base64 emits line breaks...)
  | tr -d '\n'  \    # ...strip ALL newlines so it's ONE line (a guestinfo value is single-line)
  > md.b64

# userdata for the prep boot: the cloud-config above
gzip -c cloud-init/prep-userdata.yaml | base64 | tr -d '\n' > ud.b64
```

`tr -d '\n'` matters: a multi-line value would be truncated at the first newline
when stored as a guestinfo variable.

### Set the four guestinfo variables

```bash
govc vm.change -vm ubuntu-2604-template \
  -e guestinfo.metadata="$(cat md.b64)"  -e guestinfo.metadata.encoding="gzip+base64" \
  -e guestinfo.userdata="$(cat ud.b64)"  -e guestinfo.userdata.encoding="gzip+base64"
```

Each `-e K=V` writes one **ExtraConfig** key on the VM. On boot, open-vm-tools
exposes these to the guest, and `DataSourceVMware` reads them with
`vmware-rpctool "info-get guestinfo.metadata"` etc., checks the `.encoding` key,
base64-decodes then gunzips, and parses the YAML.

### Boot once and wait for it to power itself off

```bash
govc vm.power -on ubuntu-2604-template

# poll the power state until the prep's `shutdown -h now` takes effect
until [ "$(govc vm.info ubuntu-2604-template | awk -F': +' '/Power state/{print $2}')" = poweredOff ]; do
  sleep 5
done
```

Inside the guest during this single boot: apt installs open-vm-tools, the
datasource config file is written, host keys + machine-id are cleared, cloud-init
state is wiped, then the machine powers off. (`govc vm.info` prints a
`Power state:` line; the `awk` pulls the value; the `until` loop blocks until it
reads `poweredOff`.)

## Step 1.5 — Clear the prep guestinfo, then convert to a template

```bash
# blank the four keys so CLONES don't inherit the prep config
govc vm.change -vm ubuntu-2604-template \
  -e guestinfo.metadata="" -e guestinfo.metadata.encoding="" \
  -e guestinfo.userdata="" -e guestinfo.userdata.encoding=""

# flip VM -> template
govc vm.markastemplate ubuntu-2604-template
```

Verify it really is a template:

```bash
govc object.collect -s "$(govc find -type m -name ubuntu-2604-template)" config.template
# -> true
```

`config.template=true` means it can no longer be powered on directly — only cloned.

---

# Part 2 — Creating a new VM with IP + user + password (painful detail)

Worked example: VM **`web01`**, static **`10.0.0.70/23`**, gateway
**`10.0.0.1`**, user **`ubuntu`**, password **`S0mePass!`**, plus your SSH key.

## Step 2.1 — Write the metadata (identity + STATIC IP)

```yaml
# metadata.yaml
instance-id: iid-web01-a1b2c3d4          # (A) unique-per-VM id — see note
local-hostname: web01                    # (B) hostname vCenter/guest use
network:                                 # (C) netplan v2 network config
  version: 2
  ethernets:
    ens192:                              # (D) MUST match the guest NIC name
      dhcp4: false                       # (E) turn OFF DHCP
      dhcp6: false
      addresses:
        - 10.0.0.70/23               # (F) the static IP + /23 prefix
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]    # (G) DNS servers
      routes:
        - to: default                    # (H) default route...
          via: 10.0.0.1              #     ...via the gateway (modern netplan; NOT gateway4)
```

- **(A) `instance-id` must be unique.** cloud-init records the last instance-id it
  processed in `/var/lib/cloud/`. On a clone it compares: **new id ⇒ re-run all
  per-instance modules** (create the user, apply the network); **same id ⇒ skip
  everything**. This is the single most important field — reuse it and your clone
  boots unconfigured. `deploy-vm.sh` builds it as `iid-<name>-<random from
  /dev/urandom>`.
- **(D) NIC name.** vSphere assigns the clone a brand-new MAC, but netplan here
  matches by *interface name* `ens192`, which is stable on the VMware vmxnet3 NIC
  for Ubuntu 26.04 (confirmed during testing). If yours differs (`ens160` on some
  hardware versions), set `--iface`.
- **(F)/(H)** The static IP and default gateway live **only** here. vSphere never
  sets a guest IP — cloud-init writes netplan and applies it.

## Step 2.2 — Write the user-data (USER + SUDO + PASSWORD + SSH)

```yaml
#cloud-config
# userdata.yaml
hostname: web01
fqdn: web01
manage_etc_hosts: true                   # keep /etc/hosts consistent with the hostname
ssh_pwauth: true                         # (1) permit password SSH (set false for key-only)
users:
  - name: ubuntu                         # (2) CREATE this user
    gecos: ubuntu
    groups: [sudo]                       # (3) ADD to the 'sudo' group
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL         # (4) drop a passwordless sudoers rule for them
    lock_passwd: false                   # (5) allow password login (default locks it)
    plain_text_passwd: "S0mePass!"       # (6) SET password — cloud-init hashes it IN-GUEST
    ssh_authorized_keys:
      - "ssh-ed25519 AAAA...you@mac"      # (7) install your public key
runcmd:
  - systemctl enable --now ssh           # (8) make sure sshd is enabled + running
```

Which cloud-init module turns each line into reality:

| line | cloud-init module | what it does in the guest |
|---|---|---|
| (2)(3)(5) | `cc_users_groups` | runs `useradd ubuntu -G sudo -s /bin/bash`, home dir, etc. |
| (4) | `cc_users_groups` | writes `/etc/sudoers.d/90-cloud-init-users` with the NOPASSWD rule |
| (1)(6) | `cc_set_passwords` | hashes `S0mePass!` and runs `chpasswd -e`; sets `PasswordAuthentication yes` in sshd |
| (7) | `cc_ssh` (`ssh_authorized_keys`) | writes `/home/ubuntu/.ssh/authorized_keys` (mode 600, owned by ubuntu) |
| (8) | `cc_scripts_user` (runcmd) | executes the commands as a boot script |

> **Do NOT add `qemu-guest-agent` to `packages`/`runcmd`.** That's the KVM agent;
> on VMware it has no transport, `systemctl enable --now qemu-guest-agent` hangs
> ~90 s and exits non-zero, which fails the whole `runcmd` module and makes
> `cloud-init status` report **error** (we hit this during testing). open-vm-tools
> is already in the template and is the right agent.

> **Password on macOS.** `plain_text_passwd` is used deliberately: macOS can't
> produce a SHA-512 `$6$` hash (`openssl passwd -6` doesn't exist in LibreSSL;
> python/perl `crypt` silently fall back to weak DES). Handing cloud-init the
> plaintext lets the *Linux* guest do the hashing. If you want a real hash in
> `passwd:` instead, generate it on a Linux box: `openssl passwd -6`.

## Step 2.3 — Encode both documents

```bash
MD=$(gzip -c metadata.yaml | base64 | tr -d '\n')
UD=$(gzip -c userdata.yaml | base64 | tr -d '\n')
```

Same pipeline as the template prep: gzip → base64 → strip newlines → one line.

## Step 2.4 — Clone the template (full clone, left powered off)

```bash
govc vm.clone -vm ubuntu-2604-template -on=false web01
```

- `-vm ubuntu-2604-template` = the source template.
- `-on=false` = **do not power on yet** — we must inject guestinfo first, otherwise
  the VM boots with no config.
- `web01` = the new VM's name.
- Placement (folder/pool/datastore/network) comes from the `GOVC_*` env vars.
- This is a **full clone**: an independent copy of the disk (not a linked clone).
  vCenter assigns the clone a **new BIOS UUID and a new MAC**. Because the template
  was generalized (machine-id/host-keys cleared, cloud-init state wiped), the clone
  regenerates a unique identity and cloud-init runs from scratch.

## Step 2.5 — Inject the two documents onto the clone

```bash
govc vm.change -vm web01 \
  -e guestinfo.metadata="$MD" -e guestinfo.metadata.encoding="gzip+base64" \
  -e guestinfo.userdata="$UD" -e guestinfo.userdata.encoding="gzip+base64"
```

This writes the four ExtraConfig keys onto **web01** (the clone), not the template.

## Step 2.6 — Power on

```bash
govc vm.power -on web01
```

### What happens inside web01, in boot order

1. **`cloud-init-local.service`** runs first (before networking). `DataSourceVMware`
   calls `vmware-rpctool "info-get guestinfo.metadata"` + `...userdata`, reads the
   `.encoding` keys, base64-decodes + gunzips both. It sees a **new instance-id** →
   proceeds. It renders the metadata `network:` block into
   **`/etc/netplan/50-cloud-init.yaml`** and applies it → `ens192` gets
   `10.0.0.70/23`, gateway `10.0.0.1`, DNS set.
2. **`cloud-init.service`** (network stage) runs.
3. **`cloud-config.service`** (config modules) runs `cc_users_groups`
   (create `ubuntu`, add to `sudo`, write sudoers), `cc_set_passwords` (hash +
   set the password, enable password SSH), `cc_ssh` (install your authorized key).
4. **`cloud-final.service`** runs `cc_scripts_user` → your `runcmd`
   (`systemctl enable --now ssh`). cloud-init writes `status: done`.

### Watch for the address you configured (not the transient one)

For a few seconds at the very start, the NIC pulls a **DHCP lease** before
cloud-init applies the static config, so vCenter's summary / `govc vm.ip` may flash
a wrong address (during testing we saw `10.0.0.x` before `10.0.0.70`
settled). Poll for the *configured* IP instead:

```bash
until govc vm.info -json web01 | grep -q '"10.0.0.70"'; do sleep 5; done
ssh ubuntu@10.0.0.70          # works ~30–60s after power-on
```

(`deploy-vm.sh --wait` does exactly this poll.)

---

# Part 3 — Proving/looking at what was injected

### From your Mac, see the raw guestinfo on the VM

```bash
govc vm.info -e web01 | grep guestinfo
# guestinfo.metadata:            H4sIAAAA...        (the gzip+base64 blob)
# guestinfo.metadata.encoding:   gzip+base64
# guestinfo.userdata:            H4sIAAAA...
# guestinfo.userdata.encoding:   gzip+base64
```

### From INSIDE the guest, read exactly what the datasource received

open-vm-tools ships `vmware-rpctool`:

```bash
vmware-rpctool "info-get guestinfo.metadata" | base64 -d | gunzip
vmware-rpctool "info-get guestinfo.userdata" | base64 -d | gunzip
```

### Run commands inside the guest from vCenter (no network needed)

Because open-vm-tools is present, you can execute in the guest through the
hypervisor channel — this is how the build was debugged when the guest had the
"wrong" IP. Needs a guest login (deploy with `--password`):

```bash
govc guest.run -vm web01 -l 'ubuntu:S0mePass!' ip -br a
govc guest.run -vm web01 -l 'ubuntu:S0mePass!' cloud-init status --long
govc guest.run -vm web01 -l 'ubuntu:S0mePass!' cat /etc/netplan/50-cloud-init.yaml
```

### Confirm the results (what a good deploy looks like)

Observed on the verified test VM:

```
$ cloud-init status
status: done                                  # no error

$ ip -4 -br a show ens192
ens192   UP   10.0.0.61/23                 # static IP applied

$ id -nG
ubuntu adm cdrom sudo dip lxd                  # in 'sudo'
$ sudo -n true; echo $?
0                                              # passwordless sudo works

$ systemctl is-active ssh
active                                         # SSH up
```

---

# Appendix — the whole thing as a copy/paste block

```bash
# ---- connection ----
export GOVC_URL="https://vcenter.example.com" GOVC_USERNAME="administrator@vsphere.local" \
       GOVC_PASSWORD="********" GOVC_INSECURE=1 GOVC_DATACENTER="Datacenter" \
       GOVC_DATASTORE="datastore1" GOVC_RESOURCE_POOL="/Datacenter/host/Cluster/Resources" \
       GOVC_FOLDER="vm" GOVC_NETWORK="VM Network"

# ---- build template (once) ----
curl -fL -o u.ova https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.ova
govc import.ova -name=ubuntu-2604-template u.ova
govc vm.change -vm ubuntu-2604-template -c 2 -m 2048
printf 'instance-id: prep\nlocal-hostname: ubuntu-2604-template\n' | gzip -c | base64 | tr -d '\n' > md.b64
gzip -c cloud-init/prep-userdata.yaml | base64 | tr -d '\n' > ud.b64
govc vm.change -vm ubuntu-2604-template \
  -e guestinfo.metadata="$(cat md.b64)" -e guestinfo.metadata.encoding=gzip+base64 \
  -e guestinfo.userdata="$(cat ud.b64)" -e guestinfo.userdata.encoding=gzip+base64
govc vm.power -on ubuntu-2604-template
until [ "$(govc vm.info ubuntu-2604-template | awk -F': +' '/Power state/{print $2}')" = poweredOff ]; do sleep 5; done
govc vm.change -vm ubuntu-2604-template -e guestinfo.metadata= -e guestinfo.metadata.encoding= -e guestinfo.userdata= -e guestinfo.userdata.encoding=
govc vm.markastemplate ubuntu-2604-template

# ---- deploy one VM (repeatable) ----
MD=$(gzip -c metadata.yaml | base64 | tr -d '\n')
UD=$(gzip -c userdata.yaml | base64 | tr -d '\n')
govc vm.clone -vm ubuntu-2604-template -on=false web01
govc vm.change -vm web01 \
  -e guestinfo.metadata="$MD" -e guestinfo.metadata.encoding=gzip+base64 \
  -e guestinfo.userdata="$UD" -e guestinfo.userdata.encoding=gzip+base64
govc vm.power -on web01
until govc vm.info -json web01 | grep -q '"10.0.0.70"'; do sleep 5; done
ssh ubuntu@10.0.0.70
```

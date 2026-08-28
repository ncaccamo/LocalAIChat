# LocalAIChat — Host Prerequisites

Standalone copy — this file intentionally duplicates BookTranslator's
host-prerequisites doc rather than referencing it, so this project can be
brought up on a machine that has never seen BookTranslator's repo. If you
already ran through this checklist for BookTranslator on this same
machine, you can skip straight to `README.md` Usage.

**What the host does _not_ need:** ROCm, the Vulkan SDK, or Mesa. All
GPU userspace is compiled into the container image; the host contributes
only the in-kernel `amdgpu` driver and Docker. A previously-installed
host `/opt/rocm` can be removed — nothing here reads it.

---

## 1 — Operating System

**Ubuntu 24.04 LTS or newer.** The 24.04 pin is the *container's*
(`FROM ubuntu:24.04` + the ROCm apt repo targets `noble`), resolved
inside the build and unaffected by the host OS. The host only has to run
Docker and provide the kernel `amdgpu` driver (§2), so 24.04, 26.04, or
another recent Debian-family release all work — only 24.04 is tested
here. On a non-24.04 host, use your release's codename in the Docker apt
repo line (§6).

## 2 — Kernel version (RDNA4-specific, easy to miss)

AMD RX 9000-series (RDNA4) cards need **Linux 6.12 or newer** for the
in-kernel `amdgpu` driver to recognize the card properly. 26.04+ already
ships past this; base Ubuntu 24.04 ships 6.8 and needs the HWE stack.

Check:
```bash
uname -r
```

If below 6.12 (i.e. base 24.04):
```bash
sudo apt update
sudo apt install --install-recommends linux-generic-hwe-24.04
sudo reboot
```

If even the HWE kernel is too old for brand-new hardware, the community
mainline-kernel installer is the standard fallback:
```bash
sudo add-apt-repository ppa:cappelikan/ppa
sudo apt update
sudo apt install mainline
sudo mainline install
sudo reboot
```

## 3 — BIOS/UEFI

- **Resizable BAR / Above 4G Decoding:** enable if available.
- **Secure Boot:** leave it on. Nothing here builds an out-of-tree kernel
  module — the driver is the in-tree `amdgpu`, ROCm/Vulkan live only in
  the container — so there's no MOK enrollment to deal with.

## 4 — Verify the GPU and its device nodes

```bash
lspci | grep -i vga
lspci | grep -i amd
```
You should see your Radeon card. Then confirm the kernel driver created
the compute device nodes (this is all the container needs — no ROCm
userspace):
```bash
ls -l /dev/kfd /dev/dri/renderD128
```
Both should exist, `/dev/kfd` group `render`. Missing = kernel too old
(section 2) or `amdgpu` failed to load (`dmesg | grep -i amdgpu`).

## 5 — GPU group membership

The container is granted `/dev/kfd` + `/dev/dri` access by the `render`
and `video` group GIDs (both groups exist on a stock Ubuntu install —
systemd/udev, not a driver package); `scripts/setup.sh` reads the GIDs
from your account.
```bash
sudo usermod -aG render,video "$USER"
```
**Log out and back in**, then: `id -nG | tr ' ' '\n' | grep -E '^(render|video)$'`

## 6 — Docker Engine + Compose plugin

Use Docker's official apt repo, not Ubuntu's bundled `docker.io`:

```bash
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update

sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"
```
The repo line uses `$VERSION_CODENAME` so it follows the host release. If
Docker hasn't published for a brand-new Ubuntu yet, substitute the
previous LTS codename (`noble`) in that one line until it does.

Log out and back in (or reboot), then verify:
```bash
docker run hello-world
```

## 7 — Base utilities

```bash
sudo apt install -y curl wget git
```

## 8 — Quick verification checklist

- [ ] `lsb_release -a` shows Ubuntu 24.04 or newer
- [ ] `uname -r` shows 6.12 or newer
- [ ] `lspci | grep -i amd` shows your GPU
- [ ] `ls /dev/kfd /dev/dri/renderD128` — both exist
- [ ] `id -nG` includes `render` and `video`
- [ ] `docker run hello-world` succeeds without `sudo`
- [ ] `git --version`, `curl --version`, `wget --version` all resolve

Once done, proceed to this repo's `README.md` Usage section.

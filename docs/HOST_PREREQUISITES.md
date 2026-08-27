# LocalAIChat — Host Prerequisites

Standalone copy — this file intentionally duplicates BookTranslator's
host-prerequisites doc rather than referencing it, so this project can be
brought up on a machine that has never seen BookTranslator's repo. If you
already ran through this checklist for BookTranslator on this same
machine, you can skip straight to `README.md` Usage.

---

## 1 — Operating System

**Ubuntu 24.04 LTS.** The Dockerfile's base image and the ROCm apt repo
used in the build stage are both pinned to this release.

## 2 — Kernel version (RDNA4-specific, easy to miss)

AMD RX 9000-series (RDNA4) cards need **Linux 6.12 or newer** for the
in-kernel `amdgpu` driver to recognize the card properly. Base Ubuntu
24.04 ships 6.8.

Check:
```bash
uname -r
```

If below 6.12:
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
- **Secure Boot:** no change needed — this setup avoids DKMS kernel
  modules, so nothing here requires disabling Secure Boot.

## 4 — Verify the GPU is visible

```bash
lspci | grep -i vga
lspci | grep -i amd
```

## 5 — Docker Engine + Compose plugin

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
Log out and back in (or reboot), then verify:
```bash
docker run hello-world
```

## 6 — Base utilities

```bash
sudo apt install -y curl wget git build-essential
```

## 7 — Quick verification checklist

- [ ] `lsb_release -a` shows Ubuntu 24.04
- [ ] `uname -r` shows 6.12 or newer
- [ ] `lspci | grep -i amd` shows your GPU
- [ ] `docker run hello-world` succeeds without `sudo`
- [ ] `git --version`, `curl --version`, `wget --version` all resolve

Once done, proceed to this repo's `README.md` Usage section.

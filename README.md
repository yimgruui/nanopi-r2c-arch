# NanoPi R2C Arch Linux ARM

**Unofficial / community-maintained** Arch Linux ARM SD card images for the
**FriendlyElec NanoPi R2C** (Rockchip RK3328, 1 GB DDR4), built as a small
out-of-the-box NAS/router appliance.

The NanoPi R2C is the cost-reduced NanoPi R2S: same SoC, one Gigabit WAN port
driven by the RK3328 GMAC with a **Motorcomm YT8521S** PHY, and one Gigabit LAN
port behind the **RTL8153** USB 3.0 controller. Only the WAN PHY differs from
the R2S, which is why mainline keeps the shared `rk3328-nanopi-r2` device-tree
include and the `nanopi-r2s:*` LED labels.

- Stock image: Arch Linux ARM `linux-aarch64`.
- Minimal image: `linux-nanopi-r2c-minimal` from
  [`nanopi-r2c-kernel-arch`](https://github.com/yimgruui/nanopi-r2c-kernel-arch).

The boot chain is mainline: Rockchip TPL/SPL → Trusted Firmware-A BL31 →
mainline U-Boot → `boot.scr` → `Image` + initramfs + `rk3328-nanopi-r2c.dtb`.

## Images

| Image | Kernel |
|-------|--------|
| `nanopi-r2c-arch-YYYY-MM-DD.img.xz` | Stock Arch Linux ARM `linux-aarch64` |
| `nanopi-r2c-arch-minimal-kernel-YYYY-MM-DD.img.xz` | `linux-nanopi-r2c-minimal` |

Releases are published from GitHub Actions. Branch builds are prereleases
(`test-<branch>-<run>`); default-branch builds are tagged
`nanopi-r2c-arch-<date>-r<run>`. The nightly `check-arch` workflow rebuilds when
the ALARM rootfs or the vendored `ksmbd-tools` sources change; package
bumps are committed back to the default branch automatically.

## Flash

Verify the compressed image:

```bash
sha256sum -c SHA256SUMS
```

Flash one explicit image file:

```bash
xzcat IMAGE.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Replace `/dev/sdX` with the SD card device from `lsblk`.

## First boot

- Serial console: `ttyS2` at `1500000` baud.
- The root partition and filesystem grow to fill the card on the first boot
  (`parted` + online `resize2fs`).
- Credentials come from the Arch Linux ARM rootfs: `root`/`root` and
  `alarm`/`alarm`. **Change both immediately** (`passwd`, `passwd alarm`).
- `alarm` is in `wheel` and `%wheel` is enabled in sudoers, so `sudo` works
  out of the box.
- `sshd` is enabled by the ALARM rootfs; do not expose the WAN port before
  changing the passwords.

## What the image configures

### Network

- `systemd-networkd` + `systemd-resolved`, DHCP on **both** ports, matched by
  driver: `rk_gmac-dwmac` (WAN) and `r8152` (LAN).
- zram swap: lz4, half of RAM, `vm.swappiness=100` (`zram-generator`).
- GPIO LEDs: `nanopi-r2s:green:lan` / `:wan` mapped to the detected interfaces.

### Removable storage

- A small udev + systemd automounter (`usb-mount@.service`) mounts USB block
  devices on hot-plug. There is no setuid helper and no userspace daemon.
- It requires neither a specific filesystem nor a label: the type comes from
  `blkid`, and the mountpoint is `/media/<label>`, falling back to
  `/media/<uuid>` and then `/media/usb-<kernel-name>`. Volumes that would share
  a mountpoint get a numeric suffix instead of overwriting each other.
- FAT/exFAT/NTFS are mounted with `uid=1000,gid=1000,umask=0022` so the
  appliance user owns the files; exFAT is preened when its dirty bit is set and
  vfat is checked with `fsck.vfat` before mounting. Every mount uses
  `nosuid,nodev,noexec,noatime`.
- NTFS uses the in-kernel `ntfs3` driver (the minimal kernel now ships it too)
  and falls back to `ntfs-3g`; `ntfsprogs` provides `mkntfs`/`ntfsfix`.
- Filesystem support follows the kernel: the stock ALARM kernel covers the
  common types (ext4, vfat, exFAT, NTFS3, btrfs, XFS, ...), and the minimal
  kernel additionally ships NTFS3, btrfs, XFS, F2FS, ISO9660/UDF, HFS+ and
  SquashFS modules. VFAT is mounted with `iocharset=utf8`.
- Unplugging the device stops the unit and lazily unmounts the volume.
- `ksmbd.service` has a drop-in ordering it after `usb-mount@sda1.service`, so
  a configured SMB share is not started before the data disk is mounted.

### Shell

- `zsh` is the login shell for both `alarm` and `root`, with
  `zsh-syntax-highlighting`, `zsh-autosuggestions` and `zsh-completions`
  installed.
- Type-ahead highlighting, grey history suggestions (`→` or `Ctrl+E` to
  accept) and a Tab completion menu work over plain SSH.
- Prompts use ANSI colors only (green for `alarm`, red for `root`); no extra
  fonts or powerline glyphs are needed.
- Config lives in `/home/alarm/.zshrc` and `/root/.zshrc`.

### SMB (installed, not enabled)

`ksmbd-tools` is installed, but **no share is configured and the service is not
enabled** — SMB is strictly opt-in. The package ships
`/etc/ksmbd/ksmbd.conf.example`; copy it, edit your shares, then start it:

```bash
sudo cp /etc/ksmbd/ksmbd.conf.example /etc/ksmbd/ksmbd.conf
sudoedit /etc/ksmbd/ksmbd.conf
sudo systemctl enable --now ksmbd   # loads the ksmbd module via modprobe@ksmbd
```

The image ships `/etc/systemd/system/ksmbd.service.d/usb-mount.conf`, which
orders `ksmbd` after `usb-mount@sda1.service` (the R2C has a single USB storage
port). Remove or adjust that drop-in if your disk enumerates under another
kernel name.

The kernel module is `ksmbd` (built as a module); starting the service pulls it
in. Add credentials (`valid users`, `write list`, ...) in `ksmbd.conf` before
exposing the share beyond a trusted LAN.

### Packages and system

- pacman uses the **USTC** mirrors for Arch Linux ARM and `archlinuxcn`; the
  archlinuxcn keyring is installed and locally signed. The unused ALARM `[aur]`
  repository is removed.
- Every package is upgraded to the newest version during the image build
  (`pacman -Syu`).
- `vim` is the default editor (`EDITOR`/`VISUAL`, and sudo's `editor` default);
  `nano` is not installed. `vi` maps to vim via `ex-vi-compat`.
- Unused packages (`netctl`, `dhcpcd`, `net-tools`, `cloud-utils`), docs, man
  pages, unused locales, `Image.gz` and non-Rockchip DTBs are removed to keep
  the image small. `iptables` stays because `iproute2` links `libxtables`;
  `nftables` is the firewall tool.
- Fan control follows a 51–75 °C PWM curve on the controller the device tree
  enables (PWM2 on the R2C); the `pwmchip` index is resolved at runtime.

## Build

The supported build path is GitHub Actions. See
[docs/BUILDING.md](docs/BUILDING.md) for workflow inputs, secrets, caches,
local builds, the full pipeline and troubleshooting.

Quick version:

```bash
# manual build on the default branch
gh workflow run build-image.yml --ref main -f should_publish_release=true

# or a test prerelease from a branch
gh workflow run build-image.yml --ref my-branch -f should_publish_release=true
```

Required repository secret: `R2C_KERNEL_KEY_FPR` (fingerprint of the minimal
kernel repo signing key). Optional variable: `R2C_KERNEL_REPO_URL`.

A local build is still possible on an Arch Linux host:

```bash
sudo pacman -S --needed $(./build-image.sh --print-deps) \
  arch-install-scripts qemu-user-static qemu-user-static-binfmt xz
sudo ./build-image.sh
```

## Build-time verification

The builder refuses to produce an image when something boot-critical is wrong:

- TF-A BL31 entry point is `0x40000` and has PT_LOAD segments.
- U-Boot is the pinned, signed `v2026.04` tag.
- The rootfs tarball matches its MD5 and the ALARM GPG signature.
- The stock kernel has the Motorcomm PHY driver (`CONFIG_MOTORCOMM_PHY`).
- The initramfs contains (or the kernel has built in) the SD/MMC and ext4 boot
  path; missing modules are added to `MODULES` and regenerated once.
- The appliance stack is complete: the USB automounter helper, udev rule, unit
  and ksmbd ordering drop-in are installed and syntax-checked, zsh is the login
  shell for `alarm` and `root` with its plugins and `.zshrc`, the NTFS tools
  (`ntfs-3g`, `ntfsprogs`) are present, and the minimal kernel ships the
  filesystem modules the automounter documents (NTFS3, btrfs, XFS, F2FS,
  ISO9660, UDF, HFS+, SquashFS, nls_cp936). `ksmbd.mountd` exists while
  `ksmbd.service` stays disabled, `alarm` is in `wheel`, vim is the default
  editor and nano is gone.
- The assembled image has a valid MBR, a byte-identical U-Boot payload,
  `/boot/boot.scr` and `rk3328-nanopi-r2c.dtb`.

## Troubleshooting

Common build failures (locale parsing, initramfs modules, Motorcomm PHY, AUR
rebuilds, the 2 GiB release limit) are covered in
[docs/BUILDING.md](docs/BUILDING.md#troubleshooting).

## Layout

```
build-image.sh            # entry point
docs/BUILDING.md          # CI/local build, pipeline, troubleshooting
scripts/
  common.sh               # config, deps, image helpers
  trusted-firmware.sh     # TF-A BL31 build
  bootloader.sh           # U-Boot build, bootloader writes
  chroot.sh               # arch-chroot helpers, initramfs verification
  kernel.sh               # minimal-kernel variant
  rootfs.sh               # rootfs download, network, zram, boot files
  tuning.sh               # mirrors, upgrade, USB automounter, zsh, pruning
  check-updates.py        # nightly AUR/upstream version check
  fan-control.sh          # fan-monitor cross-build and install
  postprocess.sh          # inspect, shrink, checksums
  templates/              # boot.cmd, systemd units and helper scripts
packaging/
  ksmbd-tools/            # pinned PKGBUILD (AUR, aarch64)
vendor/
  alarmsigning.gpg        # ALARM rootfs signing key
  u-boot-release.gpg      # U-Boot release tag key
  fan-monitor/            # vendored fan control daemon
.github/workflows/
  build-image.yml         # manual build + release
  check-arch.yml          # nightly rootfs + AUR check, bump and build trigger
```

## AI disclosure

Much of this repository was written with AI assistance and refined through
iterative review, builds, and hardware testing.

## Contributing

Issues and pull requests are welcome. Keep changes focused, test build changes
on a branch (prerelease), and say whether hardware testing was done.

## Credits

The image uses Trusted Firmware-A, U-Boot, Arch Linux ARM, USTC mirrors,
`archlinuxcn`, `ksmbd-tools` and optionally
`linux-nanopi-r2c-minimal`; see [NOTICE](NOTICE), [LICENSE_TFA.txt](LICENSE_TFA.txt),
[SOURCE_INFO_TFA.txt](SOURCE_INFO_TFA.txt) and
[SOURCE_OFFER_U_BOOT.txt](SOURCE_OFFER_U_BOOT.txt).

## License

Builder scripts: GPL-2.0-or-later; see [LICENSE](LICENSE) and
`LICENSE_GPL-2.0-or-later.txt`. Released images are combined works; see
[NOTICE](NOTICE).

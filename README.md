# NanoPi R2C Arch Linux ARM

**Unofficial / community-maintained** Arch Linux ARM SD card images for **FriendlyElec NanoPi R2C** (RK3328).

The NanoPi R2C is the cost-reduced NanoPi R2S: same RK3328 SoC, 1GB DDR4,
one Gigabit WAN port driven by the RK3328 GMAC with a **Motorcomm YT8521S**
PHY, and one Gigabit LAN port behind the **RTL8153** USB 3.0 controller.
Only the WAN PHY differs from the R2S, which is why mainline keeps the shared
`rk3328-nanopi-r2` device-tree include and the `nanopi-r2s:*` LED labels.

You can choose between a stock ALARM kernel image and a smaller image using
[`linux-nanopi-r2c-minimal`](https://github.com/yimgruui/nanopi-r2c-kernel-arch).

The image uses a mainline boot stack with source-built Trusted Firmware-A BL31,
mainline U-Boot, the official aarch64 rootfs, and small NanoPi R2C
adjustments. Earlier Arch-on-R2S attempts often still relied on Armbian boot
pieces or kernels; for example [larsch's gist](https://gist.github.com/larsch/a8f13faa2163984bb945d02efb897e6d) and [sakapoko/archlinux_r2s](https://github.com/sakapoko/archlinux_r2s).

This is not an official Arch Linux ARM project. For OS-level defaults such as
users, passwords, and package management, use the [Arch Linux ARM documentation](https://archlinuxarm.org/).

**Disclaimer:** Images are provided as-is, without warranty of fitness or
successful operation on your hardware. Builds follow rolling Arch Linux ARM
and upstream updates; behavior may change between releases.

## AI disclosure

Much of this repository was written with AI assistance and refined through
iterative review, builds, and hardware testing.

## Images

| Image | Kernel |
|-------|--------|
| `nanopi-r2c-arch-YYYY-MM-DD.img.xz` | Stock Arch Linux ARM `linux-aarch64` |
| `nanopi-r2c-arch-minimal-kernel-YYYY-MM-DD.img.xz` | `linux-nanopi-r2c-minimal` from [`nanopi-r2c-kernel-arch`](https://github.com/yimgruui/nanopi-r2c-kernel-arch) |

Both variants use the same bootloader/rootfs process. The minimal-kernel image
adds the public pacman repo, trusts the verified repo key, removes the stock
kernel, and keeps the repo configured for future kernel updates.

## What the image configures

- Serial console: `ttyS2` at `1500000` baud.
- First boot: the root partition expands to fill the SD card (parted + online `resize2fs`).
- Network: `systemd-networkd` with DHCP **on both** Ethernet ports, matched by
  driver (`rk_gmac-dwmac` = WAN, `r8152` = LAN), plus `systemd-resolved`.
- zram swap: lz4, half of RAM, `vm.swappiness=100` (`zram-generator`).
- GPIO LEDs: `nanopi-r2s:green:lan` / `:wan` are mapped to the detected
  interfaces (the mainline R2C dtb inherits those labels).
- Fan: `fan-monitor` follows a 51–75 °C curve on the PWM controller that the
  device tree enables (PWM2 on the R2C). It resolves `pwmchipN` at runtime, so
  it also works on kernels that number the chip differently.
- **Removable media**: `udevil` + `devmon` run as the `alarm` user and auto-mount
  hot-plugged drives under `/media`. The exFAT mount options are fixed for the
  mainline kernel (the stock udevil defaults include the vfat-only
  `namecase=0`, which the exFAT driver rejects).
- **SMB shares**: `ksmbd` serves `/media` (whatever udevil just mounted) and
  `/srv/ksmbd` as guest read-write shares, with files forced to `alarm`.
- **Package sources**: ALARM mirror and the `archlinuxcn` repo both use USTC
  (`mirrors.ustc.edu.cn`); the unused ALARM `[aur]` repo is removed.
- **Up to date on first boot**: the build runs `pacman -Syu`, so every package
  is at the newest version at image creation time.
- **Editor**: `vim` is installed and exported as `EDITOR`/`VISUAL`; `nano` is
  not part of the image.
- **Smaller image**: unused packages (nano, netctl, dhcpcd, net-tools,
  cloud-utils) are removed, and docs, man pages, unused locales, `Image.gz`
  and non-Rockchip DTBs are stripped. `nftables` is the firewall tool;
  `iptables` stays because `iproute2` links `libxtables`.
- Firmware: only `linux-firmware-realtek` (+ `-whence`) is installed; the
  heavy GPU/WiFi firmware packages are kept out via `IgnorePkg`.

**Default credentials:** `root`/`root` and `alarm`/`alarm` from the Arch Linux
ARM rootfs. The `alarm` user is in the `wheel` group and `%wheel` is enabled in
sudoers, so `sudo` works out of the box — change both passwords immediately
(`passwd`, `passwd alarm`) and do not expose the WAN port before doing so.
The SMB guest shares are read-write without authentication; keep the box on a
trusted LAN or add credentials in `/etc/ksmbd/ksmbd.conf`.

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

## Build on an Arch Linux host

Use Arch Linux (x86_64 works; aarch64 also works). The build needs root for
`arch-chroot`, bind mounts and the image assembly.

Install dependencies and the aarch64 binfmt handler:

```bash
sudo pacman -S --needed $(./build-image.sh --print-deps) \
  arch-install-scripts qemu-user-static qemu-user-static-binfmt xz uboot-tools
```

On an aarch64 host the qemu packages are not needed.

Build the stock image:

```bash
sudo ./build-image.sh
```

Build the minimal-kernel image:

```bash
sudo KERNEL_VARIANT=minimal R2C_KERNEL_KEY_FPR=<fingerprint> ./build-image.sh
```

Output is written to `output/` unless `OUTPUT_DIR` is set.

### Keeping large writes on another disk

`BUILD_ROOT` moves `cache/`, `output/` and the rootfs staging tree `mnt/` to
another filesystem, so the repository can stay on a small or non-POSIX disk
(e.g. an exFAT external drive). The staging tree needs a real Linux filesystem
(ownership, symlinks, device nodes), so point `BUILD_ROOT` at ext4/xfs/btrfs.
Two helper scripts automate the external-drive setup:

```bash
# once per boot: installs deps, enables binfmt, creates + mounts the ext4
# image on the external drive and prepares cache/output/mnt there
sudo ./scripts/setup-build-env.sh

# build with BUILD_ROOT on that volume, then copy the image(s) + SHA256SUMS
# to <drive>/nanopi-r2c-artifacts/
sudo ./scripts/local-build.sh
sudo KERNEL_VARIANT=minimal ./scripts/local-build.sh
```

Override with `DRIVE`, `BUILD_IMG`, `MOUNT_POINT`, `VOLUME_SIZE` and
`ARTIFACTS_DIR` if the defaults do not match your layout.

### Environment variables

| Variable | Default |
|----------|---------|
| `KERNEL_VARIANT` | `stock`; use `minimal` for `linux-nanopi-r2c-minimal` |
| `R2C_KERNEL_REPO_URL` | public `nanopi-r2c-kernel-arch` pacman repo |
| `R2C_KERNEL_KEY_FPR` | **required** for `minimal`; signing key fingerprint |
| `R2C_KERNEL_PKGVER` | latest repo version |
| `IMAGE_SIZE` | `1900M` |
| `ROOTFS_HOSTNAME` | `nanopi-r2c` |
| `BUILD_ROOT` | repository directory |
| `CACHE_DIR` / `OUTPUT_DIR` | `$BUILD_ROOT/cache` / `$BUILD_ROOT/output` |
| `SHOULD_SKIP_INITRAMFS_CHECK` | `0`; set `1` to bypass the boot-module check |

Shrink an existing image:

```bash
sudo ./build-image.sh --shrink-only output/IMAGE.img
```

## CI

- `build-image.yml` builds the stock image first and the minimal-kernel image
  second. A minimal-kernel failure (e.g. missing repo secret) is reported but
  does not block publishing the stock image.
- `check-arch.yml` checks the Arch Linux ARM rootfs MD5 and triggers a build of
  both images when it changes.
- Release artifacts include image `.xz` file(s), `SHA256SUMS`, `LICENSE`,
  `LICENSE_GPL-2.0-or-later.txt`, `NOTICE`, `LICENSE_TFA.txt`,
  `SOURCE_INFO_TFA.txt`, `SOURCE_OFFER_U_BOOT.txt`, and (for minimal builds)
  `SOURCE_INFO_R2C_KERNEL.txt`.

CI caches TF-A, U-Boot, and the rootfs tarball. Scheduled builds publish both
images. Manual branch builds publish test prereleases. Release/artifact files
must stay below GitHub's 2 GiB per-file limit, so the raw image defaults to
`1900M`.

For local workflow testing with [act](https://github.com/nektos/act):

```bash
./scripts/act-build.sh
```

The wrapper uses `act --bind` so gitignored `cache/` persists between runs.
Plain `act workflow_dispatch` re-downloads everything.

## Layout

```
build-image.sh
scripts/
  common.sh             # config, deps, image helpers (BUILD_ROOT)
  trusted-firmware.sh   # TF-A BL31 build
  bootloader.sh         # U-Boot build, bootloader writes
  chroot.sh             # arch-chroot helpers, initramfs verification
  kernel.sh             # optional minimal-kernel variant
  rootfs.sh             # rootfs download/configuration, network, zram
  tuning.sh             # mirrors, upgrade, udevil, ksmbd, pruning
  fan-control.sh        # fan-monitor cross-build and install
  postprocess.sh        # inspect, shrink, checksums
  setup-build-env.sh    # native Arch host + external build volume
  local-build.sh        # build with BUILD_ROOT on the external volume
  act-build.sh          # run the workflow locally with act
  templates/            # boot.cmd, LED/resize/fan/devmon units and scripts
packaging/
  udevil/               # pinned PKGBUILD (AUR, aarch64)
  ksmbd-tools/          # pinned PKGBUILD (AUR, aarch64)
vendor/
  alarmsigning.gpg      # ALARM rootfs signing key
  u-boot-release.gpg    # U-Boot release tag key
  fan-monitor/          # vendored fan control daemon
```

## Build-time verification

The builder refuses to produce an image when something boot-critical is wrong:

- TF-A BL31 entry point is `0x40000` and has PT_LOAD segments.
- U-Boot is the pinned commit and its release tag signature verifies.
- The rootfs tarball matches its MD5 and the ALARM GPG signature.
- The stock kernel has the Motorcomm PHY driver (`CONFIG_MOTORCOMM_PHY`), or
  the WAN port would never link.
- The generated initramfs contains (or the kernel has built in) the SD/MMC and
  ext4 drivers. Missing modules are added to `MODULES` and the initramfs is
  regenerated once; the build fails if they are still absent.
- The assembled image has a valid MBR, a byte-identical U-Boot payload and the
  expected `/boot/boot.scr` + `rk3328-nanopi-r2c.dtb`.
- The appliance stack is present: udevil is setuid, its exFAT options contain
  no vfat-only flags, `ksmbd.mountd` exists, `alarm` is in `wheel`, vim is the
  default editor and nano is gone.

## Contributing

Issues and pull requests are welcome. Please keep changes focused, test
image-building changes locally with `./scripts/act-build.sh` or
`./scripts/local-build.sh` when practical, and mention whether hardware
testing was done.

## Credits

The image uses Trusted Firmware-A, U-Boot, Arch Linux ARM packages, and
optionally `linux-nanopi-r2c-minimal`; see [NOTICE](NOTICE),
[LICENSE_TFA.txt](LICENSE_TFA.txt), [SOURCE_INFO_TFA.txt](SOURCE_INFO_TFA.txt),
and [SOURCE_OFFER_U_BOOT.txt](SOURCE_OFFER_U_BOOT.txt).

## License

Builder scripts: GPL-2.0-or-later; see [LICENSE](LICENSE) and the full text in
`LICENSE_GPL-2.0-or-later.txt`. Released images are combined works; see
[NOTICE](NOTICE).

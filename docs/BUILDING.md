# Building the image

The canonical build runs on GitHub Actions. A local build on an Arch Linux
host is possible for debugging, but it is not required and not supported by
CI.

## GitHub Actions

Two workflows drive everything:

| Workflow | Trigger | Purpose |
|---|---|---|
| `build-image.yml` | manual (`workflow_dispatch`) | Build stock + minimal images, publish a release |
| `check-arch.yml` | schedule (daily 20:00 UTC / 04:00 Asia/Shanghai) or manual | Poll the ALARM rootfs MD5 and trigger `build-image.yml` when it changes |

### Requirements

Repository configuration (Settings → Secrets and variables → Actions):

- **Secret `R2C_KERNEL_KEY_FPR`** — fingerprint of the signing key for the
  `linux-nanopi-r2c-minimal` pacman repository. Required for the minimal
  variant; the stock variant builds without it.
- **Variable `R2C_KERNEL_REPO_URL`** (optional) — overrides the default
  `https://yimgruui.github.io/nanopi-r2c-kernel-arch/aarch64`.

The workflow runs in an `archlinux:latest` container with `--privileged`, so
it can run `arch-chroot` and the aarch64 binfmt handlers.

### Triggering a build

From the Actions UI: *Build image* → *Run workflow* → choose a branch.

From the CLI:

```bash
gh workflow run build-image.yml --ref main -f should_publish_release=true
```

Inputs:

| Input | Default | Meaning |
|---|---|---|
| `should_publish_release` | `true` | Create a GitHub Release with the images |
| `arch_md5` | empty | Pin the ALARM rootfs MD5 instead of fetching the current one |

The image variant is always both `stock` and `minimal`; each runs the same
rootfs pipeline and publishes its own `.img.xz`.

### What gets published

- Branch builds (any non-default branch) publish a **prerelease** tagged
  `test-<branch>-<run>`.
- Default-branch builds publish a release tagged
  `nanopi-r2c-arch-<date>-r<run>`.
- Assets: both `.img.xz` files, `SHA256SUMS`, `LICENSE*`, `NOTICE`,
  `SOURCE_OFFER_U_BOOT.txt`, `SOURCE_INFO_TFA.txt` and, when the minimal
  variant built, `SOURCE_INFO_R2C_KERNEL.txt`.
- Raw images default to 1900M so every release asset stays below GitHub's
  2 GiB per-file limit.

### Caches

The workflow caches:

| Cache | Key |
|---|---|
| TF-A tree + BL31 | hash of `scripts/common.sh`, `scripts/trusted-firmware.sh` |
| U-Boot tree + binaries | hash of `scripts/common.sh`, `scripts/bootloader.sh` |
| ALARM rootfs tarball | the rootfs MD5 |
| Built udevil/ksmbd-tools packages | hash of `packaging/**/PKGBUILD` |

Cache misses only cost build time; the build always re-verifies the pinned
TF-A/U-Boot commits, the rootfs MD5/GPG signature and rebuilds missing AUR
packages.

### Nightly rootfs check

`check-arch.yml` stores the last seen rootfs MD5 in an Actions cache named
`arch-md5-state-<md5>`:

1. Fetch the current MD5 from `os.archlinuxarm.org`.
2. Restore the most recent `arch-md5-state-*` cache.
3. If the MD5 changed, trigger `build-image.yml` on the default branch.
4. Save the new MD5 **after** a successful trigger, so a failed trigger is
   retried on the next run.

Manual runs accept `should_force_build=true` to rebuild even when the MD5 is
unchanged. Every run also prunes old workflow history, keeping the 3 newest
runs of `check-arch.yml` and `build-image.yml` (release assets are unaffected).

## Local build (optional)

A local build needs an Arch Linux host (x86_64 works with qemu binfmt,
aarch64 works natively) and root for `arch-chroot`, bind mounts and image
assembly.

```bash
sudo pacman -S --needed $(./build-image.sh --print-deps) \
  arch-install-scripts qemu-user-static qemu-user-static-binfmt xz

# stock image
sudo ./build-image.sh

# minimal-kernel image
sudo KERNEL_VARIANT=minimal R2C_KERNEL_KEY_FPR=<fingerprint> ./build-image.sh
```

Output goes to `output/` (or `$OUTPUT_DIR`). Use `BUILD_ROOT` to put `cache/`,
`output/` and the rootfs staging tree `mnt/` on another filesystem; it must be
a POSIX filesystem (ext4/xfs/btrfs), because the staging tree needs ownership,
symlinks and device nodes.

Shrink an existing image and write `SHA256SUMS`:

```bash
sudo ./build-image.sh --shrink-only output/IMAGE.img
```

### Environment variables

| Variable | Default | Notes |
|---|---|---|
| `KERNEL_VARIANT` | `stock` | `stock` or `minimal` |
| `R2C_KERNEL_REPO_URL` | public nanopi-r2c-kernel-arch repo | minimal only |
| `R2C_KERNEL_KEY_FPR` | empty | required for `minimal` |
| `R2C_KERNEL_PKGVER` | latest | pin the minimal kernel version |
| `IMAGE_SIZE` | `1900M` | raw image size |
| `ROOTFS_HOSTNAME` | `nanopi-r2c` | `/etc/hostname` |
| `BUILD_ROOT` | repository dir | generated data root |
| `CACHE_DIR` / `OUTPUT_DIR` | `$BUILD_ROOT/cache` / `$BUILD_ROOT/output` | |
| `SHOULD_ENABLE_RESIZE` | `1` | first-boot partition grow |
| `SHOULD_SKIP_SLIM` | `0` | keep all firmware packages |
| `SHOULD_SKIP_SHRINK` | `0` | keep the 1900M image |
| `SHOULD_SKIP_TFA_REBUILD` | `0` | reuse a matching cached BL31 |
| `SHOULD_SKIP_UBOOT_REBUILD` | `0` | reuse a matching cached U-Boot |
| `SHOULD_SKIP_INITRAMFS_CHECK` | `0` | bypass the boot-module check |

## Build pipeline

1. Dependency check, TF-A `v2.15.0` BL31 (entry point and PT_LOAD verified),
   U-Boot `v2026.04` (signed tag + pinned commit verified).
2. MBR image with a single ext4 partition at 16 MiB; `u-boot-rockchip.bin`
   written at sector 64.
3. Arch Linux ARM rootfs downloaded over HTTP, checked against the MD5 **and**
   the ALARM GPG signature.
4. `arch-chroot` configuration: USTC mirrors + archlinuxcn, full
   `pacman -Syu`, network, LED/fan/zram services, udevil/ksmbd-tools built
   from vendored PKGBUILDs (ksmbd service left disabled), user/editor
   defaults, package pruning and stripping.
5. Stock kernel gets a Motorcomm PHY check; the minimal variant replaces the
   kernel from the signed pacman repo.
6. `/boot/boot.scr` generated, initramfs boot path verified (modules added and
   regenerated if missing), rootfs written with `mke2fs -d`.
7. Image inspected (MBR, U-Boot payload hash, boot files, DTB), shrunk with
   `resize2fs -M`, checksummed.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `BL31 entry point is none` | Non-English locale broke `readelf` parsing; `build-image.sh` forces `LC_ALL=C` |
| `initramfs still lacks ...` | Kernel has the driver neither built in nor in the initramfs; add it to `MODULES` in `/etc/mkinitcpio.conf` or set `SHOULD_SKIP_INITRAMFS_CHECK=1` only if you know the image boots |
| `stock kernel lacks the Motorcomm PHY driver` | ALARM changed the kernel config; the R2C WAN port will not link without `CONFIG_MOTORCOMM_PHY` |
| AUR build fails | Delete `cache/aur-packages` to force a rebuild; check the pinned commit/tarball hashes in `packaging/*/PKGBUILD` |
| `exceeds GitHub's 2147483648-byte asset limit` | Lower `IMAGE_SIZE` or reduce content; the compressed `.img.xz` must stay below 2 GiB |
| `failed to prepare transaction` during pruning | A package that is kept started depending on one being removed; drop it from the prune list in `scripts/tuning.sh` |
| Release exists but a variant is missing | The minimal build is allowed to fail; the stock image still publishes and the workflow logs a warning |

## Release checklist

1. Trigger `build-image.yml` on a test branch and check the prerelease.
2. Flash the stock image and verify: serial console, both NICs with DHCP, USB
   hot-plug mount, exFAT read/write, fan curve; configure and start ksmbd
   manually to test SMB.
3. Merge to the default branch; the nightly `check-arch.yml` run will then
   publish the regular release.

# Arch Linux ARM boot script for NanoPi R2C

test -n "${distro_bootpart}" || setenv distro_bootpart 1
test -n "${devtype}"         || setenv devtype mmc
test -n "${devnum}"          || setenv devnum 0
test -n "${prefix}"          || setenv prefix /boot/

setenv fdtfile    rockchip/rk3328-nanopi-r2c.dtb
setenv rootdev    /dev/mmcblk0p1
setenv rootfstype  ext4

setenv consoleargs "console=ttyS2,1500000 earlycon=uart8250,mmio32,0xff130000"
if test "${devtype}" = "mmc"; then
    part uuid mmc ${devnum}:${distro_bootpart} partuuid
fi
setenv bootargs "root=${rootdev} rootwait rootfstype=${rootfstype} rw ${consoleargs} loglevel=7 ubootpart=${partuuid}"

load ${devtype} ${devnum}:${distro_bootpart} ${ramdisk_addr_r} ${prefix}uInitrd
load ${devtype} ${devnum}:${distro_bootpart} ${kernel_addr_r} ${prefix}Image
load ${devtype} ${devnum}:${distro_bootpart} ${fdt_addr_r} ${prefix}dtbs/${fdtfile}

fdt addr ${fdt_addr_r}
fdt resize 65536

booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}
echo "FATAL: booti returned (kernel did not start)"

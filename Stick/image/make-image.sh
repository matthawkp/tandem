#!/bin/sh
# Runs inside the image container. /src is the project (read-only), /out is out/.
set -eu
VERSION=$(sed -n 's/.*TANDEM_DISPLAY_VERSION "\(.*\)"/\1/p' /src/receiver/tandem.h)
RELEASE=$(cat /out/kernel/kernel.release)
ROOT=/build/rootfs
STICK=/out/stick
echo "== Tandem Display $VERSION on Linux $RELEASE"

echo "== the display program"
rm -rf /build/receiver && cp -r /src/receiver /build/receiver
make -s -C /build/receiver clean
make -s -j"$(nproc)" -C /build/receiver CFLAGS="-O2 -march=x86-64-v2"
strip /build/receiver/tandem-display

echo "== the system"
umount $ROOT/proc 2>/dev/null || true
rm -rf $ROOT && mkdir -p $ROOT/proc
# The packages' install scripts run inside the new system; emulated, they need its /proc.
mount -t proc proc $ROOT/proc
apk --root $ROOT --initdb --keys-dir /etc/apk/keys --repositories-file /etc/apk/repositories --no-cache --quiet add \
    alpine-baselayout busybox musl kmod \
    mesa-dri-gallium mesa-egl mesa-gles mesa-gbm libdrm lz4-libs \
    avahi dropbear linux-firmware-amdgpu
# BusyBox's own applets as commands (sh, mount, ip, findfs, udhcpc, ...).
chroot $ROOT /bin/busybox --install -s
grep -q '^avahi:' $ROOT/etc/passwd || { echo "the avahi user wasn't created"; exit 1; }
umount $ROOT/proc
# Not needed at run time.
rm -rf $ROOT/var/cache/apk/* $ROOT/usr/share/man $ROOT/usr/share/doc $ROOT/etc/init.d $ROOT/etc/conf.d \
       $ROOT/lib/apk $ROOT/etc/apk $ROOT/usr/share/apk
# The kernel reads firmware as plain files.
find $ROOT/lib/firmware -name '*.zst' -exec zstd -q -d --rm {} +
# Only the graphics chips of the iMacs this is for (27-inch, 2014-2019, and the 21.5-inch
# Radeon ones): the rest is most of the firmware, and everything here is read from the stick
# by the Mac's firmware, slowly, on every start.
find $ROOT/lib/firmware/amdgpu -type f ! -name 'tonga_*' ! -name 'polaris1[012]_*' ! -name 'vegam_*' -delete

cp -a /src/image/rootfs/. $ROOT/
install -D -m 755 /build/receiver/tandem-display $ROOT/usr/bin/tandem-display
mkdir -p $ROOT/usr/share/tandem
gunzip -c /usr/share/consolefonts/ter-132n.psf.gz > $ROOT/usr/share/tandem/font.psf
echo "$VERSION" > $ROOT/usr/share/tandem/version

mkdir -p $ROOT/lib/modules
cp -a /out/kernel/modules/lib/modules/$RELEASE $ROOT/lib/modules/
depmod -b $ROOT $RELEASE
# Checked here, because getting it wrong looks like the 5K patch not working.
grep -q "^kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko:" $ROOT/lib/modules/$RELEASE/modules.dep ||
    { echo "modprobe amdgpu wouldn't load the patched driver"; exit 1; }

# SSH. A build for yourself lets in the key build.sh made (out/ssh), with a host key that stays
# the same from boot to boot. A release lets in nobody: SSH stays off unless whoever has the
# stick puts their own key on it as tandem/authorized_keys (see /usr/lib/tandem/boot).
mkdir -p $ROOT/root/.ssh $ROOT/etc/dropbear
chmod 700 $ROOT/root $ROOT/root/.ssh
if [ "${TANDEM_RELEASE:-}" != 1 ]; then
    install -m 600 /out/ssh/tandem_ed25519.pub $ROOT/root/.ssh/authorized_keys
    [ -f /out/ssh/host_key ] || dropbearkey -t ed25519 -f /out/ssh/host_key > /dev/null
    install -m 600 /out/ssh/host_key $ROOT/etc/dropbear/dropbear_ed25519_host_key
fi
sed -i 's|^root:.*|root:x:0:0:root:/root:/bin/sh|' $ROOT/etc/passwd

echo "   $(du -sh $ROOT | cut -f1) unpacked: $(du -sh $ROOT/usr/lib | cut -f1) libraries, $(du -sh $ROOT/lib/firmware | cut -f1) firmware, $(du -sh $ROOT/lib/modules | cut -f1) modules"

echo "== packing it"
rm -rf $STICK && mkdir -p $STICK/EFI/BOOT $STICK/tandem
( cd $ROOT && find . | sort | cpio -o -H newc --quiet ) | zstd -q -19 -T0 > $STICK/tandem/initramfs.zst
cp /out/kernel/vmlinuz $STICK/tandem/vmlinuz
# The unpatched driver, for the 4K entry only, which loads it as a second initramfs: it lands
# in /usr/lib/tandem beside everything else. Kept outside /lib/modules: anywhere in there,
# depmod may prefer it to the patched one, and then every boot gets 4K.
rm -rf /build/stock && install -D -m 644 /out/kernel/amdgpu-stock.ko /build/stock/usr/lib/tandem/amdgpu-stock.ko
( cd /build/stock && find . | sort | cpio -o -H newc --quiet ) | zstd -q -19 -T0 > $STICK/tandem/stock.zst
cp /src/image/grub.cfg $STICK/tandem/grub.cfg
cp /src/image/look.cfg $STICK/tandem/look.cfg
cp /src/image/tandem.conf $STICK/tandem.conf
cp /src/image/README.txt $STICK/README.txt
# The boot menu's picture: the waiting screen saying "Starting", drawn by the display program
# itself, at the size it draws the waiting screen on a 5K panel (GRUB stretches it to fit).
/build/receiver/tandem-display --font $ROOT/usr/share/tandem/font.psf --boot-picture $STICK/tandem/starting.tga 2560x1440
# Only the GRUB modules these menus use (and what they need), built in: without
# --install-modules every module GRUB has goes in too, and the firmware reads all of it from the
# stick before anything else happens.
modules="part_msdos part_gpt fat normal linux search search_label configfile echo test sleep regexp ls
         all_video efi_gop efi_uga video_bochs video_cirrus minicmd gfxterm gfxterm_background tga font"
grub-mkstandalone -O x86_64-efi -o $STICK/EFI/BOOT/BOOTX64.EFI \
    --modules="$modules" --install-modules="$modules" \
    --locales="" --fonts="ascii" --themes="" "boot/grub/grub.cfg=/src/image/grub-embedded.cfg"

echo "== the stick's image"
IMAGE=/out/tandem-display.img
used=$(du -sm $STICK | cut -f1)
size=$((used + 96))            # room for logs
rm -f $IMAGE && truncate -s ${size}M $IMAGE
# One FAT32 partition from 1 MiB, in an old-fashioned (MBR) partition table: what Boot Camp's
# own Windows installer sticks use, which every Intel Mac's firmware starts.
echo 'label: dos
start=2048, type=c, bootable' | sfdisk -q $IMAGE
mkfs.vfat -F 32 -n TANDEM --offset 2048 $IMAGE $(( (size - 1) * 1024 )) > /dev/null
export MTOOLS_SKIP_CHECK=1
mcopy -i $IMAGE@@1M -s $STICK/EFI $STICK/tandem $STICK/tandem.conf $STICK/README.txt ::
mdir -i $IMAGE@@1M -/ :: | grep -E 'files|bytes free' | tail -n 2
ls -la $STICK/tandem $STICK/EFI/BOOT | grep -vE '^total|^d'
echo "== done: tandem-display.img, $(du -m $IMAGE | cut -f1) MB"

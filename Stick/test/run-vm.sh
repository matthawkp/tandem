#!/bin/sh
# Inside the tandem-qemu container: starts a copy of the stick's image in an emulated PC.
# /out is the project's out/ folder, /src the project.
# KEEP=1 starts the existing out/test/vm.img again instead of making a fresh copy.
set -eu
mkdir -p /out/test
export MTOOLS_SKIP_CHECK=1
if [ -z "${KEEP:-}" ]; then
    cp /out/tandem-display.img /out/test/vm.img
    sed "s/^set default=0/set default=${ENTRY:-0}/" /src/test/grub-vm.cfg > /tmp/grub-vm.cfg
    mcopy -o -i /out/test/vm.img@@1M /tmp/grub-vm.cfg ::/tandem/grub.cfg
    # debug=all makes the display program log a checksum of every frame.
    echo "debug=all" > /tmp/tandem.conf
    mcopy -o -i /out/test/vm.img@@1M /tmp/tandem.conf ::/tandem.conf
fi
cp /out/test/ovmf/OVMF_VARS.fd /tmp/vars.fd
: > /out/test/serial.log
exec qemu-system-x86_64 -machine q35 -cpu max -smp 4 -m 4096 \
    -drive if=pflash,format=raw,readonly=on,file=/out/test/ovmf/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=/tmp/vars.fd \
    -device qemu-xhci -drive if=none,id=stick,format=raw,file=/out/test/vm.img -device usb-storage,drive=stick \
    -device virtio-vga,xres=${XRES:-1920},yres=${YRES:-1080} -display none \
    -netdev user,id=net,hostfwd=tcp::51515-:51515,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=net \
    -serial file:/out/test/serial.log -monitor tcp:127.0.0.1:4444,server,nowait

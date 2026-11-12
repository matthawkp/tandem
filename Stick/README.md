# Tandem Display for iMacs with a dead drive

A USB flash drive that turns a 27-inch 5K iMac into a display for a Mac running [Tandem], over
a Thunderbolt cable, without macOS on the iMac. It's for iMacs whose internal drive has died, or
that you'd rather not start macOS on. Nothing is installed, and the iMac's own drives are never
touched: the kernel has no driver for them, and the whole system runs from memory.

It is the display half of Tandem, rewritten in C for Linux (`receiver/`). It speaks Tandem's
own protocol, so the Mac you extend runs the ordinary Tandem app.

[Tandem]: ..

**[Download it](https://github.com/matthawkp/tandem/releases/tag/stick-1.0)**:
`Tandem-Display-iMac-1.0.zip`, the files for the flash drive.

## Which iMacs

- **Tested:** the 2019 27-inch 5K iMac with Radeon Pro 580 graphics. It shows the full
  5120×2880 picture, and the Mac's picture is on it seconds after Linux starts.
- **Should work:** the 2017 and 2019 27-inch 5K iMacs with Radeon Pro 570, 575 or 580
  graphics.
- **Untested:** the 2014 and 2015 27-inch 5K iMacs (Radeon R9). These have Thunderbolt 2, so
  they need Apple's Thunderbolt 3 (USB-C) to Thunderbolt 2 adapter.
- **Won't work:**
  - iMacs with Radeon Pro Vega graphics: the 5K patch doesn't cover them, and their firmware
    isn't on the drive.
  - The 2020 iMac and the iMac Pro: their T2 chip refuses to start from a flash drive unless
    that was allowed from macOS beforehand.

The Mac you extend needs Tandem and macOS 14 or later.

## Making the flash drive

You need any USB flash drive of 1 GB or more, and another Mac. Making the drive erases it.

1. Download `Tandem-Display-iMac-1.0.zip` and open it, which gives a folder of files.
2. Open **Disk Utility**, choose **View → Show All Devices**, and select the flash drive itself
   (the top line, not the volume under it).
3. Click **Erase** and choose these settings, then click **Erase**:
   - Name: **TANDEM**
   - Format: **MS-DOS (FAT)**
   - Scheme: **Master Boot Record**
4. Copy everything inside the downloaded folder onto the **TANDEM** drive: the `EFI` and
   `tandem` folders, `tandem.conf` and `README.txt`.
5. Eject the drive.

The same steps in Terminal, with the drive's number from `diskutil list` in place of N:

    diskutil eraseDisk FAT32 TANDEM MBRFormat /dev/diskN
    cp -R ~/Downloads/Tandem-Display-iMac-1.0/ /Volumes/TANDEM/
    diskutil eject /dev/diskN

The release also has `tandem-display-imac-1.0.img.zip`, a whole-drive image, for
balenaEtcher or `dd`.

## Using it

1. Plug the flash drive into the iMac.
2. Hold **Option (⌥)**, switch the iMac on, and keep holding until the startup disks appear.
   Choose **EFI Boot**.
3. Join the two Macs with a Thunderbolt cable, open Tandem on the Mac you want to extend, and
   choose **Extend This Mac**. The iMac shows up in the list as "iMac".
4. To shut the iMac down, press its power button.

While it starts, the screen shows "Tandem Display", then the Mac's picture.

If choosing **EFI Boot** goes straight back to macOS, the iMac still has a working macOS. Start
macOS, then restart holding Option and choose **EFI Boot** again; that way works. (Why the
iMac's firmware does this only when switched on from cold isn't known yet.)

A USB keyboard and mouse plugged into the iMac control the Mac while it shows a picture, if
**Use iMac Keyboard and Mouse** is on in Tandem's menu. A Magic Keyboard should work plugged in
by its cable (untested).

### Settings and logs

Settings are in `tandem.conf` on the flash drive, explained inside it, and editable on any
computer.

Each start writes its logs to `tandem-logs/boot-N/` on the drive:

| File | What's in it |
|---|---|
| `boot.txt` | Startup |
| `display.txt` | The display program |
| `kernel.txt` | The kernel's messages |
| `system.txt` | What the machine is and what state it's in |

There's no boot menu: the iMac goes straight to the 5K entry. If that goes wrong, change
`default` in `tandem/grub.cfg` on the drive to use one of the other entries:

| Entry | What it does |
|---|---|
| 0, 5K | The patched graphics driver: the panel's full 5120×2880. |
| 1, 4K | The same driver unpatched: the panel in its 3840×2160 compatibility mode. |
| 2, Fault finding | No graphics driver: the firmware's own framebuffer, drawn by the processor. It's slow, and shows what's happening. |

### Looking inside while it runs

SSH over the cable is off unless there's a key to let in. To turn it on, copy a public key onto
the drive as `tandem/authorized_keys`. Then connect with:

    ssh root@tandem-display.local

A build of your own (below) lets in the key it made, `out/ssh/tandem_ed25519`. To turn SSH off
either way, set `ssh=no` in `tandem.conf`.

## What isn't there

- Peeking through to the iMac's desktop, dragging files across, the iMac's settings in the
  Mac's menu, swapping roles, and Tandem Camera all need macOS under the picture.
- Bluetooth keyboards and mice (nothing pairs them), and trackpads.

## Building

    ./build.sh            # out/tandem-display.img and out/stick/, with an SSH key for you
    ./build.sh release    # the same with no key built in, as released
    ./build.sh kernel     # the kernel again as well (ten minutes or so)

The build needs Docker (colima is enough). Everything is built in containers: the kernel is
cross-compiled, and the rest is put together in an emulated x86-64 Alpine.

| Folder | What's in it |
|---|---|
| `receiver/` | The display program. `output.c` drives the panel, `render.c` draws, `splash.c` is the waiting screen, `net.c` and `main.c` are the protocol, and `input.c` is the keyboard and mouse. |
| `kernel/` | Linux 7.3.4's settings (`tandem.config`), the 5K patch, and how the kernel is built. |
| `image/` | The startup scripts (`rootfs/`), boot menu, settings file, and how the drive is put together. |
| `test/` | `headless.sh` is the streaming test. `run-vm.sh` runs the image in an emulated PC. `watch-imac.sh` records a running iMac over the cable. |

## Credits and sources

- **The 5K patch:** `kernel/patches/iMac5K-7.3.0.patch` is from
  [taprobane99/iMac5KLinux](https://github.com/taprobane99/iMac5KLinux) (MIT), unmodified. It
  wakes the second half of the panel, so Linux can drive it as two 2560×2880 halves.
- **The system:**
  - Alpine Linux 3.24, with Mesa, Avahi, Dropbear, BusyBox and GRUB.
  - The kernel is Linux 7.3.4 (GPL-2.0), built from kernel.org's source with the patch and
    settings in `kernel/`. The packages' sources are Alpine's.
  - The waiting screen's font is Terminus (OFL).

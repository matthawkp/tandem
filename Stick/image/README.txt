Tandem Display
==============

This flash drive turns a 27-inch 5K iMac into a display for another Mac running Tandem, over a
Thunderbolt cable, without macOS on the iMac: for iMacs whose own drive has died. Nothing is
installed and the iMac's own drives are never touched: the whole system runs from memory.

To use it
  1. Plug this drive into the iMac. Hold the Option key, switch the iMac on, and keep holding
     until the startup disks appear.
  2. Choose "EFI Boot".
  3. Join the two Macs with a Thunderbolt cable, open Tandem on the Mac you want to extend and
     choose Extend This Mac.

The iMac's power button shuts it down.

If choosing "EFI Boot" goes straight back to macOS (an iMac that still has macOS): start
macOS, then restart it holding Option and choose "EFI Boot" again.

A USB keyboard and mouse plugged into the iMac control the other Mac while it's showing a
picture (a Magic Keyboard should too, plugged in with its cable).

On this drive
  tandem.conf    settings: a text file, explained inside
  tandem-logs/   what happened each time it started, the newest with the highest number
  tandem/        the system itself, and grub.cfg, the boot menu
  EFI/           what the iMac's firmware starts

If the screen stays black or looks wrong: change "default" in tandem/grub.cfg (on any
computer) to 1 for the 4K picture, or 2 for fault finding, start the iMac again, and look in
tandem-logs.

More: https://github.com/matthawkp/tandem/tree/main/Stick

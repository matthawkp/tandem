# Tandem

Two Macs joined by a Thunderbolt cable, working as one. One Mac uses the other's screen as a
sharp, native-feeling extra display, along with its keyboard, mouse and camera, and the other is
still a Mac whenever you need it: peek through the picture to its own desktop, and drag files
back across.

It began as a way to use a 5K iMac as a Retina display for a MacBook, but either Mac can play
either part.

**[Download the latest release](../../releases/latest)**: signed and notarised, free.

## What it does

Described for the common case, a MacBook extending onto an iMac.

- **A real Retina display.** A virtual display sized to the iMac's panel, with the usual "looks
  like" resolutions in System Settings, streamed at the panel's native resolution, pixel for
  pixel. Arrangement and window positions are remembered.
- **Lossless when still.** Frames are compared on the GPU in 128×32 tiles and only changed tiles
  are sent: losslessly (LZ4) whenever the link can carry them at 60 fps. When it can't
  (full-screen video, fast scrolling), tiles that keep changing go as BC7, encoded on the
  MacBook's GPU and decoded on the iMac's at a quarter of the size, and are resent losslessly
  once they stop, so anything still is always pixel-perfect.
- **The pointer moves at once.** The iMac draws the MacBook's pointer itself, from position and
  shape messages, so moving it sends no frames.
- **The iMac's keyboard and mouse.** Click on the iMac and its keyboard and mouse control the
  MacBook across both screens; press and let go of ⌃⌥ to give them back.
- **Peek through.** Hold ⌃⌥ on either Mac's keyboard and a bubble opens through the picture to
  the iMac's own desktop, following the pointer. Click, open folders and pick files through it.
  Add ⌘, or double-click the wallpaper, to step through and use the iMac, with either Mac's
  keyboard and mouse; a quick ⌃⌥ comes back.
- **Bring files across.** Drag a file or folder out of the bubble and let go on the MacBook's
  picture: it's copied over the cable into the Finder window, folder or desktop spot you let go
  on.
- **Brightness.** The iMac follows the MacBook's brightness, including auto-brightness, and the
  brightness keys change whichever screen the pointer is on.
- **True Tone and Night Shift.** The MacBook's colour adaptation is applied to the iMac's picture
  on its GPU, so the two screens match.
- **Tandem Camera.** One virtual camera for FaceTime, Zoom and Teams that shows whichever camera
  you're facing. Vision measures how head-on each camera sees your face, and it switches only when
  the other is clearly better, for a while, and not too soon after the last switch, with a short
  crossfade. Tandem does the switching; the camera extension (`Camera/`) relays it to apps.
- **Sleeps and wakes together, like a monitor.** Only the iMac's screen sleeps: a sleeping iMac
  drops off the Thunderbolt link and couldn't be woken over it. Both Macs can open Tandem at login,
  and the iMac can start up after a power cut.
- **Swap roles** from either Mac's menu, and the iMac's settings appear in the MacBook's menu.

## Requirements

- Two Macs and a **Thunderbolt** cable (not a USB-C charge cable). 2014–15 5K iMacs need Apple's
  Thunderbolt 3 to Thunderbolt 2 adapter.
- The Mac you extend: macOS 14 Sonoma or later. The display Mac: macOS 11 Big Sur or later.
- Permissions, asked for at setup: Screen Recording (needed), Accessibility (keyboard, mouse,
  brightness keys, peeking), Camera (Tandem Camera), and control of the Finder (placing files
  brought across).

Install `Tandem.app` on both Macs, open it, and choose each Mac's role; it suggests one.

## How it's built

One universal app (Apple silicon and Intel) with two roles:

- **Extend** (`Sender/`, a menu bar app): creates the virtual display, captures it with
  ScreenCaptureKit, diffs and encodes tiles, and replays the other Mac's keyboard and mouse.
- **Display** (`Receiver/`, full screen): advertises itself over Bonjour, draws what arrives with
  Metal, and owns the peek (`Receiver/PeekSession.swift`).
- `Shared/` holds the wire protocol (`Wire.swift`: length-prefixed messages over one TCP
  connection), file transfer, permissions and the event tap.

Code in `Sender/` is marked `@available(macOS 14, *)`; the rest builds for macOS 11, and the
camera extension for 12.3.

Tandem can't go on the Mac App Store: it relies on private frameworks the store doesn't allow,
CGVirtualDisplay to create the display (there's no public API for that), DisplayServices for
brightness and CoreBrightness for True Tone.

### Security

Tandem only talks over the Thunderbolt Bridge, the cable between the two Macs: connections from
any other network, or from other apps on the same Mac, are refused. The link itself isn't
encrypted or authenticated, so anything plugged into the other end of the cable is trusted.

## Building from source

Needs Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and an
Apple Developer account: the camera extension needs Apple-issued signing.

1. Put your team ID (developer.apple.com → Membership) in `Support/team`, and a bundle identifier
   of your own in `Support/bundle-id` (otherwise `com.example.tandem`). Both are git-ignored.
2. `./build.sh` builds `build/Tandem.app` with Apple Development signing, which runs on Macs
   registered to your team.
3. `./release.sh` signs with Developer ID, has Apple notarise it and packs `build/Tandem.dmg`;
   save the notarisation password first, as described at its top.

`Tools/make-icons.sh` draws the icon; `Tools/bc7check.sh <image>` measures BC7 quality and speed.

### Testing without a second Mac

```sh
TANDEM_DEBUG=1 TANDEM_HASH_ALL=1 build/Tandem.app/Contents/MacOS/Tandem --windowed 5120x2880 --port 51600 &
TANDEM_DEBUG=1 build/Tandem.app/Contents/MacOS/Tandem --synthetic --host 127.0.0.1 --port 51600
```

`--synthetic` streams a moving test pattern instead of capturing the screen; `--windowed` runs the
display in a window (and accepts local connections). With `TANDEM_DEBUG`, both sides log image
hashes. More switches for the extending side:

- `TANDEM_NOISE=1`: full-screen incompressible noise, the worst case.
- `TANDEM_LINK_GBIT=2`: pretend the link is that fast, to force BC7.
- `TANDEM_STILL_AFTER=120`: freeze the pattern after that many frames; both sides' hashes for the
  sharp frame should then match.
- `TANDEM_STRESS=1`: resend the whole frame every time.
- `TANDEM_CHECK_DIFF=1` / `TANDEM_CPU_DIFF=1`: check, or replace, the GPU tile comparison on the
  CPU.

Logs are in `~/Library/Logs/Tandem.log`.

## Licence

MIT: see [LICENSE](LICENSE).

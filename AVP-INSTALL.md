# Installing Xbawks on Apple Vision Pro

Xbawks is an original Xbox emulator that runs on the headset itself. It is a port of [xemu](https://github.com/xemu-project/xemu) (a fork of QEMU) with a visionOS shell around it. It ships no Microsoft code and no game data.

**Want to see it running before you build it? [Watch the promo ad](https://youtu.be/AnmeuEjDdMU) -- the emulator on a real Vision Pro, played with PSVR2 Sense controllers or a PS4 controller over Bluetooth.**

## Requirements

- Apple Vision Pro on visionOS 26 or later
- A Mac with Xcode 27 or later (built and tested with 27.0), on the same network as the headset
- An Apple ID. A free developer account works; its signing profile lasts seven days, after which you sign and install again
- [Apparition](https://apparition.illixion.com) on the Mac, paired with the headset (tested with 1.0.0 and 0.4.5). **It is required at every launch**, not just the first (see JIT, below)
- A game controller: a pair of PSVR2 Sense controllers, or a PS4 controller (or another extended gamepad) over Bluetooth
- Your own console's files and your own discs (see Game files)
- About 7 GB of free disk on the Mac for the source and the build

### JIT

visionOS does not let an app make its own memory executable, and an emulator's JIT needs exactly that. Xbawks allocates its code buffer at launch and asks a debugger to prepare it, using the `brk #0x69` request. Apparition answers that request: it attaches for about two seconds, prepares the buffer, and detaches, and the emulator runs on its own from then on. Debugger tools that only answer other JIT requests will not start it. Without a debugger the emulator refuses to start and says why in its log.

Tested with Apparition 1.0.0 and 0.4.5. The first launches after installing 1.0.0 hung twice at the app's window; every launch since has started normally. If a launch hangs, end it with Ctrl-C and run `apparition jit` again.

### Memory

The build is not signed with the Increased Memory Limit entitlement, because a free profile can't carry it. Most titles sit between 4 and 4.7 GB. The heaviest I have measured, before later fixes brought it down, reached about 8 GB before the system ended it.

## Game files

You need to supply your own files, from a console and discs you own. This repository contains none, and no build of it downloads any.

- An MCPX boot ROM, named `mcpx-1.0.bin`
- A BIOS image, named `bios.bin`
- An Xbox hard disk image in qcow2 format, named `xbox_hdd.qcow2` (it holds your saves)
- Your disc images, as `.iso`

After the first install, open the Files app on the headset and find the XBAWKS folder under On My Apple Vision Pro. Put the three system files in it, with exactly those names, and your disc images in the `GAMES` folder inside it, which the app creates on its first launch. The app reads them from there at every launch.

## Build

Start from a checkout of this repository, on an Apple Silicon Mac. All commands run from its root.

You need Xcode with the visionOS platform added (Settings, Components), and `cmake` 3.28 or later, `ninja`, `pkg-config`, `python3` and `gh` on your `PATH`. With Homebrew:

```sh
brew install cmake ninja pkg-config python gh
gh auth login
```

`gh` needs to be logged in because GitHub only hands out the sysroot artifact below with a token, even though it is public. Everything fetched or built lands in ignored folders inside the checkout, about 7 GB, and every step but the last needs the network.

```sh
tools/setup-tree.sh --clone               # upstream xemu at the pinned commit, plus this repo's patches (3 GB)
tools/xros/fetch-sysroot.sh               # UTM's visionOS sysroot: glib, MoltenVK and the rest
tools/xros/build-glslang.sh device        # Vulkan shader compiler
tools/xros/build-sdl3.sh                  # audio and input
tools/xros/build-samplerate.sh            # audio resampling
tools/xros/gen-cross.sh device            # cross compile settings
tools/xros/configure-xemu-xros.sh -Ddsp_jit=disabled
ninja -C third_party/xemu/build-xros qemu-system-i386
XEMU_BUNDLE_ID=com.yourname.xbawks tools/xros/make-app.sh
```

The repository holds a pinned upstream commit and a patch series rather than a copy of QEMU, which is why the first step clones xemu. The sysroot comes from UTM, which publishes it as a public GitHub Actions artifact; artifacts expire after 90 days, and `fetch-sysroot.sh` takes the newest one. The three library builds fetch their own sources at pinned revisions.

`com.yourname.xbawks` stands for a bundle ID of your own: a free developer account can't sign the app under mine. The last step produces `build-app/Xbawks.app`, with no system files or games inside it.

## Install on Apple Vision Pro

1. Turn on Developer Mode on the headset (Settings, Privacy & Security), and pair it with the Mac in Xcode once (Window, Devices and Simulators).
2. Give Xcode a signing profile for your bundle ID: create any visionOS app project in Xcode with that bundle ID, set your team, and run it on the headset once. `sign-install.sh` finds the profile Xcode stores. With a free account it lasts seven days; run that project again to renew it.
3. Pair Apparition with the headset, with Settings, General, Remote Devices open on it:

   ```sh
   apparition pair
   ```

4. Sign and install:

   ```sh
   tools/xros/sign-install.sh
   xcrun devicectl device install app --device <device id> build-app/Xbawks.app
   ```

   `xcrun devicectl list devices` shows the device id.
5. Launch through Apparition, every time:

   ```sh
   apparition jit com.yourname.xbawks
   ```

   The app opens on the headset; Apparition attaches, prepares the JIT buffer and detaches, and the app runs on its own from then on.
6. On the first launch, add your files (see Game files), then launch again.

## Controls and known issues

- Sticks, face buttons and analog triggers map to the Xbox controller.
- Press or pinch the Xbox in the room to bring up your discs; picking one resets the console and boots it, as the hardware would.
- If a launch sits at "Launching" and Apparition never attaches, the headset's debug service has wedged; restarting the headset clears it.
- An optional file named `surface-scale` in the app's folder, containing `2` or `3`, raises the internal resolution. It suits titles with headroom, such as Doom 3; leave it out for native 640x480.
- Per-title results, including what does not work yet, are in the compatibility table in the [README](README.md).

# Building for visionOS

These scripts produced the first `qemu-system-i386` for
`arm64-apple-xros`, 2026-10-24.

The **sysroot is not in this repo**: it is 1.5 GB and it is not ours. It
lives in `_scratch/xros-sysroot/` and the scripts expect it there. If it is
missing, fetch it again, see below.

## Order

```sh
./relocate-sysroot.sh                     # after any fresh sysroot download
./build-glslang.sh device                 # Vulkan shader compiler
./build-sdl3.sh                           # audio and input, leaves with S4
./build-samplerate.sh                     # APU resampling, leaves with S4
./gen-cross.sh device                     # writes the two cross files
XEMU_TREE=<tree> ./configure-xemu-xros.sh -Ddsp_jit=disabled
cd <tree>/build-xros && ninja qemu-system-i386
```

## Getting the sysroot

UTM builds one on every push to `main` and publishes it as a public
GitHub Actions artifact. **Artifacts expire after 90 days.**

```sh
gh api "repos/utmapp/UTM/actions/artifacts?per_page=100" \
  --jq '.artifacts[] | select(.name=="Sysroot-visionos-arm64" and .expired==false)
        | "\(.id)\t\(.created_at)\t\(.size_in_bytes)"'
gh api repos/utmapp/UTM/actions/artifacts/<ID>/zip > s.zip
```

It carries glib, slirp, pixman, libffi, iconv, intl and MoltenVK.framework.
zlib is not needed: the XROS SDK ships `libz.tbd`.

Every `.pc` in it hardcodes a GitHub runner path, and every bare dylib
carries that path as its install name, so `relocate-sysroot.sh` must run
before anything else. Two traps it handles: several `.pc` files are symlinks
and `sed -i ''` refuses them, and `install_name_tool` follows the
unversioned `libfoo.dylib` symlinks, which would give the real file an
unversioned id while its siblings reference the versioned name.

## Why two cross files

Meson merges cross files left to right, but a later `[built-in options]`
section **replaces** the earlier one rather than appending. QEMU's configure
writes `config-meson.cross` with `--extra-cflags` baked into `c_args`,
including `-DXBOX=1`. A full cross file layered on top silently discards all
of it, and the symptom is thousands of compile errors minutes later rather
than a configure failure. So: a standalone file for building libraries, and
a properties-only file for layering onto QEMU's.

`system` must be `darwin`, not `ios`. QEMU has many `host_os == 'darwin'`
branches that `ios` loses quietly.

## From a binary to a running app

```sh
tools/xros/make-app.sh          # rebuilds, assembles build-app/XemuHost.app, copies media
tools/xros/sign-install.sh      # signs with the first Apple Development identity in the keychain
xcrun devicectl device install app --device <udid> build-app/XemuHost.app
apparition jit <bundle id>      # launches; attaches, prepares the JIT buffer, detaches
```

### Media is opt in, and a bundle holding it will not become an IPA

The app cannot boot without an MCPX boot ROM, a BIOS image and a hard disk
image, so a device run needs them inside the bundle. That is also precisely
what makes such a bundle undistributable, since it would carry Microsoft
firmware and, with a disc image, somebody's game.

So nothing is copied unless you name it:

```sh
XEMU_MEDIA=~/path/to/media \
XEMU_GAME="~/path/to/Some Game.iso" \
  tools/xros/make-app.sh
```

`XEMU_MEDIA` is a folder holding the MCPX ROM as `mcpx-1.0.bin`, a BIOS image
as any other `.bin`, and `xbox_hdd.qcow2`. `XEMU_GAME` is a single disc image,
optional; without it the machine boots the dashboard.

With neither set, the build produces a clean app and an IPA and copies no
media at all. **With either set, the IPA step refuses and deletes any stale
IPA**, because an IPA is the shape that gets uploaded. Install the `.app`
directly for a device run, which is what `sign-install.sh` and
`devicectl device install app` do anyway.

None of these files is in the repository and none of them should be.

The provisioning profile comes from Xcode. On a free account it lasts seven
days; `DEV_TEAM=<team id> make device` in `probes/jit-probe` refreshes it, and
`sign-install.sh` picks up whatever matching profile is on disk, exact or team
wildcard. The bundle id has to be one a profile exists for.

Apparition attaches once and detaches; the app runs on its own afterwards. If
a launch sits at "Launching" and never attaches, the headset's debug service
has wedged and a reboot clears it. Keep Tailscale off on the Mac while
pairing: it takes the LAN route and every connection to the headset times
out.

Logs land in the app's `Documents/host.log`, readable with
`devicectl device copy from`.

# Building for visionOS

These scripts produced the first `qemu-system-i386` for
`arm64-apple-xros`, 2026-10-24.

The **sysroot is not in this repo**: it is 1.5 GB and it is not ours. It
lives in `tools/xros/sysroot/`, which is ignored, and every script reads it
from there, or from `XROS_SYSROOT` if that names another folder holding the
same `lib/`, `include/` and `Frameworks/`. `fetch-sysroot.sh` puts it there.

## Order

From the repository root, on an Apple Silicon Mac. You need Xcode with the
visionOS platform added (Settings, Components), and `cmake` 3.28 or later,
`ninja`, `pkg-config`, `python3` and `gh` on `PATH`; with Homebrew that is
`brew install cmake ninja pkg-config python gh`. Run `gh auth login` once:
GitHub will not hand out even a public artifact without a token. Everything
fetched or built lands in ignored folders under `tools/xros/` and
`third_party/`, about 7 GB, and every step but the last needs the network.

```sh
tools/setup-tree.sh --clone               # upstream xemu at the pin, plus the series (3 GB)
tools/xros/fetch-sysroot.sh               # UTM's sysroot, unpacked and relocated
tools/xros/build-glslang.sh device        # Vulkan shader compiler
tools/xros/build-sdl3.sh                  # audio and input, leaves with S4
tools/xros/build-samplerate.sh            # APU resampling, leaves with S4
tools/xros/gen-cross.sh device            # writes the two cross files
tools/xros/configure-xemu-xros.sh -Ddsp_jit=disabled
ninja -C third_party/xemu/build-xros qemu-system-i386
tools/xros/make-app.sh                    # build-app/Xbawks.app and Xbawks.ipa, no media
```

The three library builds fetch their own sources at pinned revisions into
`tools/xros/src/`. `configure-xemu-xros.sh` works on `third_party/xemu`
unless `XEMU_TREE` names another tree.

## Getting the sysroot

UTM builds one on every push to `main` and publishes it as a public
GitHub Actions artifact. **Artifacts expire after 90 days.**
`fetch-sysroot.sh` takes the newest one that has not expired. By hand, it
is this, then unzip, untar the `sysroot.tgz` inside, and run
`relocate-sysroot.sh` on the folder that holds `lib/`:

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
tools/xros/make-app.sh          # rebuilds, assembles build-app/Xbawks.app; media only if named
tools/xros/sign-install.sh      # signs with the first Apple Development identity in the keychain
xcrun devicectl device install app --device <udid> build-app/Xbawks.app
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

The provisioning profile comes from Xcode's own store on the Mac.
`sign-install.sh` takes an exact profile for the bundle id if one exists,
and otherwise the team wildcard, rewriting the signed application
identifier to the real bundle id because installd refuses an upgrade whose
identifier does not match the installed app. A paid team profile lasts a
year; a free account's lasts seven days and is refreshed by building any
app with that bundle id in Xcode.

The bundle id defaults to `com.acervantez.xbawks`. `XEMU_BUNDLE_ID=<id>`
overrides it for one build. That matters on a headset that already holds
the BIOS, the discs and the hard disk image with its saves: those live in
the app's data container, a different bundle id is a different app with an
empty container, and nothing migrates one to the other. Build against the
old id until the files have been moved across in Files, then switch.

Apparition attaches once and detaches; the app runs on its own afterwards. If
a launch sits at "Launching" and never attaches, the headset's debug service
has wedged and a reboot clears it. Keep Tailscale off on the Mac while
pairing: it takes the LAN route and every connection to the headset times
out.

Logs land in the app's `Documents/host.log`, readable with
`devicectl device copy from`.

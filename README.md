# abipak

A packaging format for Linux applications that works on any distribution, is made for
portable apps, has optional sandboxing, and relies on the host's ABI instead of shipping a
runtime: an app states the ABI it needs, and the system is probed for it and, where
something is missing, given it from the distribution's own packages.

Status: an idea (2026-11-01, direction updated 2026-11-09), with a first prototype of
measure and probe (2026-11-10, see "The prototype"). This document collects what the
format should be and the problems it has to solve. The first
parts are to be built as a small tool for one real app, the MultiMC Launcher (see "First
steps").

## Why

Making a Linux app run on many distributions comes down to a few options today:

- **Flatpak, Snap:** ship a runtime (or a base snap) with the app, and make the sandbox
  central. The app no longer depends on the host's libraries, at the price of downloading
  and updating whole runtimes, and of fitting the app into the sandbox.
- **AppImage:** one portable file, sandboxing optional. In practice it bundles most of a
  runtime too (the toolkit and usually much more) and relies only on the host's glibc, by
  being built on an old distribution. It needs FUSE to mount itself.
- **A plain directory built on an old system:** what many apps do by hand. It works, but
  nothing says what it needs from the host, so when it doesn't fit the user gets a
  "symbol not found" crash instead of an explanation.

abipak takes the last approach and makes it a format: the app declares exactly what it
needs from the host, the declaration is measured from the binaries rather than written by
hand, and it is checked before anything runs.

What an app needs, in the end, is specific ABI: these libraries, with these symbol
versions. Every packaging system names it differently (package names, versions,
runtimes), but the distribution usually has all of it already installed, or a command away.
So abipak asks for ABI, not for package names, and lets the distribution supply it.

## Goals

- **Independent of distributions.** One package for every distribution that meets its
  requirements.
- **Portable apps.** An app is a directory (or one file) that can be put anywhere, run
  from anywhere, and removed by deleting it. No installer, no root.
- **ABI compatibility, not runtimes.** The app uses the host's libraries. What the host
  lacks is found in the distribution's packages and installed, with the user's consent;
  bundling is the fallback for what a distribution can't provide, not the default.
- **Measured requirements.** What an app needs from the host is read from its binaries by
  the build tool, never written by hand.
- **Checked before running.** When the host doesn't meet the requirements, the user is told
  what is missing ("needs glibc 2.17, this system has 2.12"), and nothing is started.
- **Optional sandboxing.** An app can come with a sandbox profile. Whether it runs
  sandboxed is up to the user and the packager, not forced by the format.
- **Inspectable.** The manifest is plain text, the package is plain files, and every tool
  (measure, check, run, sandbox) can be run on its own.

## Non-goals

- Replacing distribution packages for system software.
- Shipping a runtime or a base system.
- Bundling the C library or the graphics drivers.
- Making the sandbox mandatory.

## The package

A directory, optionally packed into a single file:

    MyApp.abipak/
        abipak.toml        the manifest
        bin/, lib/, ...    the app and the libraries it bundles
        share/             icons, desktop files, data

### The manifest

Written by the build tool, readable by people:

- **Architecture** and the **ELF interpreter** (for example `/lib64/ld-linux-x86-64.so.2`).
- **Host requirements:** each library expected from the host by soname, with the highest
  symbol version the app's binaries actually use, for example `libc.so.6` at GLIBC_2.17
  and `libstdc++.so.6` at GLIBCXX_3.4.21. Read from the binaries: the `DT_NEEDED`
  entries and the version references in `.gnu.version_r`.
- **Bundled libraries:** everything not in the host baseline (below), with hashes.
- **Entry points:** the commands the app provides.
- **Desktop integration:** desktop files, icons, MIME types.
- **Data:** next to the app (portable) or in the XDG directories.
- **Sandbox profile** (optional): network, home folder or parts of it, devices, display
  (Wayland, X11), audio.

### The launcher

A small static binary, so it runs on any host whatever its libraries. It:

1. reads the manifest;
2. checks the host: finds each required library (the `ld.so` cache, then the usual paths)
   and reads the symbol versions it defines (`.gnu.version_d`); stops with a clear message
   if something is missing or too old;
3. picks the newer of bundled and host copies where that matters (see libstdc++ below);
4. sets up the library path and data directories;
5. starts the app, inside bubblewrap with the app's profile if sandboxing is wanted and
   available.

## The host baseline

The set of libraries an app may expect from the host instead of bundling them. Kept small:

- the C library (glibc): it can't sensibly be bundled; its version is the app's floor;
- the graphics stack (Mesa, OpenGL and Vulkan drivers): it has to match the host's kernel
  and hardware, so it must come from the host;
- the display client libraries (Wayland, X11) and the audio libraries (ALSA, PulseAudio,
  PipeWire).

The Linux Standard Base tried to define such a baseline and failed: it was large, froze
versions, and nobody had a reason to follow it. abipak avoids promising a standard: the
baseline is only what may stay unbundled, and every app states the exact versions it
needs, measured.

## The tools

Each step is a tool of its own, runnable and inspectable by itself:

1. **measure** (where the app is built): read the app's ELF files and write its
   requirements: the architecture, the ELF interpreter, the libraries each binary links
   (`DT_NEEDED`), and per library the highest symbol version node used
   (`.gnu.version_r`).
2. **probe** (on the host): find each required library the way the dynamic loader would (the
   `ld.so` cache, then the default paths) and read the version nodes it defines
   (`.gnu.version_d`). Nothing from the libraries runs, so a static binary can do it. Once
   the app is there, the host's own loader can be asked to resolve its real binaries (what
   `ldd -r` does), the definitive "does it load here", still without loading anything into
   the tool's process.
3. **resolve:** turn what's missing into a plan of distribution packages. It only prints
   the plan.
4. **install** (optional, with the user's consent): carry out the plan through the
   distribution's package manager (with `pkexec`, or through PackageKit), or show the
   command to run.
5. **fetch and deploy:** download the app, verify it (signed documents, content files by
   SHA-256, mirrors) and put it in place, in the user's directories.
6. **run:** start it.

### How it feels to use

Like an AppImage, though built differently:

- **One file.** Download it, make it executable, run it. No installer, no root.
- **The first run does the work:** probe, fetch, deploy, run. Later runs start the app
  straight away, offline too.
- **Portable or installed, by the file's name.** If the name it was started as (`argv[0]`,
  so a symlink works too) contains the word "portable" (case doesn't matter, as a whole
  word: `MyApp-portable`, `MyApp-Portable (1)`, not `notportable`), the app and its data live
  next to it; otherwise in the user's XDG directories. Renaming the file is how a user
  switches, from any file manager; a double-click can't pass flags. An app already deployed
  next to the file wins over the name, so renaming never makes a user's data seem gone.
- **Desktop integration on request:** the first run offers a menu entry and icon pointing
  at the file, and every run updates the entry, so moving the file doesn't leave a broken
  one behind.
- **Its own options under a prefix,** like AppImage's `--appimage-*`: `--abipak-check` only
  probes and reports, `--abipak-info` says what it is, where the app and its data are and
  why (which mode, and what decided it). Every other argument goes to the app.
- **Explaining without a toolkit.** The runtime is static and can't load a GUI toolkit: it
  prints in a terminal, otherwise uses `zenity` or `kdialog` where present, and a desktop
  notification as the last resort.

Inside, the file is the generic runtime with a small app descriptor appended: the app's
name and icon, where its signed tree is, the pinned root keys. Not the app itself: that is
fetched and updates itself. The same runtime serves any app; only the descriptor changes.

### Distributions already speak ABI

The resolver translates "this soname with this version node" into each package manager's
own question; no database of its own is needed:

- **RPM** (Fedora, openSUSE, RHEL): packages get ABI provides automatically, such as
  `libQt5Widgets.so.5()(64bit)` and `libc.so.6(GLIBC_2.17)(64bit)`, so
  `dnf install 'libQt5Widgets.so.5()(64bit)'` already asks for ABI.
- **Debian, Ubuntu:** which package has a library is in the archive's Contents index (what
  `apt-file` reads); symbol versions per package are in its `.symbols` files.
- **Arch:** the files database (`pacman -F`).
- **PackageKit:** a common layer (`what-provides`, install) over the above, as good as each
  backend's support.

### Language

Zig: small static binaries for every architecture from one machine, and Ed25519 and SHA-256
in its standard library. A static binary runs whatever the host's libraries, which is the
point of a tool that checks them.

## Hard problems

- **libstdc++ and libgcc_s.** An app that bundles a newer libstdc++ than the host's
  clashes with the host's graphics drivers, which load the host's libstdc++ (Mesa uses
  LLVM). The known fix is to use whichever copy is newer, decided at start-up; AppImage's
  checkrt and the Steam Runtime do this. abipak does it in the launcher, not in each
  package.
- **One file without FUSE.** Mounting an image (squashfs, erofs) needs FUSE or user
  namespaces, and some systems have neither. The directory is the main form; a single file
  is either mounted where possible or extracted into a cache keyed by its content hash.
- **Desktop integration without an installer.** Menu entries and MIME types for an app
  that is just a directory: either the launcher registers them on first run, or a small
  optional helper does.
- **Measuring correctly.** Symbol versions cover glibc and libstdc++ well; libraries
  without symbol versioning only give a soname, so the build tool needs another way to
  state a minimum version for them (for example a known symbol that appeared in it).

## Updates

Updates fit the format naturally: a signed manifest per version, files identified by
content hash (so an update only downloads what changed), any number of mirrors, and the
host requirements checked before an update is offered. A machine that no longer meets a
new version's requirements stays on the version it has and says why.

This follows the design of the MultiMC updater overhaul
([Updater.md](https://github.com/MultiMC/Design/blob/master/Updater.md)).

## Prior art

- **Steam Runtime and pressure-vessel:** the closest in philosophy. Graphics stack from
  the host, everything else from a container; it has solved the libstdc++ and driver
  problems at scale.
- **AppImage:** the portable single-file experience, and its lessons with FUSE and
  libstdc++.
- **Linux Standard Base:** why a declared host baseline failed.
- **Flatpak portals:** what an optional sandbox needs to stay usable (file choosers,
  opening links).
- **systemd portable services:** an image plus optional confinement, for services.

## The prototype

`measure` and `probe` exist (2026-11-10), in Zig (`src/`, `zig build` with Zig 0.17; the
release build is a 250 KB static binary):

    zig-out/bin/abipak measure <directory>                 requirements, as JSON
    zig-out/bin/abipak probe [--root DIR] <requirements>   met or not, and what's missing

`measure` reads every ELF file in the app's directory through its program headers, as the
loader does: the architecture, the interpreter, the libraries linked (`DT_NEEDED`) and the
symbol version nodes needed from each (`DT_VERNEED`). Libraries the app brings itself (a
file or link of that name in the directory, or a `DT_SONAME`) aren't requirements. Weak
version references aren't either, and a private API (`Qt_5_PRIVATE_API`) is a warning:
it needs exactly the version the app was built with, which version nodes can't say.

`probe` finds each library as the loader would (its cache `/etc/ld.so.cache`, then the
usual directories, the first file of that name with the app's architecture), reads the
version nodes it defines (`DT_VERDEF`) and checks every one the app needs. Nothing is
loaded or run. Not followed yet: `DT_RUNPATH`, `LD_LIBRARY_PATH`, and what the libraries
found need themselves.

### The requirement format

    {
      "format": 1,
      "arch": "x86_64",
      "interpreter": "/lib64/ld-linux-x86-64.so.2",
      "libs": [
        {"soname": "libQt5Core.so.5", "versions": ["Qt_5", "Qt_5.6"]},
        {"soname": "libc.so.6", "versions": ["GLIBC_2.2.5", "GLIBC_2.3", "GLIBC_2.3.4", "GLIBC_2.4", "GLIBC_2.14"]},
        {"soname": "libz.so.1", "versions": []}
      ]
    }

- **Every version node needed, not only the highest.** That's exactly what the loader
  checks, so checking needs no knowledge of how a library numbers its versions (libstdc++
  has two families, `GLIBCXX_` and `CXXABI_`; Qt's minor-version nodes are empty markers).
  The highest of each family is worked out only for messages ("lacks Qt_6.8").
- **A library without symbol versions** has an empty list: finding it is all that can be
  checked.
- **The architecture and the interpreter** are part of it: a 32-bit app on a system
  without 32-bit libraries is missing its interpreter first of all.
- **Strict:** a field the reader doesn't know is a requirement it can't check, so it
  refuses the file.

### Tried on

The MultiMC Launcher's Linux packages (build 5055) and a Qt 6.8 requirement, with the same
binary in each system:

| System | lin64 (Qt 5.6) | lin32 | Qt 6.8 |
|---|---|---|---|
| CachyOS (Qt 5.15, Qt 6.12) | met | the 32-bit Qt 5 missing | met |
| Debian 12 | met | nothing 32-bit | Qt 6.4 lacks `Qt_6.8` |
| Ubuntu 22.04 | met | nothing 32-bit | Qt 6.2 lacks `Qt_6.8` |
| Fedora 41 | met | nothing 32-bit | met |

Measured: 12 libraries for lin64, and the same glibc 2.14, GLIBCXX 3.4.21 and Qt 5.6
floors that MultiMC's build pipeline reports, per library and exact.

Not covered yet: libraries loaded at run time rather than linked, such as Qt's platform
plugin (`libqxcb.so`) and what it needs (`libxcb-*`, `libxkbcommon`). For an app on the
system's Qt those come with the distribution's Qt packages, but nothing checks them.

## First steps

Grown from one real app, the MultiMC Launcher, rather than designed whole first. Its Linux
wrapper packages (Debian, RPM, Arch) today install a shell script that downloads the
Launcher on first start; the Launcher then updates itself. The plan:

1. **probe, fetch and deploy** replace that script: check the host for the Launcher's
   requirements and explain what's missing, download and verify the Launcher, put it in
   place.
2. **resolve and install** once probing has proven itself on real machines.
3. **measure** where the Launcher is built, replacing the requirements its build pipeline
   measures today, so the Launcher's updater and abipak use the same requirement format.

The MultiMC side of this is in the MultiMC Design repo's
[LinuxPackaging.md](https://github.com/MultiMC/Design/blob/master/LinuxPackaging.md).

## Open questions

- The exact host baseline, and how it changes over time.
- The single-file format: which image format, and the fallback when it can't be mounted.
- The manifest format (TOML is a placeholder).
- How desktop integration is registered and removed.
- What the build tool takes as input: a finished directory to measure, or a build it
  drives.
- Which distribution families the resolver covers first, and how an install asks for
  consent and privileges (`pkexec`, PackageKit, or only printing the command).
- Libraries without symbol versioning: how a minimum version is stated and probed.

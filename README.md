# abipak

Tools that check a Linux system's ABI against what an application needs: measure an
application's requirements from its binaries where it is built, and probe a system for them
without loading or running anything. They are built up in three stages, each useful on its
own. Only the first is being worked on.

1. **A helper for the MultiMC Launcher's move to Qt 6 on Linux** (now: a proof of concept,
   kept minimal). The Launcher's updater offers a Qt 6 build only to systems that can run
   it.
2. **A wrapper for the MultiMC Launcher, or similar applications** that ship themselves
   rather than through Linux distributions: one file that checks the system, installs what's
   missing through the system's package manager, downloads the application, and runs it.
   We do the integration with each distribution, so it supports the ones we choose.
3. **A support layer for portable applications, installed by the distribution,** with ABI
   adapters made for that distribution. The distribution does the integration.

Each stage is built when the one before has proven itself. Later stages may change what
the earlier ones decided, but the requirement format from stage 1 is meant to last.

## Why

An application that uses the system's libraries needs specific ABI: these libraries, with
these symbol versions. When the system doesn't have them, the user gets a "symbol not
found" crash instead of an explanation, and nothing knew beforehand.

The dynamic loader decides from information that's in the ELF files: the libraries a
binary links, the symbol version nodes it needs from each, and the nodes each library
defines. abipak reads the same information, on both sides, and compares it before anything
runs.

## Stage 1: the Launcher's move to Qt 6

The MultiMC Launcher's Linux builds use the system's Qt 5. The move to Qt 6 adds a
variant built against the system's Qt 6, next to the Qt 5 ones, so a system gets the Qt 6
build only if it has a recent enough Qt 6, and stays on Qt 5 otherwise. That needs:

- **measure,** where the Launcher is built: its requirements, written into the build's
  manifest;
- **probe,** in the Launcher's updater: whether this system meets a variant's requirements,
  before offering it;
- **missing Qt 6 libraries:** when a system could run the Qt 6 build but for libraries it
  doesn't have, the Launcher says so, at the least: what's missing, and that a better
  Launcher would run with it. On well-known distributions we've tested, it offers to install
  them through the package manager, with the user's consent, and checks again. Only missing
  libraries count: a Qt 6 that is there but too old has no package to fix it.

Nothing else: no downloading, no packaging, no distributions beyond the tested ones. The MultiMC side of this is in
the MultiMC Design repo's
[LinuxPackaging.md](https://github.com/MultiMC/Design/blob/master/LinuxPackaging.md) (One
requirement format) and Updater.md (Qt 6 variants).

### The prototype

`measure` and `probe` exist (2026-11-10), in Zig (`src/`, `zig build` with Zig 0.17; the
release build is a 250 KB static binary):

    zig-out/bin/abipak measure <directory>                 requirements, as JSON
    zig-out/bin/abipak probe [--root DIR] <requirements>   met or not, and what's missing

`measure` reads every ELF file in the application's directory through its program headers,
as the loader does: the architecture, the interpreter, the libraries linked (`DT_NEEDED`)
and the symbol version nodes needed from each (`DT_VERNEED`). Libraries the application
brings itself (a file or link of that name in the directory, or a `DT_SONAME`) aren't
requirements. Weak version references aren't either, and a private API
(`Qt_5_PRIVATE_API`) is a warning: it needs exactly the version the application was built
with, which version nodes can't say.

`probe` finds each library as the loader would (its cache `/etc/ld.so.cache`, then the
usual directories, the first file of that name with the application's architecture), reads
the version nodes it defines (`DT_VERDEF`) and checks every one the application needs.
Nothing is loaded or run. Not followed yet: `DT_RUNPATH`, `LD_LIBRARY_PATH`, and what the
libraries found need themselves.

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
- **The architecture and the interpreter** are part of it: a 32-bit application on a
  system without 32-bit libraries is missing its interpreter first of all.
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

### What's left for stage 1

1. MultiMC's build pipeline writes the measured `libs` into each Linux build's manifest.
2. The Launcher's updater checks them: probe ported to C++, or this static binary shipped
   in the Launcher's Linux builds and run as a child process.
3. The Linux Qt 6 build and its variant.
4. Telling users about missing Qt 6 libraries, and the install offer on tested
   distributions (the packages per distribution, tested by hand: no general resolver yet).

Not covered yet: libraries loaded at run time rather than linked, such as Qt's platform
plugin (`libqxcb.so`) and what it needs (`libxcb-*`, `libxkbcommon`). For an application
on the system's Qt those come with the distribution's Qt packages, but nothing checks them.

### Language

Zig: a small static binary for every Linux architecture from one machine. A static binary
runs whatever the system's libraries, which is the point of a tool that checks them. Its
system calls are old ones (kernel 2.6.36 has all of them), although Zig itself only
promises kernel 5.10.

Zig 0.17's standard library doesn't run on old Windows or macOS (it needs Windows 8 and
macOS 11 calls). Stage 1 is Linux only; stage 2 would need another approach there.

## Stage 2: a wrapper for applications that ship themselves

Not started. For the MultiMC Launcher, or similar applications that aren't generally
shipped with Linux distributions. It would replace the shell script MultiMC's wrapper
packages install today, and could become the download on the website.

What it would do:

- **probe** the system for the application's requirements, and explain what's missing
  ("needs glibc 2.17, this system has 2.12");
- **resolve and install** what's missing: turn it into the distribution's packages and,
  with the user's consent, install them through its package manager. Only on the
  distributions we've integrated with; elsewhere it explains what's missing and stops;
- **fetch and deploy** the application: download it, verify it (signed documents, content
  files by SHA-256, mirrors), and put it in place. The application updates itself after
  that;
- **run** it.

Later perhaps on other systems too: downloading the current release is useful everywhere,
and so could be crash reporting.

### How it would feel to use

Like an AppImage, though built differently:

- **One file.** Download it, make it executable, run it. No installer, no root.
- **The first run does the work:** probe, fetch, deploy, run. Later runs start the
  application straight away, offline too.
- **Portable or installed, by the file's name.** If the name it was started as (`argv[0]`,
  so a symlink works too) contains the word "portable" (case doesn't matter, as a whole
  word: `MyApp-portable`, `MyApp-Portable (1)`, not `notportable`), the application and its
  data live next to it; otherwise in the user's XDG directories. Renaming the file is how a
  user switches, from any file manager; a double-click can't pass flags. An application
  already deployed next to the file wins over the name, so renaming never makes a user's
  data seem gone.
- **Desktop integration on request:** the first run offers a menu entry and icon pointing
  at the file, and every run updates the entry, so moving the file doesn't leave a broken
  one behind.
- **Its own options under a prefix,** like AppImage's `--appimage-*`: `--abipak-check` only
  probes and reports, `--abipak-info` says what it is, where the application and its data
  are and why (which mode, and what decided it). Every other argument goes to the
  application.
- **Explaining without a toolkit.** A static binary can't load a GUI toolkit: it prints in
  a terminal, otherwise uses `zenity` or `kdialog` where present, and a desktop
  notification as the last resort.

Inside, the file is the generic wrapper with a small descriptor appended: the
application's name and icon, where its signed tree is, the pinned root keys. Not the
application itself: that is fetched, and updates itself. The same wrapper serves any
application; only the descriptor changes.

### Distributions already speak ABI

Resolving needs no database of our own: each package manager can already be asked which
package has a soname, or a symbol version:

- **RPM** (Fedora, openSUSE, RHEL): packages get ABI provides automatically, such as
  `libQt5Widgets.so.5()(64bit)` and `libc.so.6(GLIBC_2.17)(64bit)`, so
  `dnf install 'libQt5Widgets.so.5()(64bit)'` already asks for ABI.
- **Debian, Ubuntu:** which package has a library is in the archive's Contents index (what
  `apt-file` reads); symbol versions per package are in its `.symbols` files.
- **Arch:** the files database (`pacman -F`).
- **PackageKit:** a common layer (`what-provides`, install) over the above, as good as each
  backend's support.

### Open questions

- Which systems besides Linux, and how (C, or Zig without its standard library's I/O).
- How desktop integration is registered and removed.
- Which distributions first (the start statistics will say which matter), and how an
  install asks for consent and privileges (`pkexec`, PackageKit, or showing the command).

## Stage 3: a support layer installed by the distribution

An idea. Portable applications (a directory, or one file) that rely on the system's ABI
instead of shipping a runtime, run by a layer the distribution itself packages. What
changes from stage 2 is who integrates: the distribution maintains the ABI adapters for
its own packages, so any application can count on them there, not only the ones we
integrate for.

### Ideas, nothing decided

- **Not a runtime.** Unlike Flatpak and Snap, nothing is shipped besides the application;
  unlike AppImage, the toolkit isn't bundled either. Bundling is the fallback for what a
  distribution can't provide.
- **A small set the application may expect from the system,** never bundled: the C
  library, the graphics stack (it has to match the kernel and hardware), the display and
  audio client libraries. The Linux Standard Base tried to define such a baseline and
  failed (large, frozen versions, no reason to follow it); here every application states
  the exact versions it needs, measured.
- **Optional sandboxing:** an application may come with a profile (network, home folder or
  parts of it, devices, display, audio), run with bubblewrap if the user wants it.
- **One file without FUSE:** mounted where possible (squashfs, erofs), otherwise extracted
  into a cache keyed by its content hash.

### Hard problems

- **libstdc++ and libgcc_s.** An application that bundles a newer libstdc++ than the
  system's clashes with the graphics drivers, which load the system's libstdc++ (Mesa uses
  LLVM). The known fix is to use whichever copy is newer, decided at start-up; AppImage's
  checkrt and the Steam Runtime do this.
- **Libraries without symbol versions** only give a soname; a minimum version needs another
  way to be stated (for example a known symbol that appeared in it).
- **How a distribution would want to package it,** and keep the adapters current.

### Prior art

- **Steam Runtime and pressure-vessel:** graphics stack from the host, everything else
  from a container; it has solved the libstdc++ and driver problems at scale.
- **AppImage:** the portable single-file experience, and its lessons with FUSE and
  libstdc++.
- **Linux Standard Base:** why a declared host baseline failed.
- **Flatpak portals:** what an optional sandbox needs to stay usable (file choosers,
  opening links).
- **systemd portable services:** an image plus optional confinement, for services.

# beansprout


## Overview

A tiling window manager for the [river](https://codeberg.org/river/river/) Wayland compositor written in Zig.
The window manager communicates using the [river-window-management-v1](protocol/river-window-management-v1.xml)
protocol, as well as some of River's additional Wayland protocols.

Beansprout uses a primary/stack tiling layout inspired by dwm with a customizable ratio and primary count.
Similarly, beansprout has a 32-bit tag system, rather than workspaces. Each output has its own tags and own
primary count/ratio.

## Building

Requires [Zig](https://ziglang.org/) 0.15.1 or later.

### Dependencies

To compile beansprout, you'll need the dependencies found below. I've listed the package names for Gentoo and
Debian/Ubuntu, but they likely exist on all major distros.

Needed at both build-time and runtime:

| Dependency         | Gentoo Name                 | Debian/Ubuntu Name  |
|--------------------|-----------------------------|---------------------|
| wayland-client     | `dev-libs/wayland`          | `libwayland-dev`    |
| pixman             | `x11-libs/pixman`           | `libpixman-1-dev`   |
| xkbcommon          | `x11-libs/libxkbcommon`     | `libxkbcommon-dev`  |
| fcft               | `media-libs/fcft`           | `libfcft-dev`       |

Only needed at build-time:

| Dependency         | Gentoo Name                  | Debian/Ubuntu Name  |
|--------------------|------------------------------|---------------------|
| wayland-protocols  | `dev-libs/wayland-protocols` | `wayland-protocols` |

Optional (for building man pages):

| Dependency         | Gentoo Name                  | Debian/Ubuntu Name  |
|--------------------|------------------------------|---------------------|
| scdoc              | `app-text/scdoc`             | `scdoc`             |

#### Note for Gentoo Users

Beansprout is available in my personal [ebuild repo](https://codeberg.org/bwbuhse/beansprout).
Right now, it's just a live ebuild, but I will add versioned ebuilds once v0.1.0 is released.

### Build

Build and install with:

```
zig build -Doptimize=ReleaseSafe --prefix ~/.local install
```

Run `zig build -h` to see a list of all options.

## Usage

You can either add `beansprout` to the river `init` file or directly run `river -c beansprout`.

If you need to exit river, for example, if `beansprout` crashes, you can use river's hardcoded
`Ctrl+Alt+Delete` keybind.

## Configuration

Beansprout is configured with a [KDL](https://kdl.dev) file at
`$XDG_CONFIG_HOME/beansprout/config.kdl`. See [docs/CONFIGURATION.md](docs/CONFIGURATION.md)
for a full reference and [examples/config.kdl](examples/config.kdl) for an example config.

## Licensing

This project follows the [REUSE Specification](https://reuse.software/spec-3.3/),
all files have SPDX copyright and license information and/or are listed under
`REUSE.toml`.

In overview:

- beansprout's source code is released under the GPL-3.0-only license.
- beansprout's documentation is released under the CC-BY-4.0 license.
- beansprout's examples are released under the CC0-1.0 license.

All licenses can be found under `LICENSES`


#!/usr/bin/env bash
# Builds kitty with kitty-smooth-cursor.patch and installs it next to (never
# over) any kitty you already have.
#
#   ./install.sh              install, or update to the newest kitty release
#   ./install.sh v0.49.2      build a specific kitty tag, branch or commit
#   ./install.sh --uninstall  remove everything this script installed
#
# Afterwards run `kitty-smooth`, or pick "kitty (smooth cursor)" in your app launcher.
#
# Environment:
#   PREFIX   install location (default: $HOME/.local/kitty-smooth)
#   BINDIR   where the kitty-smooth launcher goes (default: $HOME/.local/bin)
#
# kitty is cloned into ./kitty next to this script and used only as a build
# tree: any local edits in it are discarded on every run.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/kitty"
PATCH="$HERE/kitty-smooth-cursor.patch"
PREFIX="${PREFIX:-$HOME/.local/kitty-smooth}"
BINDIR="${BINDIR:-$HOME/.local/bin}"
LAUNCHER="$BINDIR/kitty-smooth"
DESKTOP="${XDG_DATA_HOME:-$HOME/.local/share}/applications/kitty-smooth.desktop"
SLANG_VERSION=2026.14.1 # the version kitty's own release builds use
FONT=SymbolsNerdFontMono-Regular.ttf

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() {
    printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

if [ "${1:-}" = --uninstall ]; then
    if [ -x "$PREFIX/bin/kitty" ]; then rm -rf "$PREFIX"; fi
    rm -f "$LAUNCHER" "$DESKTOP"
    say "removed $PREFIX, $LAUNCHER and $DESKTOP"
    exit 0
fi

# --- build dependencies -------------------------------------------------------
# what kitty's setup.py looks for, mapped to Arch Linux package names
declare -A ARCH_PKG=(
    [git]=git [python3]=python [go]=go [cc]=gcc [pkg-config]=pkgconf [curl]=curl [tar]=tar
    [libcrypto]=openssl [libxxhash]=xxhash [libpng]=libpng [lcms2]=lcms2 [cairo-fc]=cairo
    [harfbuzz]=harfbuzz [gl]=libglvnd [x11]=libx11 [x11-xcb]=libx11 [xrandr]=libxrandr
    [xinerama]=libxinerama [xcursor]=libxcursor [xkbcommon]=libxkbcommon
    [xkbcommon-x11]=libxkbcommon-x11 [dbus-1]=dbus [wayland-client]=wayland
    [wayland-cursor]=wayland [wayland-scanner]=wayland [wayland-protocols]=wayland-protocols
    [simde]=simde
)
missing=()
for c in git python3 go cc pkg-config curl tar; do
    command -v "$c" >/dev/null || missing+=("$c")
done
if command -v pkg-config >/dev/null; then
    for m in libcrypto libxxhash libpng lcms2 cairo-fc harfbuzz gl x11 x11-xcb xrandr xinerama xcursor \
        xkbcommon xkbcommon-x11 dbus-1 wayland-client wayland-cursor wayland-scanner wayland-protocols; do
        pkg-config --exists "$m" || missing+=("$m")
    done
fi
# simde is headers only, without a pkg-config file
if command -v cc >/dev/null && ! echo '#include <simde/x86/sse4.2.h>' | cc -E -x c - >/dev/null 2>&1; then
    missing+=(simde)
fi
if [ ${#missing[@]} -gt 0 ]; then
    if command -v pacman >/dev/null && [ -z "${KITTY_SMOOTH_DEPS_INSTALLED:-}" ]; then
        pkgs=$(for m in "${missing[@]}"; do echo "${ARCH_PKG[$m]}"; done | sort -u | tr '\n' ' ')
        say "missing build dependencies: $pkgs"
        read -rp "Install them with 'sudo pacman -S --needed $pkgs'? [Y/n] " answer </dev/tty || answer=n
        case "$answer" in [nN]*) die "cannot build without: $pkgs" ;; esac
        # shellcheck disable=SC2086
        sudo pacman -S --needed $pkgs
        # check again, now that pkg-config and the compiler are surely there
        KITTY_SMOOTH_DEPS_INSTALLED=1 exec "$HERE/install.sh" "$@"
    else
        die "missing build dependencies: ${missing[*]}
Install the packages providing them (see https://sw.kovidgoyal.net/kitty/build/) and run this again."
    fi
fi

# kitty >= 0.49 compiles its shaders with slangc. Use the one on PATH, else a
# prebuilt release unpacked into ./toolchain/slang.
if [ -x "$HERE/toolchain/slang/bin/slangc" ]; then export PATH="$HERE/toolchain/slang/bin:$PATH"; fi
if ! command -v slangc >/dev/null; then
    arch=$(uname -m)
    case "$arch" in x86_64 | aarch64) ;; *) die "no prebuilt slangc for $arch, install shader-slang and run this again" ;; esac
    say "downloading slangc $SLANG_VERSION"
    mkdir -p "$HERE/toolchain/slang"
    curl -fsSL "https://github.com/shader-slang/slang/releases/download/v$SLANG_VERSION/slang-$SLANG_VERSION-linux-$arch.tar.gz" |
        tar -xz -C "$HERE/toolchain/slang"
    export PATH="$HERE/toolchain/slang/bin:$PATH"
fi

# --- kitty source + patch -----------------------------------------------------
# a full clone: git apply --3way needs the history to merge around upstream changes
[ -d "$SRC/.git" ] || git clone https://github.com/kovidgoyal/kitty.git "$SRC"
cd "$SRC"
git fetch -q --tags origin
REF="${1:-$(git tag -l 'v*' --sort=-v:refname | head -n1)}"
say "building kitty $REF with smooth cursor motion"

# drop the previously applied patch, then move to the requested version
git reset -q --hard
rm -f kitty/smooth_cursor.c kitty/shaders/smooth_cursor.slang
git checkout -q --detach "$REF"

# --3way falls back to a merge when upstream changed the context around a hunk.
# On a conflict in kitty/options/{parse.py,types.py,to-c-generated.h} (generated
# files), take either side, finish the build, run
#   ./kitty/launcher/kitty +launch gen/config.py
# inside ./kitty and build again.
git apply --3way "$PATCH"
git reset -q # --3way stages its result; keep it as plain working tree changes

# The build bundles the Symbols Nerd Font Mono: take it from a packaged kitty,
# let setup.py find an installed one, or download it
mkdir -p fonts
for f in /usr/lib/kitty/fonts/$FONT /usr/lib64/kitty/fonts/$FONT; do
    if [ ! -e "fonts/$FONT" ] && [ -e "$f" ]; then cp "$f" fonts/; fi
done
if [ ! -e "fonts/$FONT" ] && ! fc-list ':postscriptname=SymbolsNFM' file 2>/dev/null | grep -q .; then
    say "downloading Symbols Nerd Font Mono"
    curl -fsSL https://github.com/ryanoasis/nerd-fonts/releases/latest/download/NerdFontsSymbolsOnly.tar.xz |
        tar -xJ -C fonts "$FONT"
fi
# skip the sphinx docs build: packaging only requires these to exist
mkdir -p docs/_build/html docs/_build/man

python3 setup.py linux-package --prefix "$PREFIX" --update-check-interval=0

# --- launcher -----------------------------------------------------------------
mkdir -p "$BINDIR" "$(dirname "$DESKTOP")"
cat >"$LAUNCHER" <<EOF
#!/bin/sh
# kitty with smooth cursor motion, installed by kitty-smooth-cursor
exec "$PREFIX/bin/kitty" -o cursor_smooth_motion=yes "\$@"
EOF
chmod +x "$LAUNCHER"
cat >"$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=kitty (smooth cursor)
GenericName=Terminal emulator
Comment=kitty with smooth cursor motion
TryExec=$LAUNCHER
Exec=$LAUNCHER
Icon=$PREFIX/share/icons/hicolor/256x256/apps/kitty.png
Categories=System;TerminalEmulator;
EOF

say "installed $("$PREFIX/bin/kitty" --version)"
case ":$PATH:" in
    *":$BINDIR:"*) say "run: kitty-smooth" ;;
    *) say "run: $LAUNCHER   (add $BINDIR to your PATH to just type kitty-smooth)" ;;
esac

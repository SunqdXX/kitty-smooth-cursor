#!/usr/bin/env bash
# Build kitty with kitty-smooth-cursor.patch and install it to a separate prefix.
#
#   ./rebuild-kitty-smooth.sh            # newest kitty release tag (v*)
#   ./rebuild-kitty-smooth.sh v0.49.2    # a specific tag, branch or commit
#
# Environment:
#   PREFIX   install location (default: $HOME/.local/kitty-smooth)
#
# kitty is cloned into ./kitty next to this script, which is used only as a
# build tree: any local edits in it are discarded. Nothing outside ./kitty and
# $PREFIX is modified, so a kitty installed by your package manager is left alone.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/kitty"
PATCH="$HERE/kitty-smooth-cursor.patch"
PREFIX="${PREFIX:-$HOME/.local/kitty-smooth}"

# kitty >= 0.49 compiles its shaders with slangc (package: shader-slang). A copy
# unpacked into ./toolchain/slang is used when present.
if [ -x "$HERE/toolchain/slang/bin/slangc" ]; then
    export PATH="$HERE/toolchain/slang/bin:$PATH"
fi
command -v slangc >/dev/null || {
    echo "slangc not found: install shader-slang or unpack a slang release into ./toolchain/slang" >&2
    exit 1
}

# a full clone, git apply --3way needs the history to merge around upstream changes
[ -d "$SRC/.git" ] || git clone https://github.com/kovidgoyal/kitty.git "$SRC"
cd "$SRC"
git fetch -q --tags origin
REF="${1:-$(git tag -l 'v*' --sort=-v:refname | head -n1)}"
echo "==> kitty $REF + smooth cursor patch -> $PREFIX"

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

# The build bundles the Symbols Nerd Font Mono. setup.py finds it with fc-list,
# reuse the copy shipped with a packaged kitty when there is one.
mkdir -p fonts
for f in /usr/lib/kitty/fonts/SymbolsNerdFontMono-Regular.ttf /usr/lib64/kitty/fonts/SymbolsNerdFontMono-Regular.ttf; do
    [ -e fonts/SymbolsNerdFontMono-Regular.ttf ] || [ ! -e "$f" ] || cp "$f" fonts/
done
# skip the sphinx docs build: packaging only requires these to exist
mkdir -p docs/_build/html docs/_build/man

python3 setup.py linux-package --prefix "$PREFIX" --update-check-interval=0
echo "==> installed: $("$PREFIX/bin/kitty" --version)"

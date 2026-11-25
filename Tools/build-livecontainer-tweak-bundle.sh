#!/usr/bin/env bash
# Build a LiveContainer TweakLoader bundle from the built tweak .deb.
#
# LiveContainer can load tweaks without baking them into the IPA: import these
# files in the Tweaks tab (or in an app-specific Tweak Folder). Direct IPA
# injection is still the recommended path — this is the alternative for people
# who prefer TweakLoader.
#
# Output directory: Outputs/LiveContainerTweaks/
#   EeveeSpotify.dylib
#   EeveeSwiftProtobuf.framework/
#   zxPluginsInject.dylib   (only when a path is passed as $2)
#
# Usage: Tools/build-livecontainer-tweak-bundle.sh <path/to/eevee.deb> [path/to/zxPluginsInject.dylib]

set -euo pipefail

DEB="${1:-}"
ZXPI="${2:-}"
[ -f "$DEB" ] || { echo "usage: $0 <eevee.deb> [zxPluginsInject.dylib]" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

command -v dpkg-deb >/dev/null 2>&1 || { echo "dpkg-deb not found" >&2; exit 1; }
command -v ldid >/dev/null 2>&1 || { echo "ldid not found" >&2; exit 1; }
command -v install_name_tool >/dev/null 2>&1 || { echo "install_name_tool not found" >&2; exit 1; }

OUT_DIR="$REPO_DIR/Outputs/LiveContainerTweaks"
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"

EXTRACT="$(mktemp -d)"
trap 'rm -rf "$EXTRACT"' EXIT
dpkg-deb -R "$DEB" "$EXTRACT"

DYLIB_SRC="$(find "$EXTRACT" -name 'EeveeSpotify.dylib' | head -1)"
FRAMEWORK_SRC="$(find "$EXTRACT" -type d -name 'EeveeSwiftProtobuf.framework' | head -1)"
[ -n "$DYLIB_SRC" ] || { echo "EeveeSpotify.dylib not found in .deb" >&2; exit 1; }
[ -n "$FRAMEWORK_SRC" ] || { echo "EeveeSwiftProtobuf.framework not found in .deb" >&2; exit 1; }

cp "$DYLIB_SRC" "$OUT_DIR/EeveeSpotify.dylib"
cp -R "$FRAMEWORK_SRC" "$OUT_DIR/EeveeSwiftProtobuf.framework"

# The tweak links against @rpath/EeveeSwiftProtobuf.framework/EeveeSwiftProtobuf.
# Add @loader_path so it resolves the framework sitting next to it in the
# LiveContainer Tweaks folder (the injected IPA gets its rpath from cyan).
install_name_tool -add_rpath @loader_path "$OUT_DIR/EeveeSpotify.dylib" 2>/dev/null || true

if [ -n "$ZXPI" ] && [ -f "$ZXPI" ]; then
    cp "$ZXPI" "$OUT_DIR/zxPluginsInject.dylib"
    install_name_tool -add_rpath @loader_path "$OUT_DIR/zxPluginsInject.dylib" 2>/dev/null || true
fi

# LiveContainer checks signatures before loading tweaks and reports
# "Invalid Signature" otherwise. An ldid pseudo-signature is sufficient —
# LiveContainer re-signs with its own certificate on launch.
sign_macho() {
    local file="$1"
    local kind
    kind="$(file -b "$file" || true)"
    case "$kind" in
        *Mach-O*) ldid -S "$file" ;;
    esac
}
sign_macho "$OUT_DIR/EeveeSpotify.dylib"
[ ! -f "$OUT_DIR/zxPluginsInject.dylib" ] || sign_macho "$OUT_DIR/zxPluginsInject.dylib"
find "$OUT_DIR/EeveeSwiftProtobuf.framework" -type f -print0 | while IFS= read -r -d '' f; do
    sign_macho "$f"
done

# A zip makes the framework shareable via filebin; extract it before importing
# the .framework into LiveContainer's Tweaks tab.
command -v zip >/dev/null 2>&1 && \
    ( cd "$OUT_DIR" && zip -qry EeveeSwiftProtobuf.framework.zip EeveeSwiftProtobuf.framework )

echo "LiveContainer TweakLoader bundle ready:"
ls -lh "$OUT_DIR"

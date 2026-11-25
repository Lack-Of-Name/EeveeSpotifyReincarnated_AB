#!/usr/bin/env bash
# Convert an injected IPA into an "unsigned" IPA: no Apple code signature,
# no provisioning profile. Every Mach-O is pseudo-signed with `ldid -S`
# (an empty signature, no developer certificate) and bundle _CodeSignature
# directories / CodeResources are removed.
#
# This is exactly the input LiveContainer wants: it re-signs the guest with
# its own certificate at install/launch, so an ldid pseudo-signature is fine.
# Combine with Tools/strip-ipa.sh (removes appex/Watch, which LiveContainer
# cannot host) before calling this script — see build-unsigned-ipa.yml.
#
# Usage: Tools/make-unsigned-ipa.sh path/to/EeveeSpotify.ipa [path/to/entitlements.plist]
#   - When an entitlements plist is supplied it is applied to the main app
#     executable only (useful for TrollStore setups that need get-task-allow).

set -euo pipefail

IPA="${1:-}"
ENTITLEMENTS="${2:-}"
[ -f "$IPA" ] || { echo "usage: $0 path/to/Eevee.ipa [entitlements.plist]" >&2; exit 1; }

command -v ldid >/dev/null 2>&1 || { echo "ldid not found" >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "unzip not found" >&2; exit 1; }
command -v zip >/dev/null 2>&1 || { echo "zip not found" >&2; exit 1; }
command -v file >/dev/null 2>&1 || { echo "file not found" >&2; exit 1; }

if [ -n "$ENTITLEMENTS" ] && [ ! -f "$ENTITLEMENTS" ]; then
    echo "entitlements file not found: $ENTITLEMENTS" >&2
    exit 1
fi

IPA_ABS="$(cd "$(dirname "$IPA")" && pwd)/$(basename "$IPA")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

( cd "$WORK" && unzip -q "$IPA_ABS" )

APP="$(find "$WORK/Payload" -maxdepth 2 -name '*.app' -type d | head -1)"
[ -n "$APP" ] || { echo "no .app under Payload/" >&2; exit 1; }
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist" 2>/dev/null || true)"
[ -n "$EXECUTABLE" ] || EXECUTABLE="$(basename "$APP" .app)"

# Drop Apple's signature material from every bundle in the payload.
find "$WORK/Payload" -type d -name '_CodeSignature' -prune -exec rm -rf {} + 2>/dev/null || true
find "$WORK/Payload" -type f -name 'CodeResources' -delete 2>/dev/null || true

# Pseudo-sign every Mach-O. `ldid -S` writes an empty CodeDirectory, i.e. a
# signature with no Apple certificate. Applied to the app binary, injected
# dylibs and embedded frameworks alike.
SIGNED=0
while IFS= read -r -d '' macho; do
    # Capture first (pipefail + grep -q can otherwise produce a false SIGPIPE).
    kind="$(file -b "$macho" || true)"
    case "$kind" in
        *Mach-O*) ;;
        *) continue ;;
    esac

    if [ -n "$ENTITLEMENTS" ] && [ "$macho" = "$APP/$EXECUTABLE" ]; then
        ldid -S"$ENTITLEMENTS" "$macho"
    else
        ldid -S "$macho"
    fi
    SIGNED=$((SIGNED + 1))
done < <(find "$WORK/Payload" -type f -print0)

[ "$SIGNED" -gt 0 ] || { echo "no Mach-O binaries found to pseudo-sign" >&2; exit 1; }

# Rebuild the archive from scratch (zip -u does not drop removed entries).
rm -f "$IPA_ABS"
( cd "$WORK" && zip -qry "$IPA_ABS" Payload )

echo "unsigned IPA ready: $IPA_ABS (pseudo-signed $SIGNED Mach-O files)"

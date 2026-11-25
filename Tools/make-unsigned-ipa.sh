#!/usr/bin/env bash
# Convert an injected IPA into an "unsigned" IPA: no Apple code signature,
# no provisioning profile. Bundle _CodeSignature directories / CodeResources
# are removed, and Mach-Os are pseudo-signed with `ldid -S` where possible.
#
# This is exactly the input LiveContainer wants: it re-signs the guest with
# its own certificate at install/launch, so any leftover Apple signature is
# irrelevant, and ldid failures are non-fatal (see below).
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

# Drop bundle-level signature material. The actual code signature blob lives
# inside each Mach-O, but LiveContainer replaces it when it re-signs the guest.
find "$WORK/Payload" -type d -name '_CodeSignature' -prune -exec rm -rf {} + 2>/dev/null || true
find "$WORK/Payload" -type f -name 'CodeResources' -delete 2>/dev/null || true

# Enumerate files into a regular file first. The previous process-substitution
# loop died on the first ldid error and left `find` with a broken pipe, which
# turned one harmless warning into a failed workflow step.
FILE_LIST="$WORK/payload-files.null"
find "$WORK/Payload" -type f -print0 > "$FILE_LIST"

SIGNED=0
FAILED=0
MACHOS=0
while IFS= read -r -d '' macho; do
    # Capture first (pipefail + grep -q can otherwise produce a false SIGPIPE).
    kind="$(file -b "$macho" || true)"
    case "$kind" in
        *Mach-O*) ;;
        *) continue ;;
    esac
    MACHOS=$((MACHOS + 1))

    # ldid asserts ("end >= size - 0x10") on some stock Mach-Os whose symbol
    # table ends exactly at EOF. That is a known ldid limitation, not a broken
    # IPA. LiveContainer re-signs on launch, so log and keep going.
    if [ -n "$ENTITLEMENTS" ] && [ "$macho" = "$APP/$EXECUTABLE" ]; then
        if ldid -S"$ENTITLEMENTS" "$macho" >/dev/null 2>&1; then
            SIGNED=$((SIGNED + 1))
        else
            FAILED=$((FAILED + 1))
            echo "warning: ldid could not pseudo-sign main executable $macho (LiveContainer will re-sign)"
        fi
    else
        if ldid -S "$macho" >/dev/null 2>&1; then
            SIGNED=$((SIGNED + 1))
        else
            FAILED=$((FAILED + 1))
            echo "warning: ldid could not pseudo-sign $macho (LiveContainer will re-sign)"
        fi
    fi
done < "$FILE_LIST"

[ "$MACHOS" -gt 0 ] || { echo "no Mach-O binaries found under Payload/" >&2; exit 1; }
echo "pseudo-signed $SIGNED/$MACHOS Mach-O files ($FAILED skipped; LiveContainer re-signs those)."

# Rebuild the archive from scratch (zip -u does not drop removed entries).
rm -f "$IPA_ABS"
( cd "$WORK" && zip -qry "$IPA_ABS" Payload )

echo "unsigned IPA ready: $IPA_ABS"

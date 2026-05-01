#!/usr/bin/env bash
#
# Archive Markdown Preview for Mac App Store submission.
#
# Compiles with -DAPPSTORE so all Sparkle code is excluded, swaps in the
# Sparkle-free entitlements + Info.plist, and produces an .xcarchive ready
# to upload via Xcode Organizer or `xcrun altool` / `xcrun notarytool`.
#
# Prereqs:
#   - "Apple Distribution" cert installed in your login keychain.
#   - A Mac App Store provisioning profile downloaded for doc.md-preview.
#     Set its name in AppStore.xcconfig (PROVISIONING_PROFILE_SPECIFIER).
#
# Usage:
#   scripts/archive-appstore.sh                # archives to build/AppStore.xcarchive
#   scripts/archive-appstore.sh path/out.xcarchive

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="md-preview"
ARCHIVE_PATH="${1:-$PROJECT_ROOT/build/AppStore.xcarchive}"

mkdir -p "$(dirname "$ARCHIVE_PATH")"

xcodebuild \
    -project "$PROJECT_ROOT/md-preview.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -xcconfig "$PROJECT_ROOT/AppStore.xcconfig" \
    -archivePath "$ARCHIVE_PATH" \
    archive

# Sparkle is gated out at the source level (#if !APPSTORE), but Swift Package
# Manager still embeds Sparkle.framework into the bundle. Strip it and
# re-sign so the archive ships nothing Sparkle-related.
APP="$ARCHIVE_PATH/Products/Applications/Markdown Preview.app"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "Stripping embedded Sparkle.framework from archive…"
    rm -rf "$SPARKLE_FRAMEWORK"
    SIGN_IDENTITY="${APPSTORE_SIGN_IDENTITY:-Apple Distribution}"
    codesign --force --sign "$SIGN_IDENTITY" \
        --entitlements "$PROJECT_ROOT/md-preview/md-preview-appstore.entitlements" \
        --options runtime \
        "$APP"
fi

echo
echo "Archive ready: $ARCHIVE_PATH"
echo "Next: open it in Xcode Organizer and Distribute App → App Store Connect."

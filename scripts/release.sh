#!/bin/bash
# Cuts a release: bumps the version, builds, zips, publishes a GitHub release,
# and points the Homebrew cask in ExplodingCB/homebrew-tap at it.
#
#   scripts/release.sh 1.0.1 "Short summary of what changed"
#
# Uses whatever account `gh` is logged in as. To publish as ExplodingCB while
# another account is active:
#   GH_TOKEN=$(gh auth token --user ExplodingCB) scripts/release.sh 1.0.1 "…"
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [notes]}"
NOTES="${2:-}"
REPO="ExplodingCB/tv-remote"
TAP="ExplodingCB/homebrew-tap"
ZIP="dist/TV-Remote-$VERSION.zip"

if [ -n "$(git status --porcelain)" ]; then
    echo "Commit or stash your changes first." >&2
    exit 1
fi

# Version lives in Info.plist; the build number just counts up.
PLIST=Resources/Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $BUILD" "$PLIST"

./build.sh
mkdir -p dist
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "build/TV Remote.app" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

git commit -am "Release $VERSION"
git tag "v$VERSION"
git push origin HEAD "v$VERSION"

BODY=$(cat <<NOTES_EOF
Universal (Apple Silicon + Intel) build of TV Remote $VERSION, macOS 15+.

## Install

\`\`\`sh
brew install --cask explodingcb/tap/tv-remote
\`\`\`

Or download \`TV-Remote-$VERSION.zip\` below, unzip into \`/Applications\`, then run:

\`\`\`sh
xattr -dr com.apple.quarantine "/Applications/TV Remote.app"
\`\`\`

The app is ad-hoc signed (no paid Apple Developer account), so it is not notarized and macOS
quarantines it until that flag is cleared. The Homebrew cask does this for you.
${NOTES:+
## What's in $VERSION

$NOTES}
NOTES_EOF
)
gh release create "v$VERSION" "$ZIP" -R "$REPO" --title "TV Remote $VERSION" --notes "$BODY"

# Point the cask at the new zip.
TAP_DIR=$(mktemp -d)
gh repo clone "$TAP" "$TAP_DIR" -- --quiet
CASK="$TAP_DIR/Casks/tv-remote.rb"
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
git -C "$TAP_DIR" commit -qam "tv-remote $VERSION"
git -C "$TAP_DIR" push -q
rm -rf "$TAP_DIR"

echo "Released $VERSION ($SHA)"

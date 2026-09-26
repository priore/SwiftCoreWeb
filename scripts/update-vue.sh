#!/bin/sh
# SwiftCoreWeb — PolyForm Noncommercial 1.0.0. Source-available, not open-source.
#
# Downloads the official Vue 3 production browser build from npm, updates
# the vendored resource file and VueRuntime.version, and regenerates the
# precompressed .br/.gz sidecars served by app.useVue().
#
# Usage: scripts/update-vue.sh <version>   (e.g. scripts/update-vue.sh 3.4.38)

set -eu

VERSION="${1:?Usage: update-vue.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$ROOT/Sources/SwiftCoreWeb/Resources/vue"
DEST_FILE="$DEST_DIR/vue.esm-browser.prod.js"
COMPILER_FILE="$DEST_DIR/compiler-dom.global.prod.js"
RUNTIME_SWIFT="$ROOT/Sources/SwiftCoreWeb/VueRuntime.swift"

mkdir -p "$DEST_DIR"

echo "Downloading vue@$VERSION..."
curl -fsSL "https://cdn.jsdelivr.net/npm/vue@$VERSION/dist/vue.esm-browser.prod.js" -o "$DEST_FILE"

echo "Downloading @vue/compiler-dom@$VERSION (must stay in lockstep with vue)..."
curl -fsSL "https://cdn.jsdelivr.net/npm/@vue/compiler-dom@$VERSION/dist/compiler-dom.global.prod.js" -o "$COMPILER_FILE"

echo "Updating VueRuntime.version..."
sed -i.bak "s/public static let version = \".*\"/public static let version = \"$VERSION\"/" "$RUNTIME_SWIFT"
rm -f "$RUNTIME_SWIFT.bak"

echo "Regenerating precompressed sidecars..."
if command -v brotli >/dev/null 2>&1; then
    brotli -f -k "$DEST_FILE" -o "$DEST_FILE.br"
else
    echo "  brotli not found — skipping .br sidecar (brew install brotli)"
fi
if command -v gzip >/dev/null 2>&1; then
    gzip -f -k "$DEST_FILE"
fi

echo "Done. Vue $VERSION vendored at $DEST_FILE"

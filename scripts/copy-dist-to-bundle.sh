#!/bin/sh
# SwiftCoreWeb
# Copyright (c) 2026 SwiftCoreWeb contributors.
# Licensed under the PolyForm Noncommercial License 1.0.0.
# Free for noncommercial use; commercial use requires a separate license from the author.
# See LICENSE at the repository root. Source-available, not open-source.
#
# Mode C production build phase (spec the frontend development workflows): copies the Vue production
# build's dist/ directory into the app bundle, so `app.useSpa(root: .bundle("dist"))`
# can serve it with no development-only code paths involved.
#
# Wire this into Xcode as a "Run Script" build phase on the app target,
# placed AFTER "Copy Bundle Resources":
#   1. Target > Build Phases > + > New Run Script Phase.
#   2. Script: "$SRCROOT/scripts/copy-dist-to-bundle.sh"
#   3. Input Files:  $SRCROOT/frontend/dist
#      (or wherever your Vue project's `npm run build` writes its output —
#      adjust DIST_SOURCE below to match)
#   4. Output Files: $BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/dist
#   Declaring Input/Output Files lets Xcode skip the phase on unchanged
#   builds instead of re-copying dist/ on every run.

set -eu

DIST_SOURCE="${DIST_SOURCE:-$SRCROOT/frontend/dist}"
DIST_DESTINATION="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/dist"

if [ ! -d "$DIST_SOURCE" ]; then
  echo "error: dist/ not found at '$DIST_SOURCE' — run 'npm run build' in your Vue project first, or set DIST_SOURCE." >&2
  exit 1
fi

echo "copy-dist-to-bundle: syncing '$DIST_SOURCE' -> '$DIST_DESTINATION'"
mkdir -p "$DIST_DESTINATION"
rsync -a --delete "$DIST_SOURCE"/ "$DIST_DESTINATION"/

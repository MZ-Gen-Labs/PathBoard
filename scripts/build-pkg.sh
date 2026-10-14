#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
bash scripts/build-app.sh
PKG="dist/PathBoard-$VERSION-arm64.pkg"
pkgbuild --component dist/PathBoard.app --install-location /Applications --identifier io.github.mz-gen-labs.PathBoard --version "$VERSION" "$PKG"
# An unsigned package reports a nonzero exit status; inspect its actual status.
STATUS="$(pkgutil --check-signature "$PKG" 2>&1 || true)"
echo "$STATUS"
if ! echo "$STATUS" | grep -q 'no signature'; then echo "Expected an unsigned PKG" >&2; exit 1; fi
python3 scripts/verify-package.py "$PKG"
(cd dist && shasum -a 256 "$(basename "$PKG")" > "$(basename "$PKG").sha256")
echo "Built $PKG"

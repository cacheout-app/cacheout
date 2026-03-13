#!/bin/bash
set -euo pipefail

# Build a release DMG for Homebrew Cask distribution.
# Usage: ./scripts/build-dmg.sh [version]
# Example: ./scripts/build-dmg.sh 2.0.0

# ─── Configuration ───────────────────────────────────────────
APP_NAME="Cacheout"
VERSION="${1:-$(git describe --tags --abbrev=0 | sed 's/^v//')}"
BUILD_DIR="./build"
RELEASE_DIR="${BUILD_DIR}/Release"
DIST_DIR="dist"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
APP_BUNDLE="${RELEASE_DIR}/${APP_NAME}.app"

echo "=== Building ${APP_NAME} v${VERSION} ==="

# ─── Step 1: Clean build ────────────────────────────────────
echo "--- Cleaning previous build ---"
rm -rf "${BUILD_DIR}"
mkdir -p "${DIST_DIR}"

# ─── Step 2: Regenerate Xcode project ───────────────────────
if command -v xcodegen &>/dev/null; then
    echo "--- Regenerating xcodeproj ---"
    xcodegen generate 2>&1
fi

# ─── Step 3: Release build via xcodebuild ───────────────────
echo "--- Building release ---"
xcodebuild -project ${APP_NAME}.xcodeproj \
  -scheme ${APP_NAME} \
  -configuration Release \
  build \
  SYMROOT="${BUILD_DIR}" \
  MARKETING_VERSION="${VERSION}" \
  CURRENT_PROJECT_VERSION="${VERSION}" \
  2>&1 | tail -5

if [ ! -d "${APP_BUNDLE}" ]; then
  echo "ERROR: Build failed — no .app bundle found"
  exit 1
fi

echo "--- App bundle: $(du -sh "${APP_BUNDLE}" | cut -f1) ---"

# ─── Step 4: Verify bundle structure ────────────────────────
echo "--- Verifying bundle ---"
CHECKS_PASSED=true

if [ ! -f "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" ]; then
  echo "  FAIL: Missing main binary"
  CHECKS_PASSED=false
fi

if [ ! -f "${APP_BUNDLE}/Contents/Library/LaunchDaemons/CacheoutHelper" ]; then
  echo "  FAIL: Missing helper daemon"
  CHECKS_PASSED=false
fi

if [ ! -d "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework" ]; then
  echo "  FAIL: Missing Sparkle framework"
  CHECKS_PASSED=false
fi

if [ -f "${APP_BUNDLE}/Contents/Resources/Cacheout.icns" ]; then
  echo "  OK: App icon present"
else
  echo "  WARN: Missing app icon (Cacheout.icns)"
fi

if [ "${CHECKS_PASSED}" = false ]; then
  echo "ERROR: Bundle verification failed"
  exit 1
fi
echo "  OK: Bundle structure verified"

# ─── Step 5: Create DMG ─────────────────────────────────────
echo "--- Creating DMG ---"
rm -f "${DIST_DIR}/${DMG_NAME}"

  # Generate background if script exists
BG_IMG="Resources/DMG/background.png"
if [ -f "scripts/make-dmg-bg.py" ] && [ ! -f "${BG_IMG}" ]; then
  echo "--- Generating DMG background ---"
  python3 scripts/make-dmg-bg.py
fi

if command -v create-dmg &>/dev/null; then
  DMG_ARGS=(
    --volname "${APP_NAME}"
    --volicon "Cacheout.icns"
    --window-pos 200 120
    --window-size 660 400
    --icon-size 128
    --icon "${APP_NAME}.app" 165 195
    --hide-extension "${APP_NAME}.app"
    --app-drop-link 495 195
    --no-internet-enable
  )
  if [ -f "${BG_IMG}" ]; then
    DMG_ARGS+=(--background "${BG_IMG}")
  fi
  create-dmg "${DMG_ARGS[@]}" \
    "${DIST_DIR}/${DMG_NAME}" \
    "${APP_BUNDLE}" \
    2>&1 || true
else
  # Fallback: plain hdiutil DMG with /Applications symlink
  DMG_STAGING="${BUILD_DIR}/dmg-staging"
  rm -rf "${DMG_STAGING}"
  mkdir -p "${DMG_STAGING}"
  cp -R "${APP_BUNDLE}" "${DMG_STAGING}/"
  ln -s /Applications "${DMG_STAGING}/Applications"
  hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov -format UDZO \
    "${DIST_DIR}/${DMG_NAME}"
  rm -rf "${DMG_STAGING}"
fi

if [ ! -f "${DIST_DIR}/${DMG_NAME}" ]; then
  echo "ERROR: DMG creation failed"
  exit 1
fi

# ─── Step 6: Output SHA256 for Homebrew cask ────────────────
DMG_SHA=$(shasum -a 256 "${DIST_DIR}/${DMG_NAME}" | awk '{print $1}')
DMG_SIZE=$(du -sh "${DIST_DIR}/${DMG_NAME}" | cut -f1)
echo "${DMG_SHA}" > "${DIST_DIR}/${DMG_NAME}.sha256"

echo ""
echo "=== Done ==="
echo "DMG:     ${DIST_DIR}/${DMG_NAME} (${DMG_SIZE})"
echo "SHA256:  ${DMG_SHA}"
echo ""
echo "To update homebrew/cacheout.rb:"
echo "  version \"${VERSION}\""
echo "  sha256 \"${DMG_SHA}\""
echo ""
echo "Next steps for distribution:"
echo "  1. Sign app:   codesign --deep --force --sign \"Developer ID Application: ...\" ${APP_BUNDLE}"
echo "  2. Sign DMG:   codesign --force --sign \"Developer ID Application: ...\" ${DIST_DIR}/${DMG_NAME}"
echo "  3. Notarize:   xcrun notarytool submit ${DIST_DIR}/${DMG_NAME} --apple-id ... --team-id ... --password ..."
echo "  4. Staple:     xcrun stapler staple ${DIST_DIR}/${DMG_NAME}"
echo "  5. Upload:     gh release upload v${VERSION} ${DIST_DIR}/${DMG_NAME}"
echo "  6. Update:     homebrew/cacheout.rb sha256 with the hash above"

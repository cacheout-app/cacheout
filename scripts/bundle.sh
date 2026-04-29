#!/bin/bash
# Cacheout Distribution Bundle Script
# Builds, signs, creates DMG, and notarizes for direct distribution
#
# Usage:
#   ./scripts/bundle.sh              Build unsigned .app (testing)
#   ./scripts/bundle.sh --direct     Build signed DMG for distribution
#   ./scripts/bundle.sh --notarize   Notarize an existing DMG
#   ./scripts/bundle.sh --release    Build + sign + DMG + notarize (full pipeline)

set -e
set -o pipefail

APP_NAME="Cacheout"
BUNDLE_ID="com.cacheout.app"
VERSION=$(cat VERSION 2>/dev/null || echo "1.0.0")
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/release"
DEST_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$APP_NAME.app"

echo ""
echo "📦 Cacheout Distribution Builder v${VERSION}"
echo "=========================================="
echo ""

# Detect certificates
echo "🔍 Detecting certificates..."
DEVID_CERT=$(security find-identity -v -p codesigning | grep -E "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)
echo "  Developer ID Application: ${DEVID_CERT:-❌ Not found}"
echo ""

# Build release binary
build_release() {
    echo "🏗️  Building release binary (universal)..."
    cd "$PROJECT_DIR"
    swift build -c release 2>&1
    
    if [ ! -f "$BUILD_DIR/$APP_NAME" ]; then
        echo "❌ Build failed - executable not found"
        exit 1
    fi
    
    echo "✅ Build complete"
}

# Create .app bundle
create_bundle() {
    local SIGN_CERT="$1"
    
    echo "📁 Creating app bundle..."
    mkdir -p "$DEST_DIR"
    rm -rf "$DEST_DIR/$APP_BUNDLE"
    mkdir -p "$DEST_DIR/$APP_BUNDLE/Contents/MacOS"
    mkdir -p "$DEST_DIR/$APP_BUNDLE/Contents/Resources"
    
    # Copy executable
    cp "$BUILD_DIR/$APP_NAME" "$DEST_DIR/$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    
    # Copy icon
    if [ -f "$PROJECT_DIR/Cacheout.icns" ]; then
        cp "$PROJECT_DIR/Cacheout.icns" "$DEST_DIR/$APP_BUNDLE/Contents/Resources/Cacheout.icns"
        echo "   ✓ Icon embedded"
    fi
    
    # Create Info.plist
    cat > "$DEST_DIR/$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Cacheout</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>CFBundleIconFile</key>
    <string>Cacheout</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2025 This Local, Inc. MIT License.</string>
</dict>
</plist>
PLIST
    
    echo -n "APPL????" > "$DEST_DIR/$APP_BUNDLE/Contents/PkgInfo"
    
    # Sign
    if [ -n "$SIGN_CERT" ]; then
        echo "🔐 Signing with: $SIGN_CERT"
        codesign --force --options runtime \
            --sign "$SIGN_CERT" \
            "$DEST_DIR/$APP_BUNDLE"
        
        echo "🔍 Verifying signature..."
        codesign --verify --verbose "$DEST_DIR/$APP_BUNDLE"
    else
        echo "🔓 Ad-hoc signing (no certificate)..."
        codesign --force --deep --sign - "$DEST_DIR/$APP_BUNDLE"
    fi
    
    BUNDLE_SIZE=$(du -sh "$DEST_DIR/$APP_BUNDLE" | cut -f1)
    echo "✅ Bundle ready: $DEST_DIR/$APP_BUNDLE ($BUNDLE_SIZE)"
}

# Create polished DMG
create_dmg() {
    echo ""
    echo "💿 Creating polished DMG..."
    DMG_NAME="${APP_NAME}-${VERSION}.dmg"
    DMG_PATH="$DEST_DIR/$DMG_NAME"
    rm -f "$DMG_PATH"
    
    if command -v create-dmg &> /dev/null; then
        create-dmg \
            --volname "$APP_NAME" \
            --volicon "$PROJECT_DIR/Cacheout.icns" \
            --background "$PROJECT_DIR/Resources/DMG/background.png" \
            --window-pos 200 120 \
            --window-size 660 400 \
            --icon-size 128 \
            --icon "$APP_BUNDLE" 165 190 \
            --hide-extension "$APP_BUNDLE" \
            --app-drop-link 495 190 \
            --no-internet-enable \
            "$DMG_PATH" \
            "$DEST_DIR/$APP_BUNDLE" || true
            # create-dmg returns non-zero even on success sometimes
    else
        echo "⚠️  create-dmg not found, falling back to basic DMG"
        echo "   Install with: brew install create-dmg"
        DMG_TEMP="$DEST_DIR/dmg_temp"
        rm -rf "$DMG_TEMP"
        mkdir -p "$DMG_TEMP"
        cp -R "$DEST_DIR/$APP_BUNDLE" "$DMG_TEMP/"
        ln -s /Applications "$DMG_TEMP/Applications"
        hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_TEMP" -ov -format UDZO "$DMG_PATH"
        rm -rf "$DMG_TEMP"
    fi
    
    # Sign DMG
    if [ -n "$DEVID_CERT" ]; then
        echo "🔐 Signing DMG..."
        codesign --force --sign "$DEVID_CERT" "$DMG_PATH"
    fi
    
    if [ -f "$DMG_PATH" ]; then
        DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
        echo "✅ DMG created: $DMG_PATH ($DMG_SIZE)"
    else
        echo "❌ DMG creation failed"
        exit 1
    fi
}

# Notarize DMG
notarize_dmg() {
    DMG_PATH="$DEST_DIR/${APP_NAME}-${VERSION}.dmg"
    
    if [ ! -f "$DMG_PATH" ]; then
        echo "❌ DMG not found: $DMG_PATH"
        echo "   Run './scripts/bundle.sh --direct' first"
        return 1
    fi
    
    echo ""
    echo "📤 Submitting for notarization..."
    echo "   (This may take a few minutes)"
    
    # Check for stored credentials
    if ! xcrun notarytool history --keychain-profile "notarytool-profile" &>/dev/null; then
        echo ""
        echo "⚠️  No stored credentials found!"
        echo "   First, store your credentials:"
        echo "   xcrun notarytool store-credentials notarytool-profile \\"
        echo "     --apple-id YOUR_APPLE_ID \\"
        echo "     --team-id YOUR_TEAM_ID \\"
        echo "     --password APP_SPECIFIC_PASSWORD"
        echo ""
        echo "   Generate an app-specific password at: https://appleid.apple.com"
        return 1
    fi
    
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "notarytool-profile" \
        --wait
    
    echo "📎 Stapling notarization ticket..."
    xcrun stapler staple "$DMG_PATH"
    
    echo "✅ Notarization complete! DMG is ready for distribution."
}

# Main
case "${1:-}" in
    --direct)
        if [ -z "$DEVID_CERT" ]; then
            echo "❌ Developer ID Application certificate required!"
            echo "   Found in Keychain? Check: security find-identity -v -p codesigning"
            exit 1
        fi
        build_release
        create_bundle "$DEVID_CERT"
        create_dmg
        echo ""
        echo "🚀 Direct distribution build complete!"
        echo ""
        echo "To notarize (required for Gatekeeper):"
        echo "  ./scripts/bundle.sh --notarize"
        ;;
    
    --notarize)
        notarize_dmg
        ;;
    
    --release)
        if [ -z "$DEVID_CERT" ]; then
            echo "❌ Developer ID Application certificate required!"
            exit 1
        fi
        build_release
        create_bundle "$DEVID_CERT"
        create_dmg
        notarize_dmg
        echo ""
        echo "🎉 Full release pipeline complete!"
        echo "   DMG: $DEST_DIR/${APP_NAME}-${VERSION}.dmg"
        ;;
    
    *)
        build_release
        create_bundle ""
        echo ""
        echo "=========================================="
        echo "🎉 Test build complete!"
        echo ""
        echo "🚀 To run:  open $DEST_DIR/$APP_BUNDLE"
        echo ""
        echo "Distribution options:"
        echo "  ./scripts/bundle.sh --direct    Build signed DMG"
        echo "  ./scripts/bundle.sh --notarize  Notarize existing DMG"
        echo "  ./scripts/bundle.sh --release   Full pipeline (build+sign+DMG+notarize)"
        ;;
esac

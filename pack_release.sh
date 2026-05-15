#!/bin/bash
set -uo pipefail

# NotchyInput Release Packer
# Creates a self-contained .dmg with embedded Python + mlx_qwen3_asr
# Target: macOS 13.0+ Apple Silicon only (mlx requirement)

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/tmp/notchyinput-release"
APP_NAME="NotchyInput"
DMG_NAME="NotchyInput-Mac"
VERSION="1.0.0"

# Code signing identity (Developer ID Application: Yichen chu — Team HG5RRBKA8T)
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Yichen chu (HG5RRBKA8T)}"
ENTITLEMENTS="$PROJECT_DIR/NotchyInput/NotchyInput.entitlements"
# Notarize requires app-specific password stored as keychain profile.
# To enable: `xcrun notarytool store-credentials notchyinput-notary --apple-id lman@me.com --team-id HG5RRBKA8T`
# Then set NOTARIZE_PROFILE=notchyinput-notary in env. Skipped when unset.
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-}"

echo "=== NotchyInput Release Packer v${VERSION} ==="
echo ""

# --- Step 0: Clean ---
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- Step 1: Build Swift app (arm64 only) ---
echo "[1/6] Building Swift app (arm64)..."
cd "$PROJECT_DIR"
xcodebuild -project NotchyInput.xcodeproj \
    -scheme NotchyInput \
    -configuration Release \
    -arch arm64 \
    ONLY_ACTIVE_ARCH=NO \
    build 2>&1 | grep -E "BUILD|error:" || true

# Find the built app
DERIVED=$(xcodebuild -project NotchyInput.xcodeproj -scheme NotchyInput -showBuildSettings 2>/dev/null | grep "BUILT_PRODUCTS_DIR" | head -1 | awk '{print $3}')
BUILT_APP="$DERIVED/${APP_NAME}.app"

if [ ! -d "$BUILT_APP" ]; then
    echo "ERROR: Built app not found at $BUILT_APP"
    exit 1
fi

cp -R "$BUILT_APP" "$BUILD_DIR/${APP_NAME}.app"
APP="$BUILD_DIR/${APP_NAME}.app"
echo "  App copied to $APP"

# --- Step 2: Embed Python framework ---
echo "[2/6] Embedding Python framework..."

# Find homebrew python3.12
PY_PREFIX=$(/opt/homebrew/bin/python3.12 -c "import sys; print(sys.prefix)")
PY_FRAMEWORK="/opt/homebrew/Cellar/python@3.12/$(ls /opt/homebrew/Cellar/python@3.12/)/Frameworks/Python.framework"

if [ ! -d "$PY_FRAMEWORK" ]; then
    echo "ERROR: Python.framework not found. Install: brew install python@3.12"
    exit 1
fi

EMBED_DIR="$APP/Contents/Resources/python"
mkdir -p "$EMBED_DIR"

# Copy Python.framework (but skip heavy stuff we don't need)
echo "  Copying Python.framework..."
PY_VER="3.12"
PY_SRC="$PY_FRAMEWORK/Versions/$PY_VER"

mkdir -p "$EMBED_DIR/bin"
mkdir -p "$EMBED_DIR/lib/python${PY_VER}"

# Copy python binary
cp "$PY_SRC/bin/python${PY_VER}" "$EMBED_DIR/bin/python3"

# Copy libpython
cp "$PY_SRC/lib/libpython${PY_VER}.dylib" "$EMBED_DIR/lib/" 2>/dev/null || \
    cp "$PY_FRAMEWORK/Versions/${PY_VER}/Python" "$EMBED_DIR/lib/libpython${PY_VER}.dylib" 2>/dev/null || true

# Copy Python stdlib
echo "  Copying stdlib..."
cp -R "$PY_SRC/lib/python${PY_VER}/" "$EMBED_DIR/lib/python${PY_VER}/"

# Remove heavy/unnecessary stdlib modules
for d in test tests idlelib tkinter ensurepip distutils lib2to3 turtledemo; do
    rm -rf "$EMBED_DIR/lib/python${PY_VER}/$d" 2>/dev/null
done
find "$EMBED_DIR" -name "*.pyc" -delete 2>/dev/null || true
find "$EMBED_DIR" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

# Remove broken symlinks (site-packages is a symlink in Homebrew Python)
find "$EMBED_DIR" -type l ! -exec test -e {} \; -delete 2>/dev/null || true
# Clear extended attributes
xattr -cr "$EMBED_DIR" 2>/dev/null || true

# Fix python binary to find its own libpython
install_name_tool -change \
    "/opt/homebrew/Cellar/python@3.12/$(ls /opt/homebrew/Cellar/python@3.12/)/Frameworks/Python.framework/Versions/${PY_VER}/Python" \
    "@executable_path/../lib/libpython${PY_VER}.dylib" \
    "$EMBED_DIR/bin/python3" 2>/dev/null || true

echo "  Python framework embedded."

# --- Step 3: Install site-packages ---
echo "[3/6] Installing Python packages..."

SITE_PKG="$EMBED_DIR/lib/python${PY_VER}/site-packages"

# Clear quarantine/provenance xattrs that block mkdir inside copied dirs
xattr -cr "$EMBED_DIR" 2>/dev/null || true

mkdir -p "$SITE_PKG"

# Use pip to install into embedded location
/opt/homebrew/bin/python3.12 -m pip install \
    --target "$SITE_PKG" \
    --no-cache-dir \
    mlx mlx-metal mlx_qwen3_asr numpy zhconv 2>&1 | tail -5

echo "  Packages installed to $SITE_PKG"

# --- Step 4: Bundle ASR server ---
echo "[4/6] Bundling ASR server..."
ASR_DEST="$APP/Contents/Resources/asr"
mkdir -p "$ASR_DEST"
cp "$PROJECT_DIR/asr/asr_server.py" "$ASR_DEST/"
echo "  asr_server.py bundled."

# --- Step 5: Strip unnecessary files to reduce size ---
echo "[5/6] Stripping unnecessary files..."

# Remove .pyc, __pycache__, tests
find "$EMBED_DIR" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
find "$EMBED_DIR" -name "*.pyc" -delete 2>/dev/null || true
find "$SITE_PKG" -name "tests" -type d -exec rm -rf {} + 2>/dev/null || true
find "$SITE_PKG" -name "test" -type d -exec rm -rf {} + 2>/dev/null || true
# Remove pip/setuptools if present
rm -rf "$SITE_PKG/pip" "$SITE_PKG/setuptools" "$SITE_PKG/pkg_resources" 2>/dev/null || true

FINAL_SIZE=$(du -sh "$APP" | awk '{print $1}')
echo "  Final app size: $FINAL_SIZE"

# --- Step 6: Code sign (Developer ID, hardened runtime) ---
echo "[6/7] Code signing with $SIGN_IDENTITY ..."

# Clear all extended attributes (xattr) before signing — provenance/quarantine xattrs break signing.
xattr -cr "$APP" 2>/dev/null || true

# Sign bottom-up: every dylib, .so, embedded binary first; bundle last.
# Apple deprecated --deep; explicit nested signing is the supported path.
echo "  Signing nested binaries..."
find "$APP/Contents" \( -name "*.dylib" -o -name "*.so" \) -print0 \
    | xargs -0 -I {} codesign --force --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" {} 2>&1 | grep -v "replacing existing" || true

# Sign embedded Python binary (if present)
if [ -f "$APP/Contents/Resources/python/bin/python3" ]; then
    codesign --force --timestamp --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" \
        "$APP/Contents/Resources/python/bin/python3"
fi

# Sign Python.framework if present (bottom-up)
PY_FW="$APP/Contents/Frameworks/Python.framework"
if [ -d "$PY_FW" ]; then
    find "$PY_FW" -type f \( -name "Python" -o -name "*.dylib" \) -print0 \
        | xargs -0 -I {} codesign --force --timestamp --options runtime \
            --sign "$SIGN_IDENTITY" {} || true
    codesign --force --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" "$PY_FW/Versions/Current" 2>/dev/null || true
    codesign --force --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" "$PY_FW"
fi

# Sign the main app bundle last with entitlements
echo "  Signing app bundle..."
codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP"

# Verify
echo "  Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3
codesign -dvv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier"

# --- Step 7: Create DMG ---
echo "[7/7] Creating DMG..."

DMG_STAGING="$BUILD_DIR/dmg_staging"
mkdir -p "$DMG_STAGING"
cp -R "$APP" "$DMG_STAGING/"

# Create Applications symlink for drag-install
ln -s /Applications "$DMG_STAGING/Applications"

DMG_PATH="$PROJECT_DIR/${DMG_NAME}-${VERSION}.dmg"
rm -f "$DMG_PATH"

hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" 2>&1 | tail -3

# Sign the DMG itself
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

# Notarize (optional — skip if NOTARIZE_PROFILE env var not set)
if [ -n "$NOTARIZE_PROFILE" ]; then
    echo ""
    echo "Submitting for notarization (profile: $NOTARIZE_PROFILE)..."
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait
    xcrun stapler staple "$DMG_PATH"
    echo "Notarization complete + stapled."
else
    echo ""
    echo "Skipping notarization (NOTARIZE_PROFILE not set)."
    echo "First-launch users will see Gatekeeper warning. To enable:"
    echo "  1. Generate app-specific password at appleid.apple.com → Sign-In and Security → App-Specific Passwords"
    echo "  2. xcrun notarytool store-credentials notchyinput-notary --apple-id lman@me.com --team-id HG5RRBKA8T"
    echo "  3. Re-run with: NOTARIZE_PROFILE=notchyinput-notary ./pack_release.sh"
fi

echo ""
echo "=== Done ==="
echo "DMG: $DMG_PATH"
echo "Size: $(du -sh "$DMG_PATH" | awk '{print $1}')"
echo ""
echo "Note: Qwen3-ASR model (~1.8GB) downloads automatically on first launch."
echo "Target: macOS 13.0+ Apple Silicon (M1/M2/M3/M4)"

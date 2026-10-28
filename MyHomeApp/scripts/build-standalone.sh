#!/bin/bash
# baseline-guard:allow new build script, no prior baseline exists
# Build a fully standalone MyHome.app: Swift binary + embedded Python runtime,
# bridge script, tinytuya, and the bridge's third-party deps. The result runs
# from any location (or another Mac) with no repo, no .venv, no system python.
#
# Config (devices.json / tinytuya.json) is NOT bundled; the bridge reads it
# from MYHOME_DATA_DIR, which the app defaults to Application Support/MyHome.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$APP_DIR/.." && pwd)"
BUNDLE="$APP_DIR/MyHome.app"
CACHE="$APP_DIR/.cache"

# Pinned python-build-standalone release (astral-sh). The runtime is copied
# whole into the bundle; install_only builds are relocatable.
PBS_TAG="20261026"
PBS_VERSION="3.13.18"
case "$(uname -m)" in
  arm64) PBS_ARCH="aarch64-apple-darwin" ;;
  x86_64) PBS_ARCH="x86_64-apple-darwin" ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac
PBS_FILE="cpython-${PBS_VERSION}+${PBS_TAG}-${PBS_ARCH}-install_only.tar.gz"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PBS_FILE}"
PBS_CACHE="$CACHE/python-${PBS_VERSION}-${PBS_ARCH}"

echo "==> swift build (release)"
swift build -c release --package-path "$APP_DIR"
BIN_DIR="$(swift build -c release --package-path "$APP_DIR" --show-bin-path)"

echo "==> fetch python-build-standalone ${PBS_VERSION} (${PBS_ARCH})"
mkdir -p "$CACHE"
if [ ! -x "$PBS_CACHE/bin/python3" ]; then
  if [ ! -f "$CACHE/$PBS_FILE" ]; then
    curl -fL --retry 3 -o "$CACHE/$PBS_FILE.part" "$PBS_URL"
    mv "$CACHE/$PBS_FILE.part" "$CACHE/$PBS_FILE"
  fi
  rm -rf "$PBS_CACHE" "$CACHE/extract"
  mkdir -p "$CACHE/extract"
  tar -xzf "$CACHE/$PBS_FILE" -C "$CACHE/extract"
  mv "$CACHE/extract/python" "$PBS_CACHE"
  rm -rf "$CACHE/extract"
fi

echo "==> assemble $BUNDLE"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/MyHome.app/Contents/MacOS" \
         "$STAGE/MyHome.app/Contents/Resources/bridge"
cp "$BIN_DIR/MyHomeApp" "$STAGE/MyHome.app/Contents/MacOS/MyHome"
cp "$APP_DIR/AppIcon.icns" "$STAGE/MyHome.app/Contents/Resources/AppIcon.icns"

cp "$REPO_ROOT/bridge.py" "$REPO_ROOT/google_home.py" "$REPO_ROOT/appapi.py" \
   "$STAGE/MyHome.app/Contents/Resources/bridge/"
rsync -a --exclude '__pycache__' --exclude '*.pyc' --exclude '.DS_Store' \
      "$REPO_ROOT/tinytuya" "$STAGE/MyHome.app/Contents/Resources/bridge/"

# The embedded interpreter is the only python the bundle will ever use. pip
# installs into its own site-packages, so no PYTHONPATH juggling is needed.
cp -R "$PBS_CACHE" "$STAGE/MyHome.app/Contents/Resources/bridge-runtime"
RUNTIME_PY="$STAGE/MyHome.app/Contents/Resources/bridge-runtime/bin/python3"
"$RUNTIME_PY" -m pip install --disable-pip-version-check --no-warn-script-location \
  requests colorama cryptography >/dev/null

cat > "$STAGE/MyHome.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>MyHome</string>
	<key>CFBundleExecutable</key>
	<string>MyHome</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.myhome.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>MyHome</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>MyHome discovers and controls Bluetooth lights directly.</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSLocalNetworkUsageDescription</key>
	<string>MyHome controls your lights directly on the local network (WiFi and Bluetooth).</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> codesign (ad-hoc, deep)"
codesign --force --deep --sign - "$STAGE/MyHome.app"
codesign --verify --deep --strict "$STAGE/MyHome.app"

rm -rf "$BUNDLE"
mv "$STAGE/MyHome.app" "$BUNDLE"
echo "==> done: $BUNDLE"
du -sh "$BUNDLE"

# Distributable zip: ditto (not zip) preserves the signature and Finder
# metadata; without --sequesterRsrc symlinks/ACLs in the Python runtime and
# code-signing layout would be mangled.
ZIP="$APP_DIR/MyHome-standalone.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ZIP"
echo "==> zip: $ZIP"
du -h "$ZIP"

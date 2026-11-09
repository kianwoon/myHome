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
# Output goes to a staging dir by default and is never installed anywhere:
# copy the bundle to /Applications yourself. Override with MYHOME_OUT_DIR.
OUT_DIR="${MYHOME_OUT_DIR:-$APP_DIR/build/standalone}"
BUNDLE="$OUT_DIR/MyHome.app"
ZIP="$OUT_DIR/MyHome-standalone.zip"
CACHE="$APP_DIR/.cache"
ENTITLEMENTS="$APP_DIR/Xcode/MyHome.entitlements"
INFO_PLIST="$APP_DIR/Xcode/Info.plist"
# Signing identity: "-" is ad-hoc. Set MYHOME_SIGN_IDENTITY for a real cert.
SIGN_IDENTITY="${MYHOME_SIGN_IDENTITY:--}"
BUNDLE_ID="${MYHOME_BUNDLE_ID:-com.myhome.app}"
APP_VERSION="${MYHOME_VERSION:-1.0}"
APP_BUILD="${MYHOME_BUILD:-1}"

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
# MLX loads its compiled Metal kernels from this SwiftPM resource bundle; without
# it the MLX speech backend aborts at first use.
MLX_BUNDLE="$BIN_DIR/mlx-swift_Cmlx.bundle"
[ -d "$MLX_BUNDLE" ] || { echo "missing $MLX_BUNDLE (MLX backend would abort)" >&2; exit 1; }
cp -R "$MLX_BUNDLE" "$STAGE/MyHome.app/Contents/Resources/mlx-swift_Cmlx.bundle"
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

# Single source of truth: Xcode/Info.plist, with its build-setting variables
# resolved here (the Xcode project resolves the same ones).
sed -e 's/\$(DEVELOPMENT_LANGUAGE)/en/' \
    -e 's/\$(EXECUTABLE_NAME)/MyHome/' \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/" \
    -e 's/\$(PRODUCT_NAME)/MyHome/' \
    -e 's/\$(PRODUCT_BUNDLE_PACKAGE_TYPE)/APPL/' \
    -e "s/\$(MARKETING_VERSION)/$APP_VERSION/" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$APP_BUILD/" \
    -e 's/\$(MACOSX_DEPLOYMENT_TARGET)/13.0/' \
    "$INFO_PLIST" > "$STAGE/MyHome.app/Contents/Info.plist"
# CFBundleIconFile is not in the Xcode plist (asset catalog there); add it.
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
    "$STAGE/MyHome.app/Contents/Info.plist"
plutil -lint "$STAGE/MyHome.app/Contents/Info.plist"
if grep -q '\$(' "$STAGE/MyHome.app/Contents/Info.plist"; then
  echo "unresolved variable in Info.plist" >&2; exit 1
fi

# Sign nested Mach-O code first (the embedded Python runtime ships many
# dylibs/.so files and a python3 executable), then the app with hardened
# runtime + entitlements. --deep alone does not give nested code the runtime.
echo "==> codesign (identity: $SIGN_IDENTITY, hardened runtime)"
# The embedded python is a separate executable that loads pip-installed
# native .so files; those are not signed by the same team, so it needs
# library validation off (unsigned/ad-hoc .so would otherwise be rejected).
PY_ENT="$STAGE/py.entitlements"
cat > "$PY_ENT" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
ENT
while IFS= read -r f; do
  if file -b "$f" | grep -q 'Mach-O'; then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none "$f"
  fi
done < <(find "$STAGE/MyHome.app/Contents/Resources/bridge-runtime" -type f)
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none \
  --entitlements "$PY_ENT" \
  "$STAGE/MyHome.app/Contents/Resources/bridge-runtime/bin/python3."*[0-9] 2>/dev/null || true
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" "$STAGE/MyHome.app"
codesign --verify --deep --strict "$STAGE/MyHome.app"

# Every non-system dylib the main binary links must be inside the bundle.
echo "==> otool -L check"
while IFS= read -r lib; do
  case "$lib" in
    /usr/lib/*|/System/*) ;;
    @rpath/*|@executable_path/*|@loader_path/*)
      name="${lib#*/}"
      if ! find "$STAGE/MyHome.app/Contents" -path "*/$name" | grep -q .; then
        echo "unresolved bundled library: $lib" >&2; exit 1
      fi ;;
    *) echo "unexpected external library: $lib" >&2; exit 1 ;;
  esac
done < <(otool -L "$STAGE/MyHome.app/Contents/MacOS/MyHome" | tail -n +2 | awk '{print $1}')

mkdir -p "$OUT_DIR"
rm -rf "$BUNDLE"
mv "$STAGE/MyHome.app" "$BUNDLE"
echo "==> done: $BUNDLE"
du -sh "$BUNDLE"

# Distributable zip: ditto (not zip) preserves the signature and Finder
# metadata; without --sequesterRsrc symlinks/ACLs in the Python runtime and
# code-signing layout would be mangled.
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ZIP"
echo "==> zip: $ZIP"
du -h "$ZIP"

#!/bin/bash
#
# bundle-macos-local.sh
#
# Local version of the CI "Homebrew dylibs + Qt bundling" steps for OpenSpace.
# Run this AFTER you've built OpenSpace.app locally (Release config) and
# BEFORE you try to run/distribute the app, if you want it to carry its own
# Homebrew (GDAL, etc.) and Qt dependencies instead of relying on your
# local Homebrew install paths.
#
# Usage:
#   ./bundle-macos-local.sh [/path/to/OpenSpace.app]
#   ./bundle-macos-local.sh --search-dir /path/to/build/dir
#
# If no argument is given, it searches $HOME/source/OpenSpace/bin/Release
# (same default as the CI workflow) for OpenSpace.app.
#
# Flags:
#   --skip-sign       Skip the ad-hoc codesign step at the end
#   --skip-dedup      Skip rpath deduplication step
#   -h | --help       Show usage
#
set -uo pipefail

SEARCH_DIR="$HOME/source/OpenSpace/bin/Release"
APP_PATH=""
DO_SIGN=1
DO_DEDUP=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --search-dir)
      SEARCH_DIR="$2"; shift 2 ;;
    --skip-sign)
      DO_SIGN=0; shift ;;
    --skip-dedup)
      DO_DEDUP=0; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *)
      APP_PATH="$1"; shift ;;
  esac
done

if [ -z "$APP_PATH" ]; then
  APP_PATH=$(find "$SEARCH_DIR" -name "OpenSpace.app" -maxdepth 1 2>/dev/null | head -n 1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  echo "Error: could not find OpenSpace.app (looked in: $SEARCH_DIR)"
  echo "Pass the path explicitly: ./bundle-macos-local.sh /path/to/OpenSpace.app"
  exit 1
fi

echo "=================================================="
echo "OpenSpace.app: $APP_PATH"
echo "=================================================="

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/openspace-bundle.XXXXXX")
BACKUP1_DIR="$WORK_DIR/frameworks-backup-1-cef"
BACKUP2_DIR="$WORK_DIR/frameworks-backup-2-with-gdal"
echo "Working dir (backups): $WORK_DIR"

cleanup() {
  echo ""
  echo "Cleaning up temp backups in $WORK_DIR"
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Step 1: Backup CEF framework + helpers as they exist right after the build
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 1: Backing up CEF framework (pre-bundling state) ---"
mkdir -p "$BACKUP1_DIR"
cp -R "$APP_PATH/Contents/Frameworks/." "$BACKUP1_DIR/"
echo "Backup 1 (post-build, CEF+helpers):"
ls -la "$BACKUP1_DIR"

# ---------------------------------------------------------------------------
# Step 2: Bundle Homebrew dylibs (GDAL, etc.) with dylibbundler
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 2: Bundling Homebrew dylibs (GDAL, etc.) ---"
if ! command -v dylibbundler >/dev/null 2>&1; then
  echo "dylibbundler not found, installing via Homebrew..."
  brew install dylibbundler
fi

echo "Bundling dylibs into: $APP_PATH"
mkdir -p "$APP_PATH/Contents/Frameworks"

dylibbundler -od -b \
  -x "$APP_PATH/Contents/MacOS/OpenSpace" \
  -d "$APP_PATH/Contents/Frameworks" \
  -p "@executable_path/../Frameworks/"

# Also check the CEF helper executables in case Homebrew libs leaked into
# their link line too.
for helper in "OpenSpace_Helper" "OpenSpace_Helper_GPU" "OpenSpace_Helper_Renderer"; do
  HELPER_EXE="$APP_PATH/Contents/Frameworks/OpenSpace Helper.app/Contents/MacOS/OpenSpace Helper"
  if [ "$helper" = "OpenSpace_Helper_GPU" ]; then
    HELPER_EXE="$APP_PATH/Contents/Frameworks/OpenSpace Helper (GPU).app/Contents/MacOS/OpenSpace Helper (GPU)"
  elif [ "$helper" = "OpenSpace_Helper_Renderer" ]; then
    HELPER_EXE="$APP_PATH/Contents/Frameworks/OpenSpace Helper (Renderer).app/Contents/MacOS/OpenSpace Helper (Renderer)"
  fi
  if [ -f "$HELPER_EXE" ]; then
    echo "Checking $helper for stray Homebrew deps..."
    dylibbundler -od -b \
      -x "$HELPER_EXE" \
      -d "$APP_PATH/Contents/Frameworks" \
      -p "@executable_path/../../../../Frameworks/"
  fi
done

# ---------------------------------------------------------------------------
# Step 3: Restore CEF on top (dylibbundler can damage/re-link CEF files),
# then take Backup 2 = known-good CEF + GDAL dylibs together.
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 3: Restoring CEF, then taking Backup 2 (CEF + GDAL) ---"
echo "Frameworks after dylibbundler (before CEF restore):"
ls -la "$APP_PATH/Contents/Frameworks"

echo "Restoring CEF/helpers on top (undoes any dylibbundler damage)..."
chmod -R u+w "$APP_PATH/Contents/Frameworks"
cp -Rf "$BACKUP1_DIR/." "$APP_PATH/Contents/Frameworks/"

mkdir -p "$BACKUP2_DIR"
cp -R "$APP_PATH/Contents/Frameworks/." "$BACKUP2_DIR/"
echo "Backup 2 (full known-good state, CEF + GDAL dylibs):"
ls -la "$BACKUP2_DIR"

# ---------------------------------------------------------------------------
# Step 4: Bundle Qt frameworks with macdeployqt
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 4: Bundling Qt frameworks (macdeployqt) ---"
QT_PREFIX=$(brew --prefix qt@6 2>/dev/null || brew --prefix qt 2>/dev/null)
echo "Qt prefix: $QT_PREFIX"

MACDEPLOYQT=$(find "$QT_PREFIX" -name "macdeployqt" -type f 2>/dev/null | head -n 1)

if [ -z "$MACDEPLOYQT" ]; then
  echo "macdeployqt not found under $QT_PREFIX, searching whole Homebrew prefix..."
  MACDEPLOYQT=$(find "$(brew --prefix)" -name "macdeployqt" -type f 2>/dev/null | head -n 1)
fi

if [ -z "$MACDEPLOYQT" ]; then
  echo "Error: macdeployqt not found anywhere under Homebrew prefix"
  exit 1
fi

echo "Using macdeployqt at: $MACDEPLOYQT"
"$MACDEPLOYQT" "$APP_PATH" -always-overwrite -verbose=2

echo "Verifying no more /opt/homebrew Qt references remain..."
if otool -L "$APP_PATH/Contents/MacOS/OpenSpace" | grep -i homebrew; then
  echo "WARNING: Homebrew paths still present in main executable"
else
  echo "Clean — no Homebrew paths in main executable."
fi

# ---------------------------------------------------------------------------
# Step 5: Restore Backup 2 (CEF + GDAL) on top of what macdeployqt left,
# so macdeployqt's Qt frameworks stay, but CEF/GDAL aren't clobbered.
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 5: Restoring Backup 2 (CEF + GDAL) after macdeployqt ---"
echo "Frameworks after macdeployqt (before final restore):"
ls -la "$APP_PATH/Contents/Frameworks"

chmod -R u+w "$APP_PATH/Contents/Frameworks"
cp -Rf "$BACKUP2_DIR/." "$APP_PATH/Contents/Frameworks/"

echo "Final Frameworks contents:"
ls -la "$APP_PATH/Contents/Frameworks"

# ---------------------------------------------------------------------------
# Step 6 (optional): Deduplicate rpaths
# ---------------------------------------------------------------------------
if [ "$DO_DEDUP" -eq 1 ]; then
  echo ""
  echo "--- Step 6: Deduplicating rpaths ---"

  find "$APP_PATH" -type f \( -name "*.dylib" -o -perm +111 \) -print0 | \
  while IFS= read -r -d '' binary; do

    file "$binary" 2>/dev/null | grep -q "Mach-O" || continue

    rpaths=$(otool -l "$binary" 2>/dev/null | \
      awk '/cmd LC_RPATH/{f=1} f && /path /{ $1=""; sub(/ \(offset [0-9]+\)$/,""); sub(/^ /,""); print; f=0 }')

    [ -z "$rpaths" ] && continue

    uniq_paths=$(printf '%s\n' "$rpaths" | sort -u)

    while IFS= read -r rpath; do
      [ -z "$rpath" ] && continue
      count=$(printf '%s\n' "$rpaths" | grep -c -F -x "$rpath")
      if [ "$count" -gt 1 ]; then
        echo ""
        echo "Duplicate rpath in: $binary"
        echo "  Path: $rpath"
        echo "  Occurrences: $count -> removing $((count - 1)) extra"
        remove_n=$((count - 1))
        for ((i=0; i<remove_n; i++)); do
          install_name_tool -delete_rpath "$rpath" "$binary" 2>&1 | grep -v "^$" | sed 's/^/    /'
        done
      fi
    done <<< "$uniq_paths"
  done

  echo "rpath dedup pass complete."
else
  echo ""
  echo "--- Step 6: Skipped (rpath dedup) ---"
fi

# ---------------------------------------------------------------------------
# Step 7 (optional): Ad-hoc codesign, so a locally-modified bundle will
# still launch (macOS invalidates signatures when you touch app contents).
# ---------------------------------------------------------------------------
if [ "$DO_SIGN" -eq 1 ]; then
  echo ""
  echo "--- Step 7: Ad-hoc signing ---"

  echo "Stripping extended attributes (quarantine, resource forks, stale xattrs)..."
  xattr -cr "$APP_PATH"

  echo "Signing all dylibs and executables (excluding frameworks/helpers/main exe)..."
  find "$APP_PATH/Contents" -type f \( -name "*.dylib" -o -perm +111 \) -print0 | \
  while IFS= read -r -d '' f; do
    case "$f" in
      *".framework/"*) continue ;;
      *"Helper"*".app/"*) continue ;;
      *"/MacOS/OpenSpace") continue ;;
    esac
    codesign --force --sign - "$f"
  done

  echo "Signing CEF Framework libraries..."
  find "$APP_PATH/Contents/Frameworks/Chromium Embedded Framework.framework/Libraries" -type f -perm +111 -print0 2>/dev/null | \
  while IFS= read -r -d '' f; do
    codesign --force --sign - "$f" 2>/dev/null || true
  done
  codesign --force --sign - "$APP_PATH/Contents/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework" 2>/dev/null || true
  codesign --force --sign - "$APP_PATH/Contents/Frameworks/Chromium Embedded Framework.framework" 2>/dev/null || true

  echo "Signing all other frameworks..."
  find "$APP_PATH/Contents/Frameworks" -name "*.framework" -not -path "*Chromium Embedded Framework.framework*" -print0 | \
  sort -zr | \
  while IFS= read -r -d '' framework; do
    FRAMEWORK_NAME=$(basename "$framework" .framework)
    find "$framework" -name "*.dylib" -print0 2>/dev/null | while IFS= read -r -d '' dylib; do
      codesign --force --sign - "$dylib" 2>/dev/null || true
    done
    if [ -f "$framework/Versions/A/$FRAMEWORK_NAME" ]; then
      codesign --force --sign - "$framework/Versions/A/$FRAMEWORK_NAME"
    elif [ -f "$framework/$FRAMEWORK_NAME" ]; then
      codesign --force --sign - "$framework/$FRAMEWORK_NAME"
    fi
    codesign --force --sign - "$framework"
  done

  echo "Signing Qt plugins..."
  if [ -d "$APP_PATH/Contents/PlugIns" ]; then
    find "$APP_PATH/Contents/PlugIns" -name "*.dylib" -print0 | while IFS= read -r -d '' lib; do
      codesign --force --sign - "$lib"
    done
  fi

  echo "Signing Helper apps..."
  find "$APP_PATH/Contents/Frameworks" -maxdepth 1 -name "*Helper*.app" -print0 | \
  while IFS= read -r -d '' HELPER_PATH; do
    find "$HELPER_PATH/Contents" -name "*.dylib" -print0 2>/dev/null | while IFS= read -r -d '' dylib; do
      codesign --force --sign - "$dylib" 2>/dev/null || true
    done
    HELPER_EXE=$(find "$HELPER_PATH/Contents/MacOS" -type f -perm +111 | head -1)
    if [ -n "$HELPER_EXE" ]; then
      codesign --force --sign - "$HELPER_EXE"
    fi
    codesign --force --sign - "$HELPER_PATH"
  done

  echo "Signing main executable and bundle..."
  codesign --force --sign - "$APP_PATH/Contents/MacOS/OpenSpace"
  codesign --force --sign - "$APP_PATH"

  echo "Verifying signature..."
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  echo "✓ App successfully signed with ad-hoc signature"
else
  echo ""
  echo "--- Step 7: Skipped (signing) ---"
  echo "Note: without signing, macOS may refuse to launch the app after"
  echo "these modifications (Gatekeeper invalidates the build signature"
  echo "as soon as you alter bundle contents)."
fi

echo ""
echo "=================================================="
echo "Done. Bundled app: $APP_PATH"
echo "=================================================="

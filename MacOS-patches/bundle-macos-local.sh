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
# Step 1: Backup ONLY the CEF framework + helper .app bundles as they exist
# right after the build. IMPORTANT: this must NOT be a full copy of
# Contents/Frameworks, or restoring it later will clobber dylibbundler's
# fixes to any other dylib that already existed in Frameworks pre-build
# (e.g. libvapoursynth-script.0.dylib and its /opt/homebrew/.../Python
# reference).
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 1: Backing up CEF framework (pre-bundling state) ---"
mkdir -p "$BACKUP1_DIR"

CEF_ITEMS=()
[ -d "$APP_PATH/Contents/Frameworks/Chromium Embedded Framework.framework" ] && \
  CEF_ITEMS+=("Chromium Embedded Framework.framework")
while IFS= read -r -d '' helper; do
  CEF_ITEMS+=("$(basename "$helper")")
done < <(find "$APP_PATH/Contents/Frameworks" -maxdepth 1 -name "*Helper*.app" -print0)

if [ ${#CEF_ITEMS[@]} -eq 0 ]; then
  echo "Warning: no CEF framework or Helper .app bundles found under Frameworks."
  echo "Nothing CEF-specific to back up/restore — continuing without it."
else
  for item in "${CEF_ITEMS[@]}"; do
    cp -R "$APP_PATH/Contents/Frameworks/$item" "$BACKUP1_DIR/"
  done
fi

echo "Backup 1 (CEF framework + helper apps only):"
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

dylibbundler -of -b \
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
    dylibbundler -of -b \
      -x "$HELPER_EXE" \
      -d "$APP_PATH/Contents/Frameworks" \
      -p "@executable_path/../../../../Frameworks/"
  fi
done

# ---------------------------------------------------------------------------
# Step 2b: Catch dylibs that dylibbundler's static dependency walk missed.
# dylibbundler only follows the link-time (otool -L) dependency graph from
# the -x targets above. Any dylib that's loaded at runtime via dlopen()
# rather than linked (e.g. VapourSynth's script backend, plugin-style
# libraries) sits in Frameworks/ already but is invisible to that walk, so
# its own /opt/homebrew or /usr/local references never get rewritten.
# Loop: scan every dylib already in Frameworks for absolute Homebrew paths,
# and if found, hand it to dylibbundler directly as an -x target (it accepts
# any Mach-O file, not just an app executable). Repeat until clean or a
# small iteration cap is hit, since fixing one dylib can pull in another
# with the same problem.
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 2b: Sweeping for dlopen'd/indirectly-loaded dylibs with stray Homebrew refs ---"
MAX_SWEEP_ITERATIONS=5
for ((iteration=1; iteration<=MAX_SWEEP_ITERATIONS; iteration++)); do
  echo "Sweep pass $iteration..."
  offenders=()
  while IFS= read -r -d '' f; do
    file "$f" 2>/dev/null | grep -q "Mach-O" || continue
    if otool -L "$f" 2>/dev/null | grep -qE "/opt/homebrew|/usr/local"; then
      offenders+=("$f")
    fi
  done < <(find "$APP_PATH/Contents/Frameworks" -maxdepth 1 -name "*.dylib" -print0)

  if [ ${#offenders[@]} -eq 0 ]; then
    echo "No dylibs with stray Homebrew/usr-local references found. Sweep clean."
    break
  fi

  echo "Found ${#offenders[@]} dylib(s) with unresolved Homebrew references:"
  printf '  %s\n' "${offenders[@]}"

  for f in "${offenders[@]}"; do
    echo "Fixing: $f"
    if [ ! -e "$f" ]; then
      echo "  ERROR: $f does not exist right before processing — skipping."
      echo "  This usually means an earlier step didn't actually write this file"
      echo "  (check write permissions on: $(dirname "$f"))."
      continue
    fi
    # dylibbundler has known issues when its -x target is already sitting
    # inside its own -d destination directory (source == destination). Copy
    # it to a scratch location outside Frameworks/, let dylibbundler fix its
    # dependencies there, then copy the result back in.
    SCRATCH_FIX=$(mktemp -d)
    fbase=$(basename "$f")
    cp "$f" "$SCRATCH_FIX/$fbase"
    chmod u+w "$SCRATCH_FIX/$fbase"
    dylibbundler -of -b \
      -x "$SCRATCH_FIX/$fbase" \
      -d "$APP_PATH/Contents/Frameworks" \
      -p "@executable_path/../Frameworks/"
    if [ ! -e "$SCRATCH_FIX/$fbase" ]; then
      echo "  ERROR: $fbase vanished during dylibbundler processing in scratch dir. Skipping."
      rm -rf "$SCRATCH_FIX"
      continue
    fi
    [ -e "$f" ] && chmod u+w "$f" 2>/dev/null
    if ! cp -f "$SCRATCH_FIX/$fbase" "$f"; then
      echo "  ERROR: failed to copy fixed $fbase back into Frameworks (exit $?)."
      echo "  Check permissions on: $f"
      rm -rf "$SCRATCH_FIX"
      continue
    fi
    echo "  ✓ Fixed and restored $fbase"
    rm -rf "$SCRATCH_FIX"
  done

  if [ "$iteration" -eq "$MAX_SWEEP_ITERATIONS" ]; then
    echo "Warning: reached max sweep iterations ($MAX_SWEEP_ITERATIONS) with offenders still present."
    echo "Re-run the scan manually after this script finishes to check remaining state."
  fi
done

# ---------------------------------------------------------------------------
# Step 3: Restore ONLY the CEF framework + helper apps on top (dylibbundler
# can damage/re-link CEF files it shouldn't touch). Because Backup 1 is now
# scoped to just those CEF paths (see Step 1), this restore no longer
# clobbers dylibbundler's fixes to unrelated dylibs like
# libvapoursynth-script.0.dylib. Then take Backup 2 = full known-good state
# (CEF + GDAL + any other bundled Homebrew dylibs) together.
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 3: Restoring CEF (only), then taking Backup 2 (full state) ---"
echo "Frameworks after dylibbundler (before CEF restore):"
ls -la "$APP_PATH/Contents/Frameworks"

if [ ${#CEF_ITEMS[@]} -gt 0 ]; then
  echo "Restoring CEF/helpers on top (undoes any dylibbundler damage to CEF only)..."
  chmod -R u+w "$APP_PATH/Contents/Frameworks"
  cp -Rf "$BACKUP1_DIR/." "$APP_PATH/Contents/Frameworks/"
else
  echo "No CEF backup to restore, skipping."
fi

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
# Step 5b: Verify every @executable_path/../Frameworks reference in the
# bundle actually resolves to a real file on disk. This catches cases where
# a binary's load command was correctly rewritten to point into Frameworks/
# but the target file itself was never copied there (e.g. dylibbundler
# couldn't find a matching source file on disk — often because the app was
# linked against a specific versioned dylib, like libgdal.38.3.12.1.dylib,
# that Homebrew has since removed after an upgrade). This is effectively an
# automated version of manually renaming /opt/homebrew and trying to launch.
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 5b: Verifying all @executable_path/../Frameworks references resolve ---"
MACOS_DIR="$APP_PATH/Contents/MacOS"
missing_count=0

find "$APP_PATH" -type f \( -name "*.dylib" -o -perm +111 \) -print0 | \
while IFS= read -r -d '' bin; do
  file "$bin" 2>/dev/null | grep -q "Mach-O" || continue

  otool -L "$bin" 2>/dev/null | tail -n +2 | awk '{print $1}' | \
  while read -r dep; do
    case "$dep" in
      @executable_path/*)
        rel="${dep#@executable_path/}"
        resolved="$MACOS_DIR/$rel"
        if [ ! -e "$resolved" ]; then
          echo "MISSING: $bin"
          echo "  wants: $dep"
          echo "  not found at: $resolved"
        fi
        ;;
    esac
  done
done > "$WORK_DIR/verify-output.txt"

if [ -s "$WORK_DIR/verify-output.txt" ]; then
  cat "$WORK_DIR/verify-output.txt"
  missing_count=$(grep -c "^MISSING:" "$WORK_DIR/verify-output.txt")
  echo ""
  echo "✗ Verification found $missing_count unresolved reference(s)."
  echo ""
  echo "--- Step 5c: Attempting auto-repair by searching Homebrew for missing files ---"
  echo "(This happens when a binary already has an @executable_path-relative"
  echo " reference — e.g. from a prior bundling pass — that dylibbundler skips"
  echo " because it only rewrites absolute paths, even if the target file was"
  echo " never actually copied into Frameworks/.)"

  BREW_PREFIX=$(brew --prefix 2>/dev/null || echo "/opt/homebrew")
  grep "^  wants:" "$WORK_DIR/verify-output.txt" | awk '{print $2}' | sort -u | \
  while read -r dep; do
    fname=$(basename "$dep")
    dest="$APP_PATH/Contents/Frameworks/$fname"
    [ -e "$dest" ] && continue  # already repaired by an earlier iteration of this loop

    found=$(find "$BREW_PREFIX" -name "$fname" -type f 2>/dev/null | head -1)
    if [ -n "$found" ]; then
      echo "Found $fname at: $found"
      echo "  Fixing its dependencies in a scratch location, then placing it in Frameworks..."

      chmod u+w "$APP_PATH/Contents/Frameworks" 2>/dev/null

      SCRATCH_FIX=$(mktemp -d)
      if ! cp "$found" "$SCRATCH_FIX/$fname"; then
        echo "  ERROR: cp to scratch failed. Skipping $fname."
        rm -rf "$SCRATCH_FIX"
        continue
      fi
      chmod u+w "$SCRATCH_FIX/$fname"
      install_name_tool -id "@executable_path/../Frameworks/$fname" "$SCRATCH_FIX/$fname"

      # dylibbundler fixes this file's own dependencies here, OUTSIDE
      # Frameworks/, avoiding the source==destination bug where dylibbundler
      # can fail (its own internal chmod errors with "No such file") when
      # asked to process a file that already lives at its own destination.
      dylibbundler -of -b -x "$SCRATCH_FIX/$fname" -d "$APP_PATH/Contents/Frameworks" \
        -p "@executable_path/../Frameworks/"

      if [ ! -e "$SCRATCH_FIX/$fname" ]; then
        echo "  ERROR: $fname vanished during dylibbundler processing. Skipping."
        rm -rf "$SCRATCH_FIX"
        continue
      fi

      [ -e "$dest" ] && chmod u+w "$dest" 2>/dev/null
      if ! cp -f "$SCRATCH_FIX/$fname" "$dest"; then
        echo "  ERROR: failed to copy fixed $fname into $dest (permission issue?)."
        rm -rf "$SCRATCH_FIX"
        continue
      fi
      rm -rf "$SCRATCH_FIX"

      if [ ! -e "$dest" ]; then
        echo "  ERROR: final copy to $dest failed. Skipping."
        continue
      fi

      codesign --force --sign - "$dest" 2>/dev/null || true
      echo "  ✓ Repaired $fname"
    else
      echo "Could not find $fname anywhere under $BREW_PREFIX."
      echo "  This likely means a version that no longer exists locally"
      echo "  (check: brew list --versions <formula>, or search your Cellar)."
    fi
  done

  echo ""
  echo "Re-verifying after auto-repair..."
  : > "$WORK_DIR/verify-output.txt"
  find "$APP_PATH" -type f \( -name "*.dylib" -o -perm +111 \) -print0 | \
  while IFS= read -r -d '' bin; do
    file "$bin" 2>/dev/null | grep -q "Mach-O" || continue
    otool -L "$bin" 2>/dev/null | tail -n +2 | awk '{print $1}' | \
    while read -r dep; do
      case "$dep" in
        @executable_path/*)
          rel="${dep#@executable_path/}"
          resolved="$MACOS_DIR/$rel"
          if [ ! -e "$resolved" ]; then
            echo "MISSING: $bin"
            echo "  wants: $dep"
          fi
          ;;
      esac
    done
  done > "$WORK_DIR/verify-output.txt"

  if [ -s "$WORK_DIR/verify-output.txt" ]; then
    cat "$WORK_DIR/verify-output.txt"
    echo ""
    echo "✗ Still missing after auto-repair — see above. Manual investigation needed"
    echo "  (likely a version that's no longer installed anywhere locally)."
  else
    echo "✓ All references resolve after auto-repair."
  fi
else
  echo "✓ All @executable_path/../Frameworks references resolve to real files."
fi

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
echo "Done. Bundled app: $APP_PATH Now, Python has to be bundled manually"
echo "=================================================="


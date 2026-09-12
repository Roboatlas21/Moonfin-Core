#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Moonfin"
APK_SOURCE="$REPO_ROOT/build/app/outputs/flutter-apk/app-mobile-release.apk"
BUNDLE_SOURCE="$REPO_ROOT/build/app/outputs/bundle/mobileRelease/app-mobile-release.aab"
TV_APK_SOURCE="$REPO_ROOT/build/app/outputs/flutter-apk/app-androidtv-release.apk"
TV_BUNDLE_SOURCE="$REPO_ROOT/build/app/outputs/bundle/androidTvRelease/app-androidTv-release.aab"
PAGE_SIZE_CHECKER="$REPO_ROOT/scripts/check-android-16kb-pages.sh"

resolve_flutter() {
  if [ -n "${FLUTTER_BIN:-}" ] && [ -x "$FLUTTER_BIN" ]; then
    printf '%s\n' "$FLUTTER_BIN"
    return 0
  fi

  if command -v flutter >/dev/null 2>&1; then
    command -v flutter
    return 0
  fi

  local candidates=(
    "$HOME/flutter/bin/flutter"
    "$HOME/Documents/flutter/bin/flutter"
    "$HOME/snap/flutter/common/flutter/bin/flutter"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "Error: Flutter not found. Add flutter to PATH or set FLUTTER_BIN to the full flutter executable path." >&2
  exit 1
}

FLUTTER="$(resolve_flutter)"

VERSION_LINE=$(grep '^version:' "$REPO_ROOT/pubspec.yaml" | sed 's/version:[[:space:]]*//' | tr -d '[:space:]')
APP_VERSION=$(printf '%s' "$VERSION_LINE" | cut -d'+' -f1)
APP_BUILD_NUMBER=$(printf '%s' "$VERSION_LINE" | cut -d'+' -f2)
if [ -z "$APP_VERSION" ] || [ -z "$APP_BUILD_NUMBER" ]; then
  echo "Error: could not read semantic version and build number from pubspec.yaml (expected x.y.z+build)" >&2
  exit 1
fi

APK_OUTPUT="$REPO_ROOT/${APP_NAME}_Android_v${APP_VERSION}.apk"
BUNDLE_OUTPUT="$REPO_ROOT/${APP_NAME}_Android_v${APP_VERSION}.aab"

TV_VERSION=$(grep '^\s*android_tv_version:' "$REPO_ROOT/pubspec.yaml" | sed 's/.*android_tv_version:[[:space:]]*//' | tr -d '[:space:]')
TV_BUILD_NUMBER=$(grep '^\s*android_tv_build_number:' "$REPO_ROOT/pubspec.yaml" | sed 's/.*android_tv_build_number:[[:space:]]*//' | tr -d '[:space:]')
if [ -z "$TV_VERSION" ] || [ -z "$TV_BUILD_NUMBER" ]; then
  echo "Error: could not read android_tv_version / android_tv_build_number from pubspec.yaml" >&2
  exit 1
fi

TV_APK_OUTPUT="$REPO_ROOT/${APP_NAME}_AndroidTV_v${TV_VERSION}.apk"
TV_BUNDLE_OUTPUT="$REPO_ROOT/${APP_NAME}_AndroidTV_v${TV_VERSION}.aab"

echo "${APP_NAME} version: ${APP_VERSION} (${APP_BUILD_NUMBER})"
echo "${APP_NAME} Android TV version: ${TV_VERSION} (${TV_BUILD_NUMBER})"

cd "$REPO_ROOT"

echo "Preparing patched Media3 1.10.1 diagnostic source..."
MEDIA3_DIR="$REPO_ROOT/android/.media3"
rm -rf "$MEDIA3_DIR"
git clone --depth 1 --branch 1.10.1 https://github.com/androidx/media.git "$MEDIA3_DIR"

# Only include Media3 modules required by Moonfin. The stock 1.10.1
# core_settings.gradle also includes optional modules such as Cast/Compose
# that require plugins not present in Moonfin's Gradle build.
cat > "$MEDIA3_DIR/core_settings.gradle" <<'MEDIA3_SETTINGS'
def rootDir = file(".")
if (!gradle.ext.has('androidxMediaSettingsDir')) {
    gradle.ext.androidxMediaSettingsDir = rootDir.getCanonicalPath()
}
def modulePrefix = ':'
if (gradle.ext.has('androidxMediaModulePrefix')) {
    modulePrefix += gradle.ext.androidxMediaModulePrefix
}

def modules = [
    ['lib-common', 'libraries/common'],
    ['lib-container', 'libraries/container'],
    ['lib-session', 'libraries/session'],
    ['lib-exoplayer', 'libraries/exoplayer'],
    ['lib-exoplayer-dash', 'libraries/exoplayer_dash'],
    ['lib-exoplayer-hls', 'libraries/exoplayer_hls'],
    ['lib-exoplayer-rtsp', 'libraries/exoplayer_rtsp'],
    ['lib-exoplayer-smoothstreaming', 'libraries/exoplayer_smoothstreaming'],
    ['lib-ui', 'libraries/ui'],
    ['lib-database', 'libraries/database'],
    ['lib-datasource', 'libraries/datasource'],
    ['lib-decoder', 'libraries/decoder'],
    ['lib-extractor', 'libraries/extractor'],
    ['lib-effect', 'libraries/effect'],
    ['lib-muxer', 'libraries/muxer'],
    ['lib-transformer', 'libraries/transformer']
]

modules.each { m ->
    include modulePrefix + m[0]
    project(modulePrefix + m[0]).projectDir = new File(rootDir, m[1])
}
MEDIA3_SETTINGS

git -C "$MEDIA3_DIR" apply "$REPO_ROOT/patches/media3-1.10.1-hls-trace.patch"

echo "Cleaning previous Flutter outputs..."
"$FLUTTER" clean

echo "Resolving packages..."
"$FLUTTER" pub get

echo "Building Android release APK (arm64-v8a, armeabi-v7a, x86_64)..."
"$FLUTTER" build apk --release \
  --flavor mobile \
  --build-name "$APP_VERSION" \
  --build-number "$APP_BUILD_NUMBER" \
  --dart-define=DISTRIBUTION_CHANNEL=apk

if [ ! -f "$APK_SOURCE" ]; then
  echo "Error: APK not found at $APK_SOURCE" >&2
  exit 1
fi

cp "$APK_SOURCE" "$APK_OUTPUT"

if [ -x "$PAGE_SIZE_CHECKER" ]; then
  echo "Running 16 KB page-size compatibility check on APK (informational only)..."
  "$PAGE_SIZE_CHECKER" "$APK_SOURCE" || echo "Warning: APK 16 KB page-size check failed (not blocking)" >&2
fi

echo "APK created: $APK_SOURCE"
echo "APK copied to root: $APK_OUTPUT"

echo "Building Android App Bundle..."
if ! "$FLUTTER" build appbundle --release \
  --flavor mobile \
  --build-name "$APP_VERSION" \
  --build-number "$APP_BUILD_NUMBER" \
  --dart-define=DISTRIBUTION_CHANNEL=aab; then
  echo "Flutter appbundle build failed. Retrying with Gradle bundleRelease fallback..."
  (
    cd "$REPO_ROOT/android"
    ./gradlew bundleMobileRelease
  )
fi

if [ ! -f "$BUNDLE_SOURCE" ]; then
  echo "Error: App Bundle not found at $BUNDLE_SOURCE" >&2
  exit 1
fi

cp "$BUNDLE_SOURCE" "$BUNDLE_OUTPUT"

if [ -x "$PAGE_SIZE_CHECKER" ]; then
  echo "Running 16 KB page-size compatibility check on App Bundle..."
  "$PAGE_SIZE_CHECKER" "$BUNDLE_SOURCE"
fi

echo "App Bundle created: $BUNDLE_SOURCE"
echo "App Bundle copied to root: $BUNDLE_OUTPUT"

echo "Building Android TV release APK..."
"$FLUTTER" build apk --release \
  --flavor androidTv \
  --build-name "$TV_VERSION" \
  --build-number "$TV_BUILD_NUMBER" \
  --dart-define=MOONFIN_FORCE_TV=true \
  --dart-define=DISTRIBUTION_CHANNEL=android_tv_apk

if [ ! -f "$TV_APK_SOURCE" ]; then
  echo "Error: TV APK not found at $TV_APK_SOURCE" >&2
  exit 1
fi

cp "$TV_APK_SOURCE" "$TV_APK_OUTPUT"

if [ -x "$PAGE_SIZE_CHECKER" ]; then
  echo "Running 16 KB page-size compatibility check on TV APK (informational only)..."
  "$PAGE_SIZE_CHECKER" "$TV_APK_SOURCE" || echo "Warning: TV APK 16 KB page-size check failed (not blocking)" >&2
fi

echo "TV APK created: $TV_APK_SOURCE"
echo "TV APK copied to root: $TV_APK_OUTPUT"

echo "Building Android TV App Bundle..."
if ! "$FLUTTER" build appbundle --release \
  --flavor androidTv \
  --build-name "$TV_VERSION" \
  --build-number "$TV_BUILD_NUMBER" \
  --dart-define=MOONFIN_FORCE_TV=true \
  --dart-define=DISTRIBUTION_CHANNEL=android_tv_aab; then
  echo "Flutter appbundle build failed. Retrying with Gradle bundleAndroidTvRelease fallback..."
  (
    cd "$REPO_ROOT/android"
    ./gradlew bundleAndroidTvRelease
  )
fi

if [ ! -f "$TV_BUNDLE_SOURCE" ]; then
  echo "Error: TV App Bundle not found at $TV_BUNDLE_SOURCE" >&2
  exit 1
fi

cp "$TV_BUNDLE_SOURCE" "$TV_BUNDLE_OUTPUT"

if [ -x "$PAGE_SIZE_CHECKER" ]; then
  echo "Running 16 KB page-size compatibility check on TV App Bundle..."
  "$PAGE_SIZE_CHECKER" "$TV_BUNDLE_SOURCE"
fi

echo "TV App Bundle created: $TV_BUNDLE_SOURCE"
echo "TV App Bundle copied to root: $TV_BUNDLE_OUTPUT"

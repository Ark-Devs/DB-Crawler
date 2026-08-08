#!/usr/bin/env bash
#
# Cross-compiles the Go core into the native libraries the Flutter app links.
#
#   ./tool/build-core.sh android      # .so per ABI -> app/android/.../jniLibs
#   ./tool/build-core.sh ios          # .a per arch -> app/ios/Frameworks  (macOS only)
#   ./tool/build-core.sh host         # .so for this machine, for local testing
#   ./tool/build-core.sh all
#
# Android needs the NDK, because cgo has to be built with a cross-compiler
# targeting Android's libc. Point ANDROID_NDK_HOME at it, or let the script
# find it under the usual SDK location.
#
# iOS needs Xcode, for the same reason — the cgo build needs Apple's clang and
# SDK. That part only runs on a Mac; there is no cross-compiling around it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/core"
JNI_LIBS="$ROOT/app/android/app/src/main/jniLibs"
IOS_LIBS="$ROOT/app/ios/Frameworks"

# The Android API level the .so targets. Must not exceed the app's minSdk,
# which is 23 for EncryptedSharedPreferences.
ANDROID_API="${ANDROID_API:-23}"

# -s -w drops the symbol table and DWARF. The core is 20-odd MB unstripped,
# per ABI, and none of those symbols are readable in a release crash report
# anyway.
LDFLAGS="-s -w"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

find_ndk() {
  if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
    echo "$ANDROID_NDK_HOME"
    return
  fi
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
  # Take the highest installed NDK rather than the first, so an old one left
  # behind by a previous install does not win.
  local newest
  newest="$(ls -d "$sdk"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
  [[ -n "$newest" ]] && echo "$newest"
}

host_tag() {
  case "$(uname -s)" in
    Darwin) echo "darwin-x86_64" ;;
    Linux)  echo "linux-x86_64" ;;
    *)      die "unsupported build host: $(uname -s)" ;;
  esac
}

build_android() {
  local ndk
  ndk="$(find_ndk)"
  [[ -n "$ndk" && -d "$ndk" ]] || die \
    "Android NDK not found. Install it from Android Studio (SDK Tools → NDK)
   and set ANDROID_NDK_HOME, or run: sdkmanager 'ndk;27.0.12077973'"

  local bin="$ndk/toolchains/llvm/prebuilt/$(host_tag)/bin"
  [[ -d "$bin" ]] || die "no toolchain at $bin"

  info "Android core from $ndk (API $ANDROID_API)"

  # goarch : android ABI directory : clang target triple
  local targets=(
    "arm64:arm64-v8a:aarch64-linux-android"
    "arm:armeabi-v7a:armv7a-linux-androideabi"
    "amd64:x86_64:x86_64-linux-android"
  )

  for entry in "${targets[@]}"; do
    IFS=: read -r goarch abi triple <<<"$entry"
    local out="$JNI_LIBS/$abi/libdbcrawler.so"
    mkdir -p "$(dirname "$out")"

    info "  $abi"
    # GOARM only means anything for 32-bit ARM, and it is harmless elsewhere,
    # so it is always set rather than conditionally appended — an empty array
    # expanded under `set -u` is an error on the bash 3.2 that macOS ships.
    ( cd "$CORE" && env \
        CGO_ENABLED=1 \
        GOOS=android \
        GOARCH="$goarch" \
        GOARM=7 \
        CC="$bin/${triple}${ANDROID_API}-clang" \
        go build -buildmode=c-shared -trimpath -ldflags "$LDFLAGS" -o "$out" ./ffi )

    # The generated C header is only useful to a C caller; Dart looks the
    # symbols up by name, so leaving it in jniLibs would just get packaged.
    rm -f "${out%.so}.h"
    printf '     %s\n' "$(du -h "$out" | cut -f1)"
  done

  info "Android libraries in $JNI_LIBS"
}

build_ios() {
  [[ "$(uname -s)" == "Darwin" ]] || die \
    "iOS libraries can only be built on macOS — cgo needs Apple's clang and SDK."
  command -v xcrun >/dev/null || die "xcrun not found. Install Xcode."

  info "iOS core"
  mkdir -p "$IOS_LIBS"

  # Device and simulator are different platforms to the linker, so each gets
  # its own archive and they are combined into an xcframework.
  local device="$IOS_LIBS/device/libdbcrawler.a"
  local sim="$IOS_LIBS/simulator/libdbcrawler.a"
  mkdir -p "$(dirname "$device")" "$(dirname "$sim")"

  info "  device (arm64)"
  ( cd "$CORE" && env \
      CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
      CC="$(xcrun --sdk iphoneos --find clang)" \
      CGO_CFLAGS="-isysroot $(xcrun --sdk iphoneos --show-sdk-path) -arch arm64 -miphoneos-version-min=13.0" \
      CGO_LDFLAGS="-isysroot $(xcrun --sdk iphoneos --show-sdk-path) -arch arm64 -miphoneos-version-min=13.0" \
      go build -buildmode=c-archive -trimpath -ldflags "$LDFLAGS" -o "$device" ./ffi )

  info "  simulator (arm64)"
  ( cd "$CORE" && env \
      CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
      CC="$(xcrun --sdk iphonesimulator --find clang)" \
      CGO_CFLAGS="-isysroot $(xcrun --sdk iphonesimulator --show-sdk-path) -arch arm64 -mios-simulator-version-min=13.0" \
      CGO_LDFLAGS="-isysroot $(xcrun --sdk iphonesimulator --show-sdk-path) -arch arm64 -mios-simulator-version-min=13.0" \
      go build -buildmode=c-archive -trimpath -ldflags "$LDFLAGS" -o "$sim" ./ffi )

  # Each slice gets a headers directory holding only the generated header.
  # Passing the directory the archive sits in would package a 20 MB .a as a
  # "header" in every slice.
  for side in device simulator; do
    mkdir -p "$IOS_LIBS/$side/include"
    mv -f "$IOS_LIBS/$side/libdbcrawler.h" "$IOS_LIBS/$side/include/"
  done

  local xcf="$IOS_LIBS/DbCrawlerCore.xcframework"
  rm -rf "$xcf"
  xcodebuild -create-xcframework \
    -library "$device" -headers "$IOS_LIBS/device/include" \
    -library "$sim"    -headers "$IOS_LIBS/simulator/include" \
    -output "$xcf"

  info "iOS framework at $xcf"
  cat <<'NOTE'

  One manual step in Xcode, once:

    1. Open app/ios/Runner.xcworkspace
    2. Runner target → General → Frameworks, Libraries, and Embedded Content
    3. Add DbCrawlerCore.xcframework, set it to "Do Not Embed"
       (it is a static archive — it links into the binary, it is not a dylib)
    4. Build Settings → Other Linker Flags: add -lresolv
       (the Go runtime's DNS resolver needs it)

  The Dart side already expects this: NativeCore.load() uses
  DynamicLibrary.process() on iOS, because a statically linked archive means
  the app binary *is* the library.
NOTE
}

build_host() {
  info "host core (for tool/ and local testing)"
  local out="$CORE/build/libdbcrawler.so"
  mkdir -p "$(dirname "$out")"
  ( cd "$CORE" && CGO_ENABLED=1 go build -buildmode=c-shared -o "$out" ./ffi )
  info "built $out"
}

case "${1:-all}" in
  android) build_android ;;
  ios)     build_ios ;;
  host)    build_host ;;
  all)
    build_android
    if [[ "$(uname -s)" == "Darwin" ]]; then
      build_ios
    else
      warn "skipping iOS — not on macOS"
    fi
    ;;
  *) die "usage: $0 [android|ios|host|all]" ;;
esac

#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
FFMPEG_SRC="${PROJECT_DIR}/third_party/ffmpeg/ffmpeg"
APP_BUNDLE="$BUILD_DIR/BrawTranscoder.app"

bundle_binaries() {
    if [ -f "$FFMPEG_SRC" ]; then
        mkdir -p "$APP_BUNDLE/Contents/Resources"
        cp "$FFMPEG_SRC" "$APP_BUNDLE/Contents/Resources/ffmpeg"
        chmod +x "$APP_BUNDLE/Contents/Resources/ffmpeg"
        echo "  ffmpeg bundled ✓"
    else
        echo "  WARNING: ffmpeg binary not found at $FFMPEG_SRC"
    fi
    # export_helper must be inside the app bundle so subprocess
    # resolves [NSBundle mainBundle] to the app bundle and finds ffmpeg
    if [ -f "$BUILD_DIR/export_helper" ]; then
        mkdir -p "$APP_BUNDLE/Contents/MacOS"
        cp "$BUILD_DIR/export_helper" "$APP_BUNDLE/Contents/MacOS/export_helper"
        chmod +x "$APP_BUNDLE/Contents/MacOS/export_helper"
        echo "  export_helper bundled ✓"
    fi
}

case "${1:-build}" in
    clean)
        echo "Cleaning build directory..."
        rm -rf "$BUILD_DIR"
        echo "Done."
        ;;
    run)
        mkdir -p "$BUILD_DIR"
        cmake -S "$PROJECT_DIR" -B "$BUILD_DIR" -G Ninja -DCMAKE_BUILD_TYPE=Debug 2>&1
        cmake --build "$BUILD_DIR" -j "$(sysctl -n hw.logicalcpu)"
        bundle_binaries
        echo ""
        echo "Launching..."
        "$APP_BUNDLE/Contents/MacOS/BrawTranscoder"
        ;;
    release)
        mkdir -p "$BUILD_DIR"
        cmake -S "$PROJECT_DIR" -B "$BUILD_DIR" -G Ninja -DCMAKE_BUILD_TYPE=Release 2>&1
        cmake --build "$BUILD_DIR" -j "$(sysctl -n hw.logicalcpu)"
        bundle_binaries
        echo ""
        echo "Release build complete: $APP_BUNDLE"
        ;;
    build|*)
        mkdir -p "$BUILD_DIR"
        cmake -S "$PROJECT_DIR" -B "$BUILD_DIR" -G Ninja 2>&1
        cmake --build "$BUILD_DIR" -j "$(sysctl -n hw.logicalcpu)"
        bundle_binaries
        echo ""
        echo "Build complete: $APP_BUNDLE"
        ;;
esac

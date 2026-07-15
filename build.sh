#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
FFMPEG_SRC="${PROJECT_DIR}/third_party/ffmpeg/ffmpeg"
APP_BUNDLE="$BUILD_DIR/BrawTranscoder.app"
FFMPEG_DST="$APP_BUNDLE/Contents/Resources/ffmpeg"

bundle_ffmpeg() {
    if [ -f "$FFMPEG_SRC" ]; then
        mkdir -p "$APP_BUNDLE/Contents/Resources"
        cp "$FFMPEG_SRC" "$FFMPEG_DST"
        chmod +x "$FFMPEG_DST"
        echo "  ffmpeg bundled ✓"
    else
        echo "  WARNING: ffmpeg binary not found at $FFMPEG_SRC"
        echo "  Run: curl -L -o third_party/ffmpeg/ffmpeg81arm.zip https://www.osxexperts.net/ffmpeg81arm.zip"
        echo "       && cd third_party/ffmpeg && unzip ffmpeg81arm.zip && rm ffmpeg81arm.zip"
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
        bundle_ffmpeg
        echo ""
        echo "Launching..."
        "$APP_BUNDLE/Contents/MacOS/BrawTranscoder"
        ;;
    release)
        mkdir -p "$BUILD_DIR"
        cmake -S "$PROJECT_DIR" -B "$BUILD_DIR" -G Ninja -DCMAKE_BUILD_TYPE=Release 2>&1
        cmake --build "$BUILD_DIR" -j "$(sysctl -n hw.logicalcpu)"
        bundle_ffmpeg
        echo ""
        echo "Release build complete: $APP_BUNDLE"
        ;;
    build|*)
        mkdir -p "$BUILD_DIR"
        cmake -S "$PROJECT_DIR" -B "$BUILD_DIR" -G Ninja 2>&1
        cmake --build "$BUILD_DIR" -j "$(sysctl -n hw.logicalcpu)"
        bundle_ffmpeg
        echo ""
        echo "Build complete: $APP_BUNDLE"
        ;;
esac

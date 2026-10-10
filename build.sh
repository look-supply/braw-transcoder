#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BRAW_BUILD_DIR:-${PROJECT_DIR}/build-reliability}"
FFMPEG_SRC="${PROJECT_DIR}/third_party/ffmpeg/ffmpeg"
APP_BUNDLE="$BUILD_DIR/BrawTranscoder.app"

bundle_binaries() {
    if [ -f "$FFMPEG_SRC" ]; then
        mkdir -p "$APP_BUNDLE/Contents/MacOS"
        cp "$FFMPEG_SRC" "$APP_BUNDLE/Contents/MacOS/ffmpeg"
        chmod +x "$APP_BUNDLE/Contents/MacOS/ffmpeg"
        echo "  ffmpeg bundled ✓"
    else
        echo "  WARNING: ffmpeg binary not found at $FFMPEG_SRC"
    fi
    # Re-sign bundled binary — cp can corrupt code signatures
    codesign -f -s - "$APP_BUNDLE/Contents/MacOS/ffmpeg" 2>/dev/null
    codesign -f -s - "$APP_BUNDLE/Contents/MacOS/braw_worker" 2>/dev/null
    codesign -f -s - "$APP_BUNDLE" 2>/dev/null
    echo "  app and binaries signed ✓"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [command]

Commands:
  build          Build the project (default)
  clean          Remove the build directory
  run            Build and launch the app
  release        Build in Release mode
  --help, -h     Show this help message
EOF
    exit 0
}

case "${1:-build}" in
    --help|-h)
        usage
        ;;
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

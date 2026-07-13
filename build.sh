#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"

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
        echo ""
        echo "Launching..."
        "$BUILD_DIR/BrawTranscoder.app/Contents/MacOS/BrawTranscoder"
        ;;
    release)
        mkdir -p "$BUILD_DIR"
        cmake -S "$PROJECT_DIR" -B "$BUILD_DIR" -G Ninja -DCMAKE_BUILD_TYPE=Release 2>&1
        cmake --build "$BUILD_DIR" -j "$(sysctl -n hw.logicalcpu)"
        echo ""
        echo "Release build complete: $BUILD_DIR/BrawTranscoder.app"
        ;;
    build|*)
        mkdir -p "$BUILD_DIR"
        cmake -S "$PROJECT_DIR" -B "$BUILD_DIR" -G Ninja 2>&1
        cmake --build "$BUILD_DIR" -j "$(sysctl -n hw.logicalcpu)"
        echo ""
        echo "Build complete: $BUILD_DIR/BrawTranscoder.app"
        ;;
esac

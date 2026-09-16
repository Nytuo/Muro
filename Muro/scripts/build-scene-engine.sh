#!/bin/zsh
# Builds the Wallpaper Engine scene renderer (SceneEngine/, Rust) as the static
# library MuroKit links against, at .build/scene-engine/libwer_ffi.a.
#
# Usage: scripts/build-scene-engine.sh [--universal]
#   (default)    : this Mac's architecture only, which is all `swift build`
#                  and `swift test` need
#   --universal  : arm64 + x86_64, merged with lipo, for build-app.sh
#
# Needs a Rust toolchain (https://rustup.rs). For --universal, both targets:
#   rustup target add aarch64-apple-darwin x86_64-apple-darwin
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$DIR/.build/scene-engine"
MANIFEST="$DIR/SceneEngine/Cargo.toml"

if [[ ! -f "$MANIFEST" ]]; then
    echo "==> SceneEngine/ is empty — initializing the submodule"
    git -C "$DIR" submodule update --init SceneEngine
fi

export MACOSX_DEPLOYMENT_TARGET=14.0
export CARGO_TARGET_DIR="$DIR/.build/cargo"

if ! command -v cargo >/dev/null 2>&1; then
    echo "ERROR: cargo not found. Install Rust from https://rustup.rs" >&2
    exit 1
fi

mkdir -p "$OUT"

if [[ "$1" == "--universal" ]]; then
    for target in aarch64-apple-darwin x86_64-apple-darwin; do
        echo "==> cargo build --release ($target)"
        cargo build --release --manifest-path "$MANIFEST" -p wer-ffi --target "$target"
    done
    lipo -create \
        "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libwer_ffi.a" \
        "$CARGO_TARGET_DIR/x86_64-apple-darwin/release/libwer_ffi.a" \
        -output "$OUT/libwer_ffi.a"
else
    echo "==> cargo build --release (host)"
    cargo build --release --manifest-path "$MANIFEST" -p wer-ffi
    cp "$CARGO_TARGET_DIR/release/libwer_ffi.a" "$OUT/libwer_ffi.a"
fi

touch "$DIR/Sources/MuroKit/Engine/SceneSurface.swift"

echo "==> $OUT/libwer_ffi.a ($(lipo -archs "$OUT/libwer_ffi.a"))"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/Atari/zig-m68k"
LLVM_SRC="$ROOT/llvm-project"
LLVM_BUILD="$ROOT/llvm-build-21"
LLVM_TAG="llvmorg-21.1.8"
PREFIX="$HOME/Atari"
ZIG_SRC="$ROOT/zig"
NPROC=$(sysctl -n hw.ncpu)

# ── 1. Build LLVM 21.x with M68k experimental target ──────────────────────

# Zig requires ALL default LLVM targets (AMDGPU, ARM, RISCV, etc.)
# -- see cmake/Findllvm.cmake ZIG_LLVM_REQUIRED_TARGETS
if [ -f "$PREFIX/lib/libLLVMM68kCodeGen.a" ] && \
   [ -f "$PREFIX/lib/libLLVMAMDGPUCodeGen.a" ] && \
   [ -f "$PREFIX/bin/llvm-config" ]; then
    LLVM_VER=$("$PREFIX/bin/llvm-config" --version 2>/dev/null || echo "unknown")
    if [[ "$LLVM_VER" == 21.* ]]; then
        echo "✓ LLVM 21.x with M68k already installed at $PREFIX (version $LLVM_VER)"
        echo "  skipping LLVM build — delete $PREFIX/lib/libLLVMM68kCodeGen.a to force rebuild"
    else
        echo "✗ LLVM at $PREFIX is version $LLVM_VER, not 21.x — rebuilding"
        BUILD_LLVM=1
    fi
else
    BUILD_LLVM=1
fi

if [ "${BUILD_LLVM:-0}" -eq 1 ]; then
    echo "── Building LLVM $LLVM_TAG with M68k target ──"

    cd "$LLVM_SRC"
    git fetch --tags origin

    if ! git rev-parse --verify "$LLVM_TAG" >/dev/null 2>&1; then
        echo "✗ tag $LLVM_TAG not found after fetch — check your llvm-project clone"
        exit 1
    fi
    git checkout "$LLVM_TAG"

    rm -rf "$LLVM_BUILD"
    mkdir -p "$LLVM_BUILD"
    cd "$LLVM_BUILD"

    cmake "$LLVM_SRC/llvm" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DLLVM_ENABLE_PROJECTS="clang;lld" \
        -DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD="M68k" \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_INCLUDE_DOCS=OFF \
        -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_LIBXML2=OFF \
        -DLLVM_ENABLE_ZLIB=OFF \
        -DLLVM_ENABLE_ZSTD=OFF

    cmake --build . -j"$NPROC"
    cmake --install .

    echo "✓ LLVM $LLVM_TAG built and installed to $PREFIX"
fi

# ── 2. Build Zig against that LLVM ─────────────────────────────────────────

echo "── Building Zig ──"

cd "$ZIG_SRC"
rm -rf build zig-out .zig-cache
mkdir -p build
cd build

cmake .. \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DZIG_EXTRA_BUILD_ARGS="-Dllvm-has-m68k=true"

cmake --build . -j"$NPROC"
cmake --install .

echo ""
echo "✓ Zig installed to $PREFIX/bin/zig"
echo "  verify with: $PREFIX/bin/zig version"
echo "  test m68k:  $PREFIX/bin/zig targets | grep m68k"

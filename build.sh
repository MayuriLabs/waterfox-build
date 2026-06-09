#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

if [[ -f config.sh ]]; then
    source config.sh
fi

# Set architecture
ARCH="${ARCH:-$(uname -m)}"
export PATH="$HOME/.mozbuild/clang/bin:$PATH"
export PIP_CONSTRAINT="$HOME/constraints.txt"
echo "maturin==1.8.6" > "$HOME/constraints.txt"
if [[ -d "$HOME/.cargo" ]]; then
    source "$HOME/.cargo/env"
fi

function parse_parameters() {
    while (($#)); do
        case $1 in
            all | setup_rust | setup_mozconfig | set_display_version | install_clang | bootstrap_build | stage1_build | collect_profiles | stage2_build | prepare_artifacts ) action=$1 ;;
            *) exit 33 ;;
        esac
        shift
    done
}

function get_rust_version() {
    local rust_version="1.86.0"
    if [ -f waterfox/rust-toolchain.toml ]; then
        local extracted
        extracted=$(grep -E '^\s*channel\s*=' waterfox/rust-toolchain.toml | cut -d'"' -f2)
        if [ -n "$extracted" ]; then
            rust_version="$extracted"
        fi
    elif [ -f waterfox/rust-toolchain ]; then
        local extracted
        extracted=$(cat waterfox/rust-toolchain | tr -d '\r\n[:space:]')
        if [ -n "$extracted" ]; then
            rust_version="$extracted"
        fi
    fi
    echo "$rust_version"
}

function do_setup_rust() {
    echo "Installing Rust toolchain..."
    local rust_version
    rust_version=$(get_rust_version)
    echo "Detected Rust version: $rust_version"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain "$rust_version"
    . "$HOME/.cargo/env"
    rustup toolchain install "$rust_version"
    rustup default "$rust_version"
}

function do_setup_mozconfig() {
    echo "Setting up $ARCH mozconfig..."
    if [ "$ARCH" = "x86_64" ]; then
        if [ -f waterfox/.mozconfig-x86_64-pc-linux-gnu ]; then
            cp waterfox/.mozconfig-x86_64-pc-linux-gnu waterfox/.mozconfig
        else
            echo "Error: waterfox/.mozconfig-x86_64-pc-linux-gnu not found!"
            exit 1
        fi
    elif [ "$ARCH" = "aarch64" ]; then
        if [ -f .mozconfig-aarch64-pc-linux-gnu ]; then
            cp .mozconfig-aarch64-pc-linux-gnu waterfox/.mozconfig
        else
            echo "Error: .mozconfig-aarch64-pc-linux-gnu not found!"
            exit 1
        fi
    else
        echo "Error: Unsupported architecture $ARCH"
        exit 1
    fi

    # Tweak .mozconfig to prevent OOM errors on GitHub Actions runners
    echo "Applying memory-saving tweaks for CI..."
    sed -i 's/--enable-lto/--enable-lto=cross/g' waterfox/.mozconfig
    echo 'ac_add_options --disable-debug-symbols' >> waterfox/.mozconfig
}

function do_set_display_version() {
    if [ -n "$DISPLAY_VERSION" ]; then
        echo "Setting display version to $DISPLAY_VERSION..."
        echo "$DISPLAY_VERSION" > waterfox/browser/config/version_display.txt
    else
        echo "DISPLAY_VERSION not set, skipping version write."
    fi
}

function do_install_clang() {
    local rust_version
    rust_version=$(get_rust_version)
    
    local minor_version
    minor_version=$(echo "$rust_version" | cut -d. -f2)
    
    local clang_ver="19"
    if [ -n "$minor_version" ] && [ "$minor_version" -ge 87 ]; then
        clang_ver="20"
    fi
    
    echo "Installing Mozilla Clang $clang_ver..."
    mkdir -p "$HOME/.mozbuild"
    
    local clang_url=""
    if [ "$ARCH" = "x86_64" ]; then
        clang_url="https://firefox-ci-tc.services.mozilla.com/api/index/v1/task/gecko.cache.level-3.toolchains.v3.linux64-clang-${clang_ver}.latest/artifacts/public/build/clang.tar.zst"
    elif [ "$ARCH" = "aarch64" ]; then
        clang_url="https://firefox-ci-tc.services.mozilla.com/api/index/v1/task/gecko.cache.level-3.toolchains.v3.linux64-aarch64-clang-${clang_ver}.latest/artifacts/public/build/clang.tar.zst"
    else
        echo "Error: Unsupported architecture $ARCH for Clang download"
        exit 1
    fi

    echo "Downloading Clang from $clang_url..."
    curl -L "$clang_url" -o clang.tar.zst
    
    if [ -f clang.tar.zst ]; then
        echo "Extracting Clang..."
        tar --zstd -xf clang.tar.zst -C "$HOME/.mozbuild"
        rm clang.tar.zst
    else
        echo "Error: Failed to download Clang archive"
        exit 1
    fi
}

function do_bootstrap_build() {
    echo "Bootstrapping build environment..."
    (
        cd waterfox
        ./mach bootstrap --application-choice=browser --no-system-changes
    )
}

function do_stage1_build() {
    echo "Stage 1 - Generating instrumented build..."
    (
        cd waterfox
        export GEN_PGO=1
        ./mach build -j2
        ./mach package
    )
}

function do_collect_profiles() {
    echo "Running profile collection..."
    (
        cd waterfox
        export RUSTUP_HOME="$HOME/.rustup"
        export CARGO_HOME="$HOME/.cargo"
        export MOZBUILD_STATE_PATH="$HOME/.mozbuild"
        xvfb-run ./mach python build/pgo/profileserver.py --binary ./obj-*/dist/waterfox/waterfox
        
        # Merge the generated .profraw files into the final merged.profdata file
        "$HOME"/.mozbuild/clang/bin/llvm-profdata merge -o merged.profdata *.profraw
    )
}

function do_stage2_build() {
    echo "Stage 2 - Building with collected profile data..."
    (
        cd waterfox
        ./mach clobber
        export USE_PGO=1
        ./mach build -j2
        ./mach package
    )
}

function do_prepare_artifacts() {
    echo "Preparing build artifact..."
    local dist_dir
    dist_dir=$(find waterfox/obj-* -maxdepth 2 -type d -name "waterfox" | head -n 1)
    if [ -z "$dist_dir" ]; then
        echo "Error: Could not find built waterfox directory"
        exit 1
    fi
    echo "Found build at $dist_dir"
    mkdir -p artifact-staging
    cp -a "$dist_dir/"* artifact-staging/
    
    # Save the git SHA
    (
        cd waterfox
        git rev-parse --short HEAD > ../artifact-staging/GIT_SHA.txt
    )
}

function do_all() {
    do_setup_rust
    do_setup_mozconfig
    do_set_display_version
    do_install_clang
    do_bootstrap_build
    do_stage1_build
    do_collect_profiles
    do_stage2_build
    do_prepare_artifacts
}

parse_parameters "$@"
do_"${action:=all}"

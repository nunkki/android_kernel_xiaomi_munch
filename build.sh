#!/bin/bash
# Original script by TIMISONG-dev
# Make sure you have zstd installed.

set -o pipefail

export DEVICE="munch"
export VERSION="1.0.0"
export PREFIX="s"
export BUILD_TYPE="Stable"
#export TGTOKEN=bot_token
#export CHAT_ID=chat_id

start_time=$(date +%s)

MAINPATH=${GITHUB_WORKSPACE:-/home/runner/work/android_kernel_xiaomi_munch/android_kernel_xiaomi_munch}

KERNEL_DIR=$MAINPATH
KERNEL_PATH=$KERNEL_DIR/android_kernel_xiaomi_munch

CLANG_DIR=$KERNEL_DIR/clang24

cd "$KERNEL_PATH" || { echo "Error: $KERNEL_PATH not found"; exit 1; }

tg_send_message() {
    [ -n "$TGTOKEN" ] && [ -n "$CHAT_ID" ] || return 0
    curl -s -X POST "https://api.telegram.org/bot$TGTOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d text="$1"
}

tg_send_document() {
    [ -n "$TGTOKEN" ] && [ -n "$CHAT_ID" ] || return 0
    local args=(-F document=@"$1")
    [ -n "$2" ] && args+=(-F caption="$2")
    curl -s -X POST "https://api.telegram.org/bot$TGTOKEN/sendDocument?chat_id=$CHAT_ID" \
    "${args[@]}"
}

check_and_wget() {
    local dir=$1
    local repo=$2
    local file
    file=$(basename "$repo")

    if [ ! -d "$dir" ]; then
        echo "Directory $dir doesnt exist. Cloning $repo."
        mkdir -p "$dir"
        cd "$dir" || return 1
        wget "$repo"
        tar --zstd -xvf "$file"
        rm -rf "$file"
        cd "$KERNEL_PATH" || return 1
    fi
}

check_and_wget $CLANG_DIR https://github.com/Neutron-Toolchains/clang-build-catalogue/releases/download/06092026/neutron-clang-06092026.tar.zst

PATH=$CLANG_DIR/bin:$PATH
export PATH
export ARCH=arm64
export SUBARCH=ARM64

AK3_DIR="$KERNEL_DIR/main"

if [ ! -d "$AK3_DIR" ]; then
    mkdir -p "$AK3_DIR"
    
    if [ ! -d "$AK3_DIR/Anykernel" ]; then
        git clone https://github.com/nunkki/Anykernel3-Munch.git "$AK3_DIR/Anykernel"

        cp -a "$AK3_DIR/Anykernel/." "$AK3_DIR/"
        
        rm -rf "$AK3_DIR/Anykernel"
    fi
fi

if [ -d "$AK3_DIR/.git" ]; then
    rm -rf "$AK3_DIR/.git"
fi

export IMGPATH="$AK3_DIR/Image"
export DTBPATH="$AK3_DIR/dtb"
export DTBOPATH="$AK3_DIR/dtbo.img"
export KBUILD_BUILD_USER="action"
export KBUILD_BUILD_HOST="github.com"

MORPHITE_BUILD_DATE=$(date '+%Y-%m-%d_%H-%M-%S')

output_dir=out
mkdir -p "$output_dir"

BOOT="$output_dir/arch/arm64/boot"
DTS="$BOOT/dts"

# Configs
CODENAME="munch"
DEFCONFIG="munch_defconfig"
BRANCH=$(git branch --show-current)
BRANCH=${BRANCH:-${GITHUB_REF_NAME:-unknown}}

# Make Flags
MAKE_FLAGS=(
    O="$output_dir"
    ARCH=arm64
    SUBARCH=ARM64
    CC="ccache clang"
    HOSTCC=gcc
    LD=ld.lld
    AS=llvm-as
    AR=llvm-ar
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump
    STRIP=llvm-strip
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
    LLVM=1
    LLVM_IAS=1
    V=${VERBOSE:-0}
)

echo "=== Starting build for $CODENAME ==="

[[ ! -d "$AK3_DIR" ]] && echo "Error: AnyKernel3 not found at $AK3_DIR" && exit 1

LOG_FILE="$output_dir/kernel_compile.log"
rm -f "$LOG_FILE"
rm -f build.log

make "${MAKE_FLAGS[@]}" "$DEFCONFIG" 2>&1 | tee -a "$LOG_FILE"
yes "" | make "${MAKE_FLAGS[@]}" olddefconfig 2>&1 | tee -a "$LOG_FILE"

make "${MAKE_FLAGS[@]}" -j$(nproc --all) 2>&1 | tee -a "$LOG_FILE"

BUILD_STATUS=${PIPESTATUS[0]}

cp -f "$LOG_FILE" build.log

if [ "$BUILD_STATUS" -eq 0 ]; then
    make "${MAKE_FLAGS[@]}" dtbo.img 2>&1 | tee -a "$LOG_FILE" || true
    cp -f "$LOG_FILE" build.log

    find "$DTS" -type f -name '*.dtb' -exec cat {} + > "$DTBPATH"

    IMG_SRC=$(find "$BOOT" -type f -name 'Image' | head -n 1)
    if [ -n "$IMG_SRC" ]; then
        cat "$IMG_SRC" > "$IMGPATH"
    else
        echo "Error: Image not found in $BOOT"
        BUILD_STATUS=1
    fi

    DTBO_SRC=$(find "$BOOT" -type f -name 'dtbo.img' | head -n 1)
    [ -n "$DTBO_SRC" ] && cat "$DTBO_SRC" > "$DTBOPATH"
fi

end_time=$(date +%s)
elapsed_time=$((end_time - start_time))

cd "$KERNEL_PATH" || exit 1

if [ "$BUILD_STATUS" -ne 0 ] || grep -q -E '\*\*\* .*Error [0-9]+$' build.log; then
    cd "$KERNEL_PATH" || exit 1
    echo "Error: Build failed!"
    echo "Error: Compilation failed"

    tg_send_message "Compilation error!"
    tg_send_document "./build.log"

    exit 1
else
    echo "Total execution time: $elapsed_time second"
    cd "$AK3_DIR" || exit 1
    zip -r9 DGKI-AOSP-$DEVICE-$MORPHITE_BUILD_DATE.zip * -x '*.zip'

    tg_send_message "Compilation completed successfully! Execution time: $elapsed_time seconds"
    tg_send_document "./build.log"

    tg_send_document "./DGKI-AOSP-$DEVICE-$MORPHITE_BUILD_DATE.zip" \
    "DGKI ${VERSION}${PREFIX} (${BUILD_TYPE}) | branch: ${BRANCH}"
fi

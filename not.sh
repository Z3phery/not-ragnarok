#!/bin/bash

# --- Helper for logging ---
info() {
    echo -e "\n\e[1;36m==>\e[0m \e[1m$1\e[0m"
}

# --- Configuration & Paths ---
KERNEL_ROOT=$(pwd)
KERNEL_NAME="Ragnarok"
DATE=$(date +"%Y%m%d")

# Time/Data Build Fix
export LC_ALL=C 
export KBUILD_BUILD_TIMESTAMP=$(date -u "+%a %b %d %H:%M:%S UTC %Y")
export KBUILD_BUILD_USER="not-ragnarok"
export KBUILD_BUILD_HOST="Z3phery"

# Directories
TOOLCHAIN_PARENT_DIR="$HOME/toolchains"
LLVM_DIR="$TOOLCHAIN_PARENT_DIR/neutron-clang"
LLVM_PATH="$LLVM_DIR/bin/"
OUT_DIR="$KERNEL_ROOT/out"
ANYKERNEL_DIR="$KERNEL_ROOT/AnyKernel3"

# --- 1. Dependency Verification ---
info "Verifying system dependencies..."
DEPS=("curl" "jq" "tar" "zstd" "zip" "git")
missing_deps=0
for dep in "${DEPS[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
        echo -e "\e[1;31mError: Command '$dep' is missing.\e[0m"
        missing_deps=1
    fi
done

if [ "$missing_deps" -eq 1 ]; then
    echo -e "\e[1;31mPlease install the missing dependencies.\e[0m"
    exit 1
fi

# --- 2. Toolchain Setup (Neutron Clang) ---
info "Setting up Toolchain..."

API_URL="https://api.github.com/repos/Neutron-Toolchains/clang-build-catalogue/releases/latest"
TEMP_ARCHIVE_PATH="$TOOLCHAIN_PARENT_DIR/neutron-clang.tar.zst"

if [ -d "$LLVM_DIR/bin" ]; then
    info "Neutron Clang detected. Using existing version at $LLVM_DIR"
else
    info "Neutron Clang not found. Downloading latest release..."
    mkdir -p "$LLVM_DIR"
    
    DOWNLOAD_URL=$(curl -sL "$API_URL" | \
                   jq -r '.assets[] | select(.name | startswith("neutron-clang-") and endswith(".tar.zst")) | .browser_download_url')

    if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
        echo -e "\e[1;31mError: Could not get download URL.\e[0m"
        exit 1
    fi

    echo "Downloading from: $DOWNLOAD_URL"
    if ! curl -L "$DOWNLOAD_URL" -o "$TEMP_ARCHIVE_PATH"; then
        echo -e "\e[1;31mError: Download failed.\e[0m"
        rm -f "$TEMP_ARCHIVE_PATH"
        exit 1
    fi

    info "Extracting toolchain..."
    if ! tar -I 'zstd' -xvf "$TEMP_ARCHIVE_PATH" -C "$LLVM_DIR" --strip-components=1; then
        echo -e "\e[1;31mError: Extraction failed.\e[0m"
        rm -f "$TEMP_ARCHIVE_PATH"
        rm -rf "$LLVM_DIR"
        exit 1
    fi
    
    rm -f "$TEMP_ARCHIVE_PATH"
    info "Toolchain installed successfully."
fi

# --- 3. Build Environment Variables ---
PATH="$LLVM_PATH:$PATH"

HOST_BUILD_ENV="ARCH=arm64 \
                CC=clang \
                CROSS_COMPILE=aarch64-linux-gnu- \
                LLVM=1 \
                LLVM_IAS=1"

KERNEL_MAKE_ENV="DTC_EXT=$KERNEL_ROOT/tools/dtc CONFIG_BUILD_ARM64_DT_OVERLAY=y"

# --- 4. Build Process ---
echo "*****************************************"
echo " Cleaning previous output (out/)"
echo "*****************************************"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
rm -rf .version .local

info "Generating configuration (defconfig)..."
# Usando los defconfigs de tu segundo script
make O="$OUT_DIR" $HOST_BUILD_ENV vendor/kona-not_defconfig vendor/samsung/kona-sec-not.config vendor/samsung/r8q.config

if [ $? -ne 0 ]; then
    echo -e "\e[1;31mCritical Error: Configuration failed.\e[0m"
    exit 1
fi

echo "*****************************************"
echo " Compiling DTBO (Device Tree Overlay)"
echo "*****************************************"

make -j$(nproc) O="$OUT_DIR" $KERNEL_MAKE_ENV $HOST_BUILD_ENV \
    CC="clang --target=aarch64-linux-gnu" dtbo.img

echo "*****************************************"
echo " Compiling Kernel Image (Image)"
echo "*****************************************"

make -j$(nproc) O="$OUT_DIR" $KERNEL_MAKE_ENV $HOST_BUILD_ENV \
    CC="clang --target=aarch64-linux-gnu" Image

if [ ! -f "$OUT_DIR/arch/arm64/boot/Image" ]; then
    echo -e "\e[1;31mCritical Error: 'Image' file was not generated. Build failed.\e[0m"
    exit 1
fi

echo "**Build outputs:**"
ls "$OUT_DIR/arch/arm64/boot"

# --- 5. Packaging (AnyKernel3) ---

info "Starting packaging..."

if [ ! -d "$ANYKERNEL_DIR" ]; then
    echo -e "\e[1;31mError: 'AnyKernel3' folder not found inside the repository.\e[0m"
    echo "Path checked: $ANYKERNEL_DIR"
    exit 1
fi

# Cleaning old files inside AnyKernel3
rm -f "$ANYKERNEL_DIR/Image"
rm -f "$ANYKERNEL_DIR/dtbo.img"
rm -f "$ANYKERNEL_DIR/dtb"
rm -f "$ANYKERNEL_DIR"/*.zip

# Copying new compiled files
cp "$OUT_DIR/arch/arm64/boot/Image" "$ANYKERNEL_DIR/Image"

if [ -f "$OUT_DIR/arch/arm64/boot/dtbo.img" ]; then
    cp "$OUT_DIR/arch/arm64/boot/dtbo.img" "$ANYKERNEL_DIR/dtbo.img"
fi

# Concatenate DTBs
if ls "$OUT_DIR"/arch/arm64/boot/dts/vendor/qcom/*.dtb 1> /dev/null 2>&1; then
    cat "$OUT_DIR"/arch/arm64/boot/dts/vendor/qcom/*.dtb > "$ANYKERNEL_DIR/dtb"
fi

# Create final ZIP
gitsha=$(git rev-parse --short HEAD)
ZIP_NAME="Not_Kernel-${KERNEL_NAME}-${gitsha}-${DATE}.zip"

cd "$ANYKERNEL_DIR" || exit 1

# Zip everything
zip -r9 "$ZIP_NAME" * -x .git README.md *placeholder

# Move ZIP to root folder
mv "$ZIP_NAME" "$KERNEL_ROOT/"

echo "*****************************************"
echo " Build Successful!"
echo " The bomb has been planted at:"
echo " $KERNEL_ROOT/$ZIP_NAME"
echo "*****************************************"

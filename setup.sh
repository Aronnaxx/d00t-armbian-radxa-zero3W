#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color


export DOCKER_HOST="unix:///var/run/docker.sock"

# Enable debug mode if DEBUG environment variable is set
DEBUG=${DEBUG:-0}

# Function to print debug messages
debug_log() {
    if [ "$DEBUG" -eq 1 ]; then
        echo -e "${BLUE}DEBUG:${NC} $1"
    fi
}

# Function to print status messages
print_status() {
    echo -e "${GREEN}==>${NC} $1"
    debug_log "Status: $1"
}

# Function to print error messages and exit
print_error() {
    echo -e "${RED}ERROR:${NC} $1"
    debug_log "Error encountered: $1"
    exit 1
}

# Function to print warning messages
print_warning() {
    echo -e "${YELLOW}WARNING:${NC} $1"
    debug_log "Warning: $1"
}

# Function to check if a directory exists and create it if it doesn't
ensure_directory() {
    local dir="$1"
    debug_log "Checking directory: $dir"
    if [ ! -d "$dir" ]; then
        debug_log "Creating directory: $dir"
        mkdir -p "$dir" || print_error "Failed to create directory: $dir"
    fi
}

# Function to check if a file exists
check_file() {
    local file="$1"
    debug_log "Checking file: $file"
    if [ ! -f "$file" ]; then
        print_error "Required file not found: $file"
    fi
}

# Function to check if a command exists
command_exists() {
    debug_log "Checking command: $1"
    command -v "$1" >/dev/null 2>&1
}

# Function to detect OS
detect_os() {
    case "$(uname -s)" in
        Darwin*)    echo "macos";;
        Linux*)     echo "linux";;
        *)          echo "unknown";;
    esac
}

print_status "📦 Initializing Armbian build environment for Radxa Zero 3W..."
debug_log "Starting build environment initialization"

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    print_warning "Script is running as root. It's recommended to run as a regular user with sudo privileges."
    read -p "Do you want to continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check for required commands
for cmd in git curl wget; do
    if ! command_exists "$cmd"; then
        print_error "$cmd is required but not installed. Please install it first."
    fi
done

OS=$(detect_os)

if [ "$OS" = "macos" ]; then
    print_status "Detected macOS environment..."
    
    # Check for Homebrew
    if ! command_exists brew; then
        print_error "Homebrew is required but not installed. Please install it first from https://brew.sh"
    fi
    
    # Install build dependencies via Homebrew
    print_status "Installing build dependencies via Homebrew..."
    brew_packages=(
        git
        curl
        wget
        gcc
        make
        python3
        qemu
        dtc
    )
    
    for pkg in "${brew_packages[@]}"; do
        if ! brew list "$pkg" &>/dev/null; then
            if ! brew install "$pkg"; then
                print_error "Failed to install $pkg via Homebrew"
            fi
        fi
    done
    
    # Install cross-compilation tools
    if ! command_exists aarch64-linux-gnu-gcc; then
        print_status "Installing cross-compilation tools..."
        brew tap messense/macos-cross-toolchains
        brew install aarch64-unknown-linux-gnu
    fi
    
elif [ "$OS" = "linux" ]; then
    print_status "Detected Linux environment..."
    
    # Install build dependencies
    print_status "Installing build dependencies..."
    if ! sudo apt-get update; then
        print_error "Failed to update package list"
    fi

    if ! sudo apt-get install -y git curl build-essential libssl-dev bc \
        qemu-user-static debootstrap binfmt-support gcc-aarch64-linux-gnu \
        device-tree-compiler python3 wget; then
        print_error "Failed to install required packages"
    fi
else
    print_error "Unsupported operating system"
fi

# Create required directories with checks
debug_log "Setting up directory structure"
ensure_directory "submodule/build/userpatches/overlay"

# Check source files exist before copying
debug_log "Checking source overlay files"
OVERLAY_SOURCE_DIR="submodule/radxa-overlays/arch/arm64/boot/dts/rockchip/overlays"
check_file "${OVERLAY_SOURCE_DIR}/rk3568-dwc3-host.dts"
check_file "${OVERLAY_SOURCE_DIR}/radxa-zero3-rpi-camera-v2.dts"

# Copy overlay files with verification
debug_log "Copying overlay files"
cp "${OVERLAY_SOURCE_DIR}/rk3568-dwc3-host.dts" submodule/build/userpatches/overlay/ || print_error "Failed to copy rk3568-dwc3-host.dts"
cp "${OVERLAY_SOURCE_DIR}/radxa-zero3-rpi-camera-v2.dts" submodule/build/userpatches/overlay/ || print_error "Failed to copy radxa-zero3-rpi-camera-v2.dts"

# Check and copy customize-image.sh
debug_log "Checking customize-image.sh"
check_file "customize-image.sh"
cp customize-image.sh submodule/build/userpatches/customize-image.sh || print_error "Failed to copy customize-image.sh"

# Check compile script exists
debug_log "Checking compile script"
check_file "submodule/build/compile.sh"

# Compile the image
debug_log "Starting non-interactive compilation process"
./submodule/build/compile.sh BOARD=radxa-zero3 BRANCH=current RELEASE=bookworm \
     BUILD_MINIMAL=no BUILD_DESKTOP=no KERNEL_CONFIGURE=no \
     COMPRESS_OUTPUT_IMAGE=sha,img
debug_log "Compilation process completed"
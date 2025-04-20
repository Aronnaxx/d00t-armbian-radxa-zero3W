#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print status messages
print_status() {
    echo -e "${GREEN}==>${NC} $1"
}

# Function to print error messages and exit
print_error() {
    echo -e "${RED}ERROR:${NC} $1"
    exit 1
}

# Function to print warning messages
print_warning() {
    echo -e "${YELLOW}WARNING:${NC} $1"
}

# Function to check if a command exists
command_exists() {
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

# Clone Armbian build repo
if [ ! -d "build" ]; then
    print_status "Cloning Armbian build repository..."
    if ! git clone --depth=1 https://github.com/armbian/build.git; then
        print_error "Failed to clone Armbian build repository"
    fi
fi

cd build || print_error "Failed to change to build directory"

# Clone your custom config repo into userpatches
if [ ! -d "userpatches" ]; then
    print_status "Setting up userpatches..."
    if ! ln -s ../repo userpatches; then
        print_error "Failed to create userpatches symlink"
    fi
fi

# Init submodules (Radxa overlays)
cd ../repo || print_error "Failed to change to repo directory"

if [ ! -f .gitmodules ]; then
    print_status "Adding radxa-overlays as submodule..."
    if ! git submodule add https://github.com/radxa-pkg/radxa-overlays.git; then
        print_error "Failed to add radxa-overlays submodule"
    fi
fi

print_status "Initializing and updating submodules..."
if ! git submodule update --init --recursive; then
    print_error "Failed to initialize submodules"
fi

cd ../build || print_error "Failed to return to build directory"

print_status "✅ Setup completed successfully!"
print_status "You can now proceed with building the image using:"
echo "cd build && ./compile.sh"
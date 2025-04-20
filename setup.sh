#!/bin/bash
set -e

echo "📦 Initializing Armbian build environment for Radxa Zero 3W..."

# Install build dependencies
sudo apt-get update
sudo apt-get install -y git curl build-essential libssl-dev bc \
    qemu-user-static debootstrap binfmt-support gcc-aarch64-linux-gnu \
    device-tree-compiler python3 wget

# Clone Armbian build repo
if [ ! -d "build" ]; then
  git clone --depth=1 https://github.com/armbian/build.git
fi
cd build

# Clone your custom config repo into userpatches
if [ ! -d "userpatches" ]; then
  ln -s ../repo userpatches
fi

# Init submodules (Radxa overlays)
cd ../repo
if [ ! -f .gitmodules ]; then
  echo "Adding radxa-overlays as submodule..."
  git submodule add https://github.com/radxa-pkg/radxa-overlays.git
fi

git submodule update --init --recursive

cd ../build
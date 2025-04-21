#!/bin/bash
# This script runs inside the chroot of the target image at build time.

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

# Function to detect OS
detect_os() {
    case "$(uname -s)" in
        Darwin*)    echo "macos";;
        Linux*)     echo "linux";;
        *)          echo "unknown";;
    esac
}

# Function to create system group if it doesn't exist
create_group_if_missing() {
    local group_name="$1"
    if ! getent group "$group_name" > /dev/null; then
        print_status "Creating group: $group_name"
        groupadd "$group_name" || print_warning "Failed to create group $group_name"
    else
        print_status "Group $group_name already exists"
    fi
}

print_status "Customizing image for Radxa Zero 3W with Wi-Fi, BT, GPIO, Ollama, and repo support."

OS=$(detect_os)

# 1. Enable Wi-Fi and Bluetooth – install firmware and drivers for Zero 3W
print_status "Updating package list and installing base dependencies..."
if ! apt-get update; then
    print_error "Failed to update package list"
fi

if ! apt-get install -y network-manager bluez python3-libgpiod git i2c-tools gpiod device-tree-compiler wget curl; then
    print_error "Failed to install base packages"
fi

if ! systemctl enable NetworkManager.service; then
    print_warning "Failed to enable NetworkManager service"
fi

# Radxa AIC8800 Wi-Fi/BT firmware
print_status "Installing AIC8800 Wi-Fi/BT firmware..."
FIRMWARE_VERSION="3.0+git20240327.3561b08f-4"
FIRMWARE_URL="https://github.com/radxa-pkg/aic8800/releases/download/${FIRMWARE_VERSION}"

for pkg in aic8800-firmware aic8800-sdio-dkms aicrf-test; do
    if ! wget -q "${FIRMWARE_URL}/${pkg}_${FIRMWARE_VERSION}_all.deb"; then
        print_warning "Failed to download ${pkg}"
    fi
done

if ! dpkg -i aic8800-*.deb; then
    print_warning "Some AIC8800 packages failed to install, but continuing..."
fi

rm -f aic8800-*.deb
# Enable overlays for USB Host, I2C, and GPIO
print_status "Configuring device tree overlays..."
if ! grep -q '^overlays=' /boot/armbianEnv.txt; then
    sed -i '' '/^overlays=/d' /boot/armbianEnv.txt 2>/dev/null || sed -i '/^overlays=/d' /boot/armbianEnv.txt
fi

cat >> /boot/armbianEnv.txt <<EOT
overlays=rk3568-dwc3-host i2c1 i2c3
param_i2c1=on
param_i2c3=on
EOT

# Load I2C dev module
echo "i2c-dev" >> /etc/modules

# 3. Bluetooth UART setup
print_status "Configuring Bluetooth UART..."
cat > /etc/systemd/system/btattach.service << 'EOT'
[Unit]
Description=Attach Bluetooth adapter (Radxa Zero 3W)
After=dev-ttyS1.device

[Service]
Type=simple
ExecStart=/usr/bin/hciattach -s 1500000 /dev/ttyS1 any 1500000 flow
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOT

if ! ln -sf /etc/systemd/system/btattach.service /etc/systemd/system/multi-user.target.wants/btattach.service; then
    print_warning "Failed to enable btattach service"
fi

# 4. Install Ollama and configure it as a systemd service
print_status "Installing Ollama..."
OLLAMA_URL="https://ollama.com/download/ollama-linux-arm64.tgz"
OLLAMA_DIR="/usr/lib/ollama"

if ! wget -q -O /tmp/ollama.tgz "$OLLAMA_URL"; then
    print_error "Failed to download Ollama"
fi

if ! mkdir -p "$OLLAMA_DIR"; then
    print_error "Failed to create Ollama directory"
fi

if ! tar -xzf /tmp/ollama.tgz -C "$OLLAMA_DIR"; then
    print_error "Failed to extract Ollama"
fi

ln -sf "$OLLAMA_DIR/ollama" /usr/bin/ollama
rm -f /tmp/ollama.tgz

# Create Ollama user and group
if ! useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama; then
    print_warning "Ollama user may already exist"
fi

usermod -a -G ollama root

# Configure Ollama service
cat > /etc/systemd/system/ollama.service << 'EOT'
[Unit]
Description=Ollama LLM Service
After=network.target

[Service]
User=ollama
Group=ollama
ExecStart=/usr/bin/ollama serve
Restart=on-failure
RestartSec=5
Environment=OLLAMA_HOST=0.0.0.0

[Install]
WantedBy=multi-user.target
EOT

if ! ln -sf /etc/systemd/system/ollama.service /etc/systemd/system/multi-user.target.wants/ollama.service; then
    print_warning "Failed to enable Ollama service"
fi

# 5. Create required groups and robot user
print_status "Setting up system groups..."
create_group_if_missing "gpio"
create_group_if_missing "i2c"
create_group_if_missing "spi"

print_status "Setting up robot user and repository..."
if ! id robot &>/dev/null; then
    print_status "Creating robot user..."
    if ! useradd -m -G sudo,dialout,gpio,i2c,spi -s /bin/bash robot; then
        print_error "Failed to create robot user"
    fi
    
    print_status "Setting robot user password..."
    if ! echo "robot:robot" | chpasswd; then
        print_error "Failed to set robot user password"
    fi
else
    print_status "Robot user already exists, ensuring correct group membership..."
    usermod -a -G sudo,dialout,gpio,i2c,spi robot || print_warning "Failed to update robot user groups"
fi

# Ensure firstboot config is disabled
print_status "Disabling firstboot configuration..."
if [ -f /etc/default/armbian-firstboot-config ]; then
    sed -i 's/ENABLED=1/ENABLED=0/' /etc/default/armbian-firstboot-config || print_warning "Failed to disable firstboot config"
fi

# Clone repository with better error handling
print_status "Cloning Open Duck Mini Runtime repository..."
REPO_PATH="/home/robot/Open_Duck_Mini_Runtime"
if [ ! -d "$REPO_PATH" ]; then
    if ! sudo -u robot git clone https://github.com/apirrone/Open_Duck_Mini_Runtime.git "$REPO_PATH"; then
        print_error "Failed to clone Open Duck Mini Runtime repository"
    fi
    chown -R robot:robot "$REPO_PATH" || print_warning "Failed to set repository ownership"
else
    print_status "Repository already exists at $REPO_PATH"
fi

# Clean up
print_status "Cleaning up..."
apt-get clean
rm -rf /var/lib/apt/lists/*

print_status "✅ Image customization completed successfully!"

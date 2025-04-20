#!/bin/bash
# This script runs inside the chroot of the target image at build time.

set -e

echo "Customizing image for Radxa Zero 3W with Wi-Fi, BT, GPIO, Ollama, and repo support."

# 1. Enable Wi-Fi and Bluetooth – install firmware and drivers for Zero 3W
apt-get update
apt-get install -y network-manager bluez python3-libgpiod git i2c-tools gpiod device-tree-compiler wget curl
systemctl enable NetworkManager.service

# Radxa AIC8800 Wi-Fi/BT firmware (ignore failure if already installed)
wget -q https://github.com/radxa-pkg/aic8800/releases/download/3.0%2Bgit20240327.3561b08f-4/aic8800-firmware_3.0+git20240327.3561b08f-4_all.deb
wget -q https://github.com/radxa-pkg/aic8800/releases/download/3.0%2Bgit20240327.3561b08f-4/aic8800-sdio-dkms_3.0+git20240327.3561b08f-4_all.deb
wget -q https://github.com/radxa-pkg/aic8800/releases/download/3.0%2Bgit20240327.3561b08f-4/aicrf-test_3.0+git20240327.3561b08f-4_arm64.deb

dpkg -i aic8800-*.deb || true
rm -f aic8800-*.deb

# 2. Compile and enable USB OTG Host-mode overlay from radxa-overlays submodule
dtc -I dts -O dtb -@ \
  -o /boot/dtb/rockchip/overlays/rk3568-dwc3-host.dtbo \
  /root/radxa-overlays/arch/arm64/boot/dts/rockchip/overlays/rk3568-dwc3-host.dts

# Enable overlays for USB Host, I2C, and GPIO
grep -q '^overlays=' /boot/armbianEnv.txt && sed -i '/^overlays=/d' /boot/armbianEnv.txt
cat >> /boot/armbianEnv.txt <<EOT
overlays=rk3568-dwc3-host i2c1 i2c3
param_i2c1=on
param_i2c3=on
EOT

# Load I2C dev module
echo "i2c-dev" >> /etc/modules

# 3. Bluetooth UART setup
cat > /etc/systemd/system/btattach.service << 'EOT'
[Unit]
Description=Attach Bluetooth adapter (Radxa Zero 3W)
After=dev-ttyS1.device

[Service]
Type=simple
ExecStart=/usr/bin/hciattach -s 1500000 /dev/ttyS1 any 1500000 flow
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOT

ln -s /etc/systemd/system/btattach.service /etc/systemd/system/multi-user.target.wants/btattach.service

# 4. Install Ollama and configure it as a systemd service
OLLAMA_URL="https://ollama.com/download/ollama-linux-arm64.tgz"
wget -q -O /tmp/ollama.tgz "$OLLAMA_URL"
mkdir -p /usr/lib/ollama
 tar -xzf /tmp/ollama.tgz -C /usr/lib/ollama
ln -s /usr/lib/ollama/ollama /usr/bin/ollama
rm /tmp/ollama.tgz

useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama
usermod -a -G ollama root
sudo -u ollama /usr/bin/ollama --setup

cat > /etc/systemd/system/ollama.service << 'EOT'
[Unit]
Description=Ollama LLM Service
After=network.target

[Service]
User=ollama
Group=ollama
ExecStart=/usr/bin/ollama serve
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOT

ln -s /etc/systemd/system/ollama.service /etc/systemd/system/multi-user.target.wants/ollama.service

# 5. Create a user and clone the Open Duck Mini Runtime
useradd -m -G sudo,dialout,gpio -s /bin/bash robot
 echo "robot:robot" | chpasswd
sed -i 's/ENABLED=1/ENABLED=0/' /etc/default/armbian-firstboot-config || true

sudo -u robot git clone https://github.com/apirrone/Open_Duck_Mini_Runtime.git /home/robot/Open_Duck_Mini_Runtime
chown -R robot:robot /home/robot/Open_Duck_Mini_Runtime

apt-get clean

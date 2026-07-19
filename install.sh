#!/bin/bash

# =============================================================================
# BW Camera Low Level - Script d'installation
# Converting any camera to Black & White (GREY format) via v4l2loopback
# Author: Mistral Vibe
# Usage: sudo ./install.sh
# =============================================================================

set -e

# =============================================================================
# Configuration
# =============================================================================
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_VERSION=$(uname -r)
MODULE_NAME="v4l2loopback"
DEV_SRC="/dev/video0"
DEV_DST="/dev/video20"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Helper functions
# =============================================================================
print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[-]${NC} $1"
}

# =============================================================================
# Check root
# =============================================================================
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root (sudo)."
    exit 1
fi

# =============================================================================
# Step 1: Install dependencies
# =============================================================================
print_info "Installing dependencies..."
apt-get update -qq > /dev/null 2>&1
apt-get install -y -qq gcc libv4l-dev v4l-utils zstd > /dev/null 2>&1
print_success "Dependencies installed."

# =============================================================================
# Step 2: Handle v4l2loopback module
# =============================================================================
print_info "Setting up v4l2loopback module..."

# Try to use pre-compiled module first
MODULE_KO=""
for KERNEL in $(ls /lib/modules/ 2>/dev/null | grep -E "^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+" | sort -r); do
    KO_PATH="/lib/modules/$KERNEL/kernel/v4l2loopback/v4l2loopback.ko.zst"
    if [ -f "$KO_PATH" ]; then
        KO_DIR=$(dirname "$KO_PATH")
        KO_FILE="$KO_DIR/v4l2loopback.ko"
        zstd -d "$KO_PATH" -o "$KO_FILE" --force -q 2>/dev/null
        if [ -f "$KO_FILE" ]; then
            MODULE_KO="$KO_FILE"
            print_success "Found pre-compiled module: $MODULE_KO"
            break
        fi
    fi
done

# If no pre-compiled module, try DKMS
if [ -z "$MODULE_KO" ]; then
    print_info "No pre-compiled module found, trying DKMS..."
    if ! dpkg -l | grep -q v4l2loopback-dkms; then
        apt-get install -y -qq v4l2loopback-dkms > /dev/null 2>&1
    fi
    
    # Try to load via modprobe
    if modprobe $MODULE_NAME devices=1 exclusive_caps=1 video_nr=20 2>/dev/null; then
        print_success "Module loaded via modprobe."
    else
        print_error "Failed to load module. Check dmesg | tail"
        exit 1
    fi
fi

# If we have a .ko file, try insmod
if [ -n "$MODULE_KO" ] && ! lsmod | grep -q $MODULE_NAME; then
    insmod "$MODULE_KO" devices=1 exclusive_caps=1 video_nr=20 2>/dev/null || {
        print_error "Failed to load module with insmod."
        exit 1
    }
    print_success "Module loaded via insmod."
fi

# =============================================================================
# Step 3: Verify /dev/video20 exists
# =============================================================================
for i in {1..10}; do
    if [ -e "$DEV_DST" ]; then
        break
    fi
    sleep 0.5
done

if [ ! -e "$DEV_DST" ]; then
    print_error "$DEV_DST not created."
    print_error "Check: ls /dev/video*"
    print_error "And: dmesg | grep $MODULE_NAME"
    exit 1
fi

print_success "$DEV_DST is available!"

# =============================================================================
# Step 4: Configure video formats
# =============================================================================
print_info "Configuring video formats..."

# bw_camera sets both formats itself via S_FMT (source YUYV 640x480 @30 FPS,
# destination YUV420/I420 grayscale). We only pre-set the virtual camera format
# so consumer apps immediately see it. YU12 (=I420) is used because
# Teams/Chrome/WebRTC reject the GREY format.
if v4l2-ctl -d "$DEV_DST" --set-fmt-video=width=640,height=480,pixelformat=YU12 2>/dev/null; then
    print_success "Virtual camera pre-set (640x480 YU12/I420)."
else
    print_warning "Could not pre-set YU12 on $DEV_DST (bw_camera will set it)."
fi

# =============================================================================
# Step 5: Compile bw_camera if needed
# =============================================================================
print_info "Compiling bw_camera..."

cd "$PROJECT_DIR"

if [ ! -f "bw_camera" ]; then
    if [ -f "Makefile" ]; then
        make > /dev/null 2>&1
    else
        gcc -O2 -Wall -o bw_camera bw_camera.c > /dev/null 2>&1
    fi
    
    if [ ! -f "bw_camera" ]; then
        print_error "Failed to compile bw_camera."
        exit 1
    fi
    print_success "bw_camera compiled."
else
    print_info "bw_camera already compiled."
fi

# Make scripts executable
chmod +x "$PROJECT_DIR"/bw_camera
chmod +x "$PROJECT_DIR"/start_bw_camera.sh

# =============================================================================
# Step 6: Setup permanent loading
# =============================================================================
print_info "Setting up permanent configuration..."

# Create modules-load.d config
cat > /etc/modules-load.d/v4l2loopback.conf << EOF
# Load v4l2loopback at boot
v4l2loopback
EOF

# Create modprobe.d config
cat > /etc/modprobe.d/v4l2loopback.conf << EOF
# Options for v4l2loopback
options v4l2loopback devices=1 exclusive_caps=1 video_nr=20
EOF

# Create systemd service
cat > /etc/systemd/system/bw_camera.service << EOF
[Unit]
Description=BW Camera Driver (Black & White)
After=network.target syslog.target

[Service]
Type=simple
WorkingDirectory=$PROJECT_DIR
ExecStart=$PROJECT_DIR/start_bw_camera.sh start
Restart=always
RestartSec=5
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Reload and enable systemd
systemctl daemon-reload > /dev/null 2>&1
systemctl enable bw_camera.service > /dev/null 2>&1

print_success "Permanent configuration set."

# =============================================================================
# Step 7: Start the service
# =============================================================================
print_info "Starting bw_camera service..."

# Stop any existing instance (match the binary exactly, not this script's path)
pkill -x bw_camera 2>/dev/null || true
sleep 0.5

# Start via systemd
systemctl start bw_camera.service 2>/dev/null
sleep 1

# Check if running
if systemctl is-active --quiet bw_camera.service 2>/dev/null; then
    print_success "Service started successfully."
else
    # Fallback to manual start
    print_info "Starting manually..."
    cd "$PROJECT_DIR"
    ./start_bw_camera.sh start > /dev/null 2>&1 &
    sleep 1
    if pgrep -x bw_camera > /dev/null; then
        print_success "Driver started manually."
    else
        print_error "Failed to start driver."
        exit 1
    fi
fi

# =============================================================================
# Final summary
# =============================================================================
echo ""
print_success "=============================================="
print_success "BW Camera Installation COMPLETE!"
print_success "=============================================="
echo ""
print_info "Summary:"
print_info "  - Module: v4l2loopback loaded"
print_info "  - Virtual camera: $DEV_DST (640x480 I420 grayscale @30 FPS)"
print_info "  - Service: bw_camera.service (enabled)"
print_info "  - Permanent: Yes (survives reboot)"
echo ""
print_success "Usage:"
print_success "  - In Teams/Chrome/Zoom: Select '$DEV_DST' or 'Video20'"
echo ""
print_info "Useful commands:"
print_info "  - Check service:     sudo systemctl status bw_camera.service"
print_info "  - View logs:        journalctl -u bw_camera.service -f"
print_info "  - Restart:          sudo systemctl restart bw_camera.service"
print_info "  - Stop:             sudo ./start_bw_camera.sh stop"
print_info "  - Verify devices:   ls /dev/video*"
echo ""

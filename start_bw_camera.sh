#!/bin/bash

# =============================================================================
# BW Camera - Start/Stop Script
# Start or stop the black & white camera driver
# Author: Mistral Vibe
# Usage: sudo ./start_bw_camera.sh [start|stop|restart]
# =============================================================================

# Configuration - Edit these if needed
DEV_SRC="/dev/video0"      # Physical camera source
DEV_DST="/dev/video20"     # Virtual camera (v4l2loopback)
MODULE="v4l2loopback"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Helper functions
# =============================================================================
print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

# =============================================================================
# Check root
# =============================================================================
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root (sudo)."
    exit 1
fi

# =============================================================================
# Load v4l2loopback module if not loaded
# =============================================================================
load_module() {
    if ! lsmod | grep -q "$MODULE"; then
        print_info "Loading $MODULE module..."
        
        # Try modprobe first
        if modprobe $MODULE devices=1 exclusive_caps=1 video_nr=20 2>/dev/null; then
            print_success "Module loaded via modprobe."
        else
            # Try to find and load .ko file
            KO_FILE=$(find /lib/modules -name "v4l2loopback.ko" 2>/dev/null | head -1)
            if [ -n "$KO_FILE" ]; then
                insmod "$KO_FILE" devices=1 exclusive_caps=1 video_nr=20 2>/dev/null
                if [ $? -eq 0 ]; then
                    print_success "Module loaded via insmod."
                else
                    print_error "Failed to load module."
                    print_error "Install it with: sudo apt install v4l2loopback-dkms"
                    exit 1
                fi
            else
                print_error "Module file not found."
                print_error "Install with: sudo apt install v4l2loopback-dkms"
                exit 1
            fi
        fi
        
        # Wait for device to appear
        for i in {1..10}; do
            if [ -e "$DEV_DST" ]; then
                break
            fi
            sleep 0.5
        done
        
        if [ ! -e "$DEV_DST" ]; then
            print_error "$DEV_DST not created after loading module."
            print_error "Check: ls /dev/video*"
            exit 1
        fi
        print_success "$DEV_DST is available."
    else
        print_info "Module $MODULE already loaded."
    fi
}

# =============================================================================
# Start the BW camera
# =============================================================================
do_start() {
    load_module
    
    # Check source camera exists
    if [ ! -e "$DEV_SRC" ]; then
        print_error "$DEV_SRC does not exist."
        exit 1
    fi
    
    # Note: bw_camera sets both formats itself via the V4L2 S_FMT ioctl
    # (source YUYV 640x480 @30 FPS, destination YUV420/I420 grayscale). We only
    # pre-set the virtual camera format so consumer apps immediately see it.
    # YU12 (=I420) is used because Teams/Chrome/WebRTC reject the GREY format.
    print_info "Pre-setting $DEV_DST (640x480 YU12/I420)..."
    if ! v4l2-ctl -d "$DEV_DST" --set-fmt-video=width=640,height=480,pixelformat=YU12 2>/dev/null; then
        print_warning "Could not pre-set YU12 on $DEV_DST (bw_camera will set it)."
    fi
    
    # Compile if needed
    if [ ! -f "./bw_camera" ]; then
        print_info "Compiling bw_camera..."
        if [ -f "Makefile" ]; then
            make > /dev/null 2>&1
        else
            gcc -O2 -Wall -o bw_camera bw_camera.c > /dev/null 2>&1
        fi
        
        if [ ! -f "./bw_camera" ]; then
            print_error "Failed to compile bw_camera."
            print_error "Install dependencies: sudo apt install gcc libv4l-dev"
            exit 1
        fi
        print_success "bw_camera compiled."
    fi
    
    # Check if already running.
    # NOTE: match the binary name EXACTLY (-x). A loose "-f ./bw_camera" also
    # matches this script's own path (.../bw_camera_low_level/...), causing a
    # false positive and a systemd restart loop.
    if pgrep -x bw_camera > /dev/null; then
        print_warning "bw_camera is already running."
        return 0
    fi
    
    # Start the driver
    print_info "Starting bw_camera..."
    print_info "Press Ctrl+C in this terminal to stop."
    
    # Run in foreground (for service compatibility)
    exec ./"bw_camera"
}

# =============================================================================
# Stop the BW camera
# =============================================================================
do_stop() {
    print_info "Stopping bw_camera..."
    pkill -x bw_camera 2>/dev/null
    
    # Optional: unload module (requires closing all apps using /dev/video20)
    # rmmod $MODULE 2>/dev/null || true
    
    print_success "bw_camera stopped."
}

# =============================================================================
# Main
# =============================================================================
case "$1" in
    start)
        do_start
        ;;
    stop)
        do_stop
        ;;
    restart)
        do_stop
        sleep 1
        do_start
        ;;
    *)
        echo "BW Camera Start/Stop Script"
        echo ""
        echo "Usage: sudo $0 {start|stop|restart}"
        echo ""
        echo "Examples:"
        echo "  sudo $0 start    # Start BW camera"
        echo "  sudo $0 stop     # Stop BW camera"
        echo "  sudo $0 restart  # Restart BW camera"
        echo ""
        echo "The virtual camera ($DEV_DST) will be available in Teams/Chrome/Zoom."
        exit 1
        ;;
esac

exit 0

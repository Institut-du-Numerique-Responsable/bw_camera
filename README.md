# BW Camera Low Level

**Convert any webcam to Black & White (GREY format) in Linux** using V4L2 loopback.

Grayscale webcam (640x480 @ 30 FPS) compatible with **Teams, Chrome, Zoom, OBS, etc.**

Output is **I420 (YUV420) with neutral chroma** — a black & white image in a
format the apps actually accept. Bandwidth is still saved because the constant
color planes compress to almost nothing in the app's video encoder (GREY output
would be lighter on the wire but is rejected by Teams/Chrome/WebRTC).

---

## 📁 Project Structure

```
bw_camera_low_level/
├── bw_camera.c          # Main C program (V4L2 API)
├── Makefile             # Compilation rules
├── start_bw_camera.sh   # Start/stop script
├── install.sh           # Full installation script
└── README.md            # This file
```

---

## 🚀 Quick Start

### 1. Install Dependencies

```bash
sudo apt update
sudo apt install gcc libv4l-dev v4l-utils zstd
```

### 2. Run the Installer

```bash
chmod +x install.sh
sudo ./install.sh
```

That's it! Your black & white camera will be available as **`/dev/video20`**.

---

## 🔧 Manual Installation

### 1. Load v4l2loopback Module

```bash
# For most systems (pre-compiled module exists)
sudo modprobe v4l2loopback devices=1 exclusive_caps=1 video_nr=20

# If the above fails, try with DKMS
sudo apt install v4l2loopback-dkms
sudo modprobe v4l2loopback devices=1 exclusive_caps=1 video_nr=20
```

Verify the device was created:
```bash
ls /dev/video*  # Should show /dev/video20
```

### 2. (Optional) Pre-set the Virtual Camera Format

`bw_camera` configures both the source (**YUYV 640x480 @30 FPS**) and the
destination (**I420/YUV420 640x480**) itself via the V4L2 `S_FMT` ioctl, so you
don't need to set formats manually. You may still pre-set the virtual camera so
consumer apps immediately see it:

```bash
sudo v4l2-ctl -d /dev/video20 --set-fmt-video=width=640,height=480,pixelformat=YU12
```

> **Note:** the source camera must support the **YUYV** pixel format and the
> **streaming (mmap)** I/O method — the case for virtually all UVC webcams.
> Check with `v4l2-ctl --list-formats-ext -d /dev/video0`.

### 3. Compile and Run

```bash
# Compile
make

# Run (as root)
sudo ./start_bw_camera.sh start

# Stop
sudo ./start_bw_camera.sh stop
```

---

## 📖 How It Works

1. **v4l2loopback** creates a virtual camera device (`/dev/video20`)
2. **bw_camera.c** captures from your physical camera (`/dev/video0`):
   - Configures the source to **YUYV** (640x480 @ 30 FPS) and captures via
     **streaming mmap** (the I/O method UVC webcams support)
   - Extracts the **Y bytes** (luminance = grayscale) from each YUYV line
   - Writes the result to `/dev/video20` as **I420 (YUV420)** with the luminance
     in the Y plane and the U/V color planes set to a neutral 128 (grayscale) —
     a format Teams/Chrome/WebRTC accept (they reject GREY)
3. **Teams/Chrome/Zoom** sees `/dev/video20` as a regular camera

---

## ⚙️ Configuration

### Change Resolution/FPS

Edit `bw_camera.c` and modify these lines:

```c
#define WIDTH   640   // Width (pixels)
#define HEIGHT  480   // Height (pixels)
#define FPS     30    // Frames per second
```

> The chosen resolution must be supported by your camera in **YUYV**. If not,
> `bw_camera` reports the format it actually got and exits with an error.

Then recompile:
```bash
make clean && make
```

### Change Video Devices

Edit `start_bw_camera.sh`:

```bash
DEV_SRC="/dev/video1"   # Physical camera
DEV_DST="/dev/video21"  # Virtual camera
```

---

## 📦 Sharing

### Create ZIP Archive

```bash
zip -r bw_camera_low_level.zip *
```

### Share via Git

```bash
cd /home/guillaume/bw_camera_low_level
git init
git add .
git commit -m "BW Camera Low Level - Black and White Webcam"
```

---

## 🔄 Permanent Setup

To ensure the camera works after reboot:

```bash
# Run the installer (handles everything)
sudo ./install.sh
```

This creates:
- `/etc/modules-load.d/v4l2loopback.conf` (auto-load module)
- `/etc/modprobe.d/v4l2loopback.conf` (module options)
- `/etc/systemd/system/bw_camera.service` (systemd service)

### Manual Permanent Setup

```bash
# 1. Auto-load module at boot
echo "v4l2loopback" | sudo tee /etc/modules-load.d/v4l2loopback.conf

# 2. Module options
echo "options v4l2loopback devices=1 exclusive_caps=1 video_nr=20" | sudo tee /etc/modprobe.d/v4l2loopback.conf

# 3. Create systemd service
cat > /tmp/bw_camera.service << EOF
[Unit]
Description=BW Camera Driver (Black & White)
After=network.target syslog.target

[Service]
Type=simple
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/start_bw_camera.sh start
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
sudo cp /tmp/bw_camera.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable bw_camera.service
sudo systemctl start bw_camera.service
```

---

## 🐛 Troubleshooting

### `/dev/video20` does not exist

```bash
# Check if module is loaded
lsmod | grep v4l2loopback

# If not, load it
sudo modprobe v4l2loopback devices=1 exclusive_caps=1 video_nr=20

# List all video devices
ls /dev/video*
```

### "la camera n'a pas accepte le format YUYV"

`bw_camera` requires the source to provide **YUYV**. Check the formats and
resolutions your camera supports:
```bash
v4l2-ctl --list-formats-ext -d /dev/video0
```

Pick a resolution listed under `'YUYV'` and set `WIDTH`/`HEIGHT` in
`bw_camera.c` accordingly, then `make clean && make`. If your camera offers no
YUYV mode at all (only MJPG, for example), the Y-plane extraction in
`bw_camera.c` would need to be adapted to that format.

### Permission denied

```bash
# Add user to video group
sudo usermod -aG video $USER
# Log out and back in
```

### DKMS build fails (kernel version mismatch)

Use the pre-compiled module:
```bash
# Find the module
find /lib/modules -name "v4l2loopback.ko.zst"

# Decompress it
sudo zstd -d /path/to/v4l2loopback.ko.zst -o /path/to/v4l2loopback.ko --force

# Load it
sudo insmod /path/to/v4l2loopback.ko devices=1 exclusive_caps=1 video_nr=20
```

---

## 📜 License

**MIT License** - Free to use, modify, and share.

---

## 🔗 Resources

- [V4L2 Documentation](https://www.kernel.org/doc/html/latest/userspace-api/media/v4l/v4l2.html)
- [v4l2loopback GitHub](https://github.com/umlaeute/v4l2loopback)
- [Linux Video Devices](https://linuxtv.org/)

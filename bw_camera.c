#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/videodev2.h>
#include <string.h>
#include <errno.h>
#include <signal.h>

#define WIDTH   640
#define HEIGHT  480
#define FPS     30
#define NBUF    4        // nombre de buffers mmap pour la capture

// Structure pour gérer les buffers mmap de la caméra source
struct buffer {
    void   *start;
    size_t  length;
};

static volatile sig_atomic_t running = 1;

static void on_signal(int sig) {
    (void)sig;
    running = 0;
}

static int xioctl(int fd, unsigned long request, void *arg) {
    int r;
    do {
        r = ioctl(fd, request, arg);
    } while (r == -1 && errno == EINTR);
    return r;
}

// Écrit exactement `count` octets (gère les écritures partielles).
static ssize_t write_full(int fd, const unsigned char *buf, size_t count) {
    size_t done = 0;
    while (done < count) {
        ssize_t n = write(fd, buf + done, count - done);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                usleep(1000);
                continue;
            }
            return -1;
        }
        done += (size_t)n;
    }
    return (ssize_t)done;
}

int main() {
    int fd_src = -1, fd_dst = -1;
    struct v4l2_format fmt;
    struct v4l2_capability cap;
    struct buffer buffers[NBUF];
    unsigned int n_buffers = 0;
    int rc = 1; // code retour par défaut = erreur

    // Ctrl+C -> arrêt propre (STREAMOFF, munmap, close)
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    // Ouvre la caméra source (ex: /dev/video0)
    fd_src = open("/dev/video0", O_RDWR);
    if (fd_src < 0) {
        perror("Erreur: Impossible d'ouvrir /dev/video0");
        return 1;
    }

    // Ouvre la caméra virtuelle (v4l2loopback, ex: /dev/video20)
    fd_dst = open("/dev/video20", O_RDWR);
    if (fd_dst < 0) {
        perror("Erreur: Impossible d'ouvrir /dev/video20");
        close(fd_src);
        return 1;
    }

    // La plupart des webcams UVC ne supportent que le streaming (mmap),
    // pas la methode read(). On le verifie explicitement.
    memset(&cap, 0, sizeof(cap));
    if (xioctl(fd_src, VIDIOC_QUERYCAP, &cap) == -1) {
        perror("Erreur: VIDIOC_QUERYCAP");
        goto cleanup;
    }
    if (!(cap.capabilities & V4L2_CAP_STREAMING)) {
        fprintf(stderr, "Erreur: /dev/video0 ne supporte pas le streaming.\n");
        goto cleanup;
    }

    // Configure le format source (YUYV = YUV 4:2:2 packed)
    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = WIDTH;
    fmt.fmt.pix.height = HEIGHT;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;

    if (xioctl(fd_src, VIDIOC_S_FMT, &fmt) == -1) {
        perror("Erreur: Impossible de configurer le format source");
        goto cleanup;
    }

    // S_FMT n'echoue pas si le format demande est indisponible : il l'ajuste
    // silencieusement. On verifie donc ce que le driver a reellement accepte.
    if (fmt.fmt.pix.pixelformat != V4L2_PIX_FMT_YUYV) {
        fprintf(stderr,
            "Erreur: la camera n'a pas accepte le format YUYV.\n"
            "        Formats dispo: v4l2-ctl --list-formats-ext -d /dev/video0\n");
        goto cleanup;
    }

    // Geometrie reellement negociee (le driver a pu ajuster).
    const unsigned int width        = fmt.fmt.pix.width;
    const unsigned int height       = fmt.fmt.pix.height;
    const unsigned int bytesperline = fmt.fmt.pix.bytesperline
                                        ? fmt.fmt.pix.bytesperline
                                        : width * 2; // YUYV = 2 octets/pixel
    // Plan de luminance (Y) et plans de chrominance (U, V) au format I420.
    const size_t luma_size   = (size_t)width * height;
    const size_t chroma_size = (size_t)(width / 2) * (height / 2); // par plan U ou V
    const size_t out_size    = luma_size + 2 * chroma_size;        // I420 = W*H*3/2

    if (width != WIDTH || height != HEIGHT) {
        fprintf(stderr, "Info: resolution ajustee: %ux%u (demande %dx%d)\n",
                width, height, WIDTH, HEIGHT);
    }

    // Configure la destination en YUV420 (I420).
    // GREY n'est PAS accepte par Teams/Chrome/WebRTC : on sort donc dans un
    // format standard (I420) mais avec un contenu en niveaux de gris (plans de
    // couleur neutres a 128). L'encodeur de l'appli compresse la chroma constante
    // en quasi-zero -> l'economie de bande passante est preservee.
    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    fmt.fmt.pix.width = width;
    fmt.fmt.pix.height = height;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUV420;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    fmt.fmt.pix.bytesperline = width;
    fmt.fmt.pix.sizeimage = out_size;

    if (xioctl(fd_dst, VIDIOC_S_FMT, &fmt) == -1) {
        perror("Erreur: Impossible de configurer le format destination");
        goto cleanup;
    }
    if (fmt.fmt.pix.pixelformat != V4L2_PIX_FMT_YUV420) {
        fprintf(stderr, "Erreur: /dev/video20 n'a pas accepte le format YUV420.\n");
        goto cleanup;
    }

    // Framerate source (best-effort)
    struct v4l2_streamparm parm;
    memset(&parm, 0, sizeof(parm));
    parm.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    parm.parm.capture.timeperframe.numerator = 1;
    parm.parm.capture.timeperframe.denominator = FPS;
    if (xioctl(fd_src, VIDIOC_S_PARM, &parm) == -1) {
        perror("Warning: Impossible de configurer le FPS source");
    }

    // --- Mise en place du streaming mmap sur la source ---
    struct v4l2_requestbuffers req;
    memset(&req, 0, sizeof(req));
    req.count  = NBUF;
    req.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd_src, VIDIOC_REQBUFS, &req) == -1) {
        perror("Erreur: VIDIOC_REQBUFS");
        goto cleanup;
    }
    if (req.count < 2) {
        fprintf(stderr, "Erreur: memoire buffer insuffisante sur la source.\n");
        goto cleanup;
    }

    for (n_buffers = 0; n_buffers < req.count; n_buffers++) {
        struct v4l2_buffer buf;
        memset(&buf, 0, sizeof(buf));
        buf.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index  = n_buffers;
        if (xioctl(fd_src, VIDIOC_QUERYBUF, &buf) == -1) {
            perror("Erreur: VIDIOC_QUERYBUF");
            goto cleanup;
        }
        buffers[n_buffers].length = buf.length;
        buffers[n_buffers].start  = mmap(NULL, buf.length,
                                         PROT_READ | PROT_WRITE, MAP_SHARED,
                                         fd_src, buf.m.offset);
        if (buffers[n_buffers].start == MAP_FAILED) {
            perror("Erreur: mmap");
            goto cleanup;
        }
    }

    // Met tous les buffers dans la file du driver.
    for (unsigned int i = 0; i < n_buffers; i++) {
        struct v4l2_buffer buf;
        memset(&buf, 0, sizeof(buf));
        buf.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index  = i;
        if (xioctl(fd_src, VIDIOC_QBUF, &buf) == -1) {
            perror("Erreur: VIDIOC_QBUF (init)");
            goto cleanup;
        }
    }

    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(fd_src, VIDIOC_STREAMON, &type) == -1) {
        perror("Erreur: VIDIOC_STREAMON");
        goto cleanup;
    }

    // Buffer de sortie I420. Les plans de chrominance U/V restent constants
    // (128 = gris neutre) : on les remplit une seule fois, seul le plan Y change.
    unsigned char *out_frame = malloc(out_size);
    if (!out_frame) {
        perror("Erreur: malloc out_frame");
        goto stream_off;
    }
    memset(out_frame + luma_size, 128, 2 * chroma_size); // U et V neutres

    printf("Lecture depuis /dev/video0 (%ux%u YUYV @%d FPS) -> /dev/video20 (I420 N&B)\n",
           width, height, FPS);
    printf("Appuyez sur Ctrl+C pour arreter...\n");

    // --- Boucle principale de capture ---
    while (running) {
        struct v4l2_buffer buf;
        memset(&buf, 0, sizeof(buf));
        buf.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;

        // Recupere une frame remplie par le driver.
        if (xioctl(fd_src, VIDIOC_DQBUF, &buf) == -1) {
            if (errno == EAGAIN) { usleep(1000); continue; }
            if (!running) break; // interrompu par un signal
            perror("Erreur: VIDIOC_DQBUF");
            break;
        }

        const unsigned char *frame = buffers[buf.index].start;

        // Remplit le plan Y (luminance) de la frame I420.
        // YUYV: chaque ligne = Y0 U0 Y1 V0 Y2 U1 Y3 V1 ...
        // Les octets Y sont aux positions paires de la ligne.
        // Les plans U/V restent a 128 (deja initialises hors boucle).
        for (unsigned int y = 0; y < height; y++) {
            const unsigned char *src_row = frame + (size_t)y * bytesperline;
            unsigned char *dst_row = out_frame + (size_t)y * width;
            for (unsigned int x = 0; x < width; x++) {
                dst_row[x] = src_row[x * 2];
            }
        }

        // Ecrit la frame I420 (niveaux de gris) vers la camera virtuelle.
        if (write_full(fd_dst, out_frame, out_size) < 0) {
            perror("Erreur: write");
            // On rend le buffer avant de sortir.
            xioctl(fd_src, VIDIOC_QBUF, &buf);
            break;
        }

        // Rend le buffer au driver pour reutilisation.
        if (xioctl(fd_src, VIDIOC_QBUF, &buf) == -1) {
            perror("Erreur: VIDIOC_QBUF");
            break;
        }
    }

    rc = 0; // sortie normale (Ctrl+C)
    free(out_frame);

stream_off:
    xioctl(fd_src, VIDIOC_STREAMOFF, &type);

cleanup:
    for (unsigned int i = 0; i < n_buffers; i++) {
        if (buffers[i].start && buffers[i].start != MAP_FAILED) {
            munmap(buffers[i].start, buffers[i].length);
        }
    }
    if (fd_src >= 0) close(fd_src);
    if (fd_dst >= 0) close(fd_dst);
    return rc;
}

# BW Camera

[![License: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](#licence)
[![Langage: C](https://img.shields.io/badge/langage-C-555555.svg)](bw_camera.c)
[![Plateforme: Linux](https://img.shields.io/badge/plateforme-Linux-yellow.svg)](#pr%C3%A9requis)

**Réduire l'empreinte environnementale de la visioconférence, sans quitter la caméra.**

Convertit n'importe quelle webcam Linux en caméra virtuelle noir & blanc via
**V4L2 loopback**, compatible Teams, Chrome, Zoom, OBS et tout consommateur
V4L2/WebRTC.

## Pourquoi ce projet

La visioconférence est l'un des usages numériques les plus consommateurs en
bande passante et en énergie au poste de travail : le flux vidéo domine très
largement le volume de données échangé face à l'audio ou au partage d'écran.
Une part significative de ce coût vient de l'information de **couleur**, que
l'encodeur vidéo doit constamment recalculer et transmettre à chaque image,
alors qu'elle n'apporte souvent rien à l'intelligibilité d'un échange de
travail (un visage, un geste, un tableau blanc restent compréhensibles en
niveaux de gris).

`bw_camera` agit à la source : en supprimant la chrominance réelle du flux
capturé (plans U/V fixés à une valeur neutre) avant même qu'il n'atteigne
l'application de visioconférence, il permet à l'encodeur vidéo de
l'application de compresser cette information désormais constante à
quasi-zéro. Le résultat, à qualité perçue équivalente pour un usage
professionnel classique, est une charge d'encodage/décodage et un débit
réseau réduits — donc une consommation d'énergie moindre côté poste client,
réseau et infrastructure de visioconférence, ainsi qu'un usage préservé sur
les canaux avec une bande passante contrainte (Wi-Fi surchargé, 4G,
connexions internationales).

Ce projet est développé dans une démarche de **sobriété numérique** : réduire
l'impact environnemental des usages numériques du quotidien par des choix
techniques simples, portables et sans dépendance à une application tierce,
plutôt que par la seule sensibilisation. Il s'inscrit dans les travaux de
l'[Institut du Numérique Responsable](https://institutnr.org/).

### Un levier parmi d'autres

Le passage en noir & blanc n'est qu'une des façons de réduire le coût d'un
flux vidéo : c'est un levier agissant sur la **couleur**, indépendant des
deux autres leviers classiques d'encodage vidéo, la **résolution** et la
**fréquence d'images (FPS)**. Les trois sont complémentaires et peuvent se
cumuler :

- réduire la résolution (par exemple 480x360 au lieu de 640x480) diminue le
  nombre de pixels à encoder et à transmettre à chaque image ;
- réduire le FPS (par exemple 15 au lieu de 30) diminue le nombre d'images à
  encoder par seconde, donc la charge CPU et le débit, au prix de la fluidité ;
- supprimer la chrominance (ce que fait `bw_camera`) diminue le volume
  d'information par image sans réduire ni la résolution spatiale ni la
  fluidité perçues.

`bw_camera.c` expose `WIDTH`, `HEIGHT` et `FPS` comme des constantes de
compilation (voir [Configuration](#configuration)) : ces trois leviers sont
donc directement réglables et cumulables dans ce projet, à adapter selon
l'usage (un point de visio en 15 FPS basse résolution consommera nettement
moins qu'un flux 30 FPS pleine résolution, même en noir & blanc).

## Principe

`bw_camera` est un petit programme C qui capture le flux d'une caméra physique
via l'API V4L2 (streaming mmap), extrait la luminance de chaque image et la
réinjecte dans une caméra virtuelle créée par le module noyau
[`v4l2loopback`](https://github.com/umlaeute/v4l2loopback).

Les applications de visioconférence n'acceptent généralement pas le format
`GREY` (8 bits, un seul plan) en entrée V4L2. Le flux de sortie est donc
encodé en **I420 (YUV 4:2:0)** : le plan Y contient la luminance réelle, les
plans U et V sont fixés à une valeur neutre (128), ce qui produit une image
en niveaux de gris dans un format standard accepté par Teams/Chrome/WebRTC.
Les plans de chrominance étant constants, l'encodeur vidéo de l'application
réceptrice les compresse quasiment à zéro : le gain de bande passante d'un
flux monochrome est donc conservé malgré l'usage d'un format couleur.

### Chaîne de traitement

```
/dev/video0 (caméra physique)          /dev/video20 (v4l2loopback)
     │  YUYV 640x480 @30 FPS                  │  I420 640x480
     │  capture streaming (mmap)               │  write()
     ▼                                          ▼
 ┌────────────────────────────────────────────────────┐
 │                     bw_camera                       │
 │  1. VIDIOC_S_FMT source  -> YUYV                     │
 │  2. VIDIOC_S_FMT dest    -> I420                     │
 │  3. VIDIOC_REQBUFS/QBUF/DQBUF (mmap, 4 buffers)      │
 │  4. extraction du plan Y (octets pairs de YUYV)      │
 │  5. plans U/V = 128 (calculés une seule fois)        │
 │  6. write() de la frame I420 vers /dev/video20       │
 └────────────────────────────────────────────────────┘
```

YUYV (4:2:2 empaqueté) stocke chaque paire de pixels sous la forme
`Y0 U0 Y1 V0`. Les octets de luminance sont donc aux positions paires de
chaque ligne ; il suffit de les recopier pour obtenir le plan Y du I420 de
sortie, sans conversion colorimétrique.

## Structure du dépôt

| Fichier                | Rôle                                                          |
|-------------------------|----------------------------------------------------------------|
| `bw_camera.c`           | Programme principal : capture V4L2, extraction Y, écriture I420 |
| `Makefile`              | Compilation (`gcc -O2 -Wall`)                                  |
| `start_bw_camera.sh`    | Démarrage/arrêt du binaire, chargement du module, pré-configuration du format |
| `install.sh`            | Installation complète : dépendances, module, service systemd  |

## Prérequis

- Linux avec en-têtes noyau correspondant à `uname -r`
- Module `v4l2loopback` (pré-compilé ou via DKMS)
- Caméra source exposant le format **YUYV** en streaming (mmap) — le cas de
  la quasi-totalité des webcams UVC

```bash
sudo apt update
sudo apt install gcc libv4l-dev v4l-utils zstd
```

## Installation

```bash
chmod +x install.sh
sudo ./install.sh
```

Le script `install.sh` :

1. installe les dépendances (`gcc`, `libv4l-dev`, `v4l-utils`, `zstd`) ;
2. charge `v4l2loopback` — utilise en priorité le module pré-compilé
   (`v4l2loopback.ko.zst` sous `/lib/modules/`), sinon retombe sur DKMS
   (`v4l2loopback-dkms`) ;
3. vérifie l'apparition de `/dev/video20` ;
4. pré-configure `/dev/video20` en `YU12` (I420) pour que les applications le
   détectent immédiatement ;
5. compile `bw_camera` (`make`) ;
6. installe la configuration de démarrage automatique :
   - `/etc/modules-load.d/v4l2loopback.conf` (chargement du module au boot)
   - `/etc/modprobe.d/v4l2loopback.conf` (options : `devices=1 exclusive_caps=1 video_nr=20`)
   - `/etc/systemd/system/bw_camera.service` (service `Restart=always`)
7. démarre le service et affiche un résumé.

## Installation manuelle

### 1. Charger le module v4l2loopback

```bash
sudo modprobe v4l2loopback devices=1 exclusive_caps=1 video_nr=20
```

Si le module n'est pas disponible pré-compilé :

```bash
sudo apt install v4l2loopback-dkms
sudo modprobe v4l2loopback devices=1 exclusive_caps=1 video_nr=20
```

Vérification :

```bash
ls /dev/video*   # doit lister /dev/video20
```

### 2. (Optionnel) Pré-configurer le format de la caméra virtuelle

`bw_camera` configure lui-même la source (YUYV 640x480 @30 FPS) et la
destination (I420 640x480) via l'ioctl `VIDIOC_S_FMT`. Pré-configurer
`/dev/video20` n'est utile que pour que les applications le détectent avant
même le premier lancement de `bw_camera` :

```bash
sudo v4l2-ctl -d /dev/video20 --set-fmt-video=width=640,height=480,pixelformat=YU12
```

Vérifier que la caméra source supporte bien YUYV en streaming :

```bash
v4l2-ctl --list-formats-ext -d /dev/video0
```

### 3. Compiler et lancer

```bash
make
sudo ./start_bw_camera.sh start
sudo ./start_bw_camera.sh stop
```

`start_bw_camera.sh` charge le module si nécessaire, pré-configure le format
de sortie, compile le binaire s'il est absent, puis exécute `bw_camera` au
premier plan (compatible `systemd Type=simple`). Il vérifie qu'aucune
instance n'est déjà active via `pgrep -x bw_camera` (correspondance exacte du
nom du binaire, pour éviter tout faux positif avec le chemin du script).

## Configuration

### Résolution et fréquence

Dans `bw_camera.c` :

```c
#define WIDTH   640
#define HEIGHT  480
#define FPS     30
```

La résolution demandée doit être supportée par la caméra en YUYV. Le pilote
V4L2 n'échoue pas silencieusement en cas de résolution non supportée : il
ajuste le format à la volée. `bw_camera` compare le format réellement négocié
(`VIDIOC_S_FMT` en sortie) à celui demandé et affiche une info si un
ajustement a eu lieu, ou une erreur si le format n'est pas YUYV du tout.

Recompiler après modification :

```bash
make clean && make
```

### Périphériques

Dans `start_bw_camera.sh` :

```bash
DEV_SRC="/dev/video1"    # caméra physique
DEV_DST="/dev/video21"   # caméra virtuelle
```

Les chemins des périphériques sont en dur dans `bw_camera.c`
(`/dev/video0` et `/dev/video20`) : les modifier nécessite d'éditer le source
et de recompiler.

## Déploiement permanent (systemd)

Géré automatiquement par `install.sh`. Pour une mise en place manuelle :

```bash
# Chargement du module au démarrage
echo "v4l2loopback" | sudo tee /etc/modules-load.d/v4l2loopback.conf

# Options du module
echo "options v4l2loopback devices=1 exclusive_caps=1 video_nr=20" | sudo tee /etc/modprobe.d/v4l2loopback.conf

# Service systemd
sudo tee /etc/systemd/system/bw_camera.service > /dev/null << EOF
[Unit]
Description=BW Camera Driver (Black & White)
After=network.target syslog.target

[Service]
Type=simple
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/start_bw_camera.sh start
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now bw_camera.service
```

## Problèmes rencontrés

Quelques difficultés concrètes ont orienté les choix d'implémentation du
projet :

**Le format `GREY` (niveaux de gris natif, 1 octet/pixel) est rejeté par les
applications de visio.** V4L2 propose un format dédié au noir & blanc pur,
plus léger que I420, mais Teams, Chrome et globalement WebRTC n'acceptent en
entrée que des formats couleur standard. Solution retenue : sortir en I420
(YUV 4:2:0) avec des plans de chrominance neutres (128) — l'image perçue est
identique, l'application est satisfaite, et le gain de bande passante se fait
au niveau de l'encodeur de l'application plutôt qu'au niveau du flux brut V4L2.

**`VIDIOC_S_FMT` n'échoue pas en cas de résolution non supportée.** Le pilote
V4L2 de la caméra source ajuste silencieusement le format demandé (résolution
ou pixel format) sans retourner d'erreur. `bw_camera` doit donc systématiquement
relire le format réellement négocié après l'ioctl et le comparer à celui
demandé pour détecter un ajustement ou une incompatibilité (voir
`bw_camera.c`, vérification du `pixelformat` après `VIDIOC_S_FMT`).

**Écritures partielles et `EAGAIN` sur `/dev/video20`.** Le `write()` vers le
périphérique de sortie v4l2loopback peut n'écrire qu'une partie de la frame,
ou échouer temporairement avec `EAGAIN`/`EWOULDBLOCK` si aucun consommateur
n'est encore attaché. `bw_camera` boucle sur `write()` (`write_full`) jusqu'à
écriture complète, avec une courte pause en cas de blocage temporaire.

**Faux positif de détection de processus déjà lancé.** Un premier essai de
détection via `pgrep -f ./bw_camera` correspondait aussi au chemin du script
`start_bw_camera.sh` lui-même (le nom du binaire apparaissant dans son propre
chemin), provoquant une boucle de redémarrage sous systemd. Correction :
`pgrep -x bw_camera` / `pkill -x bw_camera`, qui ne matche que le nom exact du
processus.

**Compilation DKMS instable selon la version du noyau.** Le module
`v4l2loopback-dkms` peut échouer à se compiler sur certains noyaux récents ou
patchés. `install.sh` privilégie donc un module pré-compilé (`.ko.zst`) déjà
livré avec la distribution quand il existe, et ne recourt à DKMS qu'en
absence de module pré-compilé disponible.

## Dépannage

**`/dev/video20` n'existe pas**

```bash
lsmod | grep v4l2loopback
sudo modprobe v4l2loopback devices=1 exclusive_caps=1 video_nr=20
ls /dev/video*
```

**« la camera n'a pas accepte le format YUYV »**

`bw_camera` exige YUYV en source. Lister les formats/résolutions supportés :

```bash
v4l2-ctl --list-formats-ext -d /dev/video0
```

Choisir une résolution listée sous `'YUYV'`, mettre à jour `WIDTH`/`HEIGHT`
dans `bw_camera.c`, puis `make clean && make`. Si la caméra n'expose aucun
mode YUYV (uniquement MJPG par exemple), l'extraction du plan Y devra être
adaptée au format réellement disponible (décodage MJPG préalable).

**Permission refusée sur `/dev/video0` ou `/dev/video20`**

```bash
sudo usermod -aG video $USER
# puis se déconnecter/reconnecter
```

**Échec de compilation DKMS (incompatibilité de version noyau)**

Utiliser le module pré-compilé livré avec la distribution :

```bash
find /lib/modules -name "v4l2loopback.ko.zst"
sudo zstd -d /path/to/v4l2loopback.ko.zst -o /path/to/v4l2loopback.ko --force
sudo insmod /path/to/v4l2loopback.ko devices=1 exclusive_caps=1 video_nr=20
```

## Limitations connues

- Résolution et périphériques source/destination fixés à la compilation
  (`bw_camera.c`) ; seule la copie des périphériques dans `start_bw_camera.sh`
  ne recompile pas le binaire.
- Suppose une source YUYV : les caméras exposant uniquement MJPG ou un autre
  format packed nécessitent une adaptation du code d'extraction.
- Aucune gestion de la reconnexion à chaud de la caméra source pendant
  l'exécution : une déconnexion entraîne l'arrêt de la boucle de capture.

## Licence

MIT.

## Ressources

- [Documentation V4L2](https://www.kernel.org/doc/html/latest/userspace-api/media/v4l/v4l2.html)
- [v4l2loopback (GitHub)](https://github.com/umlaeute/v4l2loopback)
- [linuxtv.org](https://linuxtv.org/)

FROM --platform=linux/arm64 alpine:3.20

RUN apk add --no-cache \
    e2fsprogs \
    alpine-base \
    docker \
    docker-cli-compose \
    socat \
    linux-lts \
    openrc

COPY <<'BUILD_SCRIPT' /build.sh
#!/bin/sh
set -e

OUTPUT=/output
IMG=$OUTPUT/vm-root.img
IMG_SIZE_MB=2048

mkdir -p $OUTPUT

# Create ext4 image
echo "Creating ext4 image (${IMG_SIZE_MB}MB)..."
dd if=/dev/zero of=$IMG bs=1M count=$IMG_SIZE_MB
mkfs.ext4 -F $IMG

# Mount and populate
MOUNT=/mnt/rootfs
mkdir -p $MOUNT
mount -o loop $IMG $MOUNT

# Bootstrap Alpine root filesystem
echo "Bootstrapping Alpine..."
mkdir -p $MOUNT/etc/apk
cp /etc/apk/repositories $MOUNT/etc/apk/
apk add --root $MOUNT --initdb --no-cache \
    alpine-base \
    openrc \
    docker \
    docker-cli-compose \
    socat \
    linux-lts \
    e2fsprogs

# Configure networking
echo "apppod" > $MOUNT/etc/hostname
cat > $MOUNT/etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# Configure Docker daemon
mkdir -p $MOUNT/etc/docker
cat > $MOUNT/etc/docker/daemon.json <<'EOF'
{
  "data-root": "/data/docker",
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": false
}
EOF

# Enable services
chroot $MOUNT rc-update add networking default
chroot $MOUNT rc-update add docker default

# Install vm-agent scripts
mkdir -p $MOUNT/usr/local/bin
cat > $MOUNT/usr/local/bin/vm-agent.sh <<'AGENT'
#!/bin/sh
exec socat VSOCK-LISTEN:1024,reuseaddr,fork EXEC:/usr/local/bin/vm-agent-handler.sh
AGENT

cat > $MOUNT/usr/local/bin/vm-agent-handler.sh <<'HANDLER'
#!/bin/sh
while IFS= read -r line; do
    cmd=$(printf '%s' "$line" | tr -d '\r')
    case "$cmd" in
        HEALTH)  printf 'OK\n' ;;
        SHUTDOWN) printf 'ACK\n'; poweroff ;;
        *)       printf 'ERR:unknown-command\n' ;;
    esac
done
HANDLER

chmod +x $MOUNT/usr/local/bin/vm-agent.sh
chmod +x $MOUNT/usr/local/bin/vm-agent-handler.sh

# Create OpenRC service for vm-agent
cat > $MOUNT/etc/init.d/vm-agent <<'SERVICE'
#!/sbin/openrc-run

description="VM Agent - vsock control channel"
command="/usr/local/bin/vm-agent.sh"
command_background=true
pidfile="/run/vm-agent.pid"

depend() {
    need docker
    after docker
}
SERVICE
chmod +x $MOUNT/etc/init.d/vm-agent
chroot $MOUNT rc-update add vm-agent default

# Configure fstab
cat > $MOUNT/etc/fstab <<'EOF'
/dev/vda    /       ext4    defaults,noatime    0 1
/dev/vdb    /data   ext4    defaults,noatime    0 2
EOF

# Create data mount point
mkdir -p $MOUNT/data

# Clean up
umount $MOUNT

# Copy kernel and initramfs
cp /boot/vmlinuz-lts $OUTPUT/vmlinuz-lts
cp /boot/initramfs-lts $OUTPUT/initramfs-lts

echo "Build complete. Artifacts in $OUTPUT/"
ls -lh $OUTPUT/
BUILD_SCRIPT

RUN chmod +x /build.sh

ENTRYPOINT ["/build.sh"]

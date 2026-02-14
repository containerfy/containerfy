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
PIDS_FILE="/tmp/apppod-forwards.pids"
while IFS= read -r line; do
    cmd=$(printf '%s' "$line" | tr -d '\r')
    case "$cmd" in
        HEALTH)  printf 'OK\n' ;;
        SHUTDOWN)
            printf 'ACK\n'
            if [ -f /data/docker-compose.yml ]; then
                docker compose -f /data/docker-compose.yml down --timeout 15 2>/dev/null
            fi
            poweroff
            ;;
        DISK)
            if mountpoint -q /data 2>/dev/null; then
                eval $(df -m /data | awk 'NR==2 {printf "used=%s;total=%s", $3, $2}')
                printf 'DISK:%s/%s\n' "$used" "$total"
            else
                printf 'DISK:0/0\n'
            fi
            ;;
        FORWARD:*)
            params=$(printf '%s' "$cmd" | cut -d: -f2-)
            vsock_port=$(printf '%s' "$params" | cut -d: -f1)
            target_port=$(printf '%s' "$params" | cut -d: -f2)
            if [ -n "$vsock_port" ] && [ -n "$target_port" ]; then
                setsid socat VSOCK-LISTEN:"$vsock_port",reuseaddr,fork TCP:127.0.0.1:"$target_port" &
                echo $! >> "$PIDS_FILE"
                printf 'ACK\n'
            else
                printf 'ERR:invalid-forward-params\n'
            fi
            ;;
        FORWARD-STOP)
            if [ -f "$PIDS_FILE" ]; then
                while read pid; do
                    kill "$pid" 2>/dev/null
                    pkill -P "$pid" 2>/dev/null
                done < "$PIDS_FILE"
                rm -f "$PIDS_FILE"
            fi
            printf 'ACK\n'
            ;;
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

# Configure fstab (nofail on /dev/vdb prevents boot hang if data disk missing)
cat > $MOUNT/etc/fstab <<'EOF'
/dev/vda    /       ext4    defaults,noatime        0 1
/dev/vdb    /data   ext4    defaults,noatime,nofail 0 2
EOF

# Create data mount point
mkdir -p $MOUNT/data

# Create OpenRC service for data-disk: formats /dev/vdb on first boot, then mounts
cat > $MOUNT/etc/init.d/data-disk <<'DATADISK'
#!/sbin/openrc-run

description="Format and mount data disk (/dev/vdb)"

depend() {
    before docker
    before vm-agent
}

start() {
    ebegin "Preparing data disk"
    if [ ! -b /dev/vdb ]; then
        ewarn "/dev/vdb not found, skipping data disk"
        eend 0
        return 0
    fi

    # Format if unformatted (no filesystem detected)
    if ! blkid /dev/vdb >/dev/null 2>&1; then
        einfo "Formatting /dev/vdb as ext4..."
        mkfs.ext4 -F /dev/vdb || { eend 1; return 1; }
    fi

    # Mount if not already mounted
    if ! mountpoint -q /data; then
        mkdir -p /data
        mount /dev/vdb /data || { eend 1; return 1; }
    fi
    eend 0
}

stop() {
    ebegin "Unmounting data disk"
    umount /data 2>/dev/null
    eend 0
}
DATADISK
chmod +x $MOUNT/etc/init.d/data-disk
chroot $MOUNT rc-update add data-disk default

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

FROM --platform=linux/arm64 alpine:3.20

RUN apk add --no-cache \
    e2fsprogs \
    alpine-base \
    docker \
    docker-cli-compose \
    socat \
    linux-lts \
    openrc \
    lz4

COPY <<'BUILD_SCRIPT' /build.sh
#!/bin/sh
set -e

OUTPUT=/output
IMG=$OUTPUT/vm-root.img

mkdir -p $OUTPUT

# Create sparse ext4 image (16GB virtual, actual usage grows as needed)
echo "Creating ext4 image..."
truncate -s 16G $IMG
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

# Configure Docker daemon (runtime uses /data/docker on persistent data disk)
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

# Pull container images directly into root filesystem via Docker-in-Docker
if [ -n "$APPPOD_IMAGES" ]; then
    echo "Starting Docker daemon for image preloading..."
    dockerd \
        --data-root $MOUNT/var/lib/docker \
        --host unix:///tmp/build-docker.sock \
        --pidfile /tmp/build-docker.pid \
        --iptables=false \
        --bridge=none \
        >/tmp/dockerd.log 2>&1 &

    echo "Waiting for Docker daemon..."
    for i in $(seq 1 30); do
        if DOCKER_HOST=unix:///tmp/build-docker.sock docker info >/dev/null 2>&1; then
            break
        fi
        if [ $i -eq 30 ]; then
            echo "Docker daemon failed to start:"
            cat /tmp/dockerd.log
            exit 1
        fi
        sleep 1
    done

    for image in $APPPOD_IMAGES; do
        echo "Pulling $image..."
        DOCKER_HOST=unix:///tmp/build-docker.sock docker pull --platform linux/arm64 "$image"
    done

    # Stop dockerd cleanly
    kill $(cat /tmp/build-docker.pid) 2>/dev/null
    wait 2>/dev/null
    echo "Image preloading complete."
fi

# Install vm-agent scripts
mkdir -p $MOUNT/usr/local/bin
cat > $MOUNT/usr/local/bin/vm-agent.sh <<'AGENT'
#!/bin/sh
exec socat VSOCK-LISTEN:1024,reuseaddr,fork EXEC:/usr/local/bin/vm-agent-handler.sh
AGENT

cat > $MOUNT/usr/local/bin/vm-agent-handler.sh <<'HANDLER'
#!/bin/sh
COMPOSE_FILE="/etc/apppod/docker-compose.yml"
PIDS_FILE="/tmp/apppod-forwards.pids"
while IFS= read -r line; do
    cmd=$(printf '%s' "$line" | tr -d '\r')
    case "$cmd" in
        HEALTH)  printf 'OK\n' ;;
        SHUTDOWN)
            printf 'ACK\n'
            if [ -f "$COMPOSE_FILE" ]; then
                docker compose -f "$COMPOSE_FILE" down --timeout 15 2>/dev/null
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
        LOGS:*)
            lines=$(printf '%s' "$cmd" | cut -d: -f2)
            if [ -f "$COMPOSE_FILE" ]; then
                log_data=$(docker compose -f "$COMPOSE_FILE" logs --tail="$lines" --no-color 2>/dev/null)
            else
                log_data=""
            fi
            byte_count=$(printf '%s' "$log_data" | wc -c)
            printf 'LOGS:%s\n%s' "$byte_count" "$log_data"
            exit 0
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

# Create OpenRC service to seed Docker data on first boot
cat > $MOUNT/etc/init.d/apppod-seed <<'SEEDRC'
#!/sbin/openrc-run

description="Seed Docker data from preloaded images"

depend() {
    after data-disk
    before docker
}

start() {
    # Copy preloaded images to data disk on first boot
    if [ -d /var/lib/docker/overlay2 ] && [ ! -d /data/docker ]; then
        ebegin "Seeding Docker with preloaded images"
        cp -a /var/lib/docker /data/docker
        eend $?
    else
        eend 0
    fi
}
SEEDRC
chmod +x $MOUNT/etc/init.d/apppod-seed
chroot $MOUNT rc-update add apppod-seed default

# Create OpenRC service for compose services
cat > $MOUNT/etc/init.d/apppod-compose <<'COMPOSERC'
#!/sbin/openrc-run

description="Start compose services"

depend() {
    need docker
    after docker
}

start() {
    ebegin "Starting compose services"
    if [ -f /etc/apppod/docker-compose.yml ]; then
        docker compose -f /etc/apppod/docker-compose.yml up -d
    fi
    eend $?
}

stop() {
    ebegin "Stopping compose services"
    if [ -f /etc/apppod/docker-compose.yml ]; then
        docker compose -f /etc/apppod/docker-compose.yml down --timeout 15
    fi
    eend $?
}
COMPOSERC
chmod +x $MOUNT/etc/init.d/apppod-compose
chroot $MOUNT rc-update add apppod-compose default

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
    before apppod-compose
    before apppod-seed
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

# Copy compose file and env files from workspace
if [ -d /workspace ]; then
    mkdir -p $MOUNT/etc/apppod
    if [ -f /workspace/docker-compose.yml ]; then
        cp /workspace/docker-compose.yml $MOUNT/etc/apppod/
        echo "Installed docker-compose.yml"
    fi
    for envfile in /workspace/*.env; do
        [ -f "$envfile" ] || continue
        cp "$envfile" $MOUNT/etc/apppod/
        echo "Installed $(basename "$envfile")"
    done
fi

# Clean up
umount $MOUNT

# Shrink filesystem to minimum size
echo "Shrinking filesystem..."
e2fsck -f -y $IMG
resize2fs -M $IMG

# Copy kernel and initramfs
cp /boot/vmlinuz-lts $OUTPUT/vmlinuz-lts
cp /boot/initramfs-lts $OUTPUT/initramfs-lts

# Compress root image with lz4
echo "Compressing root image with lz4..."
lz4 -f $IMG $IMG.lz4
rm -f $IMG
echo "Compressed: $(du -h $IMG.lz4 | cut -f1)"

echo "Build complete. Artifacts in $OUTPUT/"
ls -lh $OUTPUT/
BUILD_SCRIPT

RUN chmod +x /build.sh

ENTRYPOINT ["/build.sh"]

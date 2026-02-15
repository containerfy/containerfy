#!/bin/sh
set -e

OUTPUT=/output
IMG=$OUTPUT/vm-root.img
MOUNT=/mnt/rootfs
mkdir -p $OUTPUT $MOUNT

# Create ext4 from staged rootfs
echo "Creating ext4 image..."
truncate -s 16G $IMG
mkfs.ext4 -F $IMG
mount -o loop $IMG $MOUNT
rsync -a /vm-rootfs/ $MOUNT/

# Install compose + env files from workspace
if [ -d /workspace ]; then
    mkdir -p $MOUNT/etc/apppod
    if [ -f /workspace/docker-compose.yml ]; then
        cp /workspace/docker-compose.yml $MOUNT/etc/apppod/
        echo "Installed docker-compose.yml"
    fi
    for f in /workspace/*.env; do
        [ -f "$f" ] && cp "$f" $MOUNT/etc/apppod/
    done
fi

# Pull images via Docker-in-Docker
if [ -n "$APPPOD_IMAGES" ]; then
    echo "Starting Docker daemon for image preloading..."
    dockerd \
        --data-root $MOUNT/var/lib/docker \
        --host unix:///tmp/build.sock \
        --pidfile /tmp/build.pid \
        --iptables=false --bridge=none \
        >/tmp/dockerd.log 2>&1 &

    echo "Waiting for Docker daemon..."
    for i in $(seq 1 30); do
        if DOCKER_HOST=unix:///tmp/build.sock docker info >/dev/null 2>&1; then
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
        DOCKER_HOST=unix:///tmp/build.sock docker pull --platform linux/arm64 "$image"
    done

    kill $(cat /tmp/build.pid) 2>/dev/null
    wait 2>/dev/null
    echo "Image preloading complete."
fi

umount $MOUNT

# Shrink + compress
echo "Shrinking filesystem..."
e2fsck -f -y $IMG
resize2fs -M $IMG

cp /vm-rootfs/boot/vmlinuz-lts /vm-rootfs/boot/initramfs-lts $OUTPUT/

echo "Compressing root image with lz4..."
lz4 -f $IMG $IMG.lz4
rm -f $IMG
echo "Compressed: $(du -h $IMG.lz4 | cut -f1)"

echo "Build complete. Artifacts in $OUTPUT/"
ls -lh $OUTPUT/

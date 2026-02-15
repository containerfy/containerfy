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

# Install compose + env files + image tars from workspace
if [ -d /workspace ]; then
    mkdir -p $MOUNT/etc/apppod
    if [ -f /workspace/docker-compose.yml ]; then
        cp /workspace/docker-compose.yml $MOUNT/etc/apppod/
        echo "Installed docker-compose.yml"
    fi
    for f in /workspace/*.env; do
        [ -f "$f" ] && cp "$f" $MOUNT/etc/apppod/
    done
    if [ -d /workspace/images ]; then
        mkdir -p $MOUNT/var/cache/apppod/images
        cp /workspace/images/*.tar $MOUNT/var/cache/apppod/images/
        echo "Installed $(ls /workspace/images/*.tar | wc -l) image tar(s)"
    fi
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

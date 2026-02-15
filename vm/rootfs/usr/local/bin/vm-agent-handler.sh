#!/bin/sh
# VM Agent Handler — per-connection command processor
# Invoked by socat for each vsock connection on port 1024.
# Protocol: line-based text.
# Commands: HEALTH, SHUTDOWN, DISK, FORWARD:<vsock_port>:<target_port>, FORWARD-STOP, LOGS:<lines>
# Build commands: BUILD:<image1>,<image2>,...  PACK

COMPOSE_FILE="/etc/apppod/docker-compose.yml"
PIDS_FILE="/tmp/apppod-forwards.pids"
WORKSPACE="/mnt/workspace"
OUTPUT="/mnt/output"

while IFS= read -r line; do
    cmd=$(printf '%s' "$line" | tr -d '\r')

    case "$cmd" in
        HEALTH)
            printf 'OK\n'
            ;;
        SHUTDOWN)
            printf 'ACK\n'
            # Stop compose services gracefully before powering off
            if [ -f "$COMPOSE_FILE" ]; then
                docker compose -f "$COMPOSE_FILE" down --timeout 15 2>/dev/null
            fi
            poweroff
            ;;
        DISK)
            # Report data partition usage: DISK:<used_mb>/<total_mb>
            if mountpoint -q /data 2>/dev/null; then
                eval $(df -m /data | awk 'NR==2 {printf "used=%s;total=%s", $3, $2}')
                printf 'DISK:%s/%s\n' "$used" "$total"
            else
                printf 'DISK:0/0\n'
            fi
            ;;
        FORWARD:*)
            # FORWARD:<vsock_port>:<target_port> — start a socat bridge
            params=$(printf '%s' "$cmd" | cut -d: -f2-)
            vsock_port=$(printf '%s' "$params" | cut -d: -f1)
            target_port=$(printf '%s' "$params" | cut -d: -f2)

            if [ -n "$vsock_port" ] && [ -n "$target_port" ]; then
                # Start socat bridge in background (setsid detaches from handler)
                setsid socat VSOCK-LISTEN:"$vsock_port",reuseaddr,fork TCP:127.0.0.1:"$target_port" &
                echo $! >> "$PIDS_FILE"
                printf 'ACK\n'
            else
                printf 'ERR:invalid-forward-params\n'
            fi
            ;;
        FORWARD-STOP)
            # Kill all forwarding socat processes
            if [ -f "$PIDS_FILE" ]; then
                while read pid; do
                    kill "$pid" 2>/dev/null
                    # Also kill the socat children (fork mode)
                    pkill -P "$pid" 2>/dev/null
                done < "$PIDS_FILE"
                rm -f "$PIDS_FILE"
            fi
            printf 'ACK\n'
            ;;
        LOGS:*)
            # LOGS:<lines> — fetch recent docker compose logs, then close connection
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
        BUILD:*)
            # BUILD:<image1>,<image2>,... — pull images into Docker
            images=$(printf '%s' "$cmd" | cut -d: -f2-)
            printf 'BUILD_START\n'
            old_ifs="$IFS"
            IFS=','
            for image in $images; do
                printf 'PULLING:%s\n' "$image"
                if docker pull --platform linux/arm64 "$image" >/dev/null 2>&1; then
                    printf 'PULLED:%s\n' "$image"
                else
                    printf 'ERR:pull-failed:%s\n' "$image"
                    IFS="$old_ifs"
                    exit 1
                fi
            done
            IFS="$old_ifs"
            printf 'BUILD_IMAGES_DONE\n'
            ;;
        PACK)
            # PACK — create ext4 root image from current rootfs + pulled images
            # Expects workspace mounted at /mnt/workspace, output at /mnt/output
            printf 'PACK_START\n'

            IMG="$OUTPUT/vm-root.img"
            MOUNT="/tmp/pack-rootfs"
            mkdir -p "$MOUNT" "$OUTPUT"

            # Create ext4 image from current rootfs
            printf 'PACK_STEP:creating ext4\n'
            truncate -s 16G "$IMG"
            mkfs.ext4 -F "$IMG" >/dev/null 2>&1
            mount -o loop "$IMG" "$MOUNT"

            # Copy the running system's rootfs (excluding runtime-only paths)
            printf 'PACK_STEP:copying rootfs\n'
            rsync -a \
                --exclude='/proc/*' \
                --exclude='/sys/*' \
                --exclude='/dev/*' \
                --exclude='/run/*' \
                --exclude='/tmp/*' \
                --exclude='/mnt/*' \
                --exclude='/data/*' \
                / "$MOUNT/"

            # Install compose file and env files from workspace
            mkdir -p "$MOUNT/etc/apppod"
            if [ -f "$WORKSPACE/docker-compose.yml" ]; then
                cp "$WORKSPACE/docker-compose.yml" "$MOUNT/etc/apppod/"
                printf 'PACK_STEP:installed compose file\n'
            fi
            for f in "$WORKSPACE"/*.env; do
                [ -f "$f" ] && cp "$f" "$MOUNT/etc/apppod/"
            done

            # Save pulled images as tars for preloading on first boot
            mkdir -p "$MOUNT/var/cache/apppod/images"
            for image in $(docker images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>'); do
                tarname=$(printf '%s' "$image" | tr '/:.' '_')
                printf 'PACK_STEP:saving %s\n' "$image"
                docker save -o "$MOUNT/var/cache/apppod/images/${tarname}.tar" "$image" 2>/dev/null
            done

            umount "$MOUNT"

            # Shrink + compress
            printf 'PACK_STEP:shrinking filesystem\n'
            e2fsck -f -y "$IMG" >/dev/null 2>&1
            resize2fs -M "$IMG" >/dev/null 2>&1

            # Copy kernel + initramfs to output
            cp /boot/vmlinuz-lts /boot/initramfs-lts "$OUTPUT/" 2>/dev/null

            printf 'PACK_STEP:compressing with lz4\n'
            lz4 -f "$IMG" "$IMG.lz4" >/dev/null 2>&1
            rm -f "$IMG"

            printf 'PACK_DONE\n'
            ;;
        *)
            printf 'ERR:unknown-command\n'
            ;;
    esac
done

#!/bin/sh
# VM Agent Handler — per-connection command processor
# Invoked by socat for each vsock connection on port 1024.
# Protocol: line-based text.
# Commands: HEALTH, SHUTDOWN, DISK, FORWARD:<vsock_port>:<target_port>, FORWARD-STOP, LOGS:<lines>

COMPOSE_FILE="/etc/apppod/docker-compose.yml"
PIDS_FILE="/tmp/apppod-forwards.pids"

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
            if [ -f /data/docker-compose.yml ]; then
                log_data=$(docker compose -f /data/docker-compose.yml logs --tail="$lines" --no-color 2>/dev/null)
            else
                log_data=""
            fi
            byte_count=$(printf '%s' "$log_data" | wc -c)
            printf 'LOGS:%s\n%s' "$byte_count" "$log_data"
            exit 0
            ;;
        *)
            printf 'ERR:unknown-command\n'
            ;;
    esac
done

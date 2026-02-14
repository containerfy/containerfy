#!/bin/sh
# VM Agent Handler — per-connection command processor
# Invoked by socat for each vsock connection on port 1024.
# Protocol: line-based text. Commands: HEALTH, SHUTDOWN.

while IFS= read -r line; do
    cmd=$(printf '%s' "$line" | tr -d '\r')

    case "$cmd" in
        HEALTH)
            printf 'OK\n'
            ;;
        SHUTDOWN)
            printf 'ACK\n'
            # Stop compose services gracefully before powering off
            if [ -f /data/docker-compose.yml ]; then
                docker compose -f /data/docker-compose.yml down --timeout 15 2>/dev/null
            fi
            poweroff
            ;;
        *)
            printf 'ERR:unknown-command\n'
            ;;
    esac
done

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
            poweroff
            ;;
        *)
            printf 'ERR:unknown-command\n'
            ;;
    esac
done

#!/usr/bin/env bash
# Listen for Hyprland monitor connect/disconnect events and reconfigure.
# socat, not nc: libressl nc busy-loops in user space on this socket
# and stops reading events.

SOCKET="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"

# Wait for the socket to exist
for i in $(seq 1 10); do
    [ -S "$SOCKET" ] && break
    sleep 1
done

if [ ! -S "$SOCKET" ]; then
    echo "Hyprland socket not found, exiting"
    exit 1
fi

# Read events from the socket
socat -u UNIX-CONNECT:"$SOCKET" - | while read -r line; do
    case "$line" in
        monitoradded\>\>*|monitorremoved\>\>*)
            echo "Monitor event: $line"
            # Debounce, then drain events queued during the wait so a burst
            # (MST panels enumerate one at a time) reconfigures only once.
            sleep 2
            while read -r -t 0.05 line; do :; done
            hypr-monitor-setup
            ;;
    esac
done

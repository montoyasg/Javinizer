#!/usr/bin/env bash
set -euo pipefail

if [ -n "${VNC_PASSWORD:-}" ]; then
    /usr/bin/x11vnc -storepasswd "$VNC_PASSWORD" /tmp/vncpasswd >/dev/null
    exec /usr/bin/x11vnc -display :99 -forever -shared -rfbport "${VNC_PORT:-5900}" -rfbauth /tmp/vncpasswd
else
    exec /usr/bin/x11vnc -display :99 -forever -shared -rfbport "${VNC_PORT:-5900}" -nopw
fi

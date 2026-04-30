#!/usr/bin/env bash
set -euo pipefail

umask "${UMASK:-0002}"

mkdir -p /root/.jvsettings /root/.javinizer/assemblies /root/.config/Javinizer

exec /usr/bin/supervisord -c /opt/docker/supervisord.conf

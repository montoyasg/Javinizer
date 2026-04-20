#!/usr/bin/env bash
set -euo pipefail

mkdir -p /root/.jvsettings /root/.javinizer/assemblies /root/.config/Javinizer

exec /usr/bin/supervisord -c /opt/docker/supervisord.conf

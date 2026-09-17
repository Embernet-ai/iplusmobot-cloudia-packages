#!/bin/bash
#
# Container entrypoint for the EmberNET Cloudia image.
#
# One image, two roles, because the vendor ships two long-running supervisors:
#
#   server  `cloudia serve`, which starts cloudserver_v2, cloudweb, apiserver and
#           gohttpserver per cloudia.toml. Runs the schema migration first.
#   rcs     `rcsctl`, the Space Management UI. It starts a jzrouter and a
#           libmrpc for each space once that space has a map and a robot type.
#
# They run as two containers in one pod instead of one process tree, so each
# gets its own probe and its own restart. They share the data volumes, because
# cloudserver_v2 runs the vendor's update_map.sh after a map upload and that
# writes into /opt/jz/rcs/spaces for rcsctl to pick up.
#
# Anything else is exec'd as-is, so `podman run <img> bash` still works.
set -euo pipefail

role="${1:-server}"
shift || true

wait_tcp() {
    local host=$1 port=$2 name=$3 i
    for i in $(seq 1 "${CLOUDIA_WAIT_SECONDS:-180}"); do
        if nc -z "$host" "$port" 2>/dev/null; then
            echo "$name is up on $host:$port"
            return 0
        fi
        sleep 1
    done
    echo "gave up waiting for $name on $host:$port after ${CLOUDIA_WAIT_SECONDS:-180}s" >&2
    return 1
}

case "$role" in
    server)
        cd /opt/jz/cloudia/bin
        wait_tcp 127.0.0.1 3306 mysql
        wait_tcp 127.0.0.1 6379 redis
        wait_tcp 127.0.0.1 8086 influxdb
        # Idempotent. First boot seeds the schema from the snapshot built into
        # cloudserver_v2, later boots walk it forward to this image's version.
        # It is the same call the vendor's install_service.sh and
        # update_cloudia.sh make before every start.
        ./cloudserver_v2 -dbup
        exec ./cloudia serve "$@"
        ;;
    rcs)
        cd /opt/jz/rcs
        exec ./rcsctl -p "${RCS_PORT:-10000}" "$@"
        ;;
    *)
        exec "$role" "$@"
        ;;
esac

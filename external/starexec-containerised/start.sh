#!/usr/bin/env bash
# Simplified StarExec startup for local validation — no mkcert required.
# The container generates a self-signed TLS cert on first boot.
# Ports: HTTPS → https://localhost:7827  HTTP → http://localhost:7826
# Credentials: admin / admin
#
# Usage: ./start.sh [start|stop|status|logs]
set -euo pipefail

CONTAINER=starexec-app
IMAGE=ghcr.io/starexecmiami/starexec-arc:latest
STATE_DIR="$(cd "$(dirname "$0")" && pwd)/starexec_saved_state"
KEY="$(cd "$(dirname "$0")" && pwd)/starexec_podman_key"

cmd="${1:-start}"

case "$cmd" in
  start)
    if podman ps --filter "name=$CONTAINER" --format '{{.ID}}' | grep -q .; then
      echo "Already running. Visit https://localhost:7827  (admin:admin)"
      exit 0
    fi

    if ! podman image exists "$IMAGE"; then
      echo "Pulling $IMAGE ..."
      podman pull "$IMAGE"
    fi

    mkdir -p "$STATE_DIR"/{volDB,volExport,volStarexec}
    [ -f "$KEY" ] || ssh-keygen -t ed25519 -N '' -f "$KEY" -q

    echo "Starting StarExec…"
    podman run -d --name "$CONTAINER" \
      --cap-add=NET_RAW \
      --network slirp4netns:allow_host_loopback=true \
      --tmpfs /var/run/mysqld:rw,size=128m,mode=775 \
      -v "$STATE_DIR/volDB:/var/lib/mysql:U" \
      -v "$STATE_DIR/volExport:/export" \
      -v "$STATE_DIR/volStarexec:/home/starexec" \
      -v "$KEY:/root/.ssh/starexec_podman_key" \
      -e SSH_USERNAME="$USER" \
      -e HOST_MACHINE=host.containers.internal \
      -e SSH_PORT=22 \
      -e "SSH_SOCKET_PATH=/run/user/$(id -u)/podman/podman.sock" \
      -e MYSQL_START_TIMEOUT=180 \
      -p 7827:443 -p 7826:80 \
      "$IMAGE"

    # The image's ssl.conf has 'Redirect permanent "/" "/starexec"' which
    # also matches /starexec/... paths and breaks API access. Replace it with
    # a regex-anchored RedirectMatch that only fires for the bare root. Done
    # as soon as the container is up (before Apache has been hit for a real
    # request) so the first request the user makes lands on the fixed config.
    echo "Waiting for Apache to come up…"
    until podman exec "$CONTAINER" test -f /etc/apache2/sites-available/ssl.conf 2>/dev/null; do
      sleep 2
    done
    echo "Patching Apache redirect rule…"
    podman exec "$CONTAINER" sed -i \
      's|Redirect permanent "/" "/starexec"|RedirectMatch permanent "^/$" "/starexec/"|' \
      /etc/apache2/sites-available/ssl.conf
    podman exec "$CONTAINER" apache2ctl graceful 2>/dev/null || true

    echo "Waiting for StarExec webapp to be deployed (may take several minutes on first boot)…"
    until podman exec "$CONTAINER" test -d /project/apache-tomcat-7/webapps/starexec 2>/dev/null; do
      sleep 10
      printf "."
    done
    echo
    echo "Waiting a few extra seconds for the webapp to finish loading…"
    sleep 15

    echo "Done.  Visit https://localhost:7827  (admin:admin)"
    ;;

  stop)
    id=$(podman ps --filter "name=$CONTAINER" --format '{{.ID}}')
    if [ -n "$id" ]; then
      podman stop "$id" && podman rm "$id"
      echo "Stopped."
    else
      echo "Not running."
    fi
    ;;

  status)
    podman ps --filter "name=$CONTAINER"
    ;;

  logs)
    podman logs -f "$CONTAINER"
    ;;

  *)
    echo "Usage: $0 [start|stop|status|logs]"
    exit 1
    ;;
esac

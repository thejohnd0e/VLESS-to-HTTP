#!/bin/sh
# Docker HEALTHCHECK: one real request through the tunnel, not just "is the port open".
# Goes through the container's own HTTP proxy (the same routing every client gets, so with several
# links it tests the one in use), with the proxy login when PROXY_USER/PROXY_PASS are set.
# Healthy = PROBE_URL answered with HTTP 2xx/3xx through the tunnel within HEALTH_TIMEOUT seconds.
set -u
url="${PROBE_URL:-https://www.gstatic.com/generate_204}"
timeout="${HEALTH_TIMEOUT:-10}"
port="${HTTP_LISTEN_PORT:-8080}"
case "${LISTEN_ADDR:-0.0.0.0}" in
  0.0.0.0|::) addr=127.0.0.1 ;;            # listening everywhere: use loopback
  *:*) addr="[${LISTEN_ADDR}]" ;;          # a specific IPv6 address
  *) addr="$LISTEN_ADDR" ;;                # a specific IPv4 address
esac

# The login goes to curl on stdin (curl config syntax), not on the command line, so it does not show
# up in the process list.
login=""
if [ -n "${PROXY_USER:-}" ]; then
  login="proxy-user = \"$(printf '%s:%s' "$PROXY_USER" "${PROXY_PASS:-}" | sed 's/\\/\\\\/g; s/"/\\"/g')\""
fi
out="$(printf '%s\n' "$login" | curl -K - -sS -o /dev/null -w '%{http_code}' --max-time "$timeout" \
  --proxy "http://$addr:$port" "$url" 2>&1)" || {
  echo "unhealthy: $(printf '%s\n' "$out" | head -n 1)"; exit 1; }

case "$out" in
  2??|3??) echo "healthy: HTTP $out via tunnel"; exit 0 ;;
  *) echo "unhealthy: HTTP $out via tunnel"; exit 1 ;;
esac

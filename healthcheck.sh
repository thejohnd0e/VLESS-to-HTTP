#!/bin/sh
# Docker HEALTHCHECK: one real request through the tunnel, not just "is the port open".
# Goes through the internal health inbound (127.0.0.1:HEALTH_PORT, default 18080, no login), which
# uses the same routing as the HTTP/SOCKS5 proxies, so with several links it tests the active one.
# Healthy = PROBE_URL answered with HTTP 2xx/3xx through the tunnel within HEALTH_TIMEOUT seconds.
set -u
url="${PROBE_URL:-https://www.gstatic.com/generate_204}"
timeout="${HEALTH_TIMEOUT:-10}"
out="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$timeout" \
  --proxy "http://127.0.0.1:${HEALTH_PORT:-18080}" "$url" 2>&1)" || {
  echo "unhealthy: $(printf '%s\n' "$out" | head -n 1)"; exit 1; }
case "$out" in
  2??|3??) echo "healthy: HTTP $out via tunnel"; exit 0 ;;
  *) echo "unhealthy: HTTP $out via tunnel"; exit 1 ;;
esac

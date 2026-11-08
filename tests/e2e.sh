#!/usr/bin/env bash
# End-to-end test in a disposable Docker environment (CI): a throwaway Xray REALITY server with
# freshly generated synthetic keys, and the proxy image as its client. Nothing here touches real
# servers or credentials. Usage: tests/e2e.sh IMAGE
set -euo pipefail

IMAGE="${1:?usage: tests/e2e.sh IMAGE}"
NET=v2h-e2e
WORK="$(mktemp -d)"
chmod 755 "$WORK"
UUID="$(cat /proc/sys/kernel/random/uuid)"
URL=https://www.gstatic.com/generate_204
DEAD="203.0.113.1"   # TEST-NET-3, never answers

cleanup() {
  docker rm -f v2h-srv v2h-cli >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; echo "--- client log"; docker logs v2h-cli 2>&1 | tail -30 || true
         echo "--- server log"; docker logs v2h-srv 2>&1 | tail -30 || true; exit 1; }

# ---- synthetic REALITY keys ----
keys="$(docker run --rm --entrypoint Xray "$IMAGE" x25519)"
PRIV="$(printf '%s\n' "$keys" | awk -F': ' 'NR == 1 { print $2 }')"
PUB="$(printf '%s\n' "$keys" | awk -F': ' 'NR == 2 { print $2 }')"
[ -n "$PRIV" ] && [ -n "$PUB" ] || fail "cannot parse 'xray x25519' output"

# ---- throwaway server: REALITY+Vision on 4443, REALITY+XHTTP on 8443 ----
reality="\"realitySettings\": { \"target\": \"www.microsoft.com:443\", \"serverNames\": [\"www.microsoft.com\"], \"privateKey\": \"$PRIV\", \"shortIds\": [\"\", \"ab12\"] }"
cat > "$WORK/server.json" <<EOF
{
  "log": { "loglevel": "warning", "access": "" },
  "inbounds": [
    { "port": 4443, "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision", "email": "e2e-vision" } ], "decryption": "none" },
      "streamSettings": { "network": "tcp", "security": "reality", $reality } },
    { "port": 8443, "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID", "email": "e2e-xhttp" } ], "decryption": "none" },
      "streamSettings": { "network": "xhttp", "xhttpSettings": { "path": "/e2e" }, "security": "reality", $reality } }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
chmod 644 "$WORK/server.json"

docker network create "$NET" >/dev/null
# Also published on the runner's loopback for the host-network-mode client (step 5).
docker run -d --name v2h-srv --network "$NET" -p 127.0.0.1:4443:4443 -v "$WORK/server.json:/srv.json:ro" \
  --entrypoint Xray "$IMAGE" run -config /srv.json >/dev/null

VISION="vless://$UUID@v2h-srv:4443?security=reality&encryption=none&pbk=$PUB&fp=chrome&sni=www.microsoft.com&sid=ab12&flow=xtls-rprx-vision#vision"
XHTTP="vless://$UUID@v2h-srv:8443?security=reality&encryption=none&type=xhttp&path=%2Fe2e&mode=auto&pbk=$PUB&fp=chrome&sni=www.microsoft.com&sid=#xhttp"
DEADLINK="vless://$UUID@$DEAD:443?security=reality&pbk=$PUB&sni=www.microsoft.com&sid=ab12#dead"

# start_client "LINKS" [docker run args...]
start_client() {
  docker rm -f v2h-cli >/dev/null 2>&1 || true
  printf '%s\n' "$1" > "$WORK/vless.conf"
  chmod 644 "$WORK/vless.conf"
  shift
  docker run -d --name v2h-cli --network "$NET" -p 127.0.0.1:19000:8080 -p 127.0.0.1:11080:1080 \
    -v "$WORK/vless.conf:/app/vless.conf:ro" -e PROBE_INTERVAL=10s "$@" "$IMAGE" >/dev/null
}

# wait_ok DESCRIPTION curl-args... : retry for up to 60 s until curl gets HTTP 204
wait_ok() {
  local what="$1"; shift
  for _ in $(seq 1 30); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" "$URL" || true)" = 204 ]; then
      echo "ok   - $what"; return 0
    fi
    sleep 2
  done
  fail "$what"
}

# log_has CONTAINER PATTERN...: true when the container log contains any of the fixed strings.
# The log is read into a variable first: with pipefail, `docker logs | grep -q` fails when grep exits
# early and docker logs gets SIGPIPE, which made this test flaky (and could hide a leak).
log_has() {
  local c="$1" text; shift
  text="$(docker logs "$c" 2>&1 || true)"
  local p
  for p in "$@"; do
    case "$text" in *"$p"*) return 0 ;; esac
  done
  return 1
}

server_saw() { log_has v2h-srv "email: $1" || fail "server log has no connection for $1"; echo "ok   - server saw $1"; }

health() {  # expected: 0 healthy / 1 unhealthy
  local rc=0
  docker exec v2h-cli /app/healthcheck.sh || rc=$?
  [ "$rc" = "$1" ] || fail "healthcheck exit $rc, want $1"
  echo "ok   - healthcheck exit $rc"
}

echo "# 1. failover: dead link first, working Vision link second"
start_client "$DEADLINK
$VISION"
wait_ok "HTTP proxy works through the second link" --proxy http://127.0.0.1:19000
wait_ok "SOCKS5 proxy works" --socks5-hostname 127.0.0.1:11080
server_saw e2e-vision
health 0
log_has v2h-cli '2 links, failover=leastPing' || fail "startup summary"
if log_has v2h-cli "$UUID" "$PUB"; then fail "client log leaks UUID or key"; fi
echo "ok   - client log has no UUID/key"

echo "# 2. server down -> healthcheck fails"
docker stop v2h-srv >/dev/null
health 1
docker start v2h-srv >/dev/null

echo "# 3. single XHTTP link with login"
start_client "$XHTTP" -e PROXY_USER=e2e -e PROXY_PASS='p"w\d'
wait_ok "SOCKS5 with login over XHTTP" --socks5-hostname 127.0.0.1:11080 --proxy-user 'e2e:p"w\d'
# For an https:// URL the 407 is the answer to CONNECT, which curl reports as %{http_connect}.
code="$(curl -s -o /dev/null -w '%{http_connect}' --max-time 5 --proxy http://127.0.0.1:19000 "$URL" || true)"
[ "$code" = 407 ] || fail "HTTP without login: got $code, want 407"
echo "ok   - HTTP without login is refused (407)"
server_saw e2e-xhttp
health 0

echo "# 4. only a dead link -> healthcheck fails"
start_client "$DEADLINK"
sleep 3
health 1

echo "# 5. host network mode: UDP through SOCKS5 (what e.g. Telegram calls need)"
docker rm -f v2h-cli >/dev/null 2>&1 || true
printf '%s\n' "${VISION/@v2h-srv:4443/@127.0.0.1:4443}" > "$WORK/vless.conf"
host_client() {
  docker rm -f v2h-cli >/dev/null 2>&1 || true
  docker run -d --name v2h-cli --network host -v "$WORK/vless.conf:/app/vless.conf:ro" \
    -e LISTEN_ADDR=127.0.0.1 -e HTTP_LISTEN_PORT=19100 -e SOCKS_LISTEN_PORT=11180 \
    "$@" "$IMAGE" >/dev/null
}
host_client
wait_ok "host mode: HTTP proxy on 19100" --proxy http://127.0.0.1:19100
python3 tests/socks5_udp.py 127.0.0.1 11180 || fail "host mode: UDP through SOCKS5"
echo "ok   - host mode: UDP (DNS) through SOCKS5"
log_has v2h-srv "accepted udp:1.1.1.1:53" || fail "server saw no UDP to 1.1.1.1:53"
echo "ok   - server relayed the UDP datagram"
health 0

host_client -e PROXY_USER=e2e -e PROXY_PASS=secret
wait_ok "host mode with login: HTTP" --proxy http://e2e:secret@127.0.0.1:19100
python3 tests/socks5_udp.py 127.0.0.1 11180 e2e secret || fail "host mode: UDP through SOCKS5 with login"
echo "ok   - host mode: UDP through SOCKS5 with login"
health 0   # healthcheck uses the proxy itself: custom LISTEN_ADDR/port and the login
if docker exec v2h-cli sh -c 'ss -ltn 2>/dev/null || netstat -ltn' | grep -q ':18080'; then fail "port 18080 is still open"; fi
echo "ok   - no extra healthcheck port"

echo "e2e: all passed"

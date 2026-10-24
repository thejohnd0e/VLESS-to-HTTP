#!/bin/sh
set -eu

CFG=/app/config.json

# ---- read vless.conf, strip CR/LF and remove trailing comment after # ----
if [ ! -s /app/vless.conf ]; then
  echo "vless.conf not found or empty" >&2
  exit 23
fi
VLESS_URL="$(tr -d '\r\n' < /app/vless.conf)"
VLESS_URL="${VLESS_URL%%#*}"

# ---- extract fields from URL ----
USER_ID="$(printf '%s' "$VLESS_URL" | sed -n 's#^vless://\([^@/]*\).*#\1#p')"
SERVER="$(  printf '%s' "$VLESS_URL" | sed -n 's#.*@\([^:/?]*\).*#\1#p')"
PORT_RAW="$(printf '%s' "$VLESS_URL" | sed -n 's#.*:\([0-9][0-9]*\).*#\1#p')"
PORT="$(printf '%s' "$PORT_RAW" | tr -cd '0-9')"

PUBKEY="$( printf '%s' "$VLESS_URL" | sed -n 's#.*[?&]pbk=\([^&]*\).*#\1#p')"
SNI="$(    printf '%s' "$VLESS_URL" | sed -n 's#.*[?&]sni=\([^&]*\).*#\1#p')"
FP="$(     printf '%s' "$VLESS_URL" | sed -n 's#.*[?&]fp=\([^&]*\).*#\1#p')"
SID="$(    printf '%s' "$VLESS_URL" | sed -n 's#.*[?&]sid=\([^&]*\).*#\1#p')"
SPX="$(    printf '%s' "$VLESS_URL" | sed -n 's#.*[?&]spx=\([^&]*\).*#\1#p' | sed 's/%2F/\//g')"
FLOW="$(   printf '%s' "$VLESS_URL" | sed -n 's#.*[?&]flow=\([^&]*\).*#\1#p')"
TYPE="$(   printf '%s' "$VLESS_URL" | sed -n 's#.*[?&]type=\([^&]*\).*#\1#p')"
PATH_RAW="$(printf '%s' "$VLESS_URL" | sed -n 's#.*[?&]path=\([^&]*\).*#\1#p')"
HOST_RAW="$(printf '%s' "$VLESS_URL" | sed -n 's#.*[?&]host=\([^&]*\).*#\1#p')"
MODE="$(   printf '%s' "$VLESS_URL" | sed -n 's#.*[?&]mode=\([^&]*\).*#\1#p')"

[ -z "${FP:-}" ]  && FP="chrome"
[ -z "${SPX:-}" ] && SPX="/"
[ -z "${TYPE:-}" ] && TYPE="tcp"
XHTTP_PATH="$(printf '%s' "${PATH_RAW:-}" | sed 's/%2[Ff]/\//g')"
HOST="$(printf '%s' "${HOST_RAW:-}" | sed 's/%2[Cc]/,/g')"

# ---- minimal validation ----
[ -n "${USER_ID:-}" ] || { echo "ERR: empty USER_ID"; exit 23; }
[ -n "${SERVER:-}" ]  || { echo "ERR: empty SERVER";  exit 23; }
[ -n "${PORT:-}" ]    || { echo "ERR: empty PORT";    exit 23; }
[ -n "${PUBKEY:-}" ]  || { echo "ERR: empty PUBKEY";  exit 23; }
[ -n "${SNI:-}" ]     || { echo "ERR: empty SNI";     exit 23; }
[ -n "${SID:-}" ]     || { echo "ERR: empty SID";     exit 23; }

case "$TYPE" in
  tcp|xhttp) ;;
  *)
    echo "ERR: unsupported transport type '$TYPE' (supported: tcp, xhttp)" >&2
    exit 23
    ;;
esac

if [ "$TYPE" = "xhttp" ] && [ -z "${XHTTP_PATH:-}" ]; then
  echo "ERR: empty PATH for xhttp transport" >&2
  exit 23
fi

# ---- build user block safely (with/without flow) ----
if [ -n "${FLOW:-}" ]; then
  USER_BLOCK=$(cat <<JSON
{
  "id": "${USER_ID}",
  "encryption": "none",
  "level": 0,
  "flow": "${FLOW}"
}
JSON
)
else
  USER_BLOCK=$(cat <<JSON
{
  "id": "${USER_ID}",
  "encryption": "none",
  "level": 0
}
JSON
)
fi

if [ "$TYPE" = "xhttp" ]; then
  XHTTP_HOST_LINE=""
  XHTTP_MODE_LINE=""
  if [ -n "${HOST:-}" ]; then
    XHTTP_HOST_LINE=$(cat <<JSON
,
          "host": "${HOST}"
JSON
)
  fi
  if [ -n "${MODE:-}" ]; then
    XHTTP_MODE_LINE=$(cat <<JSON
,
          "mode": "${MODE}"
JSON
)
  fi
  STREAM_SETTINGS_BLOCK=$(cat <<JSON
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "publicKey": "${PUBKEY}",
          "shortId": "${SID}",
          "spiderX": "${SPX}",
          "fingerprint": "${FP}",
          "serverName": "${SNI}"
        },
        "xhttpSettings": {
          "path": "${XHTTP_PATH}"${XHTTP_HOST_LINE}${XHTTP_MODE_LINE}
        }
      },
JSON
)
else
  STREAM_SETTINGS_BLOCK=$(cat <<JSON
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "publicKey": "${PUBKEY}",
          "shortId": "${SID}",
          "spiderX": "${SPX}",
          "fingerprint": "${FP}",
          "serverName": "${SNI}"
        }
      },
JSON
)
fi

# ---- generate config.json ----
cat > "$CFG" <<EOF
{
  "log": { "loglevel": "debug" },
  "inbounds": [
    {
      "port": 8080,
      "protocol": "http",
      "listen": "0.0.0.0",
      "settings": { "allowTransparent": true, "timeout": 300 },
      "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
    },
    {
      "port": 1080,
      "protocol": "socks",
      "listen": "0.0.0.0",
      "settings": { "auth": "noauth", "udp": true }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${SERVER}",
            "port": ${PORT},
            "users": [
              ${USER_BLOCK}
            ]
          }
        ]
      },
${STREAM_SETTINGS_BLOCK}
      "tag": "proxy"
    },
    { "protocol": "freedom", "settings": {}, "tag": "direct" }
  ]
}
EOF

# ---- print generated config for debugging ----
echo "===== GENERATED CONFIG ====="
cat "$CFG"
echo "============================"

# ---- start Xray ----
exec /usr/local/bin/Xray run -config "$CFG"

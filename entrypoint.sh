#!/bin/sh
set -eu

# Paths can be overridden for tests; the defaults are what the image uses.
CONF="${VLESS_CONF:-/app/vless.conf}"
CFG="${XRAY_CONFIG:-/app/config.json}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/Xray}"

# Runtime options (see README):
#   LOG_LEVEL     Xray error-log level: debug|info|warning|error|none (default warning).
#                 The access log (every visited destination) is written only for debug/info.
#   PROXY_USER    \ when both are set, the HTTP and SOCKS5 inbounds require this login.
#   PROXY_PASS    /
#   PRINT_CONFIG  1 prints the generated config.json with the UUID, keys and password masked.
LOG_LEVEL="${LOG_LEVEL:-warning}"
PROXY_USER="${PROXY_USER:-}"
PROXY_PASS="${PROXY_PASS:-}"
PRINT_CONFIG="${PRINT_CONFIG:-0}"

die() { echo "ERR: $*" >&2; exit 23; }

# Escape a value for a JSON string literal (backslash and double quote).
json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ---- read vless.conf: the first line that starts with vless:// ----
# Other lines (comments, blank lines) are ignored; a "#fragment" after the link is dropped.
[ -f "$CONF" ] || die "$CONF not found (mount your vless.conf)"
VLESS_URL="$(tr -d '\r' < "$CONF" | sed -n 's#^[[:space:]]*\(vless://[^[:space:]]*\).*#\1#p' | head -n 1)"
VLESS_URL="${VLESS_URL%%#*}"
[ -n "$VLESS_URL" ] || die "no vless:// link found in $CONF (put the link on its own line)"

# ---- runtime options ----
case "$LOG_LEVEL" in
  debug|info) ACCESS_LOG="" ;;            # "" = stdout
  warning|error|none) ACCESS_LOG="none" ;;
  *) die "LOG_LEVEL must be one of debug, info, warning, error, none (got '$LOG_LEVEL')" ;;
esac

if [ -n "$PROXY_USER" ] || [ -n "$PROXY_PASS" ]; then
  [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ] || die "set both PROXY_USER and PROXY_PASS, or neither"
  case "$PROXY_USER" in *:*) die "PROXY_USER must not contain ':'" ;; esac
  case "$PROXY_USER$PROXY_PASS" in *[[:cntrl:]]*) die "PROXY_USER/PROXY_PASS must not contain control characters" ;; esac
  AUTH=on
  ACCOUNTS="[ { \"user\": \"$(json_str "$PROXY_USER")\", \"pass\": \"$(json_str "$PROXY_PASS")\" } ]"
  HTTP_SETTINGS="{ \"accounts\": $ACCOUNTS, \"allowTransparent\": true, \"timeout\": 300 }"
  SOCKS_SETTINGS="{ \"auth\": \"password\", \"accounts\": $ACCOUNTS, \"udp\": true }"
else
  AUTH=off
  HTTP_SETTINGS='{ "allowTransparent": true, "timeout": 300 }'
  SOCKS_SETTINGS='{ "auth": "noauth", "udp": true }'
fi

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
# sid may be empty: an empty shortId is valid when the server lists "" in shortIds.
[ -n "${USER_ID:-}" ] || die "empty USER_ID"
[ -n "${SERVER:-}" ]  || die "empty SERVER"
[ -n "${PORT:-}" ]    || die "empty PORT"
[ -n "${PUBKEY:-}" ]  || die "empty PUBKEY (pbk)"
[ -n "${SNI:-}" ]     || die "empty SNI"

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
  "log": { "loglevel": "${LOG_LEVEL}", "access": "${ACCESS_LOG}" },
  "inbounds": [
    {
      "port": 8080,
      "protocol": "http",
      "listen": "0.0.0.0",
      "settings": ${HTTP_SETTINGS},
      "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
    },
    {
      "port": 1080,
      "protocol": "socks",
      "listen": "0.0.0.0",
      "settings": ${SOCKS_SETTINGS}
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

# ---- startup summary (no UUID, keys or password) ----
echo "VLESS-to-HTTP: server=${SERVER}:${PORT} type=${TYPE} sni=${SNI} fp=${FP} flow=${FLOW:-none} auth=${AUTH} loglevel=${LOG_LEVEL}"

# ---- optional: print the generated config with secrets masked ----
if [ "$PRINT_CONFIG" = 1 ]; then
  echo "===== GENERATED CONFIG (secrets masked) ====="
  sed -E 's/("(id|publicKey|shortId|pass)": ")([^"\\]|\\.)+"/\1***"/g' "$CFG"
  echo "============================================="
fi

# ---- start Xray ----
exec "$XRAY_BIN" run -config "$CFG"

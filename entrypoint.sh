#!/bin/sh
# Renders an Xray client config from one or more vless:// links and starts Xray.
set -eu

# Paths can be overridden for tests; the defaults are what the image uses.
CONF="${VLESS_CONF:-/app/vless.conf}"
CFG="${XRAY_CONFIG:-/tmp/config.json}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/Xray}"

# Runtime options (see README):
#   LOG_LEVEL          Xray error-log level: debug|info|warning|error|none (default warning).
#                      The access log (every visited destination) is written only for debug/info.
#   PROXY_USER         \ when both are set, the HTTP and SOCKS5 inbounds require this login.
#   PROXY_PASS         /
#   PRINT_CONFIG       1 prints the generated config.json with the UUID, keys and password masked.
#   FAILOVER_STRATEGY  with several links: leastPing (default) | random | roundRobin.
#   PROBE_URL          URL the observatory and the healthcheck request through the tunnel.
#   PROBE_INTERVAL     pause between observatory probe rounds (default 1m).
LOG_LEVEL="${LOG_LEVEL:-warning}"
PROXY_USER="${PROXY_USER:-}"
PROXY_PASS="${PROXY_PASS:-}"
PRINT_CONFIG="${PRINT_CONFIG:-0}"
FAILOVER_STRATEGY="${FAILOVER_STRATEGY:-leastPing}"
PROBE_URL="${PROBE_URL:-https://www.gstatic.com/generate_204}"
PROBE_INTERVAL="${PROBE_INTERVAL:-1m}"

# Internal HTTP inbound for the healthcheck: container loopback only, never published, no login.
HEALTH_PORT=18080

die() { echo "ERR: $*" >&2; exit 23; }

# Escape a value for a JSON string literal (backslash and double quote).
json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

has_cntrl() { case "$1" in *[[:cntrl:]]*) return 0 ;; esac; return 1; }

# Decode %XX escapes (a "+" stays a "+", as in URIs).
pct_decode() {
  case "$1" in
    *%*) printf '%s' "$1" | awk '
      BEGIN { for (i = 0; i < 256; i++) hex[sprintf("%02X", i)] = i }
      {
        s = $0; out = ""
        while (match(s, /%[0-9A-Fa-f][0-9A-Fa-f]/)) {
          out = out substr(s, 1, RSTART - 1) sprintf("%c", hex[toupper(substr(s, RSTART + 1, 2))])
          s = substr(s, RSTART + 3)
        }
        printf "%s", out s
      }' ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---- runtime options ----
case "$LOG_LEVEL" in
  debug|info) ACCESS_LOG="" ;;            # "" = stdout
  warning|error|none) ACCESS_LOG="none" ;;
  *) die "LOG_LEVEL must be one of debug, info, warning, error, none (got '$LOG_LEVEL')" ;;
esac

case "$FAILOVER_STRATEGY" in
  leastPing|random|roundRobin) ;;
  *) die "FAILOVER_STRATEGY must be one of leastPing, random, roundRobin (got '$FAILOVER_STRATEGY')" ;;
esac
case "$PROBE_INTERVAL" in
  *[0-9]s|*[0-9]m|*[0-9]h) ;;
  *) die "PROBE_INTERVAL must look like 30s, 1m or 1h (got '$PROBE_INTERVAL')" ;;
esac
case "$PROBE_URL" in
  http://?*|https://?*) has_cntrl "$PROBE_URL" && die "PROBE_URL contains control characters" ;;
  *) die "PROBE_URL must be an http:// or https:// URL" ;;
esac

if [ -n "$PROXY_USER" ] || [ -n "$PROXY_PASS" ]; then
  [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ] || die "set both PROXY_USER and PROXY_PASS, or neither"
  case "$PROXY_USER" in *:*) die "PROXY_USER must not contain ':'" ;; esac
  has_cntrl "$PROXY_USER$PROXY_PASS" && die "PROXY_USER/PROXY_PASS must not contain control characters"
  AUTH=on
  ACCOUNTS="[ { \"user\": \"$(json_str "$PROXY_USER")\", \"pass\": \"$(json_str "$PROXY_PASS")\" } ]"
  HTTP_SETTINGS="{ \"accounts\": $ACCOUNTS, \"allowTransparent\": true, \"timeout\": 300 }"
  SOCKS_SETTINGS="{ \"auth\": \"password\", \"accounts\": $ACCOUNTS, \"udp\": true }"
else
  AUTH=off
  HTTP_SETTINGS='{ "allowTransparent": true, "timeout": 300 }'
  SOCKS_SETTINGS='{ "auth": "noauth", "udp": true }'
fi

# ---- parse one vless:// link into the L_* variables ----
# vless://UUID@HOST:PORT[/]?key=value&...#name ; HOST may be an IPv6 literal in [brackets].
parse_link() {
  link="$1"; n="$2"
  L_NAME=""
  case "$link" in *'#'*) L_NAME="$(pct_decode "${link#*#}")"; link="${link%%#*}" ;; esac
  rest="${link#vless://}"
  query=""
  case "$rest" in *'?'*) query="${rest#*\?}"; rest="${rest%%\?*}" ;; esac
  rest="${rest%/}"

  case "$rest" in *@*) ;; *) die "link $n: no '@' between UUID and server" ;; esac
  L_ID="$(pct_decode "${rest%@*}")"
  hostport="${rest##*@}"
  case "$hostport" in
    \[*\]:*) L_SERVER="${hostport#\[}"; L_SERVER="${L_SERVER%%\]*}"; L_PORT="${hostport##*\]:}" ;;
    \[*) die "link $n: bad IPv6 address, use [addr]:port" ;;
    *:*) L_SERVER="${hostport%:*}"; L_PORT="${hostport##*:}" ;;
    *) die "link $n: no port after the server address" ;;
  esac

  L_SECURITY=""; L_ENC=""; L_PBK=""; L_SNI=""; L_FP=""; L_SID=""; L_SPX=""; L_PQV=""
  L_FLOW=""; L_TYPE=""; L_PATH=""; L_HOST=""; L_MODE=""; L_EXTRA=""; L_HEADER=""
  old_ifs="$IFS"; IFS='&'
  # Split the query on "&" on purpose (globbing is off).
  set -f
  # shellcheck disable=SC2086
  set -- $query
  set +f
  IFS="$old_ifs"
  for kv in "$@"; do
    [ -n "$kv" ] || continue
    key="${kv%%=*}"
    case "$kv" in *=*) val="$(pct_decode "${kv#*=}")" ;; *) val="" ;; esac
    case "$key" in
      security) L_SECURITY="$val" ;;
      encryption) L_ENC="$val" ;;
      pbk) L_PBK="$val" ;;
      sni) L_SNI="$val" ;;
      fp) L_FP="$val" ;;
      sid) L_SID="$val" ;;
      spx) L_SPX="$val" ;;
      pqv) L_PQV="$val" ;;
      flow) L_FLOW="$val" ;;
      type) L_TYPE="$val" ;;
      path) L_PATH="$val" ;;
      host) L_HOST="$val" ;;
      mode) L_MODE="$val" ;;
      extra) L_EXTRA="$val" ;;
      headerType) L_HEADER="$val" ;;
    esac
  done

  # ---- validation ----
  has_cntrl "$L_ID$L_SERVER$L_PBK$L_SNI$L_FP$L_SID$L_SPX$L_PQV$L_FLOW$L_PATH$L_HOST$L_MODE$L_ENC$L_EXTRA" &&
    die "link $n: control characters in the link"
  [ -n "$L_ID" ]     || die "link $n: empty USER_ID"
  [ -n "$L_SERVER" ] || die "link $n: empty SERVER"
  case "$L_SERVER" in *[!A-Za-z0-9.:_-]*) die "link $n: bad server address '$L_SERVER'" ;; esac
  case "$L_PORT" in ''|*[!0-9]*) die "link $n: bad PORT '$L_PORT'" ;; esac
  L_PORT="$(printf '%s' "$L_PORT" | sed 's/^0*//')"   # no octal surprises with a leading 0
  case "$L_PORT" in ?|??|???|????|?????) ;; *) die "link $n: PORT out of range" ;; esac
  [ "$L_PORT" -ge 1 ] && [ "$L_PORT" -le 65535 ] || die "link $n: PORT $L_PORT out of range"
  case "${L_SECURITY:-reality}" in
    reality) ;;
    *) die "link $n: security=$L_SECURITY is not supported (only reality)" ;;
  esac
  [ -n "$L_PBK" ] || die "link $n: empty PUBKEY (pbk)"
  [ -n "$L_SNI" ] || die "link $n: empty SNI"
  # sid may be empty: an empty shortId is valid when the server lists "" in shortIds.
  case "$L_FLOW" in *[!a-z0-9-]*) die "link $n: bad flow '$L_FLOW'" ;; esac
  [ -n "$L_ENC" ] || L_ENC=none
  [ -n "$L_FP" ]  || L_FP=chrome
  [ -n "$L_SPX" ] || L_SPX=/
  case "${L_TYPE:-tcp}" in
    tcp|raw) L_TYPE=tcp
      case "${L_HEADER:-none}" in none) ;; *) die "link $n: headerType=$L_HEADER is not supported" ;; esac ;;
    xhttp) [ -n "$L_PATH" ] || die "link $n: empty PATH for xhttp transport" ;;
    *) die "link $n: unsupported transport type '$L_TYPE' (supported: tcp, xhttp)" ;;
  esac
  case "$L_EXTRA" in ''|'{'*'}') ;; *) die "link $n: extra must be a JSON object" ;; esac
  has_cntrl "$L_NAME" && L_NAME=""
  return 0
}

# ---- outbound JSON for the parsed link ----
outbound_json() {
  tag="$1"
  user="\"id\": \"$(json_str "$L_ID")\", \"encryption\": \"$(json_str "$L_ENC")\", \"level\": 0"
  [ -z "$L_FLOW" ] || user="$user, \"flow\": \"$L_FLOW\""
  reality="\"show\": false, \"publicKey\": \"$(json_str "$L_PBK")\", \"shortId\": \"$(json_str "$L_SID")\", \"spiderX\": \"$(json_str "$L_SPX")\", \"fingerprint\": \"$(json_str "$L_FP")\", \"serverName\": \"$(json_str "$L_SNI")\""
  [ -z "$L_PQV" ] || reality="$reality, \"mldsa65Verify\": \"$(json_str "$L_PQV")\""
  xhttp=""
  if [ "$L_TYPE" = xhttp ]; then
    xhttp="\"path\": \"$(json_str "$L_PATH")\""
    [ -z "$L_HOST" ]  || xhttp="$xhttp, \"host\": \"$(json_str "$L_HOST")\""
    [ -z "$L_MODE" ]  || xhttp="$xhttp, \"mode\": \"$(json_str "$L_MODE")\""
    [ -z "$L_EXTRA" ] || xhttp="$xhttp, \"extra\": $L_EXTRA"
    xhttp=", \"xhttpSettings\": { $xhttp }"
  fi
  cat <<JSON
    {
      "tag": "$tag",
      "protocol": "vless",
      "settings": {
        "vnext": [ { "address": "$(json_str "$L_SERVER")", "port": $L_PORT, "users": [ { $user } ] } ]
      },
      "streamSettings": {
        "network": "$L_TYPE",
        "security": "reality",
        "realitySettings": { $reality }$xhttp
      }
    },
JSON
}

# ---- read vless.conf: every line that starts with vless:// ----
# Other lines (comments, blank lines) are ignored; a "#name" after a link is its display name.
[ -f "$CONF" ] || die "$CONF not found (mount your vless.conf)"
[ -r "$CONF" ] || die "$CONF is not readable by the container user (uid $(id -u)); run: chmod 644 vless.conf"
LINKS="$(tr -d '\r' < "$CONF" | sed -n 's#^[[:space:]]*\(vless://[^[:space:]]*\).*#\1#p')"
[ -n "$LINKS" ] || die "no vless:// link found in $CONF (put each link on its own line)"

OUTBOUNDS=""
SUMMARY=""
COUNT=0
NL='
'
while IFS= read -r line; do
  [ -n "$line" ] || continue
  COUNT=$((COUNT + 1))
  parse_link "$line" "$COUNT"
  OUTBOUNDS="$OUTBOUNDS$(outbound_json "proxy-$COUNT")$NL"
  SUMMARY="${SUMMARY}  link $COUNT${L_NAME:+ ($L_NAME)}: server=${L_SERVER}:${L_PORT} type=${L_TYPE} sni=${L_SNI} fp=${L_FP} flow=${L_FLOW:-none}${NL}"
done <<EOF
$LINKS
EOF

# ---- routing: one link goes straight out; several links go through a balancer ----
IN_TAGS='"http-in", "socks-in", "health-in"'
if [ "$COUNT" -eq 1 ]; then
  ROUTING="\"routing\": { \"rules\": [ { \"type\": \"field\", \"inboundTag\": [ $IN_TAGS ], \"outboundTag\": \"proxy-1\" } ] },"
  OBSERVATORY=""
else
  # fallbackTag is the first link, never "direct": with every link down, traffic fails instead of leaking.
  ROUTING="\"routing\": {
    \"rules\": [ { \"type\": \"field\", \"inboundTag\": [ $IN_TAGS ], \"balancerTag\": \"links\" } ],
    \"balancers\": [ { \"tag\": \"links\", \"selector\": [ \"proxy-\" ], \"fallbackTag\": \"proxy-1\", \"strategy\": { \"type\": \"$FAILOVER_STRATEGY\" } } ]
  },"
  OBSERVATORY="\"observatory\": { \"subjectSelector\": [ \"proxy-\" ], \"probeUrl\": \"$(json_str "$PROBE_URL")\", \"probeInterval\": \"$PROBE_INTERVAL\", \"enableConcurrency\": true },"
fi

# ---- generate config.json ----
cat > "$CFG" <<EOF
{
  "log": { "loglevel": "${LOG_LEVEL}", "access": "${ACCESS_LOG}" },
  "inbounds": [
    {
      "tag": "http-in",
      "port": 8080,
      "protocol": "http",
      "listen": "0.0.0.0",
      "settings": ${HTTP_SETTINGS},
      "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
    },
    {
      "tag": "socks-in",
      "port": 1080,
      "protocol": "socks",
      "listen": "0.0.0.0",
      "settings": ${SOCKS_SETTINGS}
    },
    {
      "tag": "health-in",
      "port": ${HEALTH_PORT},
      "protocol": "http",
      "listen": "127.0.0.1",
      "settings": { "timeout": 30 }
    }
  ],
  ${ROUTING}
  ${OBSERVATORY}
  "outbounds": [
${OUTBOUNDS}    { "protocol": "freedom", "settings": {}, "tag": "direct" }
  ]
}
EOF

# ---- startup summary (no UUID, keys or password) ----
if [ "$COUNT" -eq 1 ]; then
  echo "VLESS-to-HTTP: 1 link, auth=${AUTH}, loglevel=${LOG_LEVEL}"
else
  echo "VLESS-to-HTTP: ${COUNT} links, failover=${FAILOVER_STRATEGY} (probe ${PROBE_URL} every ${PROBE_INTERVAL}), auth=${AUTH}, loglevel=${LOG_LEVEL}"
fi
printf '%s' "$SUMMARY"

# ---- optional: print the generated config with secrets masked ----
if [ "$PRINT_CONFIG" = 1 ]; then
  echo "===== GENERATED CONFIG (secrets masked) ====="
  sed -E 's/("(id|encryption|publicKey|shortId|pass|mldsa65Verify)": ")([^"\\]|\\.)+"/\1***"/g' "$CFG"
  echo "============================================="
fi

# ---- start Xray ----
exec "$XRAY_BIN" run -config "$CFG"

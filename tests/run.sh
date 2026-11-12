#!/bin/sh
# Regression tests for entrypoint.sh. No real Xray and no real credentials:
# XRAY_BIN is a stub, every link is synthetic, everything happens in a temp dir.
# Needs: sh, jq. Run: sh tests/run.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTRY="$ROOT/entrypoint.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUB="$WORK/xray-stub"
printf '#!/bin/sh\nexit 0\n' > "$STUB"
chmod +x "$STUB"

UUID=11111111-2222-3333-4444-555555555555
PBK=AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA
BASE="vless://$UUID@203.0.113.10:443?security=reality&encryption=none&pbk=$PBK&fp=chrome&sni=example.com&sid=abcd1234&flow=xtls-rprx-vision"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

# run_entry CONF_CONTENT [VAR=value ...] -> sets RC, OUT (stdout+stderr), CFG
run_entry() {
  printf '%s' "$1" > "$WORK/vless.conf"
  shift
  rm -f "$WORK/config.json"
  CFG="$WORK/config.json"
  OUT="$(env -i PATH="$PATH" VLESS_CONF="$WORK/vless.conf" XRAY_CONFIG="$CFG" XRAY_BIN="$STUB" "$@" sh "$ENTRY" 2>&1)"
  RC=$?
}

jqv() { jq -r "$1" "$CFG"; }
# check NAME VALUE EXPECTED
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2], want [$3]"; fi; }

expect_ok() {  # name
  if [ "$RC" -ne 0 ]; then bad "$1" "exit $RC: $OUT"; return 1; fi
  if ! jq empty "$CFG" 2>/dev/null; then bad "$1" "config.json is not valid JSON"; return 1; fi
  return 0
}
expect_fail() {  # name pattern
  if [ "$RC" -eq 23 ] && printf '%s' "$OUT" | grep -q "$2"; then ok "$1"; else bad "$1" "exit $RC: $OUT"; fi
}

# ---- 1. reading vless.conf ----
run_entry "$BASE"
expect_ok "plain link" && check "plain link" "$(jqv '.outbounds[0].settings.vnext[0].users[0].id')" "$UUID"

run_entry "# Put your key here
$BASE
"
expect_ok "comment line above the link" && check "comment line above the link" "$(jqv '.outbounds[0].settings.vnext[0].address')" 203.0.113.10

run_entry "$(printf '%s#my-server\r\n# trailing comment\r\n' "$BASE")"
expect_ok "CRLF, fragment and trailing comment" && check "CRLF, fragment and trailing comment" "$(jqv '.outbounds[0].streamSettings.realitySettings.shortId')" abcd1234

run_entry "# Put your key here
"
expect_fail "file without a link" "no vless:// link"

rm -f "$WORK/vless.conf"
OUT="$(env -i PATH="$PATH" VLESS_CONF="$WORK/missing.conf" XRAY_CONFIG="$WORK/config.json" XRAY_BIN="$STUB" sh "$ENTRY" 2>&1)"; RC=$?
expect_fail "missing vless.conf" "not found"

# ---- 2. empty sid is accepted ----
run_entry "$(printf '%s' "$BASE" | sed 's/sid=abcd1234/sid=/')"
expect_ok "empty sid" && check "empty sid" "$(jqv '.outbounds[0].streamSettings.realitySettings.shortId')" ""

run_entry "$(printf '%s' "$BASE" | sed 's/&sid=abcd1234//')"
expect_ok "no sid parameter" && ok "no sid parameter"

run_entry "$(printf '%s' "$BASE" | sed 's/pbk=[^&]*&//')"
expect_fail "missing pbk still fails" "empty PUBKEY"

# ---- 3. logging and secrets ----
run_entry "$BASE"
if expect_ok "default log settings"; then
  if [ "$(jqv '.log.loglevel')" = warning ] && [ "$(jqv '.log.access')" = none ]; then ok "default log settings"; else bad "default log settings" "$(jq -c .log "$CFG")"; fi
fi
if printf '%s' "$OUT" | grep -q -e "$UUID" -e "$PBK" -e abcd1234; then bad "default output has no secrets" "$OUT"; else ok "default output has no secrets"; fi
check "summary shows auth=off" "$(printf '%s' "$OUT" | grep -c "auth=off")" 1

run_entry "$BASE" LOG_LEVEL=debug
expect_ok "LOG_LEVEL=debug" && check "LOG_LEVEL=debug enables access log" "$(jq -c '[.log.loglevel, .log.access]' "$CFG")" '["debug",""]'

run_entry "$BASE" LOG_LEVEL=verbose
expect_fail "invalid LOG_LEVEL" "LOG_LEVEL must be"

run_entry "$BASE" PRINT_CONFIG=1 PROXY_USER=alice 'PROXY_PASS=s3cr"et\x'
if expect_ok "PRINT_CONFIG=1"; then
  if printf '%s' "$OUT" | grep -q -e "$UUID" -e "$PBK" -e abcd1234 -e 's3cr'; then bad "PRINT_CONFIG=1 masks secrets" "$OUT"
  elif printf '%s' "$OUT" | grep -q 'GENERATED CONFIG' && printf '%s' "$OUT" | grep -q '"id": "\*\*\*"'; then ok "PRINT_CONFIG=1 masks secrets"
  else bad "PRINT_CONFIG=1 masks secrets" "$OUT"; fi
fi

# ---- 4. proxy authentication ----
run_entry "$BASE" PROXY_USER=alice 'PROXY_PASS=p@ss "w\ord'
if expect_ok "auth with special characters"; then
  h="$(jq -c '.inbounds[0].settings.accounts' "$CFG")"
  s="$(jq -c '[.inbounds[1].settings.auth, .inbounds[1].settings.accounts]' "$CFG")"
  want='[{"user":"alice","pass":"p@ss \"w\\ord"}]'
  if [ "$h" = "$want" ] && [ "$s" = "[\"password\",$want]" ]; then ok "auth with special characters"; else bad "auth with special characters" "http=$h socks=$s"; fi
fi
check "summary shows auth=on" "$(printf '%s' "$OUT" | grep -c "auth=on")" 1

run_entry "$BASE"
check "no auth by default" "$(jq -c '[.inbounds[1].settings.auth, .inbounds[0].settings.accounts]' "$CFG")" '["noauth",null]'

run_entry "$BASE" PROXY_USER=alice
expect_fail "only PROXY_USER" "set both PROXY_USER and PROXY_PASS"
run_entry "$BASE" PROXY_PASS=x
expect_fail "only PROXY_PASS" "set both PROXY_USER and PROXY_PASS"
run_entry "$BASE" PROXY_USER=a:b PROXY_PASS=x
expect_fail "':' in PROXY_USER" "must not contain ':'"

# ---- 5. parser: URI edge cases ----
L="vless://$UUID@"
Q="pbk=$PBK&sni=example.com&sid=ab"
ob='.outbounds[0]'

run_entry "${L}[2001:db8::1]:8443?$Q"
expect_ok "IPv6 server" && check "IPv6 server" "$(jq -c "$ob.settings.vnext[0] | [.address, .port]" "$CFG")" '["2001:db8::1",8443]'

run_entry "${L}203.0.113.10:443?type=xhttp&path=%2Fx&host=cdn.example.com:8443&$Q"
expect_ok "colon in host= does not change the port" && check "colon in host= does not change the port" "$(jqv "$ob.settings.vnext[0].port")" 443

run_entry "${L}203.0.113.10:0443/?$Q"
expect_ok "leading zero port and trailing slash" && check "leading zero port and trailing slash" "$(jqv "$ob.settings.vnext[0].port")" 443

run_entry "${L}203.0.113.10:443?$Q&spx=%2fabc%3Fq%3D1&type=xhttp&path=%2Fp%20x"
expect_ok "percent decoding" && check "percent decoding" "$(jq -c "$ob.streamSettings | [.realitySettings.spiderX, .xhttpSettings.path]" "$CFG")" '["/abc?q=1","/p x"]'

run_entry "${L}203.0.113.10:443?pbk=$PBK&sni=a%22b%5Cc&sid=ab"
expect_ok "quote and backslash are JSON-escaped" && check "quote and backslash are JSON-escaped" "$(jqv "$ob.streamSettings.realitySettings.serverName")" 'a"b\c'

run_entry "${L}203.0.113.10:443?$Q&type=raw"
expect_ok "type=raw is tcp" && check "type=raw is tcp" "$(jqv "$ob.streamSettings.network")" tcp

run_entry "${L}203.0.113.10:443?$Q&encryption=mlkem768x25519plus.native.0rtt.SYNTH&pqv=SYNTHPQV"
expect_ok "VLESS Encryption and pqv" && check "VLESS Encryption and pqv" "$(jq -c "$ob | [.settings.vnext[0].users[0].encryption, .streamSettings.realitySettings.mldsa65Verify]" "$CFG")" '["mlkem768x25519plus.native.0rtt.SYNTH","SYNTHPQV"]'

run_entry "${L}203.0.113.10:443?$Q&type=xhttp&path=/x&extra=%7B%22xmux%22%3A%7B%22maxConcurrency%22%3A%2216-32%22%7D%7D"
expect_ok "xhttp extra" && check "xhttp extra" "$(jq -c "$ob.streamSettings.xhttpSettings.extra" "$CFG")" '{"xmux":{"maxConcurrency":"16-32"}}'

run_entry "${L}203.0.113.10:443?$Q&security=tls"
expect_fail "security=tls rejected" "only reality"
run_entry "${L}203.0.113.10:443?$Q&headerType=http"
expect_fail "headerType=http rejected" "headerType"
run_entry "${L}203.0.113.10:99999?$Q"
expect_fail "port out of range" "out of range"
run_entry "${L}203.0.113.10?$Q"
expect_fail "missing port" "no port"
run_entry "vless://203.0.113.10:443?$Q"
expect_fail "missing @" "no '@'"
run_entry "${L}203.0.113.10:443?$Q&sni=a%0Ab"
expect_fail "encoded newline rejected" "control characters"
run_entry "${L}bad\"host:443?$Q"
expect_fail "bad server address" "bad server address"

# ---- 6. several links: balancer + observatory ----
TWO="# primary
${L}203.0.113.10:443?$Q&flow=xtls-rprx-vision#Primary%20NL
# backup
${L}198.51.100.20:8443?$Q&type=xhttp&path=/x#backup"

run_entry "${L}203.0.113.10:443?$Q#only"
if expect_ok "one link: no balancer"; then
  check "one link: no balancer" "$(jq -c '[.routing.rules[0].outboundTag, .routing.balancers, .observatory, (.outbounds | map(.tag))]' "$CFG")" '["proxy-1",null,null,["proxy-1","direct"]]'
fi

run_entry "$TWO"
if expect_ok "two links"; then
  check "two links: outbounds" "$(jq -c '[.outbounds[] | [.tag, .settings.vnext[0].address // null]]' "$CFG")" '[["proxy-1","203.0.113.10"],["proxy-2","198.51.100.20"],["direct",null]]'
  check "two links: balancer" "$(jq -c '.routing | [.rules[0].inboundTag, .rules[0].balancerTag, .balancers[0].selector, .balancers[0].fallbackTag, .balancers[0].strategy.type]' "$CFG")" '[["http-in","socks-in"],"links",["proxy-"],"proxy-1","leastPing"]'
  check "two links: observatory" "$(jq -c '.observatory | [.subjectSelector, .probeUrl, .probeInterval, .enableConcurrency]' "$CFG")" '[["proxy-"],"https://www.gstatic.com/generate_204","1m",true]'
  check "two links: names in summary" "$(printf '%s' "$OUT" | grep -c -e 'link 1 (Primary NL)' -e 'link 2 (backup)' -e '2 links, failover=leastPing')" 3
fi
check "fallback is never direct" "$(jqv '.routing.balancers[0].fallbackTag')" proxy-1

run_entry "$TWO" FAILOVER_STRATEGY=roundRobin PROBE_INTERVAL=30s PROBE_URL=https://cp.cloudflare.com/
expect_ok "failover settings" && check "failover settings" "$(jq -c '[.routing.balancers[0].strategy.type, .observatory.probeInterval, .observatory.probeUrl]' "$CFG")" '["roundRobin","30s","https://cp.cloudflare.com/"]'

run_entry "$TWO" FAILOVER_STRATEGY=fastest
expect_fail "invalid FAILOVER_STRATEGY" "FAILOVER_STRATEGY must be"
run_entry "$TWO" PROBE_INTERVAL=5
expect_fail "invalid PROBE_INTERVAL" "PROBE_INTERVAL must"
run_entry "$TWO" PROBE_URL=ftp://x
expect_fail "invalid PROBE_URL" "PROBE_URL must"

run_entry "$TWO
${L}203.0.113.30:443?$Q&security=none"
expect_fail "bad third link names its number" "link 3: security=none"

run_entry "$TWO"
if printf '%s' "$OUT" | grep -q -e "$UUID" -e "$PBK"; then bad "two links: no secrets in output" "$OUT"; else ok "two links: no secrets in output"; fi

run_entry "$BASE"

# ---- 7. listen address and ports (host network mode) ----
run_entry "$BASE"
check "default listen" "$(jq -c '[.inbounds[] | [.tag, .listen, .port]]' "$CFG")" '[["http-in","0.0.0.0",8080],["socks-in","0.0.0.0",1080]]'

run_entry "$BASE" LISTEN_ADDR=192.168.0.12 HTTP_LISTEN_PORT=9000 SOCKS_LISTEN_PORT=1081
expect_ok "custom listen" && check "custom listen" "$(jq -c '[.inbounds[] | [.tag, .listen, .port]]' "$CFG")" '[["http-in","192.168.0.12",9000],["socks-in","192.168.0.12",1081]]'

run_entry "$BASE" LISTEN_ADDR=::
expect_ok "IPv6 any listen" && check "IPv6 any listen" "$(jqv '.inbounds[0].listen')" "::"

run_entry "$BASE" HTTP_LISTEN_PORT=70000
expect_fail "port out of range" "out of range"
run_entry "$BASE" SOCKS_LISTEN_PORT=abc
expect_fail "port not a number" "ports must be numbers"
run_entry "$BASE" SOCKS_LISTEN_PORT=8080
expect_fail "same port twice" "must differ"
run_entry "$BASE" LISTEN_ADDR=lan0
expect_fail "LISTEN_ADDR not an IP" "LISTEN_ADDR must be"

run_entry "$BASE"
check "socks UDP on, no fixed ip (Xray answers with the address the client connected to)" "$(jq -c '.inbounds[1].settings | [.udp, .ip]' "$CFG")" '[true,null]'

# ---- 8. unchanged behaviour ----
run_entry "vless://$UUID@203.0.113.10:443?security=reality&type=xhttp&path=%2Fmy-path&host=example.com&mode=auto&pbk=$PBK&sni=example.com&sid=ab"
expect_ok "xhttp" && check "xhttp" "$(jq -c '.outbounds[0].streamSettings | [.network, .xhttpSettings.path, .xhttpSettings.host, .xhttpSettings.mode]' "$CFG")" '["xhttp","/my-path","example.com","auto"]'

run_entry "vless://$UUID@203.0.113.10:443?security=reality&type=xhttp&pbk=$PBK&sni=example.com&sid=ab"
expect_fail "xhttp without path" "empty PATH"

run_entry "vless://$UUID@203.0.113.10:443?security=reality&type=ws&pbk=$PBK&sni=example.com&sid=ab"
expect_fail "unsupported type" "unsupported transport"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]

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

# ---- 4. empty sid is accepted ----
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

# ---- 1. proxy authentication ----
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

# ---- unchanged behaviour ----
run_entry "vless://$UUID@203.0.113.10:443?security=reality&type=xhttp&path=%2Fmy-path&host=example.com&mode=auto&pbk=$PBK&sni=example.com&sid=ab"
expect_ok "xhttp" && check "xhttp" "$(jq -c '.outbounds[0].streamSettings | [.network, .xhttpSettings.path, .xhttpSettings.host, .xhttpSettings.mode]' "$CFG")" '["xhttp","/my-path","example.com","auto"]'

run_entry "vless://$UUID@203.0.113.10:443?security=reality&type=xhttp&pbk=$PBK&sni=example.com&sid=ab"
expect_fail "xhttp without path" "empty PATH"

run_entry "vless://$UUID@203.0.113.10:443?security=reality&type=ws&pbk=$PBK&sni=example.com&sid=ab"
expect_fail "unsupported type" "unsupported transport"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]

#!/bin/sh
# Generates a sing-box client config from VLESS_*/TUN_* environment
# variables and starts sing-box. See README.md for the full variable
# reference.
set -eu

CONFIG_PATH="${CONFIG_PATH:-/etc/sing-box/config.json}"
mkdir -p "$(dirname "$CONFIG_PATH")"

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

# --- required ---
: "${VLESS_SERVER:?VLESS_SERVER is required}"
: "${VLESS_PORT:?VLESS_PORT is required}"
: "${VLESS_UUID:?VLESS_UUID is required}"
VLESS_SECURITY="${VLESS_SECURITY:-reality}"

case "$VLESS_SECURITY" in
    reality|tls|none) ;;
    *) fail "VLESS_SECURITY must be one of: reality, tls, none (got '$VLESS_SECURITY')" ;;
esac

if [ "$VLESS_SECURITY" != "none" ] && [ -z "${VLESS_SERVER_NAME:-}" ]; then
    fail "VLESS_SERVER_NAME (SNI) is required when VLESS_SECURITY=$VLESS_SECURITY"
fi

if [ "$VLESS_SECURITY" = "reality" ] && [ -z "${VLESS_REALITY_PUBLIC_KEY:-}" ]; then
    fail "VLESS_REALITY_PUBLIC_KEY is required when VLESS_SECURITY=reality"
fi

# --- optional, with defaults ---
VLESS_FLOW="${VLESS_FLOW:-}"
VLESS_TRANSPORT="${VLESS_TRANSPORT:-tcp}"
VLESS_FINGERPRINT="${VLESS_FINGERPRINT:-chrome}"
VLESS_ALPN="${VLESS_ALPN:-}"
VLESS_WS_PATH="${VLESS_WS_PATH:-/}"
VLESS_WS_HOST="${VLESS_WS_HOST:-${VLESS_SERVER_NAME:-}}"
VLESS_REALITY_SHORT_ID="${VLESS_REALITY_SHORT_ID:-}"
VLESS_ALLOW_INSECURE="${VLESS_ALLOW_INSECURE:-false}"

TUN_INTERFACE_NAME="${TUN_INTERFACE_NAME:-vless-tun}"
TUN_ADDRESS="${TUN_ADDRESS:-172.19.0.1/30}"
TUN_MTU="${TUN_MTU:-1420}"
TUN_STACK="${TUN_STACK:-system}"
DNS_SERVER="${DNS_SERVER:-1.1.1.1}"
LOG_LEVEL="${LOG_LEVEL:-info}"

case "$VLESS_TRANSPORT" in
    tcp|ws) ;;
    *) fail "VLESS_TRANSPORT must be one of: tcp, ws (got '$VLESS_TRANSPORT')" ;;
esac

case "$TUN_STACK" in
    system|gvisor|mixed) ;;
    *) fail "TUN_STACK must be one of: system, gvisor, mixed (got '$TUN_STACK')" ;;
esac

# --- tls object (omitted entirely when security=none) ---
if [ "$VLESS_SECURITY" = "none" ]; then
    TLS_JSON='{"enabled": false}'
else
    ALPN_JSON="[]"
    if [ -n "$VLESS_ALPN" ]; then
        ALPN_JSON=$(printf '%s' "$VLESS_ALPN" | jq -R -c 'split(",")')
    fi

    UTLS_JSON="{}"
    if [ -n "$VLESS_FINGERPRINT" ]; then
        UTLS_JSON=$(jq -n --arg fp "$VLESS_FINGERPRINT" '{"enabled": true, "fingerprint": $fp}')
    fi

    REALITY_JSON="{}"
    if [ "$VLESS_SECURITY" = "reality" ]; then
        REALITY_JSON=$(jq -n \
            --arg pbk "$VLESS_REALITY_PUBLIC_KEY" \
            --arg sid "$VLESS_REALITY_SHORT_ID" \
            '{"enabled": true, "public_key": $pbk, "short_id": $sid}')
    fi

    INSECURE_JSON=false
    [ "$VLESS_ALLOW_INSECURE" = "true" ] && INSECURE_JSON=true

    TLS_JSON=$(jq -n \
        --arg sni "$VLESS_SERVER_NAME" \
        --argjson alpn "$ALPN_JSON" \
        --argjson utls "$UTLS_JSON" \
        --argjson reality "$REALITY_JSON" \
        --argjson insecure "$INSECURE_JSON" \
        '{"enabled": true, "server_name": $sni, "insecure": $insecure}
         + (if ($alpn | length) > 0 then {"alpn": $alpn} else {} end)
         + (if ($utls | length) > 0 then {"utls": $utls} else {} end)
         + (if ($reality | length) > 0 then {"reality": $reality} else {} end)')
fi

# --- outbound object ---
OUTBOUND_JSON=$(jq -n \
    --arg server "$VLESS_SERVER" \
    --argjson port "$VLESS_PORT" \
    --arg uuid "$VLESS_UUID" \
    --arg flow "$VLESS_FLOW" \
    --argjson tls "$TLS_JSON" \
    '{"type": "vless", "tag": "vless-out", "server": $server, "server_port": $port, "uuid": $uuid, "tls": $tls}
     + (if ($flow | length) > 0 then {"flow": $flow} else {} end)')

if [ "$VLESS_TRANSPORT" = "ws" ]; then
    TRANSPORT_JSON=$(jq -n \
        --arg path "$VLESS_WS_PATH" \
        --arg host "$VLESS_WS_HOST" \
        '{"type": "ws", "path": $path, "headers": {"Host": $host}}')
    OUTBOUND_JSON=$(printf '%s' "$OUTBOUND_JSON" | jq --argjson transport "$TRANSPORT_JSON" '. + {"transport": $transport}')
fi

# --- full config ---
# Запросы клиентов уходят в туннель (dns server "remote"), а адрес самого
# VLESS-сервера резолвится системным резолвером ("local") через
# default_domain_resolver: иначе домен сервера пришлось бы разрешать через
# ещё не поднятый туннель, и старт зависал бы.
jq -n \
    --arg loglevel "$LOG_LEVEL" \
    --arg dns_server "$DNS_SERVER" \
    --arg ifname "$TUN_INTERFACE_NAME" \
    --arg tunaddr "$TUN_ADDRESS" \
    --argjson mtu "$TUN_MTU" \
    --arg stack "$TUN_STACK" \
    --argjson outbound "$OUTBOUND_JSON" \
    '{
        "log": {"level": $loglevel},
        "dns": {
            "servers": [
                {"type": "udp", "tag": "remote", "server": $dns_server},
                {"type": "local", "tag": "local"}
            ],
            "final": "remote"
        },
        "inbounds": [{
            "type": "tun",
            "tag": "tun-in",
            "interface_name": $ifname,
            "address": [$tunaddr],
            "mtu": $mtu,
            "auto_route": true,
            "strict_route": true,
            "stack": $stack
        }],
        "outbounds": [$outbound],
        "route": {
            "rules": [
                {"action": "sniff"},
                {"protocol": "dns", "action": "hijack-dns"}
            ],
            "final": "vless-out",
            "auto_detect_interface": true,
            "default_domain_resolver": {"server": "local"}
        }
    }' > "$CONFIG_PATH"

echo "Generated sing-box config at $CONFIG_PATH:"
cat "$CONFIG_PATH"

sing-box check -c "$CONFIG_PATH" || fail "generated config failed sing-box's own validation"

exec sing-box run -c "$CONFIG_PATH"

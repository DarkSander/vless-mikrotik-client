# vless-mikrotik-client

A minimal Docker image that runs [sing-box](https://sing-box.sagernet.org/) as a
VLESS client with a TUN interface, configured entirely from environment
variables. Meant to run as a container on MikroTik RouterOS (v7, with the
Container feature enabled) so the router itself can send traffic through a
VLESS server -- REALITY or plain TLS/WS, not the newer VLESS Encryption
(see **Limitations** below).

Verified locally (Windows, against the real `sing-box` binary via
`sing-box check`): the entrypoint's config generation for both a REALITY
profile and a WS+TLS profile, required-variable validation, and the
Dockerfile's download step (asset exists, internal tar layout matches what
the Dockerfile expects). **Not verified**: actual behavior on RouterOS
hardware/Container feature, or a real end-to-end tunnel -- see the RouterOS
section for why.

## Environment variables

### Required

| Variable | Example | Notes |
|---|---|---|
| `VLESS_SERVER` | `cat.3dgrind.ru` | Server address (domain or IP) |
| `VLESS_PORT` | `4443` | Server port |
| `VLESS_UUID` | `xxxxxxxx-xxxx-...` | User UUID |

### Security (default: `reality`)

| Variable | Default | Notes |
|---|---|---|
| `VLESS_SECURITY` | `reality` | `reality`, `tls`, or `none` |
| `VLESS_SERVER_NAME` | *(required unless `none`)* | SNI, e.g. `github.com` or your domain |
| `VLESS_REALITY_PUBLIC_KEY` | *(required if `reality`)* | from your server's REALITY key generator |
| `VLESS_REALITY_SHORT_ID` | `""` | one of the server's `shortIds` |
| `VLESS_FINGERPRINT` | `chrome` | uTLS fingerprint; set `""` to disable |
| `VLESS_ALPN` | `""` | comma-separated, e.g. `h2,http/1.1` |
| `VLESS_ALLOW_INSECURE` | `false` | skip certificate validation (testing only) |

### Transport (default: `tcp`, i.e. raw -- what REALITY uses)

| Variable | Default | Notes |
|---|---|---|
| `VLESS_TRANSPORT` | `tcp` | `tcp` or `ws` |
| `VLESS_WS_PATH` | `/` | only used when `VLESS_TRANSPORT=ws` |
| `VLESS_WS_HOST` | *(= `VLESS_SERVER_NAME`)* | Host header, only used when `ws` |
| `VLESS_FLOW` | `""` | e.g. `xtls-rprx-vision`; leave empty for REALITY-without-Vision or WS |

### TUN / misc

| Variable | Default | Notes |
|---|---|---|
| `TUN_INTERFACE_NAME` | `vless-tun` | virtual interface name inside the container |
| `TUN_ADDRESS` | `172.19.0.1/30` | TUN interface CIDR |
| `TUN_MTU` | `1420` | |
| `TUN_STACK` | `system` | `system`, `gvisor`, or `mixed` |
| `DNS_SERVER` | `1.1.1.1` | resolves domains through the tunnel (avoids DNS leaks) |
| `LOG_LEVEL` | `info` | sing-box log level |

## Building the image

```bash
docker build -t vless-mikrotik-client --build-arg SINGBOX_ARCH=arm64 .
```

`SINGBOX_ARCH` must match your router's CPU: `arm64`, `amd64`, `armv7`,
`armv6`, or `armv5`. Confirmed to exist as a sing-box v1.14.0 release asset
for all of those.

## Two example profiles

**REALITY** (matches a `VLESS TCP REALITY` inbound):
```bash
docker run --rm --cap-add=NET_ADMIN --device /dev/net/tun \
  -e VLESS_SERVER=1.2.3.4 -e VLESS_PORT=4443 -e VLESS_UUID=... \
  -e VLESS_SECURITY=reality -e VLESS_SERVER_NAME=github.com \
  -e VLESS_REALITY_PUBLIC_KEY=... -e VLESS_REALITY_SHORT_ID=... \
  vless-mikrotik-client
```

**WS + TLS behind a CDN** (matches a `VLESS WS TLS CDN` inbound):
```bash
docker run --rm --cap-add=NET_ADMIN --device /dev/net/tun \
  -e VLESS_SERVER=cat.example.com -e VLESS_PORT=443 -e VLESS_UUID=... \
  -e VLESS_SECURITY=tls -e VLESS_SERVER_NAME=cat.example.com \
  -e VLESS_TRANSPORT=ws -e VLESS_WS_PATH=/cat-ws \
  vless-mikrotik-client
```

## Limitations

- **VLESS Encryption (the post-quantum `mlkem768x25519plus` scheme) is not
  supported.** Verified directly against the real sing-box v1.14.0 binary:
  it rejects an `encryption` field on a VLESS outbound with
  `json: unknown field "encryption"`. That feature currently only exists in
  xray-core (and one community sing-box fork, not mainline). Point this
  client at your REALITY or WS+TLS inbound instead.
- TUN mode needs `NET_ADMIN` and `/dev/net/tun` inside the container --
  confirmed these are things RouterOS Container generally supports, but the
  *exact* RouterOS command to grant them may differ by RouterOS version (see
  below).

## Running it on RouterOS (Container feature)

This part is **not verified against real hardware** -- I don't have a
MikroTik device to test against. It's assembled from MikroTik's own
Container documentation; treat it as a starting point, not a copy-paste
guarantee, and expect to adjust it for your RouterOS version.

1. Enable the Container feature and set up networking for it:
   ```
   /system/device-mode/update container=yes
   /interface/veth/add name=veth-vless address=172.17.0.2/24 gateway=172.17.0.1
   /interface/bridge/add name=containers
   /ip/address/add address=172.17.0.1/24 interface=containers
   /interface/bridge/port add bridge=containers interface=veth-vless
   /ip/firewall/nat/add chain=srcnat action=masquerade src-address=172.17.0.0/24
   ```

2. Define your VLESS_*/TUN_* variables:
   ```
   /container/envs/add list=vless-env key=VLESS_SERVER value="cat.example.com"
   /container/envs/add list=vless-env key=VLESS_PORT value="443"
   /container/envs/add list=vless-env key=VLESS_UUID value="..."
   /container/envs/add list=vless-env key=VLESS_SECURITY value="tls"
   /container/envs/add list=vless-env key=VLESS_SERVER_NAME value="cat.example.com"
   /container/envs/add list=vless-env key=VLESS_TRANSPORT value="ws"
   /container/envs/add list=vless-env key=VLESS_WS_PATH value="/cat-ws"
   ```

3. Add the container. Getting `NET_ADMIN`/`/dev/net/tun` granted is the part
   I can't give you verified syntax for -- check
   `/container/config` and your RouterOS version's Container docs for
   whatever the current mechanism is (this has reportedly changed across
   RouterOS releases). Push the image to a registry (Docker Hub/GHCR) first
   if you're not building directly on the router:
   ```
   /container/add remote-image=yourrepo/vless-mikrotik-client:latest \
       interface=veth-vless root-dir=disk1/vless-container envlist=vless-env \
       name=vless-client
   /container/start vless-client
   ```

4. Once the container's TUN interface comes up and becomes its default
   route, route whatever traffic you want tunneled to `172.17.0.2` (the
   container's veth address) as gateway, e.g.:
   ```
   /ip/route/add dst-address=0.0.0.0/0 gateway=172.17.0.2 distance=1
   ```
   Start narrow (a single test host or destination) before pointing the
   router's entire default route at it.

If the container can't get `/dev/net/tun`/`NET_ADMIN` on your RouterOS
version, TUN mode won't come up at all -- that would need a different
approach (e.g. running this on a separate Linux box instead of RouterOS's
own container feature).

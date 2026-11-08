[![Xray Core](https://img.shields.io/badge/Xray-Core-00BFFF?style=for-the-badge)](https://github.com/XTLS/Xray-core)
[![Docker](https://img.shields.io/badge/Docker-2496ED?style=for-the-badge&logo=docker&logoColor=white)](https://www.docker.com/)
[![SOCKS5](https://img.shields.io/badge/Proxy-SOCKS5-ff6b35?style=for-the-badge)](https://en.wikipedia.org/wiki/SOCKS)
[![Shell](https://img.shields.io/badge/Shell-POSIX%20sh-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html)
[![License: MIT](https://img.shields.io/badge/License-MIT-2ea44f?style=for-the-badge)](./LICENSE)



# VLESS-to-HTTP/SOCKS5 proxy

A lightweight Dockerized **HTTP/HTTPS + SOCKS5 proxy** that forwards traffic through a **VLESS + Reality** server.
Designed for simplicity: paste your VLESS link into `vless.conf`, run Docker, and you're done.

---

## ✨ Features
- VLESS + Reality client (Xray-core)
- Supports `tcp` and `xhttp` transports
- HTTP proxy inbound (works for HTTP and HTTPS via CONNECT)
- SOCKS5 proxy inbound
- Auto-generated `config.json`; secrets stay out of the logs (optional masked dump with `PRINT_CONFIG=1`)
- Optional login/password for both proxies (`PROXY_USER`/`PROXY_PASS`)
- Several links in `vless.conf` = automatic failover (Xray observatory + balancer, no restarts)
- Docker healthcheck that makes a real request through the tunnel
- Runs as a non-root user
- Minimal footprint, no host dependencies besides Docker
- Default host ports: **9000** (HTTP/HTTPS) and **1080** (SOCKS5) on all interfaces (shared with the whole LAN), configurable in `.env`

---
## Related Projects

These projects complement each other: the kits set up the servers, and the proxy containers bring a
tunnel to your local network as a plain HTTP/SOCKS5 proxy.

- [xray-vps-kit](https://github.com/thejohnd0e/xray-vps-kit) — installer, client manager and updater for an
  **Xray VLESS + REALITY + Vision** server on your VPS. `xray-client show NAME` prints the `vless://` link
  you paste into `vless.conf` here, so the server and this proxy work together out of the box.
- [awg-vps-kit](https://github.com/thejohnd0e/awg-vps-kit) — one-shot **AmneziaWG (UDP)** server installer and
  client manager for Debian/Ubuntu. Use it next to the VLESS server when you want a UDP tunnel as well; the
  two are independent and can run on the same VPS.
- [AmneziaWG-to-Proxy](https://github.com/thejohnd0e/AmneziaWG-to-Proxy) — the same idea as this project for
  **AmneziaWG**: a container that brings up an AmneziaWG tunnel and exposes it as an HTTP/SOCKS5 proxy.
  **VLESS-to-HTTP** does this for VLESS + REALITY.

---

## 📁 Project Layout
```
VLESS-to-HTTP/
├── docker-compose.yml     # docker compose service
├── Dockerfile             # image build (CI publishes it to ghcr.io; also usable locally)
├── entrypoint.sh          # parses vless.conf → generates config.json
├── healthcheck.sh         # Docker healthcheck: a request through the tunnel
├── .env.example           # optional settings: bind address, ports, login, log level, failover
├── tests/run.sh           # parser tests (synthetic links, Xray stubbed)
├── tests/e2e.sh           # end-to-end test against a throwaway local server (CI)
└── vless.conf             # your VLESS Reality link(s), one per line
```

---

## ✅ Requirements
- Docker & Docker Compose
  ```bash
  docker --version
  docker compose version
  ```

---

## ⚙️ Configure
Edit `vless.conf` and paste your full VLESS URL in one line:

TCP example:
```bash
vless://UUID@HOST:PORT?security=reality&encryption=none&pbk=PUBLIC_KEY&fp=fingerprint&sni=servername&sid=shortid&spx=/&flow=xtls-rprx-vision
```

XHTTP example:
```bash
vless://UUID@HOST:PORT?security=reality&encryption=none&type=xhttp&path=%2Fmy-path&host=example.com&sni=example.com&pbk=PUBLIC_KEY&sid=SHORT_ID&fp=chrome&mode=auto
```

Supported link parameters:
- `security=reality` (the only supported security; may be omitted)
- `pbk`, `sni` (required), `sid` (may be empty), `fp` (default `chrome`), `spx` (default `/`), `pqv`, `flow`
- `encryption` (default `none`; a VLESS Encryption client string is passed to Xray as is)
- `type=tcp`/`raw` or `type=xhttp` (`tcp` is the default if omitted)
- For `xhttp`: `path` is required; `host`, `mode` and `extra` (URL-encoded JSON object) are optional
- The server may be a hostname, an IPv4 address or an IPv6 address in brackets: `@[2001:db8::1]:443`
- Values may be percent-encoded (`%2F`, `%3F`, ...)

Example:
```
vless://49b4b82b-73f0-4772-86ca-ca5059375c63@45.127.127.127:443?security=reality&encryption=none&pbk=6ECfTRNxRBiv7GLIIwOhwlkDs9NyYoZ7lHZrWeU1Q&fp=chrome&sni=github.com&sid=c8aa6a68a476c885&spx=/&flow=xtls-rprx-vision
```

> Tip: each link must be on one line. Every line that starts with `vless://` is used; other lines
> (e.g. `# comments`) are ignored. A `#name` after a link is shown in the startup log.

### Several links: automatic failover
Put several links into `vless.conf`, one per line (e.g. two servers, or TCP and XHTTP to the same server):
```
# main server
vless://UUID@1.2.3.4:443?security=reality&pbk=...&sni=...&sid=...&flow=xtls-rprx-vision#main
# backup
vless://UUID@5.6.7.8:443?security=reality&pbk=...&sni=...&sid=...&type=xhttp&path=%2Fx#backup
```
Xray then probes every link through its tunnel (`PROBE_URL`, every `PROBE_INTERVAL`) and sends
traffic over a working one; the container is not restarted. With `FAILOVER_STRATEGY=leastPing` (default) the
fastest working link is used, so a dead link is skipped after its next failed probe and is used again
once it answers. `random` and `roundRobin` spread connections over the working links.
If every link is down, traffic fails (it never goes out directly) and the healthcheck turns `unhealthy`.

> The probes are small regular requests to `PROBE_URL` through each link. A very short
> `PROBE_INTERVAL` produces a noticeable periodic pattern; the default `1m` is a reasonable trade-off.

---

## 🚀 Run
```bash
docker compose up -d
```
This pulls the prebuilt image `ghcr.io/thejohnd0e/vless-to-http:latest`; if it cannot be pulled, Docker
builds the image from the `Dockerfile` instead. Only `docker-compose.yml` and `vless.conf` are needed
to run the prebuilt image.

Stop and start:
```bash
docker compose stop      # stop, keep the container
docker compose start     # start it again
docker compose down      # stop and remove the container
```

Logs (a short startup summary without the UUID or keys, then Xray warnings and errors):
```bash
docker logs -f vless-to-http
```
Logs are rotated (3 × 10 MB).

By default:
- HTTP/HTTPS proxy: **http://HOST:9000**
- SOCKS5 proxy: **socks5://HOST:1080**

`HOST` is the LAN address of the machine running the container (or `127.0.0.1` on that machine itself):
every device in your network can point its proxy settings there.

### Health
The image has a Docker healthcheck that makes a real request to `PROBE_URL` **through the tunnel** every
minute (via an internal port that is not published and needs no login), so `healthy` means traffic
actually passes, not just that the port is open:
```bash
docker ps                                   # STATUS shows (healthy) / (unhealthy)
docker inspect --format '{{json .State.Health}}' vless-to-http
docker exec vless-to-http /app/healthcheck.sh   # run it now
```
Docker itself does not restart an `unhealthy` container; use the status for monitoring or with a tool such
as autoheal. With several links Xray already switches to a working link on its own.

## 🔐 Settings and optional login
Optional settings go into `.env` next to `docker-compose.yml` (`cp .env.example .env`):

| Variable | Default | Meaning |
|---|---|---|
| `BIND_ADDR` | empty | Host address the ports are published on: empty = all interfaces (IPv4 and IPv6), a LAN address = that network only, `127.0.0.1` = this machine only |
| `HTTP_PORT` / `SOCKS_PORT` | `9000` / `1080` | Host ports |
| `PROXY_USER` / `PROXY_PASS` | empty | Login for both proxies (set both or neither) |
| `LOG_LEVEL` | `warning` | `debug`, `info`, `warning`, `error`, `none`. `debug`/`info` also log every visited destination |
| `PRINT_CONFIG` | `0` | `1` prints the generated `config.json` at startup with UUID, keys and password masked |
| `FAILOVER_STRATEGY` | `leastPing` | With several links: `leastPing` (fastest working), `random`, `roundRobin` |
| `PROBE_URL` | `https://www.gstatic.com/generate_204` | Requested through the tunnel by the failover probes and the healthcheck; must answer 2xx/3xx |
| `PROBE_INTERVAL` | `1m` | Pause between failover probe rounds (`30s`, `1m`, `5m`, ...) |

Without a login, any device that can reach the ports can use the proxy, which is what you want in a home
LAN. If the host is also reachable from untrusted networks (a public IP, a guest Wi-Fi), set a login or
restrict `BIND_ADDR`:
```bash
PROXY_USER=me
PROXY_PASS=a-long-random-password
```
then `docker compose up -d`. Clients use `http://me:PASSWORD@HOST:9000` or `socks5://me:PASSWORD@HOST:1080`.

---

## 🧪 Test
HTTP proxy (HTTPS target via CONNECT):
```bash
curl -x http://127.0.0.1:9000 https://api.ipify.org -m 10 -v
```
Expected: your VLESS server's egress IP.

Test plain HTTP (no TLS):
```bash
curl -x http://127.0.0.1:9000 http://neverssl.com -m 10 -v
```

Test SOCKS5:
```bash
curl --socks5-hostname 127.0.0.1:1080 https://api.ipify.org -m 10 -v
```

With a login: `curl -x http://me:PASSWORD@127.0.0.1:9000 ...` / `curl --socks5-hostname 127.0.0.1:1080 --proxy-user me:PASSWORD ...`.

Parser tests (needs `sh` and `jq`, no Docker, no real link): `sh tests/run.sh`.
End-to-end test (needs Docker; starts a throwaway local server with generated keys): `bash tests/e2e.sh IMAGE`.

---

## 🔄 Update / Change server
1) Edit `vless.conf` (add, remove or replace links)  
2) Restart (the links are read when the container starts):
```bash
docker compose restart
```

## 🏷️ Versions and updates
Releases are tagged `vX.Y.Z` ([Releases](https://github.com/thejohnd0e/VLESS-to-HTTP/releases), with the
list of changes). CI publishes `linux/amd64` and `linux/arm64` images to `ghcr.io/thejohnd0e/vless-to-http`:

| Tag | What it is |
|---|---|
| `latest` | Newest release with the current stable Xray-core (default) |
| `1`, `1.0` | Newest release in that line |
| `1.0.0` | That release, rebuilt with each new Xray-core and weekly (Alpine updates) |
| `1.0.0-xray26.10.31` | That release with exactly that core; never changes, use it to pin or roll back |
| `26.10.31` | Newest release with that core |
| `edge` | Current `master`, not a release |

The newest release is rebuilt daily when a new Xray-core is out and weekly anyway; an image is published
only after the tests pass. Update:
```bash
docker compose pull
docker compose up -d
```
Pin a version (or roll back) with `IMAGE_TAG` in `.env`, e.g. `IMAGE_TAG=1.0.0-xray26.10.31`, then the same
two commands. The version is shown in the first log line (`VLESS-to-HTTP 1.0.0: ...`).

`docker-compose.yml` still has `build: .`, so it builds locally when the image cannot be pulled.

**Build it yourself.** The `Dockerfile` downloads the latest Xray-core when it is built and verifies
the archive's SHA256 from the release's `.dgst` file. Docker reuses that cached layer afterwards, so a
plain `docker compose up -d --build` keeps the old core. To get the current release, rebuild without
the cache:
```bash
docker compose build --pull --no-cache
docker compose up -d
```
To pin a specific core: `docker compose build --build-arg XRAY_VERSION=v26.10.21`.

Do this when your server's Xray-core is updated: newer servers can refuse clients from older cores
(see Troubleshooting).

---

## 🛠 Troubleshooting

- **Container restarts with code 23**
  - `vless.conf` missing, has no `vless://` line, has empty/invalid mandatory parameters, or `.env` has
    an invalid setting. The `ERR:` line in the log says which (and `link N:` which link).
- **`ERR: ... vless.conf is not readable by the container user`**
  - The container runs as a non-root user; make the file readable: `chmod 644 vless.conf`.
- **Container is `unhealthy`**
  - No request passed through the tunnel. Check the server and the link(s); `docker exec vless-to-http
    /app/healthcheck.sh` prints the error. If `PROBE_URL` is blocked on your server, set another one.
- **HTTP 407 / SOCKS authentication failed**
  - `PROXY_USER`/`PROXY_PASS` are set; pass them in the client.
- **HTTP returns 503**
  - Usually your VLESS parameters are incorrect (pbk/sid/sni/flow).
- **Container exits with `ERR: empty PATH for xhttp transport`**
  - Add `path=...` to the VLESS URL when `type=xhttp`.
- **TLS errors during CONNECT**
  - Verify `flow`, `fp` (fingerprint), `sni`, `pbk`, `sid` match your server.
- **Log shows `REALITY: received real certificate (potential MITM or redirection)`**
  - The server did not accept the client. If `pbk`/`sid`/`sni`/UUID are right, the cause is usually an
    old client core or an outdated fingerprint: current Xray servers reject a TLS ClientHello without
    `X25519MLKEM768`. Use `fp=chrome` (the default when `fp` is omitted) and update the image with
    `docker compose pull && docker compose up -d` (see "Versions and updates").
- To see the generated config, set `PRINT_CONFIG=1` (and `LOG_LEVEL=debug` for detailed Xray logs), restart,
  and look between `===== GENERATED CONFIG (secrets masked) =====` … `====`. Secrets are masked, but the log
  still shows your server address; check it before sharing.

---

## 📜 License
MIT

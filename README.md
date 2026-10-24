[![Xray Core](https://img.shields.io/badge/Xray-Core-00BFFF?style=for-the-badge)](https://github.com/XTLS/Xray-core)
[![Docker](https://img.shields.io/badge/Docker-2496ED?style=for-the-badge&logo=docker&logoColor=white)](https://www.docker.com/)
[![SOCKS5](https://img.shields.io/badge/Proxy-SOCKS5-ff6b35?style=for-the-badge)](https://en.wikipedia.org/wiki/SOCKS)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
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
- Auto-generated and printed `config.json` (easy debugging)
- Minimal footprint, no host dependencies besides Docker
- Default host ports: **9000** (HTTP/HTTPS) and **1080** (SOCKS5), configurable in `docker-compose.yml`

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
├── Dockerfile             # image build (Xray installation)
├── entrypoint.sh          # parses vless.conf → generates config.json
└── vless.conf             # your VLESS Reality URL (single line)
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

Supported transport query parameters:
- `type=tcp` or `type=xhttp` (`tcp` is the default if omitted)
- For `xhttp`, `path` is required
- For `xhttp`, `host` and `mode` are optional

Example:
```
vless://49b4b82b-73f0-4772-86ca-ca5059375c63@45.127.127.127:443?security=reality&encryption=none&pbk=6ECfTRNxRBiv7GLIIwOhwlkDs9NyYoZ7lHZrWeU1Q&fp=chrome&sni=github.com&sid=c8aa6a68a476c885&spx=/&flow=xtls-rprx-vision
```

> Tip: keep it on a single line; comments after `#` are ignored.

---

## 🚀 Run
```bash
docker compose up -d --build
```

Logs (shows the generated config and Xray output):
```bash
docker logs -f vless-to-http
```

By default:
- HTTP/HTTPS proxy: **http://127.0.0.1:9000**
- SOCKS5 proxy: **socks5://127.0.0.1:1080**

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

---

## 🔄 Update / Change server
1) Edit `vless.conf` with your new VLESS URL  
2) Restart:
```bash
docker compose down
docker compose up -d --build
```

## ⬆️ Update the Xray core
**Prebuilt image (recommended).** A GitHub Actions workflow builds `linux/amd64` and `linux/arm64`
images with the current stable Xray-core and publishes them to
`ghcr.io/thejohnd0e/vless-to-http` (tags `latest` and the core version, e.g. `26.10.21`). It runs
on every change to the `Dockerfile`/`entrypoint.sh` and once a day, so a new Xray release gets a new
image within a day. To update:
```bash
docker compose pull
docker compose up -d
```
`docker-compose.yml` names this image and still has `build: .`, so it also builds locally when the
image cannot be pulled.

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
  - `vless.conf` missing or has empty/invalid mandatory parameters.
- **HTTP returns 503**
  - Usually your VLESS parameters are incorrect (pbk/sid/sni/flow).
- **Container exits with `ERR: empty PATH for xhttp transport`**
  - Add `path=...` to the VLESS URL when `type=xhttp`.
- **TLS errors during CONNECT**
  - Verify `flow`, `fp` (fingerprint), `sni`, `pbk`, `sid` match your server.
- **Log shows `REALITY: received real certificate (potential MITM or redirection)`**
  - The server did not accept the client. If `pbk`/`sid`/`sni`/UUID are right, the cause is usually an
    old client core or an outdated fingerprint: current Xray servers reject a TLS ClientHello without
    `X25519MLKEM768`. Use `fp=chrome` (the default when `fp` is omitted) and rebuild the image with
    `docker compose build --pull --no-cache` (see "Update the Xray core").
- View the generated config section in logs between:
  - `===== GENERATED CONFIG =====` … `============================`

---

## 📜 License
MIT

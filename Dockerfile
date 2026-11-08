# ---- stage 1: download and verify Xray-core ----
FROM alpine:3.23 AS xray

# TARGETARCH is set by buildx (amd64, arm64, arm); XRAY_VERSION is "latest" or a tag such as v26.10.21.
ARG TARGETARCH
ARG XRAY_VERSION=latest

RUN set -eux; \
    apk add --no-cache curl unzip; \
    case "${TARGETARCH:-amd64}" in \
      amd64) asset=Xray-linux-64.zip ;; \
      arm64) asset=Xray-linux-arm64-v8a.zip ;; \
      arm)   asset=Xray-linux-arm32-v7a.zip ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    if [ "$XRAY_VERSION" = latest ]; then \
      base=https://github.com/XTLS/Xray-core/releases/latest/download; \
    else \
      base="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}"; \
    fi; \
    curl -fsSL -o /tmp/xray.zip "$base/$asset"; \
    curl -fsSL -o /tmp/xray.zip.dgst "$base/$asset.dgst"; \
    want="$(sed -n 's/^SHA2-256= *//p' /tmp/xray.zip.dgst | tr -d '\r')"; \
    [ -n "$want" ]; \
    echo "$want  /tmp/xray.zip" | sha256sum -c -; \
    mkdir -p /out; \
    unzip /tmp/xray.zip xray geoip.dat geosite.dat -d /out; \
    chmod 755 /out/xray; chmod 644 /out/geoip.dat /out/geosite.dat

# ---- stage 2: runtime ----
FROM alpine:3.23

# curl is used by the healthcheck.
RUN apk add --no-cache ca-certificates curl \
    && addgroup -S xray && adduser -S -D -H -G xray -s /sbin/nologin xray

COPY --from=xray /out/xray /usr/local/bin/Xray
COPY --from=xray /out/geoip.dat /out/geosite.dat /usr/local/share/xray/
COPY --chmod=755 entrypoint.sh healthcheck.sh /app/

WORKDIR /app
USER xray
EXPOSE 8080 1080

# A real request through the tunnel (see healthcheck.sh). "unhealthy" after ~3 failed minutes.
HEALTHCHECK --interval=60s --timeout=20s --start-period=30s --retries=3 CMD ["/app/healthcheck.sh"]

CMD ["/app/entrypoint.sh"]

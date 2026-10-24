FROM alpine:3.20

# TARGETARCH is set by buildx (amd64, arm64, arm); XRAY_VERSION is "latest" or a tag such as v26.10.21.
ARG TARGETARCH
ARG XRAY_VERSION=latest

WORKDIR /app
RUN set -eux; \
    apk add --no-cache curl unzip ca-certificates; \
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
    unzip /tmp/xray.zip -d /tmp/xray; \
    install -m755 /tmp/xray/xray /usr/local/bin/Xray; \
    mkdir -p /usr/local/share/xray; \
    mv /tmp/xray/geoip.dat /tmp/xray/geosite.dat /usr/local/share/xray/; \
    rm -rf /tmp/xray /tmp/xray.zip /tmp/xray.zip.dgst

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
EXPOSE 8080
CMD ["/app/entrypoint.sh"]

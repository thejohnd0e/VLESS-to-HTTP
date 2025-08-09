FROM alpine:3.20

WORKDIR /app
RUN apk add --no-cache curl unzip ca-certificates      && curl -L -o /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip      && unzip /tmp/xray.zip -d /tmp/xray      && install -m755 /tmp/xray/xray /usr/local/bin/Xray      && mkdir -p /usr/local/share/xray      && mv /tmp/xray/geoip.dat /tmp/xray/geosite.dat /usr/local/share/xray/      && rm -rf /tmp/xray /tmp/xray.zip

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
EXPOSE 8080
CMD ["/app/entrypoint.sh"]

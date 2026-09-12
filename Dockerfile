FROM alpine:3.20

ARG SINGBOX_VERSION=1.14.0
# arm64 | amd64 | armv7 | armv6 | armv5 -- match your router's CPU
ARG SINGBOX_ARCH=arm64

RUN apk add --no-cache jq ca-certificates curl \
    && curl -fL -o /tmp/sb.tar.gz \
       "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${SINGBOX_ARCH}.tar.gz" \
    && tar -xzf /tmp/sb.tar.gz -C /tmp \
    && mv "/tmp/sing-box-${SINGBOX_VERSION}-linux-${SINGBOX_ARCH}/sing-box" /usr/local/bin/sing-box \
    && chmod +x /usr/local/bin/sing-box \
    && rm -rf /tmp/sb.tar.gz "/tmp/sing-box-${SINGBOX_VERSION}-linux-${SINGBOX_ARCH}" \
    && apk del curl

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

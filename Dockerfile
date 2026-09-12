# syntax=docker/dockerfile:1
#
# Итоговый образ - scratch: только sing-box, статические busybox и jq и
# набор корневых сертификатов. sing-box собирается из исходников с тем
# минимумом build-тегов, который реально нужен этому клиенту, - готовый
# бинарник из релиза тянет за собой Tailscale, WireGuard, QUIC, OpenVPN,
# DHCP, ACME, Clash API и прочее, чего этот образ не использует.
#
# Архитектура задаётся штатно, через --platform: linux/arm64, linux/arm/v7
# или linux/amd64 (RouterOS Container работает на ARM, ARM64 и x86_64).
# Сборочные стадии идут на платформе хоста и только кросс-компилируют или
# скачивают файлы для целевой архитектуры - эмуляция не нужна, а итоговый
# образ получает правильную архитектуру в метаданных.

ARG SINGBOX_VERSION=1.14.0
ARG GO_VERSION=1.25.5
ARG JQ_VERSION=1.8.2
# true -> сжать бинарник sing-box через UPX: примерно вчетверо меньше на
# диске ценой распаковки в память при старте. По умолчанию выключено.
ARG COMPRESS=false
# false -> собрать без gVisor (минус ~3.8 МиБ). Тогда доступен только
# TUN_STACK=system, значения gvisor и mixed работать не будут.
ARG WITH_GVISOR=true

# ---------- сборка sing-box ----------
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS singbox
ARG SINGBOX_VERSION
ARG WITH_GVISOR
ARG TARGETARCH
ARG TARGETVARIANT
WORKDIR /src
RUN wget -qO- "https://github.com/SagerNet/sing-box/archive/refs/tags/v${SINGBOX_VERSION}.tar.gz" \
    | tar -xz --strip-components=1
# Теги: with_utls - REALITY и uTLS-отпечатки; with_gvisor - TUN_STACK
# gvisor/mixed; badlinkname и tfogo_checklinkname0 идут в паре с
# -checklinkname=0, как в апстримной сборке.
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    set -eu; \
    case "$TARGETARCH/$TARGETVARIANT" in \
        amd64/*) export GOARCH=amd64 ;; \
        arm64/*) export GOARCH=arm64 ;; \
        arm/v7)  export GOARCH=arm GOARM=7 ;; \
        *) echo "unsupported platform $TARGETARCH/$TARGETVARIANT: use linux/amd64, linux/arm64 or linux/arm/v7" >&2; exit 1 ;; \
    esac; \
    TAGS="with_utls,badlinkname,tfogo_checklinkname0"; \
    if [ "$WITH_GVISOR" = "true" ]; then TAGS="with_gvisor,$TAGS"; fi; \
    CGO_ENABLED=0 GOOS=linux GOTOOLCHAIN=local go build -trimpath \
        -ldflags "-X 'github.com/sagernet/sing-box/constant.Version=${SINGBOX_VERSION}' -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0 -s -w -buildid=" \
        -tags "$TAGS" \
        -o /out/sing-box ./cmd/sing-box

# ---------- корневая ФС для итогового образа ----------
FROM --platform=$BUILDPLATFORM alpine:3.20 AS rootfs
ARG JQ_VERSION
ARG TARGETARCH
ARG TARGETVARIANT
RUN apk add --no-cache ca-certificates curl
RUN set -eu; \
    case "$TARGETARCH/$TARGETVARIANT" in \
        amd64/*) APK_ARCH=x86_64;  JQ_ARCH=amd64 ;; \
        arm64/*) APK_ARCH=aarch64; JQ_ARCH=arm64 ;; \
        arm/v7)  APK_ARCH=armv7;   JQ_ARCH=armhf ;; \
        *) echo "unsupported platform $TARGETARCH/$TARGETVARIANT: use linux/amd64, linux/arm64 or linux/arm/v7" >&2; exit 1 ;; \
    esac; \
    mkdir -p /out/bin /out/etc/ssl/certs /out/etc/sing-box /out/tmp; \
    KEYS="/usr/share/apk/keys/$APK_ARCH"; [ -d "$KEYS" ] || KEYS=/etc/apk/keys; \
    apk --arch "$APK_ARCH" --root /target --initdb --keys-dir "$KEYS" \
        --repository https://dl-cdn.alpinelinux.org/alpine/v3.20/main \
        --no-cache add busybox-static; \
    cp /target/bin/busybox.static /out/bin/busybox; \
    for applet in sh ash cat ls mkdir dirname env printf echo grep sed head tail \
                  sleep ps kill uname ip ping nslookup wget; do \
        ln -s busybox "/out/bin/$applet"; \
    done; \
    curl -fsSL -o /out/bin/jq \
        "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-${JQ_ARCH}"; \
    curl -fsSL -o /tmp/jq.sha256 \
        "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/sha256sum.txt"; \
    cd /out/bin; \
    awk -v n="jq-linux-${JQ_ARCH}" '$2 == n { print $1 "  jq"; found = 1 } \
        END { if (!found) exit 1 }' /tmp/jq.sha256 | sha256sum -c -; \
    chmod +x /out/bin/jq; \
    cp /etc/ssl/certs/ca-certificates.crt /out/etc/ssl/certs/

# UPX здесь, а не в стадии сборки: у alpine:3.20 репозиторий community
# зафиксирован, а в golang:alpine его наличие не гарантировано. Упаковщик
# работает и с бинарником чужой архитектуры.
COPY --from=singbox /out/sing-box /out/usr/local/bin/sing-box
ARG COMPRESS
RUN set -eu; \
    if [ "$COMPRESS" = "true" ]; then \
        apk add --no-cache \
            --repository https://dl-cdn.alpinelinux.org/alpine/v3.20/community upx; \
        upx --lzma --best /out/usr/local/bin/sing-box; \
    fi

# ---------- итоговый образ (платформа = целевая) ----------
FROM scratch
COPY --from=rootfs /out/ /
COPY --chmod=755 entrypoint.sh /entrypoint.sh
ENV PATH=/usr/local/bin:/bin
ENTRYPOINT ["/entrypoint.sh"]

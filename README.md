# vless-mikrotik-client

Минимальный Docker-образ (`scratch`: только sing-box, статические busybox и
jq, корневые сертификаты), который запускает [sing-box](https://sing-box.sagernet.org/)
в роли VLESS-клиента с TUN-интерфейсом, полностью настраиваемый через
переменные окружения. Предназначен для запуска в контейнере на MikroTik
RouterOS (v7, с включённой функцией Container), чтобы сам роутер мог
направлять трафик через VLESS-сервер — REALITY или обычный TLS/WS, но не
через новый VLESS Encryption (см. **Ограничения** ниже).

Проверено локально (Windows, кросс-компиляцией sing-box и запуском
`sing-box check`): генерация конфига в entrypoint'е для профилей REALITY,
WS+TLS и `TUN_STACK=gvisor` — все три конфига принимаются бинарником,
собранным ровно с тем урезанным набором build-тегов, который использует
Dockerfile; проверка обязательных переменных и отказ на неверном
`TUN_STACK`; размеры бинарников (см. «Размер образа»); резолв доменного
имени VLESS-сервера — конфиг запускался на живом sing-box, домен сервера
разрешается системным резолвером за десятки миллисекунд, а не уходит в
ещё не поднятый туннель (см. «Резолв адреса сервера»).

Проверено в Docker Desktop: образ собирается под `linux/arm64`,
`linux/arm/v7` и `linux/amd64` с правильной архитектурой в метаданных;
arm64-бинарники запускаются под эмуляцией; amd64-образ, запущенный с
`--cap-add=NET_ADMIN --device /dev/net/tun`, поднимает `vless-tun`, трафик
контейнера уходит в VLESS-outbound, домен сервера резолвится локально, и
соединение доходит до TLS+WebSocket-обмена с сервером. **Не проверено**:
поведение на железе RouterOS/в функции Container и туннель с настоящим
VLESS-сервером.

## Переменные окружения

### Обязательные

| Переменная | Пример | Описание |
|---|---|---|
| `VLESS_SERVER` | `vpn.srv.com` | Адрес сервера (домен или IP) |
| `VLESS_PORT` | `4443` | Порт сервера |
| `VLESS_UUID` | `xxxxxxxx-xxxx-...` | UUID пользователя |

### Безопасность (по умолчанию: `reality`)

| Переменная | По умолчанию | Описание |
|---|---|---|
| `VLESS_SECURITY` | `reality` | `reality`, `tls` или `none` |
| `VLESS_SERVER_NAME` | *(обязательна, если не `none`)* | SNI, например `github.com` или ваш домен |
| `VLESS_REALITY_PUBLIC_KEY` | *(обязательна при `reality`)* | из генератора REALITY-ключей на вашем сервере |
| `VLESS_REALITY_SHORT_ID` | `""` | один из `shortIds` сервера |
| `VLESS_FINGERPRINT` | `chrome` | uTLS-отпечаток; поставьте `""`, чтобы отключить |
| `VLESS_ALPN` | `""` | через запятую, например `h2,http/1.1` |
| `VLESS_ALLOW_INSECURE` | `false` | не проверять сертификат (только для тестов) |

### Транспорт (по умолчанию: `tcp`, т.е. голый — то, что использует REALITY)

| Переменная | По умолчанию | Описание |
|---|---|---|
| `VLESS_TRANSPORT` | `tcp` | `tcp` или `ws` |
| `VLESS_WS_PATH` | `/` | используется только при `VLESS_TRANSPORT=ws` |
| `VLESS_WS_HOST` | *(= `VLESS_SERVER_NAME`)* | заголовок Host, только при `ws` |
| `VLESS_FLOW` | `""` | например `xtls-rprx-vision`; оставьте пустым для REALITY без Vision или для WS |

### TUN и прочее

| Переменная | По умолчанию | Описание |
|---|---|---|
| `TUN_INTERFACE_NAME` | `vless-tun` | имя виртуального интерфейса внутри контейнера |
| `TUN_ADDRESS` | `172.19.0.1/30` | CIDR TUN-интерфейса |
| `TUN_MTU` | `1420` | |
| `TUN_STACK` | `system` | `system`, `gvisor` или `mixed`; последние два требуют образа, собранного с `WITH_GVISOR=true` (по умолчанию так и есть) |
| `DNS_SERVER` | `1.1.1.1` | резолвит домены клиентов через туннель (чтобы не было утечки DNS). Адрес самого VLESS-сервера при этом резолвится системным резолвером — см. ниже |
| `LOG_LEVEL` | `info` | уровень логирования sing-box |

## Сборка образа

```bash
docker build --platform linux/arm64 -t vless-mikrotik-client .
```

Архитектура задаётся через `--platform` под процессор роутера:
`linux/arm64`, `linux/arm/v7` (32-битный ARM) или `linux/amd64`. RouterOS
Container работает только на ARM, ARM64 и x86_64. Без `--platform`
собирается под архитектуру машины, на которой идёт сборка. Архитектура
попадает в метаданные образа — RouterOS по ним выбирает образ при
`remote-image`.

Все три архитектуры одним образом (нужен `docker buildx` и registry):

```bash
docker buildx build --platform linux/arm64,linux/arm/v7,linux/amd64 \
  -t yourrepo/vless-mikrotik-client:latest --push .
```

Нужен BuildKit (в современном Docker он включён по умолчанию): Dockerfile
использует `--mount=type=cache` и `COPY --chmod`.

| build-arg | По умолчанию | Описание |
|---|---|---|
| `SINGBOX_VERSION` | `1.14.0` | тег исходников sing-box |
| `GO_VERSION` | `1.25.5` | минимум, который требует `go.mod` sing-box 1.14.0 |
| `JQ_VERSION` | `1.8.2` | статический jq; скачивается и сверяется с официальным `sha256sum.txt` |
| `WITH_GVISOR` | `true` | `false` — собрать без gVisor (−3.8 МиБ), тогда доступен только `TUN_STACK=system` |
| `COMPRESS` | `false` | `true` — сжать бинарник sing-box через UPX (см. ниже) |

Кросс-сборка не требует QEMU: sing-box кросс-компилируется силами Go, а
файлы для целевой архитектуры (busybox, jq) только скачиваются, но не
запускаются на этапе сборки.

Registry (и аккаунт в нём) для доставки на роутер не обязателен: образ
можно передать файлом — `docker save -o vless.tar vless-mikrotik-client`,
залить `vless.tar` на роутер и добавить контейнер с `file=vless.tar`
вместо `remote-image=…`.

## Размер образа

Главный вклад в вес — сам бинарник sing-box. Официальный релизный
бинарник собран со всеми возможностями (Tailscale, WireGuard, QUIC,
OpenVPN, OpenConnect, DHCP, ACME, Clash API, cloudflared…), из которых
этому клиенту нужны только VLESS, REALITY/uTLS, TUN и WebSocket. Поэтому
образ собирает sing-box из исходников с тегами
`with_gvisor,with_utls,badlinkname,tfogo_checklinkname0`.

Замеры для arm64, sing-box 1.14.0 (байты):

| Бинарник sing-box | Размер | |
|---|---|---|
| официальный релизный | 75 759 845 | 72.3 МиБ |
| та же сборка из исходников со стандартными тегами (контроль методики) | 75 694 228 | совпадает с официальным |
| **минимальные теги (то, что в образе)** | **38 207 636** | **36.4 МиБ, −49 %** |
| минимальные теги без gVisor | 34 209 940 | 32.6 МиБ |
| минимальные теги + `COMPRESS=true` (UPX --lzma) | 8 491 576 | 8.1 МиБ, 22 % от исходного |

Остальное содержимое образа: статический jq 2.27 МБ, busybox-static
≈1.1 МиБ, набор CA-сертификатов ≈0.25 МиБ, entrypoint. Базового слоя нет
вообще — образ строится от `scratch`.

Реальные образы (Docker Desktop, sing-box 1.14.0):

| Образ | Распакован | В registry (сжат) | ОЗУ после старта |
|---|---|---|---|
| `linux/arm64` | 41.4 МБ | 15.1 МБ | — |
| `linux/arm/v7` | — | 15.3 МБ | — |
| `linux/amd64` | 44.3 МБ | 16.6 МБ | 9.75 МиБ |
| `linux/amd64`, `COMPRESS=true` | 13.9 МБ | 12.2 МБ | 48.4 МиБ |

Прежний образ на alpine с релизным бинарником — около 82 МиБ в
распакованном виде. Для сравнения, распространённый образ
`wiktorbgu/vless-sing-box-tunnel-mikrotik` весит 15.7 МБ в сжатом виде.

Про `COMPRESS=true`: UPX ужимает бинарник sing-box втрое на диске
(amd64: 40 722 580 → 10 354 980 байт), но при старте он распаковывается в
память целиком. По замеру выше потребление ОЗУ после старта растёт с
9.75 до 48.4 МиБ — впятеро. То есть экономится место на накопителе
роутера ценой оперативной памяти, которой на роутерах обычно меньше. По
умолчанию выключено; включать стоит, только если на накопителе совсем
тесно, а ОЗУ с запасом.

Busybox в образе оставлен намеренно: без него в `scratch` нельзя ни
запустить entrypoint (`/bin/sh`), ни зайти внутрь контейнера
(`/container/shell`) для диагностики.

## Два примера профилей

**REALITY** (соответствует инбаунду `VLESS TCP REALITY`):
```bash
docker run --rm --cap-add=NET_ADMIN --device /dev/net/tun \
  -e VLESS_SERVER=1.2.3.4 -e VLESS_PORT=4443 -e VLESS_UUID=... \
  -e VLESS_SECURITY=reality -e VLESS_SERVER_NAME=github.com \
  -e VLESS_REALITY_PUBLIC_KEY=... -e VLESS_REALITY_SHORT_ID=... \
  vless-mikrotik-client
```

**WS + TLS за CDN** (соответствует инбаунду `VLESS WS TLS CDN`):
```bash
docker run --rm --cap-add=NET_ADMIN --device /dev/net/tun \
  -e VLESS_SERVER=cat.example.com -e VLESS_PORT=443 -e VLESS_UUID=... \
  -e VLESS_SECURITY=tls -e VLESS_SERVER_NAME=cat.example.com \
  -e VLESS_TRANSPORT=ws -e VLESS_WS_PATH=/cat-ws \
  vless-mikrotik-client
```

## Резолв адреса сервера

Весь трафик, включая DNS-запросы клиентов, уходит в туннель — на
`DNS_SERVER` (по умолчанию `1.1.1.1`), так что утечки DNS нет. Но адрес
самого VLESS-сервера так резолвить нельзя: чтобы поднять туннель, нужно
знать IP сервера, а чтобы узнать IP через туннель — нужен поднятый
туннель. Поэтому в конфиге есть второй DNS-сервер типа `local`
(системный резолвер контейнера) и `route.default_domain_resolver`,
который направляет туда только резолв адреса сервера.

Проверено на живом sing-box: без этого запуск с доменом в `VLESS_SERVER`
подвисает на `dns: lookup domain …` до таймаута, с этим — домен
разрешается за ~35 мс и клиент идёт к серверу. При `VLESS_SERVER`,
заданном IP-адресом, разницы нет.

## Ограничения

- **VLESS Encryption (пост-квантовая схема `mlkem768x25519plus`) не
  поддерживается.** Проверено напрямую на реальном бинарнике sing-box
  v1.14.0: он отвергает поле `encryption` в VLESS outbound с ошибкой
  `json: unknown field "encryption"`. Эта фича сейчас существует только в
  xray-core (и в одном community-форке sing-box, не в основной ветке).
  Направляйте этот клиент на ваш инбаунд REALITY или WS+TLS вместо неё.
- Режиму TUN нужны `NET_ADMIN` и `/dev/net/tun` внутри контейнера —
  подтверждено, что RouterOS Container в целом это поддерживает, но
  *точная* команда RouterOS для выдачи этих прав может отличаться в разных
  версиях — сверяйтесь с документацией по вашей версии.

## Запуск на RouterOS (функция Container)


# vless-mikrotik-client

Минимальный Docker-образ, который запускает [sing-box](https://sing-box.sagernet.org/)
в роли VLESS-клиента с TUN-интерфейсом, полностью настраиваемый через
переменные окружения. Предназначен для запуска в контейнере на MikroTik
RouterOS (v7, с включённой функцией Container), чтобы сам роутер мог
направлять трафик через VLESS-сервер — REALITY или обычный TLS/WS, но не
через новый VLESS Encryption (см. **Ограничения** ниже).

Проверено локально (Windows, на реальном бинарнике `sing-box` через
`sing-box check`): генерация конфига в entrypoint'е для профилей REALITY и
WS+TLS, проверка обязательных переменных, и шаг скачивания в Dockerfile
(ассет существует, структура внутри архива совпадает с тем, что ожидает
Dockerfile). **Не проверено**: реальное поведение на железе RouterOS/в
функции Container, как и сквозной туннель целиком — см. раздел про
RouterOS, почему.

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
| `TUN_STACK` | `system` | `system`, `gvisor` или `mixed` |
| `DNS_SERVER` | `1.1.1.1` | резолвит домены через туннель (чтобы не было утечки DNS) |
| `LOG_LEVEL` | `info` | уровень логирования sing-box |

## Сборка образа

```bash
docker build -t vless-mikrotik-client --build-arg SINGBOX_ARCH=arm64 .
```

`SINGBOX_ARCH` должен соответствовать процессору вашего роутера: `arm64`,
`amd64`, `armv7`, `armv6` или `armv5`. Подтверждено, что для всех этих
архитектур существует нужный ассет в релизе sing-box v1.14.0.

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
  версиях (см. ниже).

## Запуск на RouterOS (функция Container)

Эта часть **не проверена на реальном железе** — у меня нет устройства
MikroTik для тестирования. Собрана по официальной документации MikroTik по
контейнерам; считайте это отправной точкой, а не гарантированным
copy-paste-решением, и будьте готовы подстраивать под вашу версию RouterOS.

1. Включите функцию Container и настройте для неё сеть:
   ```
   /system/device-mode/update container=yes
   /interface/veth/add name=veth-vless address=172.17.0.2/24 gateway=172.17.0.1
   /interface/bridge/add name=containers
   /ip/address/add address=172.17.0.1/24 interface=containers
   /interface/bridge/port add bridge=containers interface=veth-vless
   /ip/firewall/nat/add chain=srcnat action=masquerade src-address=172.17.0.0/24
   ```

2. Задайте переменные VLESS_*/TUN_*:
   ```
   /container/envs/add list=vless-env key=VLESS_SERVER value="cat.example.com"
   /container/envs/add list=vless-env key=VLESS_PORT value="443"
   /container/envs/add list=vless-env key=VLESS_UUID value="..."
   /container/envs/add list=vless-env key=VLESS_SECURITY value="tls"
   /container/envs/add list=vless-env key=VLESS_SERVER_NAME value="cat.example.com"
   /container/envs/add list=vless-env key=VLESS_TRANSPORT value="ws"
   /container/envs/add list=vless-env key=VLESS_WS_PATH value="/cat-ws"
   ```

3. Добавьте контейнер. Получение прав `NET_ADMIN`/`/dev/net/tun` — та
   часть, для которой я не могу дать проверенный синтаксис: смотрите
   `/container/config` и документацию по Container для вашей версии
   RouterOS — механизм, судя по всему, менялся от версии к версии.
   Сначала залейте образ в registry (Docker Hub/GHCR), если не собираете
   его прямо на роутере:
   ```
   /container/add remote-image=yourrepo/vless-mikrotik-client:latest \
       interface=veth-vless root-dir=disk1/vless-container envlist=vless-env \
       name=vless-client
   /container/start vless-client
   ```

4. Когда TUN-интерфейс контейнера поднимется и станет его маршрутом по
   умолчанию, направьте нужный вам трафик на `172.17.0.2` (адрес veth
   контейнера) как на шлюз, например:
   ```
   /ip/route/add dst-address=0.0.0.0/0 gateway=172.17.0.2 distance=1
   ```
   Начните с малого (один тестовый хост или назначение), прежде чем
   направлять на него весь маршрут по умолчанию роутера.

Если контейнер не сможет получить `/dev/net/tun`/`NET_ADMIN` на вашей
версии RouterOS, режим TUN вообще не поднимется — тогда потребуется другой
подход (например, запускать это на отдельной Linux-машине вместо
встроенной функции Container в RouterOS).

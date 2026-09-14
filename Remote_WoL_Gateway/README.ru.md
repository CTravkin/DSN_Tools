# Remote WoL Gateway

[English](README.md) | [Русский](README.ru.md) | [DSN Tools](../README.ru.md)

`remote-wol-gateway` предоставляет небольшой HTTP API с Bearer-аутентификацией для проверки и пробуждения одной настроенной машины. Wake-on-LAN отправляется локально по UDP или через ограниченный SSH sender, а доступность подтверждается ICMP- и/или TCP-проверками.

IPv4-сервис последовательно обрабатывает ограниченную очередь и разрешает только одну операцию пробуждения одновременно. Оставляй его на loopback либо размещай за доверенным туннелем или TLS-endpoint: сам сервис использует обычный HTTP.

## Требования

- Linux, Python 3.10+ и systemd
- Локальный режим: доступ к нужному IPv4 broadcast-адресу
- Проверка ping: `/usr/bin/ping`
- SSH-режим: `/usr/bin/ssh`, отдельный ключ, закрепленный `known_hosts` и [`remote-wol-sender`](remote-wol-sender) на отправляющем хосте

## Конфигурация

Скопируй [`remote-wol-gateway.env.example`](remote-wol-gateway.env.example).

| Переменная | Обязательна | По умолчанию | Назначение |
|---|---:|---|---|
| `WOL_TOKEN` | да | — | Не шаблонный Bearer-секрет длиной не менее 32 байт |
| `WOL_TARGET_IP` | да | — | IPv4-адрес цели для проверок |
| `WOL_TARGET_MAC` | да | — | MAC-адрес цели |
| `WOL_TARGET_NAME` | нет | `target` | Имя в ответах API |
| `WOL_BIND` / `WOL_PORT` | нет | `127.0.0.1` / `18080` | IPv4-listener |
| `WOL_WAIT_SECONDS` | нет | `60` | Максимальное ожидание подтверждения после отправки |
| `WOL_PROBE_INTERVAL_SECONDS` | нет | `2` | Задержка между проверками |
| `WOL_CHECK_PING` | нет | `true` | Включить ICMP-проверку |
| `WOL_CHECK_PORTS` | нет | пусто | TCP-порты через запятую |
| `WOL_SEND_MODE` | нет | `local` | `local` или `ssh` |
| `WOL_BROADCAST_IP` / `WOL_BROADCAST_PORT` | нет | `255.255.255.255` / `9` | Получатель локального UDP |
| `WOL_SSH_HOST`, `WOL_SSH_USER` | SSH | — | Выделенный endpoint и учетная запись sender |
| `WOL_SSH_KEY`, `WOL_SSH_KNOWN_HOSTS` | SSH | — | Абсолютные локальные пути к ключу и host keys |
| `WOL_SSH_INTERFACE` | SSH | — | Интерфейс на отправляющем хосте |
| `WOL_SSH_EXECUTABLE` | нет | `/usr/local/sbin/remote-wol-sender` | Путь к удаленному helper |

Токен можно создать командой `openssl rand -hex 32`. Должен быть включен хотя бы один способ проверки доступности.

## Установка

```sh
sudo useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin remote-wol-gateway
sudo install -m 0755 remote-wol-gateway /usr/local/sbin/remote-wol-gateway
sudo install -d -o remote-wol-gateway -g remote-wol-gateway -m 0700 /etc/remote-wol-gateway
sudo install -m 0600 remote-wol-gateway.env.example /etc/remote-wol-gateway/remote-wol-gateway.env
sudo install -m 0644 remote-wol-gateway.service /etc/systemd/system/remote-wol-gateway.service
```

В SSH-режиме положи закрытый ключ и `known_hosts` в `/etc/remote-wol-gateway` с доступом только сервисной учетной записи. На отправляющем хосте установи helper и ограничь им публичный ключ:

```sh
sudo install -m 0755 remote-wol-sender /usr/local/sbin/remote-wol-sender
# префикс строки authorized_keys:
restrict,command="/usr/local/sbin/remote-wol-sender" ssh-ed25519 AAAA...
```

Выделенная учетная запись sender должна иметь право запускать `/usr/sbin/ether-wake` на настроенном интерфейсе. При старте gateway выполняет `--check` и завершается с кодом `3`, если helper, интерфейс или SSH-политика недоступны.

Отредактируй ENV-файл и включи сервис:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now remote-wol-gateway.service
sudo journalctl -u remote-wol-gateway.service
```

## API

Задай тот же токен в вызывающей оболочке, не выводя его:

```sh
read -rsp 'WoL token: ' WOL_TOKEN; export WOL_TOKEN; echo
curl -H "Authorization: Bearer $WOL_TOKEN" http://127.0.0.1:18080/status
curl -X POST -H "Authorization: Bearer $WOL_TOKEN" http://127.0.0.1:18080/wol
```

| Запрос | Успех | Остальные результаты |
|---|---|---|
| `GET /status` | `200` с результатами проверок | `401`, `404` или `405` |
| `POST /wol` | `200`, если цель уже или теперь доступна; `202`, если пакет отправлен, но цель пока недоступна | `409`, если пробуждение уже идет; `502` при ошибке отправки |

Ответы и access log имеют формат JSON. Заголовок авторизации и токен не журналируются.

## Тесты и удаление

```sh
python3 -m unittest discover -s tests -v
```

Для удаления отключи сервис, затем удали unit, исполняемый файл, директорию конфигурации и привязку ключа на sender-хосте. Постоянных прикладных данных сервис не создает.

Если сервис не запускается, проверь journal и вручную вызови настроенный SSH helper с `--check <interface>`. Ответ `202` означает, что пакет отправлен, но ни одна проверка не сработала до deadline.

## Ограничения

- Доставка пакета не доказывает завершение запуска прошивки или операционной системы
- Проверка только через ICMP дает ложное отрицание, если ping заблокирован
- Доступ из tray, браузера или другой пользовательской среды должен идти через отдельный доверенный HTTPS- или tunnel-слой

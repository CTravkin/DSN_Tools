# Remote WoL Gateway

[English](README.md) | [Русский](README.ru.md)

[К DSN Tools](../README.ru.md)

`remote-wol-gateway` проверяет и пробуждает одну настроенную машину через HTTP API с Bearer-аутентификацией. Для каждой цели нужен отдельный экземпляр сервиса.

Wake-on-LAN отправляется напрямую по UDP или через SSH-хоп. Доступность проверяется через ICMP и/или настроенные TCP-порты. SSH запускается без локальной оболочки и со строгой проверкой ключа хоста.

## Стек

Стандартная библиотека Python, HTTP, UDP Wake-on-LAN, SSH и systemd.

## Требования

- Linux с Python 3.10 или новее и systemd
- Локальный режим: доступ к настроенному UDP broadcast-адресу
- ICMP-проверки: `/usr/bin/ping`
- SSH-режим: `/usr/bin/ssh`, отдельный ключ, закрепленный `known_hosts` и доступ к удаленной утилите пробуждения

| Переменная | Обязательна | По умолчанию | Назначение |
|---|---:|---|---|
| `WOL_TOKEN` | да | — | Bearer-токен |
| `WOL_TARGET_IP` | да | — | Адрес цели для проверок |
| `WOL_TARGET_MAC` | да | — | MAC-адрес цели |
| `WOL_TARGET_NAME` | нет | `target` | Имя в ответах API |
| `WOL_BIND` | нет | `127.0.0.1` | Адрес прослушивания |
| `WOL_PORT` | нет | `18080` | Порт прослушивания |
| `WOL_WAIT_SECONDS` | нет | `60` | Предел ожидания после пробуждения |
| `WOL_PROBE_INTERVAL_SECONDS` | нет | `2` | Интервал проверок |
| `WOL_CHECK_PING` | нет | `true` | Включить ICMP-проверки |
| `WOL_CHECK_PORTS` | нет | пусто | TCP-порты через запятую |
| `WOL_SEND_MODE` | нет | `local` | `local` или `ssh` |
| `WOL_BROADCAST_IP` | нет | `255.255.255.255` | Получатель UDP |
| `WOL_BROADCAST_PORT` | нет | `9` | Порт UDP |
| `WOL_SSH_HOST` | только SSH | — | SSH-хост |
| `WOL_SSH_USER` | только SSH | — | Учетная запись SSH |
| `WOL_SSH_KEY` | только SSH | — | Абсолютный путь к закрытому ключу |
| `WOL_SSH_KNOWN_HOSTS` | только SSH | — | Абсолютный путь к `known_hosts` |
| `WOL_SSH_INTERFACE` | только SSH | — | Удаленный сетевой интерфейс |
| `WOL_SSH_EXECUTABLE` | нет | `/usr/sbin/ether-wake` | Удаленная утилита пробуждения |

Должен быть включен хотя бы один способ проверки доступности. Пример: [`remote-wol-gateway.env.example`](remote-wol-gateway.env.example).

## Обмен данными

Для каждого запроса требуется `Authorization: Bearer <token>`.

| Запрос | Результат |
|---|---|
| `GET /status` | Результаты проверок и состояние SSH-отправителя, если применимо |
| `POST /wol` | Цель уже доступна, стала доступна, еще ожидается или отправка завершилась ошибкой |

Ответы возвращаются в JSON. `POST /wol` возвращает `202`, если пакет отправлен, но цель не стала доступна до истечения срока, и `502`, если отправка не удалась.

Сервис использует обычный HTTP. Оставляй его на loopback или размещай за доверенным TLS-endpoint либо защищенным туннелем.

## Эксплуатация

### Установка

```sh
sudo useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin remote-wol-gateway
sudo install -m 0755 remote-wol-gateway /usr/local/sbin/remote-wol-gateway
sudo install -d -o remote-wol-gateway -g remote-wol-gateway -m 0700 /etc/remote-wol-gateway
sudo install -m 0600 remote-wol-gateway.env.example /etc/remote-wol-gateway/remote-wol-gateway.env
sudo install -m 0644 remote-wol-gateway.service /etc/systemd/system/remote-wol-gateway.service
```

Отредактируй установленный ENV-файл. Если подходящая учетная запись уже существует, пропусти `useradd`.

### Запуск

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now remote-wol-gateway.service

curl -H "Authorization: Bearer $WOL_TOKEN" http://127.0.0.1:18080/status
curl -X POST -H "Authorization: Bearer $WOL_TOKEN" http://127.0.0.1:18080/wol
```

### Проверка

```sh
python3 -m unittest discover -s tests -v
sudo systemctl status remote-wol-gateway.service
sudo journalctl -u remote-wol-gateway.service
```

## Ограничения

- Wake-on-LAN зависит от прошивки цели, состояния питания и сетевой конфигурации
- Успешная отправка пакета не доказывает, что цель запустилась
- Проверка только через ICMP может считать работающую машину недоступной, если ping заблокирован

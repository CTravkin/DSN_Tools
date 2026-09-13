# Syncthing ACL Refresh

[English](README.md) | [Русский](README.ru.md)

[К DSN Tools](../README.ru.md)

`syncthing-acl-refresh` синхронизирует именованные записи POSIX ACL с папками и фактическими правилами исключения локального экземпляра Syncthing.

Управляемые пользователи получают доступ к включенным объектам и теряют только свои именованные ACL на исключенных объектах. Владение, базовые права, посторонние ACL, содержимое и символические ссылки сохраняются. Выход через символическую ссылку и расширение чужих прав через ACL mask блокируются.

## Стек

Стандартная библиотека Python, SQLite, systemd, утилиты POSIX ACL и inotify-tools.

## Требования

- Linux с Python 3.10 или новее и systemd
- Права root
- `getfacl`, `setfacl` и `inotifywait`
- Syncthing GUI с HTTPS на loopback IP
- PEM-копия сертификата Syncthing GUI под управлением root
- Существующие учетные записи для всех управляемых пользователей

Параметры командной строки имеют приоритет над соответствующими переменными окружения.

| Переменная | Обязательна | По умолчанию | Назначение |
|---|---:|---|---|
| `ACL_USERS` | да | — | Управляемые пользователи через запятую |
| `SYNCTHING_USER` | нет | `syncthing` | Сервисная учетная запись Syncthing |
| `SYNCTHING_CONFIG` | нет | автоопределение | Абсолютный путь к `config.xml` |
| `STATE_PATH` | нет | `/var/lib/syncthing-acl-refresh/state.sqlite3` | Кеш SQLite |
| `TLS_CERTIFICATE` | нет | `/etc/syncthing-acl-refresh/https-cert.pem` | Закрепленный сертификат GUI |
| `REFRESH_HOURS` | нет | `3` | Интервал полного сканирования; должен делить 24 |
| `MISSING_RECHECK_SECONDS` | нет | `60` | Повторная проверка отсутствующих корней, 1–3600 секунд |

Пример: [`syncthing-acl-refresh.env.example`](syncthing-acl-refresh.env.example).

## Интеграции

Воркер читает XML-конфигурацию Syncthing и развернутые правила исключения через его loopback HTTPS API. API-ключ остается в конфигурации Syncthing.

## Эксплуатация

### Установка

```sh
sudo install -m 0755 syncthing-acl-refresh /usr/local/sbin/syncthing-acl-refresh
sudo install -d -m 0700 /etc/syncthing-acl-refresh /var/lib/syncthing-acl-refresh
sudo install -m 0600 syncthing-acl-refresh.env.example /etc/syncthing-acl-refresh/syncthing-acl-refresh.env
sudo install -m 0644 syncthing-acl-refresh.service /etc/systemd/system/syncthing-acl-refresh.service
sudo install -m 0600 /path/to/syncthing-https-cert.pem /etc/syncthing-acl-refresh/https-cert.pem
```

Отредактируй установленный ENV-файл. При смене сертификата Syncthing GUI замени закрепленную копию.

### Запуск

```sh
sudo /usr/local/sbin/syncthing-acl-refresh --scan
sudo /usr/local/sbin/syncthing-acl-refresh --scan --force

sudo systemctl daemon-reload
sudo systemctl enable --now syncthing-acl-refresh.service
sudo journalctl -u syncthing-acl-refresh.service
```

`--scan` выполняет один проход. `--force` игнорирует кеш метаданных и повторно читает ACL. Непрерывный режим использует inotify, периодические полные сканирования, кеш SQLite и повторные попытки с задержкой.

### Проверка

```sh
sudo ACL_TEST_USERS=root,nobody python3 -m unittest discover -s tests -v
```

Интеграционным тестам нужны root, два существующих пользователя, `getfacl`, `setfacl`, `runuser` и `openssl`. Других пользователей можно указать через `ACL_TEST_USERS`.

## Ограничения

- Имена хостов, не-loopback адреса GUI и обычный HTTP отклоняются
- Существующие default ACL могут влиять на права, наследуемые новыми объектами
- Специальные файлы никогда не получают управляемый доступ

# Syncthing ACL Refresh

[English](README.md) | [Русский](README.ru.md) | [DSN Tools](../README.ru.md)

`syncthing-acl-refresh` синхронизирует именованные записи POSIX ACL с локальными папками Syncthing и их фактическими правилами исключения. Включенные файлы получают доступ для настроенных пользователей; с исключенных файлов удаляются только ACL, которыми управляет эта утилита.

Процесс работает от root. Он принимает папку только при точном совпадении ID Syncthing и абсолютного пути с root-owned allowlist. Также блокируются символические ссылки в управляемом пути, вложенные mount, системные директории, не-loopback адреса Syncthing, обычный HTTP и изменения ACL mask, расширяющие посторонний доступ.

## Требования

- Linux, Python 3.10+ и systemd
- `getfacl`, `setfacl` и `inotifywait`
- Syncthing GUI с HTTPS на loopback IP
- Копия сертификата Syncthing GUI под управлением root
- Существующие локальные учетные записи из `ACL_USERS`

## Конфигурация

Скопируй [`syncthing-acl-refresh.env.example`](syncthing-acl-refresh.env.example) и [`folders.conf.example`](folders.conf.example).

| Переменная | Обязательна | По умолчанию | Назначение |
|---|---:|---|---|
| `ACL_USERS` | да | — | Учетные записи через запятую, чьими ACL управляет утилита |
| `LEGACY_ACL_USERS` | только для миграции | — | Учетные записи, которыми управляла предыдущая установка |
| `SYNCTHING_USER` | нет | `syncthing` | Учетная запись, из которой читается конфигурация Syncthing |
| `SYNCTHING_CONFIG` | нет | определяется по этой учетной записи | Абсолютный путь к `config.xml` |
| `STATE_PATH` | нет | `/var/lib/syncthing-acl-refresh/state.sqlite3` | Состояние синхронизации и отзыва ACL |
| `TLS_CERTIFICATE` | нет | `/etc/syncthing-acl-refresh/https-cert.pem` | Закрепленный сертификат GUI |
| `FOLDER_ALLOWLIST` | нет | `/etc/syncthing-acl-refresh/folders.conf` | Список разрешенных папок под управлением root |
| `REFRESH_HOURS` | нет | `3` | Интервал полного прохода; положительный делитель 24 |
| `MISSING_RECHECK_SECONDS` | нет | `60` | Повторная проверка отсутствующих корней, 1–3600 секунд |

Формат allowlist: `folder-id=/absolute/path`, одна строка на каждую папку Syncthing. Файл и все родительские директории должны принадлежать root и не разрешать запись группе или остальным пользователям. Каждой настроенной папке должна соответствовать ровно одна строка; лишние, отсутствующие, дублирующиеся или измененные записи останавливают синхронизацию.

Параметры CLI имеют приоритет над ENV-файлом. `--env-file` нужен для прямого запуска; systemd сам загружает установленный ENV-файл.

При обновлении базы состояния, созданной старой версией, укажи в `LEGACY_ACL_USERS` точное прежнее значение `ACL_USERS` для первого запуска. После успешной миграции удали параметр. Если прежних пользователей или управляемый объект нельзя безопасно идентифицировать, миграция остановится без изменения базы.

## Установка и запуск

```sh
sudo install -m 0755 syncthing-acl-refresh /usr/local/sbin/syncthing-acl-refresh
sudo install -d -m 0700 /etc/syncthing-acl-refresh /var/lib/syncthing-acl-refresh
sudo install -m 0600 syncthing-acl-refresh.env.example /etc/syncthing-acl-refresh/syncthing-acl-refresh.env
sudo install -m 0600 folders.conf.example /etc/syncthing-acl-refresh/folders.conf
sudo install -m 0600 /path/to/syncthing-https-cert.pem /etc/syncthing-acl-refresh/https-cert.pem
sudo install -m 0644 syncthing-acl-refresh.service /etc/systemd/system/syncthing-acl-refresh.service
```

Отредактируй оба файла конфигурации и перед включением сервиса выполни разовую проверку:

```sh
sudo /usr/local/sbin/syncthing-acl-refresh \
  --env-file /etc/syncthing-acl-refresh/syncthing-acl-refresh.env \
  --scan --force

sudo systemctl daemon-reload
sudo systemctl enable --now syncthing-acl-refresh.service
sudo journalctl -u syncthing-acl-refresh.service
```

Непрерывный режим следит за конфигурацией Syncthing, allowlist, управляющими ignore-файлами и деревьями папок. Пропущенные или неудачные события покрываются полными проходами и повторными попытками с задержкой.

## Проверка, отзыв и удаление

`--scan` возвращает `0` при успехе и `1`, если хотя бы один путь обработать не удалось. `--force` отключает кеш метаданных для текущего прохода.

Перед удалением папки из allowlist или самой утилиты останови сервис и отзови все ACL, записанные в state:

```sh
sudo systemctl stop syncthing-acl-refresh.service
sudo /usr/local/sbin/syncthing-acl-refresh \
  --env-file /etc/syncthing-acl-refresh/syncthing-acl-refresh.env \
  --revoke-all
```

Код `1` означает, что некоторые записанные пути не удалось безопасно идентифицировать или очистить. Сохрани базу состояния и разберись с этими путями до удаления установки.

## Тесты

```sh
sudo ACL_TEST_USERS=root,nobody python3 -m unittest discover -s tests -v
```

Интеграционным тестам ACL нужны root, два существующих пользователя, `getfacl`, `setfacl`, `runuser` и `openssl`.

## Ограничения

- Объект, перемещенный за пределы наблюдаемого корня, может сохранить ACL; незавершенная запись остается для ручного восстановления
- Жесткие ссылки используют один inode, поэтому изменение ссылки внутри корня действует и на ссылки на тот же inode снаружи
- Вложенные файловые системы блокируются; настрой каждую как отдельную разрешенную папку Syncthing
- Существующие посторонние default ACL продолжают действовать
- Специальные файлы никогда не получают управляемый доступ

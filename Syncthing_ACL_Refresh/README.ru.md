# Syncthing ACL Refresh

[English](README.md) | [Русский](README.ru.md) | [DSN Tools](../README.ru.md)

`syncthing-acl-refresh` синхронизирует именованные записи POSIX ACL с локальными папками Syncthing и их фактическими правилами исключения. Включенные файлы получают доступ для настроенных пользователей; с исключенных файлов удаляются только ACL, которыми управляет эта утилита.

Процесс работает от root и управляет только папками с точным совпадением ID Syncthing и абсолютного пути в root-owned allowlist. Он блокирует корень файловой системы, символические ссылки в управляемом пути, не-loopback адреса Syncthing, обычный HTTP и изменения ACL mask, расширяющие посторонний доступ.

## Требования

- Linux, Python 3.10+ и systemd
- `getfacl` и `setfacl`
- Syncthing GUI с HTTPS на loopback IP
- Копия сертификата Syncthing GUI под управлением root
- Существующие локальные учетные записи из `ACL_USERS`

## Конфигурация

Скопируй [`syncthing-acl-refresh.env.example`](syncthing-acl-refresh.env.example) и [`folders.conf.example`](folders.conf.example).

| Переменная | Обязательна | По умолчанию | Назначение |
|---|---:|---|---|
| `ACL_USERS` | да | — | Учетные записи через запятую, чьими ACL управляет утилита |
| `SYNCTHING_USER` | нет | `syncthing` | Учетная запись, из которой читается конфигурация Syncthing |
| `SYNCTHING_CONFIG` | нет | определяется по этой учетной записи | Абсолютный путь к `config.xml` |
| `STATE_PATH` | нет | `/var/lib/syncthing-acl-refresh/state.sqlite3` | Состояние синхронизации и отзыва ACL |
| `TLS_CERTIFICATE` | нет | `/etc/syncthing-acl-refresh/https-cert.pem` | Закрепленный сертификат GUI |
| `FOLDER_ALLOWLIST` | нет | `/etc/syncthing-acl-refresh/folders.conf` | Список разрешенных папок под управлением root |

Формат allowlist: `folder-id=/absolute/path`, одна строка на каждую папку, которой должна управлять утилита. Файл должен принадлежать root и не разрешать запись группе или остальным пользователям. Каждый указанный ID и путь должен совпадать с конфигурацией Syncthing; остальные папки Syncthing игнорируются. Пути управляемых папок не должны пересекаться.

Параметры CLI имеют приоритет над ENV-файлом. `--env-file` нужен для прямого запуска; systemd сам загружает установленный ENV-файл.

Старая схема state мигрирует с текущим значением `ACL_USERS`. Если одновременно меняется список пользователей, сначала отзови записанные ACL.

## Установка и запуск

```sh
sudo install -m 0755 syncthing-acl-refresh /usr/local/sbin/syncthing-acl-refresh
sudo install -d -m 0700 /etc/syncthing-acl-refresh /var/lib/syncthing-acl-refresh
sudo install -m 0600 syncthing-acl-refresh.env.example /etc/syncthing-acl-refresh/syncthing-acl-refresh.env
sudo install -m 0600 folders.conf.example /etc/syncthing-acl-refresh/folders.conf
sudo install -m 0600 /path/to/syncthing-https-cert.pem /etc/syncthing-acl-refresh/https-cert.pem
sudo install -m 0644 syncthing-acl-refresh.service /etc/systemd/system/syncthing-acl-refresh.service
sudo install -m 0644 syncthing-acl-refresh.timer /etc/systemd/system/syncthing-acl-refresh.timer
```

Отредактируй оба файла конфигурации и перед включением сервиса выполни разовую проверку:

```sh
sudo /usr/local/sbin/syncthing-acl-refresh \
  --env-file /etc/syncthing-acl-refresh/syncthing-acl-refresh.env \
  --force

sudo systemctl daemon-reload
sudo systemctl enable --now syncthing-acl-refresh.timer
sudo journalctl -u syncthing-acl-refresh.service
```

Таймер запускает полный проход каждые 15 минут. Default ACL дают доступ новым объектам между запусками, а следующий проход исправляет расхождения.

## Проверка, отзыв и удаление

Команда возвращает `0` при успехе и `1`, если хотя бы один путь обработать не удалось. `--force` отключает кеш метаданных для текущего прохода.

Перед удалением папки из allowlist или самой утилиты останови сервис и отзови все ACL, записанные в state:

```sh
sudo systemctl disable --now syncthing-acl-refresh.timer
sudo /usr/local/sbin/syncthing-acl-refresh \
  --env-file /etc/syncthing-acl-refresh/syncthing-acl-refresh.env \
  --revoke-all
```

Код `1` означает, что некоторые записанные пути не удалось безопасно идентифицировать или очистить. Сохрани базу состояния и разберись с этими путями до удаления установки.

## Тесты

```sh
sudo ACL_TEST_USERS=root,nobody python3 -m unittest discover -s tests -v
```

Интеграционным тестам ACL нужны root, два существующих пользователя, еще одна локальная учетная запись, `getfacl`, `setfacl`, `runuser` и `openssl`. Дополнительная учетная запись выбирается автоматически и не получает доступ.

## Ограничения

- Объект, перемещенный за пределы управляемого корня, может сохранить ACL, поскольку state привязан к пути
- Жесткие ссылки используют один inode, поэтому изменение ссылки внутри корня действует и на ссылки на тот же inode снаружи
- Существующие посторонние default ACL продолжают действовать
- Специальные файлы никогда не получают управляемый доступ

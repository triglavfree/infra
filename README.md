#  INFRA - GitOps-инфраструктура для домашнего сервера

> **v4.1** • Quadlets + Podman + systemd + авто-обновление  
> Единственный источник истины — `infra.sh`  
> Хост — только платформа, не объект конфигурации  
> Все сервисы в контейнерах • Данные легко переносятся • Восстановление за 5 минут
---
### 🧱 Архитектура

```txt
Хост (Ubuntu Server 24.04)
 └── Podman + Quadlet (systemd --user)
      ├── Gitea + Actions Runner   ← Git-сервер + CI/CD
      ├── Vaultwarden              ← Менеджер паролей (Bitwarden-совместимый)
      ├── TorrServer               ← Стриминг торрентов
      ├── AdGuard Home             ← Блокировка рекламы и DNS-фильтрация
      ├── Caddy                    ← Reverse proxy + автоматический HTTPS
      ├── Dozzle                   ← Просмотр логов контейнеров в браузере
      ├── WireGuard                ← VPN-сервер для безопасного доступа
      └── Restic                   ← Автоматические облачные бэкапы
```
### 🔑 Ключевые принципы

|Принцип|Реализация|
|:---|:---|
|Хост не управляется|Скрипты только готовят платформу (пакеты, оптимизации), не трогают `/etc` сервисов|
|Disposable-контейнеры|Любой контейнер можно удалить — данные сохраняются в `~/infra/volumes/`|
|Автономное развёртывание|Один файл `infra.sh` с флешки развёртывает всю инфраструктуру без интернета|
|Безопасность по умолчанию|Пароли в SSH отключаются только после проверки ключей, UFW + Fail2Ban, WireGuard VPN|
|Минимализм|Только необходимые сервисы без телеметрии и проприетарных компонентов|


### ⚡ Быстрый старт (автономное развёртывание с флешки)

<details>
<summary>Отключить действие при закрытии крышки ноутбука на Ubuntu Server</summary>

1. Создайте или отредактируйте файл конфигурации:
```bash
sudo nano /etc/systemd/logind.conf
```

2. Найдите и раскомментируйте строки

```txt
[Login]
# При закрытии крышки на батарее - ничего не делать
HandleLidSwitch=ignore
# При закрытии крышки с питанием от сети - ничего не делать
HandleLidSwitchExternalPower=ignore
# При закрытии крышки в док-станции - ничего не делать
HandleLidSwitchDocked=ignore
# Дополнительно отключить блокировку сессии при закрытии
LidSwitchIgnoreInhibited=yes
```
3. Перезагрузите службу:
```bash
sudo systemctl restart systemd-logind
```
</details>

<details>
<summary>Добавление публичного SSH-ключа на сервер</summary>

   - На сервере создайте/отредактируйте authorized_keys
```bash
mkdir -p ~/.ssh && nano ~/.ssh/authorized_keys
```
   - Установите правильные права
```bash
chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys && sudo service ssh reload
```
</details>

<details>
 
 <summary>Обновите Ситему:</summary>
 
```bash
sudo apt update && sudo apt full-upgrade -y
```

```bash
sudo reboot && exit
```
</details>

<summary>Подключите флешку:</summary>

```bash
lsblk
```
- Создайте папку для монтирования (если ее нет) и смонтируйте флешку:
```bash
sudo mkdir -p /mnt/usb
```
- (Замените /dev/sdb на ваше устройство из п.1).
```bash
sudo mount /dev/sdb /mnt/usb
```
- Копирование папки с содержимым (рекурсивно) в домашнюю папку:
```bash
cp -r /mnt/usb/* ~/
```
- Отмонтируйте флешку после завершения копирования:
```bash
sudo umount /mnt/usb
```
</details>

1. Подключитесь к серверу по SSH как пользователь
2. Скопируйте скрипт с флешки (пример для /media/usb)
```bash
cp /media/usb/infra.sh ~/
chmod +x infra.sh
```
3. Запустите развёртывание 🚀
```bash
./infra.sh
```
### Скрипт автоматически:

- Создаст структуру `~/infra/` со всеми каталогами
- Запустит sudo `~/infra/bootstrap/bootstrap.sh` для настройки хоста:
- Обновит систему
- Установит `Podman`, `UFW`, `Fail2Ban`, `WireGuard`
- Настроит `BBR`, `swap`, оптимизацию `SSD/NVMe`
>💡 Swap настраивается автоматически в зависимости от объёма RAM:\
> - ≤ 1 ГБ → 2 ГБ swap
> - ≤ 2 ГБ → 1 ГБ swap
> - ≤ 4 ГБ → 512 МБ swap
> - 4 ГБ → 512 МБ swap
- Сгенерирует ключи и настроит `WireGuard` (порт 51820/UDP)
- Отключит пароли в SSH (только после проверки ключей!)
- Включит `linger` для автозапуска контейнеров после перезагрузки
- Активирует `podman-auto-update.timer` для авто-обновления контейнеров
- Зарегистрирует контейнеры через `Quadlet`
- Запустит все сервисы (кроме Gitea-раннера)
- Дождётся готовности Gitea и покажет ссылку для настройки админа
- Запросит токен раннера и настроит его
- Настроит `healthcheck` через `cron` (проверка каждые 5 минут)
- Покажет финальный отчёт с портами и командами управления

### 🔐 Управление инфраструктурой

```bash
# Статус всех сервисов
infra status

# Создать бэкап (тома + зашифрованные секреты)
infra backup

# Восстановить из последнего бэкапа
infra restore

# Управление авто-обновлениями
infra update status     # Статус таймера и логи
infra update run        # Проверить наличие обновлений (dry-run)
infra update apply      # Применить обновления

# Мониторинг доступности сервисов
infra monitor

# Логи конкретного сервиса
infra logs gitea
infra logs torrserver

# Управление сервисами
infra start             # Запустить все сервисы
infra stop              # Остановить все сервисы
systemctl --user restart gitea.service
```
> 💡 Команда `infra` доступна сразу после развёртывания (добавлена в `~/.bashrc`).

### 🩺 Мониторинг и уведомления

Инфраструктура включает встроенный механизм healthcheck, который запускается каждые 5 минут через `cron`:

- Проверяет доступность всех основных сервисов (Gitea, Vaultwarden, AdGuard Home, TorrServer)
- Проверяет сетевое состояние (WireGuard, SSH)
- Отправляет уведомления в Telegram при сбоях (опционально)
- Логирует результаты в `~/infra/logs/healthcheck.log`

Для настройки уведомлений задайте переменные окружения:
```bash
export TELEGRAM_BOT_TOKEN="ваш_токен_бота"
export TELEGRAM_CHAT_ID="ваш_chat_id"
```

### 🔄 Восстановление 
```bash
# 1. Установите чистый Ubuntu Server 24.04

# 2. Скопируйте с флешки:
#    • infra.sh
#    • зашифрованный архив: infra-backup-*.tar.gz.gpg
# 3. Запустите развёртывание БЕЗ запуска контейнеров
./infra.sh --restore
# 4. Скопируйте архив в директорию бэкапов
cp /media/usb/infra-backup-*.tar.gz.gpg ~/infra/backups/
# 5. Восстановите данные (запросит пароль)
infra restore
# 6. Сервисы автоматически запустятся после восстановления
```

> 💡 После восстановления:
> - Проверьте статус: `infra status`
> - Убедитесь, что все сервисы работают: `infra monitor`
> - Настройте облачные бэкапы (Restic) если использовались:
>   1. Скопируйте конфигурацию из старого сервера в `~/infra/secrets/restic/`
>   2. Активируйте таймер: `systemctl --user enable --now restic.timer`
> - Healthcheck автоматически настроен через cron (проверьте: `crontab -l`)
### 🔐 Cхема бэкапов
```txt
infra-backup-20260205-143022.tar.gz.gpg
└── volumes/
    ├── gitea/               # ← Репозитории Git + БД SQLite + конфигурация
    ├── gitea-runner/        # ← Конфигурация раннера + токен регистрации
    ├── vaultwarden/         # ← База паролей (шифрованная) + ключи
    ├── adguardhome/         # ← Конфигурация AdGuard Home
    ├── torrserver/          # ← .torrent файлы + медиа-кэш + база метаданных
    ├── restic/              # ← Конфигурация Restic для облачных бэкапов
    └── caddy/               # ← TLS-сертификаты Let's Encrypt + кэш
```
> ✅ Все критичные данные сохраняются, включая:
> - Историю коммитов и репозитории Gitea 
> - Токен раннера (не нужно заново регистрировать) 
> - Базу паролей Vaultwarden 
> - Конфигурацию AdGuard Home
> - Скачанные торренты и медиа 
> - Конфигурацию Restic для облачных бэкапов
> - Действующие TLS-сертификаты (избегаем лимитов Let's Encrypt при восстановлении)

> 💡 Облачные бэкапы (Restic) — дополнительный уровень защиты:
> - Создают зашифрованные бэкапы в облаке (S3, WebDAV, etc.)
> - Настроены через файлы в ~/infra/secrets/restic/
> - Работают по расписанию через systemd.timer

💡 Пример использования
```bash
# Создать бэкап
infra backup
# ← запросит пароль дважды, создаст ~/infra/backups/infra-backup-20260205-143022.tar.gz.gpg

# Скопировать на флешку
cp ~/infra/backups/infra-backup-*.tar.gz.gpg /usb/

# На новом сервере
./infra.sh --restore
cp /usb/infra-backup-*.tar.gz.gpg ~/infra/backups/
infra restore
# ← запросит пароль, восстановит все данные, запустит сервисы

# Проверить статус сервисов
infra status

# Быстрая проверка доступности
infra monitor

# Управление авто-обновлениями
infra update run        # Проверить обновления
infra update apply      # Применить обновления
```

> ✨ Особенности v4:
> - Авто-обновление контейнеров через podman-auto-update.timer
> - Встроенный healthcheck с уведомлениями в Telegram
> - Поддержка облачных бэкапов через Restic
> - Встроенный WireGuard VPN-сервер
> - AdGuard Home для блокировки рекламы и DNS-фильтрации
> - Улучшенная система мониторинга и управления

📚 Ресурсы 

[Quadlets (Podman)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html?spm=a2ty_o01.29997173.0.0.213551718a05nT) \
[Podman auto-update](https://docs.podman.io/en/latest/markdown/podman-auto-update.1.html?spm=a2ty_o01.29997173.0.0.213551718a05nT) \
[Restic](https://restic.readthedocs.io/?spm=a2ty_o01.29997173.0.0.213551718a05nT) \
[WireGuard](https://www.wireguard.com/quickstart/?spm=a2ty_o01.29997173.0.0.213551718a05nT) \
[AdGuard Home](https://github.com/AdguardTeam/AdGuardHome/wiki?spm=a2ty_o01.29997173.0.0.213551718a05nT)


> ✨ Инфраструктура как код — это не про сложность, а про воспроизводимость.

[![Ubuntu](https://img.shields.io/badge/Ubuntu_Server-24.04_LTS-E95420?style=flat-square&logo=ubuntu)](https://github.com/canonical/ubuntu-server)
[![NetBird](https://img.shields.io/badge/NetBird-0.64.4-0066FF?style=flat-square&logo=netbird)](https://github.com/netbirdio/netbird/releases/latest)
[![TorrServer](https://img.shields.io/badge/TorrServer-MatriX.139-FF6B6B?style=flat-square&logo=webtorrent)](https://github.com/YouROK/TorrServer/releases/latest)
[![Gitea](https://img.shields.io/badge/Gitea-1.25.3-609926?style=flat-square&logo=gitea)](https://github.com/go-gitea/gitea/releases/latest)
[![Podman](https://img.shields.io/badge/Podman-4.0+-892CA0?style=flat-square&logo=podman)](https://github.com/containers/podman/releases)

---
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
<details>
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
2. Скачать и сразу выполнить в bash 🚀
```bash
bash <(curl -s https://raw.githubusercontent.com/triglavfree/infra/main/infra.sh)
```
### 🔐 Управление инфраструктурой

```bash
# Показать статус всех сервисов (самая полезная команда)
infra status

# Запустить все сервисы
infra start

# Остановить все сервисы
infra stop

# Посмотреть логи сервиса
infra logs gitea
infra logs torrserver
infra logs netbird      # требует sudo
infra logs gitea-runner # требует sudo

# Перезапустить конкретный сервис
infra restart gitea
infra restart netbird

# Принудительное обновление контейнеров
infra update

# Создать бэкап вручную
infra backup

# Посмотреть список всех бэкапов
infra backup-list

# Восстановить из restic снапшота
infra backup-restore

# Восстановить из локального архива
infra restore-local
```
> 💡 Команда `infra` доступна сразу после развёртывания (добавлена в `~/.bashrc`).

📚 Ресурсы 

[Quadlets (Podman)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html?spm=a2ty_o01.29997173.0.0.213551718a05nT) \
[Podman auto-update](https://docs.podman.io/en/latest/markdown/podman-auto-update.1.html?spm=a2ty_o01.29997173.0.0.213551718a05nT) \
[Restic](https://restic.readthedocs.io/?spm=a2ty_o01.29997173.0.0.213551718a05nT) \
[WireGuard](https://www.wireguard.com/quickstart/?spm=a2ty_o01.29997173.0.0.213551718a05nT) \
[AdGuard Home](https://github.com/AdguardTeam/AdGuardHome/wiki?spm=a2ty_o01.29997173.0.0.213551718a05nT)


> ✨ Инфраструктура как код — это не про сложность, а про воспроизводимость.

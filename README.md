![Linux](https://img.shields.io/badge/Linus_Torvalds-🐧-FCC624?style=for-the-badge&logo=linux&logoColor=black)
[![Ubuntu](https://img.shields.io/badge/Ubuntu_Server-24.04.4_LTS-E95420?style=for-the-badge&logo=ubuntu&logoColor=orange)](https://ubuntu.com/download/server)
[![Podman](https://img.shields.io/badge/Podman-4.9.3-892CA0?style=for-the-badge&logo=podman&logoColor=white)](https://podman.io/)
[![Gitea](https://img.shields.io/badge/Gitea-1.25.4-609926?style=for-the-badge&logo=gitea&logoColor=white)](https://github.com/go-gitea/gitea/releases/tag/v1.25.4)
[![NetBird](https://img.shields.io/badge/NetBird-0.65.3-0066FF?style=for-the-badge&logo=netbird&logoColor=white)](https://github.com/netbirdio/netbird/releases/latest)
[![TorrServer](https://img.shields.io/badge/TorrServer-MatriX.139-FF6B6B?style=for-the-badge&logo=webtorrent&logoColor=white)](https://github.com/YouROK/TorrServer/releases/latest)
[![Restic](https://img.shields.io/badge/Restic-0.18.1-00ADD8?style=for-the-badge&logo=go&logoColor=white)](https://github.com/restic/restic/releases/tag/v0.18.1)
---

### Быстрый старт

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
 
 <summary>Обновите Систему:</summary>
 
```bash
sudo apt update && sudo apt full-upgrade -y
```

```bash
sudo reboot && exit
```
</details>

### Скачать и сразу выполнить в bash 🚀
```bash
bash <(curl -s https://raw.githubusercontent.com/triglavfree/infra/main/infra.sh)
```

<details>
<summary>c флешки:</summary>

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

### 🕉️ Cтек технологий
```txt
🐧 Linux Kernel (спасибо Линусу!)
├── 🐳 Podman 4.9.3
│   ├── 📦 Quadlet (systemd интеграция)
│   ├── 🏠 Gitea 1.25.4
│   ├── 🎥 TorrServer MatriX.139
│   ├── 🤖 Gitea Runner
│   └── 🌐 NetBird 0.65.3
├── 💾 Restic 0.18.1 (бэкапы)
├── 🛡️ UFW + fail2ban (безопасность)
└── 🚀 BBR (сетевая оптимизация)
```
### 🔐 Управление инфраструктурой

```bash
# Статус всей инфраструктуры
infra status

# Логи сервисов
infra logs gitea
infra logs torrserver
sudo infra logs netbird
sudo infra logs gitea-runner

# Управление
infra start
infra stop
infra restart gitea

# Бэкапы
infra backup-setup
infra backup
infra backup-list
infra restore-local

# Обновление контейнеров
infra update

# Полное удаление
infra clear
```
> 💡 Команда `infra` доступна сразу после развёртывания (добавлена в `~/.bashrc`).

### 🙏 **Благодарности**

- [Podman](https://podman.io/) — за безопасные контейнеры
- [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) — за интеграцию с systemd
- [Gitea](https://gitea.io/) — за лёгкий Git сервер
- [NetBird](https://netbird.io/) — за простой VPN
- [TorrServer](https://github.com/YouROK/TorrServer) — за стриминг торрентов
- [Restic](https://restic.net/) — за шифрованные бэкапы

---

<p align="center">
  <img src="https://img.shields.io/badge/Харе_Кришна!-🕉️-FF9900?style=for-the-badge" alt="Харе Кришна!" />
</p>

<p align="center">
  <b>Сделано с ❤️ и заботой о вашей инфраструктуре</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Version-10.0.0-blue?style=flat-square" />
  <img src="https://img.shields.io/badge/License-MIT-yellow?style=flat-square" />
  <img src="https://img.shields.io/badge/Ubuntu-24.04-E95420?style=flat-square&logo=ubuntu" />
</p>

<p align="center">
  <i>Праведная инфраструктура для праведных дел</i> 🙏
</p>

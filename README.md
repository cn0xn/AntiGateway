# AntiGateway

Прозрачный шлюз на базе Raspberry Pi с AmneziaWG VPN, обходом DPI (zapret2) и веб-интерфейсом управления.

## Что включено

- **AmneziaWG** — обфусцированный WireGuard туннель
- **nftables** — policy routing, kill-switch, DNS-перехват, блокировка IPv6-утечек
- **dnsmasq** — DNS с nftset-директивами, upstream через VPN-туннель
- **zapret2 (nfqws2)** — DPI bypass для заблокированных сервисов
- **Web UI** — управление списками доменов, сервисами, AWG-конфигом

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/cn0xn/AntiGateway/main/install.sh | sudo bash
```

Или клонировать и запустить вручную:

```bash
git clone https://github.com/cn0xn/AntiGateway
cd antigateway
sudo bash install.sh
```

### Что потребуется

- Debian или Ubuntu (aarch64, x86_64, armv7l)
- Пользователь с sudo
- Интернет (установка пакетов, AWG, zapret2)
- Файл `awg0.conf` от VPN-провайдера (можно загрузить через Web UI после установки)

## Обновление приложения

```bash
cd /opt/antigateway && git pull
sudo systemctl restart antigateway-ui
```

## Структура репозитория

```
antigateway/
├── app/                    # Flask веб-приложение
│   ├── app.py
│   ├── templates/
│   └── static/
├── nftables/               # Правила nftables (__IFACE__, __PI_IP__ — плейсхолдеры)
│   ├── 00_gateway_base.nft
│   ├── 10_nat.nft
│   ├── 20_dns_intercept.nft
│   ├── 30_killswitch.nft
│   └── 40_ipv6_block.nft
├── scripts/                # Скрипты обновления и watchdog
│   ├── update-lists        # Синхронизация списков доменов (атомарный nftset)
│   ├── update-routes.sh    # Обновление заблокированных IP (antifilter.download)
│   ├── update-antizapret.sh
│   └── check-tunnel.sh     # Watchdog (каждую минуту)
├── systemd/                # Systemd unit-файлы
├── config/                 # Шаблоны конфигов
└── install.sh              # Инсталлер
```

## После установки

- Web UI: `http://<IP>:8080`
- Токен авторизации: `sudo cat /etc/antigateway/auth.conf`
- Лог установки: `/var/log/antigateway-install.log`

## Архитектура трафика

```
Клиент → eth0 → dnsmasq (DNS через awg0)
                    ↓ nftset: blocked_ips / zapret_ips
              nftables prerouting → fwmark 0x1
                    ↓
              ip rule fwmark 0x1 → table 100
                    ↓
                  awg0 (AmneziaWG → VPN сервер)
```

Kill-switch: при падении awg0 трафик с fwmark 0x1 дропается на eth0.

# AntiGateway — контекст для Claude

Прозрачный шлюз на Raspberry Pi 3: AmneziaWG + nftables + dnsmasq + zapret2 + Flask Web UI.

**Репозиторий:** https://github.com/cn0xn/AntiGateway  
**На Pi деплоится в:** `/opt/antigateway/`

---

## Инфраструктура

| | |
|---|---|
| Pi IP | 192.168.1.5 |
| Pi user | user / 9123 |
| VPN сервер | 147.45.193.8:35829 (Frankfurt) |
| AWG интерфейс | awg0, адрес 10.8.1.28/32 |
| LAN интерфейс | eth0 |
| Web UI | http://192.168.1.5:8080 |
| Auth токен | `/etc/antigateway/auth.conf` |

---

## Структура репозитория

```
antigateway/
├── app/                    # Flask веб-приложение
│   ├── app.py              # бэкенд: API, auth, диагностика
│   ├── static/app.js       # фронтенд: SPA, apiFetch(), auth modal
│   ├── static/style.css
│   └── templates/index.html
├── nftables/               # правила с плейсхолдерами __IFACE__ / __PI_IP__
│   ├── 00_gateway_base.nft # tunnel_routing table, sets, policy routing, zapret queue
│   ├── 10_nat.nft          # MASQUERADE awg0 + eth0
│   ├── 20_dns_intercept.nft# DNAT 53 → dnsmasq, REJECT DoH
│   ├── 30_killswitch.nft   # DROP fwmark 0x1 на eth0 при падении VPN
│   └── 40_ipv6_block.nft   # DROP IPv6 forward
├── scripts/
│   ├── update-lists        # атомарный nftset reset (нет race condition)
│   ├── update-routes.sh    # antifilter.download → blocked_ips (cron 04:00)
│   ├── update-antizapret.sh# itdoginfo/allow-domains → dnsmasq (cron 04:30)
│   └── check-tunnel.sh     # watchdog: каждую минуту
├── systemd/
│   ├── gateway-ui.service
│   ├── awg-quick@.service
│   └── awg-quick-override.conf  # ExecStartPre fix ("already exists")
├── config/
│   ├── dnsmasq-main.conf   # шаблон: server=1.1.1.1@__IFACE__
│   ├── lists-config.json
│   └── sudoers.template
├── install.sh              # тонкий инсталлер, клонирует репо на Pi
├── deploy.sh               # умный деплой: git pull + перезапуск нужных сервисов
└── Makefile                # make push-deploy / logs / status / ssh
```

---

## Деплой

```bash
make push-deploy   # git push + ssh на Pi + git pull + restart нужных сервисов
make deploy        # только деплой (без push)
make logs          # journalctl -u antigateway-ui -f на Pi
make status        # статус всех сервисов
make ssh           # открыть SSH на Pi
```

`deploy.sh` смотрит на изменённые файлы (`git diff HEAD@{1} HEAD`) и перезапускает только нужное:
- `app/` → `systemctl restart antigateway-ui`
- `nftables/` → подставляет __IFACE__/__PI_IP__ из `/etc/antigateway/network.conf`, `systemctl restart nftables`
- `scripts/` → копирует в `/usr/local/bin/`
- `config/dnsmasq*` → `systemctl reload dnsmasq`

---

## Архитектура трафика

```
Клиент → eth0 → dnsmasq (DNS через awg0)
                    ↓ nftset: blocked_ips / zapret_ips
              nftables prerouting → fwmark 0x1
                    ↓
              ip rule fwmark 0x1 → table 100
                    ↓
                  awg0 (AmneziaWG → VPN)
```

Kill-switch: при падении awg0 трафик с fwmark 0x1 дропается на eth0 — клиенты не утекают в открытый интернет.

---

## Ключевые технические решения (не менять без понимания)

- **PostUp/PostDown** в AWG конфиге — только в секции `[Interface]`, не в `[Peer]`
- **nftset update** — атомарный через единый `nft -f` (нет race condition)
- **DNS upstream** через туннель: `server=1.1.1.1@awg0` (SO_BINDTODEVICE)
- **dnsmasq reload** — `systemctl reload` (SIGHUP), не restart — сохраняет DNS кэш
- **ip route replace** — идемпотентно, не падает если маршрут уже есть
- **awg-quick override** — `ExecStartPre=-/usr/bin/awg-quick down ...` решает "already exists" при restart
- **nftables.conf** — явные `include`, не glob (glob не работает с `flush ruleset` в nft v1.0.9)

---

## Важные файлы на Pi

| Файл на Pi | Источник в репо |
|---|---|
| `/etc/amnezia/amneziawg/awg0.conf` | генерируется app.py из загруженного конфига |
| `/etc/nftables.d/*.nft` | `nftables/*.nft` с подставленными плейсхолдерами |
| `/etc/dnsmasq.d/main.conf` | `config/dnsmasq-main.conf` |
| `/etc/antigateway/auth.conf` | генерируется при install.sh |
| `/etc/antigateway/network.conf` | генерируется при install.sh (JSON: iface, pi_ip) |
| `/opt/antigateway/app/app.py` | `app/app.py` |
| `/usr/local/bin/update-lists` | `scripts/update-lists` |
| `/etc/systemd/system/awg-quick@awg0.service.d/override.conf` | `systemd/awg-quick-override.conf` |

---

## app.py — соглашения

- `run_cmd(args)` — всегда `shell=False`, args — список
- `validate_iface()`, `validate_ip()` — вызывать перед использованием в командах
- `require_auth` — декоратор на все write-эндпоинты (X-Auth-Token + hmac.compare_digest)
- `nft_get_tables()` — кэш 5 сек, не вызывать напрямую nft в других местах

---

## Открытые задачи

- [ ] Протестировать `install.sh` на чистой машине (первый деплой не тестировался)
- [ ] Настроить systemd зависимость: dnsmasq After=awg-quick@awg0.service
- [ ] Добавить deploy key на Pi для `git pull` без пароля

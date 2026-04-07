# AntiGateway — Лог сессии 2026-04-07

## Инфраструктура

| Что | Значение |
|---|---|
| Pi IP | 192.168.1.5 |
| Pi user | user / 9123 |
| VPN сервер | 147.45.193.8:35829 (Frankfurt) |
| AWG интерфейс | awg0, адрес 10.8.1.28/32 |
| LAN интерфейс | eth0 |
| Web UI порт | 8080 |
| Auth токен | /etc/antigateway/auth.conf (или /etc/gateway-ui/auth.conf) |
| Репозиторий | https://github.com/cn0xn/AntiGateway |

---

## Что было сделано за сессию

### 1. Аудит и диагностика
- Диагностировали TikTok: роутинг работал корректно, проблема была account-level (регион)
- Провели полный архитектурный аудит gateway-ui

### 2. Этап 1 — nftables (P0)
Заменили единый файл на декларативную структуру `/etc/nftables.d/`:
- `00_gateway_base.nft` — tunnel_routing table, sets blocked_ips/zapret_ips, policy routing, zapret queue
- `10_nat.nft` — gateway_nat table, MASQUERADE для awg0 и eth0 (убрали из iptables PostUp)
- `20_dns_intercept.nft` — DNAT port 53 → dnsmasq, REJECT DoH серверов
- `30_killswitch.nft` — DROP fwmark 0x1 на eth0 при падении VPN
- `40_ipv6_block.nft` — DROP IPv6 forward от клиентов

`/etc/nftables.conf` — явные include (glob не работает с flush ruleset в nft v1.0.9).

### 3. Этап 2 — DNS (P1)
- `update-lists`: атомарный nftset reset через единый `nft -f` (нет race condition)
- `systemctl reload dnsmasq` (SIGHUP) вместо restart — сохраняет DNS кэш
- DNS upstream через туннель: `server=1.1.1.1@awg0`, `server=1.0.0.1@awg0` в `/etc/dnsmasq.d/main.conf`
- Подтверждено tcpdump: DNS идёт через awg0 (10.8.1.28 → 1.1.1.1)

### 4. Этап 3 — app.py (P2)
- `run_cmd(args)` — shell=False для всех системных команд
- `validate_iface()`, `validate_ip()` — защита от injection
- `require_auth` декоратор — X-Auth-Token на write endpoints, hmac.compare_digest
- `nft_get_tables()` — кэшированный список таблиц (5 сек), парсит "table ip name"
- `/api/status` — добавлены tiktok/telegram/meta в routing, nftables dict
- `/api/diagnostics` — 8 проверок: AWG ping, DNS, nft tunnel_routing, nft gateway_nat, nft dns_intercept, nft kill-switch, ip rule fwmark, table 100 route
- `build_awg_conf()` — убраны iptables MASQUERADE, PostUp/PostDown в [Interface] секции

### 5. AWG фикс
**Проблема**: PostUp/PostDown были в секции `[Peer]` вместо `[Interface]` → "Configuration parsing error"  
**Фикс**: перенесли в `[Interface]`, `ip route replace` (идемпотентно), `|| true` для ip rule add

**AWG override** `/etc/systemd/system/awg-quick@awg0.service.d/override.conf`:
```ini
[Service]
ExecStartPre=-/usr/bin/awg-quick down /etc/amnezia/amneziawg/awg0.conf
```
Решает "already exists" при restart.

### 6. Фронтенд — авторизация
- Модальное окно при открытии страницы (если нет токена в localStorage)
- `localStorage` хранит токен постоянно
- `apiFetch()` — все POST запросы идут с X-Auth-Token заголовком
- 401 → модал открывается снова

### 7. Cron скрипты (исправлены)
`/etc/cron.d/` (не crontab пользователя):
- `gateway-tunnel-watchdog` — каждую минуту, `check-tunnel.sh`
- `gateway-update-routes` — 04:00, antifilter.download → blocked_ips
- `gateway-update-antizapret` — 04:30, itdoginfo/allow-domains → dnsmasq

Все три скрипта исправлены:
- `check-tunnel.sh`: `ip route replace` вместо `ip route add`
- `update-routes.sh`: атомарный `nft -f` (нет race condition)
- `update-antizapret.sh`: проверка COUNT > 0 перед заменой файла

### 8. Репозиторий AntiGateway
Проект переименован, выделен в отдельный git репо.

**Структура:**
```
antigateway/
├── app/                    # Flask веб-приложение (актуальная версия с сервера)
├── nftables/               # 5 .nft файлов с __IFACE__, __PI_IP__ плейсхолдерами
├── scripts/                # update-lists, update-routes.sh, update-antizapret.sh, check-tunnel.sh
├── systemd/                # service units + awg-quick-override.conf
├── config/                 # dnsmasq-main.conf, sudoers.template, lists-config.json
├── install.sh              # тонкий инсталлер (~300 строк), клонирует репо
├── deploy.sh               # деплой на Pi: git pull + умный перезапуск сервисов
└── Makefile                # make push-deploy / make logs / make status
```

**Workflow:**
```bash
# Правка + деплой одной командой:
make push-deploy

# Только деплой (уже запушено):
make deploy

# Логи Pi:
make logs
```

---

## Текущее состояние Pi (всё работает)

```
● awg-quick@awg0    — active, handshake ~58ms
● zapret2-nfqws2    — active
● dnsmasq           — active, DNS через awg0
● nftables          — active, 5 таблиц
● gateway-ui        — active, порт 8080
```

Все 8 диагностических проверок `/api/diagnostics` — ✓

---

## Что НЕ сделано / отложено

- [ ] Обновить встроенный app.py/JS в старом install-gateway.sh (монолит в gateway-ui/tmp/) — он устарел, но заменён новым тонким инсталлером в AntiGateway
- [ ] Первый деплой через новый install.sh на чистую машину не тестировался
- [ ] `dnsmasq upstream via awg0` — теперь работает, но при перезапуске AWG нужно убедиться что dnsmasq поднимается после AWG (systemd зависимость не настроена явно)
- [ ] SSH-ключ Pi не добавлен в GitHub → Pi не может сам делать `git pull` без пароля. Нужно добавить deploy key или настроить HTTPS с токеном

---

## Важные файлы на Pi

| Файл | Назначение |
|---|---|
| `/etc/amnezia/amneziawg/awg0.conf` | AWG конфиг (PostUp в [Interface]) |
| `/etc/nftables.d/*.nft` | Правила nftables |
| `/etc/dnsmasq.d/main.conf` | DNS через awg0 |
| `/etc/gateway-ui/auth.conf` | Токен авторизации |
| `/opt/gateway-ui/app.py` | Flask бэкенд |
| `/usr/local/bin/update-lists` | Атомарное обновление nftsets |
| `/etc/sudoers.d/gateway-ui` | Sudo правила для web UI |
| `/etc/systemd/system/awg-quick@awg0.service.d/override.conf` | ExecStartPre fix |

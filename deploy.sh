#!/usr/bin/env bash
# AntiGateway — деплой на Pi
# Запускается на Pi: sudo bash /opt/antigateway/deploy.sh
# Файлы уже синхронизированы через rsync с dev-машины.
set -euo pipefail

INSTALL_DIR="/opt/antigateway"
NETWORK_CONF="/etc/antigateway/network.conf"
AWG_CONF="/etc/amnezia/amneziawg/awg0.conf"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
log()  { echo -e "${G}[deploy]${N} $*"; }
warn() { echo -e "${Y}[deploy]${N} $*"; }
err()  { echo -e "${R}[deploy]${N} $*"; }

cd "$INSTALL_DIR"

# ── 1. Чистим текущее состояние ───────────────────────────────────────────
log "Останавливаем zapret2..."
systemctl stop zapret2-nfqws2 2>/dev/null || true

log "Отключаем AWG туннель..."
/usr/bin/awg-quick down "$AWG_CONF" 2>/dev/null || true

log "Сбрасываем nftables..."
/usr/sbin/nft flush ruleset 2>/dev/null || true

log "Сбрасываем правила маршрутизации..."
ip rule del fwmark 0x1 table 100 priority 100 2>/dev/null || true
ip route flush table 100 2>/dev/null || true

# ── 2. Применяем новые конфиги ────────────────────────────────────────────
log "Читаем network.conf..."
if [[ ! -f "$NETWORK_CONF" ]]; then
  err "Не найден $NETWORK_CONF — запустите install.sh сначала"; exit 1
fi
IFACE=$(python3 -c "import json; d=json.load(open('$NETWORK_CONF')); print(d['iface'])")
PI_IP=$(python3  -c "import json; d=json.load(open('$NETWORK_CONF')); print(d['pi_ip'])")
log "  iface=$IFACE  pi_ip=$PI_IP"

log "Применяем nftables..."
for f in "$INSTALL_DIR/nftables/"*.nft; do
  dest="/etc/nftables.d/$(basename "$f")"
  sed "s/__IFACE__/${IFACE}/g; s/__PI_IP__/${PI_IP}/g" "$f" > "$dest"
done
systemctl restart nftables && log "nftables перезапущены ✓" || { err "nftables не применились"; exit 1; }

log "Обновляем скрипты в /usr/local/bin..."
for s in update-lists update-routes.sh update-antizapret.sh check-tunnel.sh; do
  [[ -f "$INSTALL_DIR/scripts/$s" ]] \
    && cp "$INSTALL_DIR/scripts/$s" /usr/local/bin/ \
    && chmod +x "/usr/local/bin/$s"
done

log "Обновляем dnsmasq конфиг..."
sed "s/__IFACE__/${IFACE}/g" "$INSTALL_DIR/config/dnsmasq-main.conf" > /etc/dnsmasq.d/main.conf

# ── 3. Запускаем сервисы ──────────────────────────────────────────────────
log "Запускаем AWG туннель..."
systemctl restart awg-quick@awg0 \
  && log "AWG поднят ✓" || warn "AWG не запустился"

log "Перезапускаем dnsmasq..."
systemctl restart dnsmasq \
  && log "dnsmasq запущен ✓" || warn "dnsmasq не запустился"

log "Запускаем zapret2..."
systemctl start zapret2-nfqws2 \
  && log "zapret2 запущен ✓" || warn "zapret2 не запустился"

log "Перезапускаем Web UI..."
# Поддерживаем оба имени сервиса (legacy: gateway-ui, новое: antigateway-ui)
if systemctl cat antigateway-ui &>/dev/null; then
  systemctl restart antigateway-ui \
    && log "Web UI перезапущен ✓ (antigateway-ui)" || warn "Web UI не перезапустился"
elif systemctl cat gateway-ui &>/dev/null; then
  systemctl restart gateway-ui \
    && log "Web UI перезапущен ✓ (gateway-ui)" || warn "Web UI не перезапустился"
else
  warn "Сервис Web UI не найден (antigateway-ui / gateway-ui)"
fi

# ── 4. Health check ────────────────────────────────────────────────────────
sleep 2
log "Проверка туннеля..."
if ping -c 2 -W 2 -I awg0 1.1.1.1 &>/dev/null; then
  log "Туннель работает ✓  (ping 1.1.1.1 через awg0)"
else
  warn "Туннель не отвечает на ping (но сервисы могут работать)"
fi

# ── 5. Итог ───────────────────────────────────────────────────────────────
echo ""
log "Деплой завершён ✓"
for svc in antigateway-ui awg-quick@awg0 dnsmasq zapret2-nfqws2 nftables; do
  st=$(systemctl is-active "$svc" 2>/dev/null || echo "?")
  [[ "$st" == "active" ]] \
    && echo -e "  ${G}●${N} $svc" \
    || echo -e "  ${R}○${N} $svc ($st)"
done

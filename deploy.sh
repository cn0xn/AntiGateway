#!/usr/bin/env bash
# AntiGateway — деплой на Pi
# Запускается на Pi: sudo bash /opt/antigateway/deploy.sh
set -euo pipefail

INSTALL_DIR="/opt/antigateway"
APP_DIR="$INSTALL_DIR/app"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
log()  { echo -e "${G}[deploy]${N} $*"; }
warn() { echo -e "${Y}[deploy]${N} $*"; }

cd "$INSTALL_DIR"

# ── 1. Получаем изменения ────────────────────────────────────────────────
log "git pull…"
git pull --ff-only

CHANGED=$(git diff HEAD@{1} HEAD --name-only 2>/dev/null || git show --name-only --format="" HEAD)

log "Изменены файлы:"
echo "$CHANGED" | sed 's/^/  /'

# ── 2. Деплоим по категориям ─────────────────────────────────────────────

RESTART_UI=0
RESTART_NFT=0
RESTART_DNSMASQ=0
COPY_SCRIPTS=0

# app/ → перезапуск web UI
if echo "$CHANGED" | grep -q "^app/"; then
  RESTART_UI=1
fi

# nftables/ → перезагрузка nftables
if echo "$CHANGED" | grep -q "^nftables/"; then
  RESTART_NFT=1
fi

# scripts/ → обновление бинарей в /usr/local/bin
if echo "$CHANGED" | grep -q "^scripts/"; then
  COPY_SCRIPTS=1
fi

# config/dnsmasq → перезапуск dnsmasq
if echo "$CHANGED" | grep -q "^config/dnsmasq"; then
  RESTART_DNSMASQ=1
fi

# Если ничего специфического не изменилось — всё равно перезапустим UI
if [[ $RESTART_UI -eq 0 && $RESTART_NFT -eq 0 && $COPY_SCRIPTS -eq 0 && $RESTART_DNSMASQ -eq 0 ]]; then
  warn "Специфических изменений не найдено, перезапускаем UI на всякий случай"
  RESTART_UI=1
fi

# ── 3. Применяем ─────────────────────────────────────────────────────────

if [[ $COPY_SCRIPTS -eq 1 ]]; then
  log "Обновляем скрипты в /usr/local/bin…"
  for s in update-lists update-routes.sh update-antizapret.sh check-tunnel.sh; do
    [[ -f "$INSTALL_DIR/scripts/$s" ]] && cp "$INSTALL_DIR/scripts/$s" /usr/local/bin/ && chmod +x "/usr/local/bin/$s"
  done
  log "Скрипты обновлены"
fi

if [[ $RESTART_NFT -eq 1 ]]; then
  log "Обновляем nftables…"

  # Читаем текущий network.conf для подстановки переменных
  IFACE=$(python3 -c "import json; d=json.load(open('/etc/antigateway/network.conf')); print(d['iface'])")
  PI_IP=$(python3  -c "import json; d=json.load(open('/etc/antigateway/network.conf')); print(d['pi_ip'])")

  for f in "$INSTALL_DIR/nftables/"*.nft; do
    dest="/etc/nftables.d/$(basename "$f")"
    sed "s/__IFACE__/${IFACE}/g; s/__PI_IP__/${PI_IP}/g" "$f" > "$dest"
  done

  systemctl restart nftables && log "nftables перезапущены" || warn "nftables не применились"
fi

if [[ $RESTART_DNSMASQ -eq 1 ]]; then
  log "Обновляем dnsmasq конфиг…"
  IFACE=$(python3 -c "import json; d=json.load(open('/etc/antigateway/network.conf')); print(d['iface'])")
  sed "s/__IFACE__/${IFACE}/g" "$INSTALL_DIR/config/dnsmasq-main.conf" > /etc/dnsmasq.d/main.conf
  systemctl reload dnsmasq && log "dnsmasq перезагружен" || warn "dnsmasq не перезагрузился"
fi

if [[ $RESTART_UI -eq 1 ]]; then
  log "Перезапускаем Web UI…"
  systemctl restart antigateway-ui && log "Web UI перезапущен" || warn "Web UI не перезапустился"
fi

# ── 4. Итог ──────────────────────────────────────────────────────────────
echo ""
log "Деплой завершён ✓"
for svc in antigateway-ui awg-quick@awg0 dnsmasq nftables; do
  st=$(systemctl is-active "$svc" 2>/dev/null || echo "?")
  [[ "$st" == "active" ]] \
    && echo -e "  ${G}●${N} $svc" \
    || echo -e "  ${R}○${N} $svc ($st)"
done

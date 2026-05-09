#!/usr/bin/env bash
# AntiGateway — деплой на Pi.
# Запускается на Pi: sudo bash /opt/antigateway/deploy.sh
# Файлы уже синхронизированы через rsync с dev-машины (см. Makefile).
#
# Идемпотентен: повторный запуск не ломает то что уже на месте. Включает
# миграцию с legacy gateway-ui (старое имя сервиса/конфигов).
set -euo pipefail

INSTALL_DIR="/opt/antigateway"
APP_DIR="/opt/antigateway/app"
ETC_DIR="/etc/antigateway"
LEGACY_ETC="/etc/gateway-ui"
NETWORK_CONF="$ETC_DIR/network.conf"
AWG_CONF="/etc/amnezia/amneziawg/awg0.conf"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
log()  { echo -e "${G}[deploy]${N} $*"; }
warn() { echo -e "${Y}[deploy]${N} $*"; }
err()  { echo -e "${R}[deploy]${N} $*"; }

cd "$INSTALL_DIR"

# ── 1. Миграция /etc/gateway-ui → /etc/antigateway ─────────────────────────
# Если legacy директория ещё существует и содержит более свежий конфиг —
# забираем его (актуальные настройки списков, токен), потом архивируем.
mkdir -p "$ETC_DIR"
mkdir -p /var/cache/antigateway/lists
# Мигрируем кэш списков, если был под старым именем
if [[ -d /var/cache/gateway-ui/lists && ! -L /var/cache/gateway-ui ]]; then
  cp -an /var/cache/gateway-ui/lists/. /var/cache/antigateway/lists/ 2>/dev/null || true
  ts=$(date +%Y%m%d-%H%M%S)
  mv /var/cache/gateway-ui "/var/cache/gateway-ui.bak.${ts}"
  log "Кэш мигрирован: /var/cache/gateway-ui → /var/cache/antigateway"
fi
chown -R "${SUDO_USER:-user}:${SUDO_USER:-user}" /var/cache/antigateway 2>/dev/null || true

if [[ -d "$LEGACY_ETC" && ! -L "$LEGACY_ETC" ]]; then
  log "Миграция $LEGACY_ETC → $ETC_DIR"
  for f in lists-config.json auth.conf network.conf dns-records.json custom-hosts; do
    src="$LEGACY_ETC/$f"; dst="$ETC_DIR/$f"
    if [[ -f "$src" ]]; then
      if [[ ! -f "$dst" ]] || [[ "$src" -nt "$dst" ]]; then
        cp -p "$src" "$dst"
        log "  ← $f (взято из legacy)"
      fi
    fi
  done
  ts=$(date +%Y%m%d-%H%M%S)
  mv "$LEGACY_ETC" "${LEGACY_ETC}.bak.${ts}"
  log "  ${LEGACY_ETC} → ${LEGACY_ETC}.bak.${ts}"
fi

# Чистим legacy /etc/dnsmasq.d/antizapret.conf (теперь покрывается update-lists)
rm -f /etc/dnsmasq.d/antizapret.conf

# Гарантируем права на auth.conf — иначе сервис под user не прочитает токен
# и require_auth уйдёт в fail-closed (503 "auth not configured")
WEB_USER=$(systemctl show -p User --value antigateway-ui 2>/dev/null \
       || systemctl show -p User --value gateway-ui 2>/dev/null || true)
WEB_USER="${WEB_USER:-${SUDO_USER:-user}}"
if [[ -f "$ETC_DIR/auth.conf" ]]; then
  chown "root:$WEB_USER" "$ETC_DIR/auth.conf"
  chmod 0640 "$ETC_DIR/auth.conf"
fi
# lists-config.json пишется самим Web UI — должен быть его владельца
if [[ -f "$ETC_DIR/lists-config.json" ]]; then
  chown "$WEB_USER:$WEB_USER" "$ETC_DIR/lists-config.json"
fi
if [[ -f "$ETC_DIR/network.conf" ]]; then
  chown "$WEB_USER:$WEB_USER" "$ETC_DIR/network.conf"
fi

# ── 2. Helper-скрипты в /usr/local/bin/ (root-owned, 0755) ─────────────────
log "Обновляем helper-скрипты..."
for s in update-lists update-routes.sh check-tunnel.sh \
         apply-awg-conf apply-dns-records apply-dns-hosts \
         render-nftables antigateway-reset; do
  if [[ -f "$INSTALL_DIR/scripts/$s" ]]; then
    install -m 0755 -o root -g root "$INSTALL_DIR/scripts/$s" /usr/local/bin/
  fi
done
# Удаляем legacy скрипт
rm -f /usr/local/bin/update-antizapret.sh

# ── 3. Sudoers (антигейтвей вместо legacy gateway-ui*) ─────────────────────
log "Web UI пользователь: $WEB_USER"

log "Устанавливаем /etc/sudoers.d/antigateway..."
tmp_sudo=$(mktemp)
trap 'rm -f "$tmp_sudo"' EXIT
sed "s/__USER__/${WEB_USER}/g" "$INSTALL_DIR/config/sudoers.template" > "$tmp_sudo"
# visudo -c проверяет синтаксис. Без проверки можно сломать sudo полностью.
if visudo -cf "$tmp_sudo" >/dev/null; then
  install -m 0440 -o root -g root "$tmp_sudo" /etc/sudoers.d/antigateway
  # Удаляем legacy правила
  rm -f /etc/sudoers.d/gateway-ui /etc/sudoers.d/gateway-ui-nft /etc/sudoers.d/route-control
  log "  sudoers применён ✓"
else
  err "sudoers.template не прошёл visudo -c — НЕ применяю"
  exit 1
fi
trap - EXIT
rm -f "$tmp_sudo"

# ── 4. Systemd unit antigateway-ui ─────────────────────────────────────────
log "Обновляем antigateway-ui.service..."
sed "s|__APP_DIR__|${APP_DIR}|g; s|__USER__|${WEB_USER}|g; s|__PORT__|8080|g" \
  "$INSTALL_DIR/systemd/antigateway-ui.service" \
  > /lib/systemd/system/antigateway-ui.service

# Override для awg-quick (idempotent up)
mkdir -p /etc/systemd/system/awg-quick@awg0.service.d
install -m 0644 "$INSTALL_DIR/systemd/awg-quick-override.conf" \
  /etc/systemd/system/awg-quick@awg0.service.d/override.conf

systemctl daemon-reload

# Останавливаем legacy gateway-ui.service, если он ещё активен
if systemctl is-enabled gateway-ui >/dev/null 2>&1; then
  log "Отключаем legacy gateway-ui.service..."
  systemctl stop    gateway-ui 2>/dev/null || true
  systemctl disable gateway-ui 2>/dev/null || true
  # Удаляем legacy unit-файл (он лежит в /usr/lib/systemd/system)
  rm -f /usr/lib/systemd/system/gateway-ui.service /lib/systemd/system/gateway-ui.service
  systemctl daemon-reload
fi

systemctl enable antigateway-ui >/dev/null 2>&1

# ── 5. Cron + logrotate ────────────────────────────────────────────────────
log "Cron + logrotate..."
cat > /etc/cron.d/antigateway-watchdog << 'EOF'
* * * * * root /usr/local/bin/check-tunnel.sh
EOF
cat > /etc/cron.d/antigateway-update-routes << 'EOF'
0 4 * * * root /usr/local/bin/update-routes.sh >> /var/log/antigateway-update-routes.log 2>&1
EOF
cat > /etc/cron.d/antigateway-update-lists << 'EOF'
30 4 * * * root /usr/local/bin/update-lists >> /var/log/antigateway-update-lists.log 2>&1
EOF
rm -f /etc/cron.d/antigateway-update-antizapret /etc/cron.d/gateway-ui-watchdog \
      /etc/cron.d/gateway-update-routes /etc/cron.d/gateway-update-antizapret

install -m 0644 -o root -g root \
  "$INSTALL_DIR/config/logrotate.conf" /etc/logrotate.d/antigateway

# ── 6. Применяем nftables через render-nftables ───────────────────────────
log "Рендерим nftables..."
if [[ ! -f "$NETWORK_CONF" ]]; then
  err "Не найден $NETWORK_CONF"; exit 1
fi
/usr/local/bin/render-nftables --src "$INSTALL_DIR/nftables" || {
  err "render-nftables провалился"; exit 1
}

log "Перезапускаем nftables (атомарный flush+load)..."
systemctl restart nftables && log "nftables перезапущены ✓" \
  || { err "nftables не применились"; exit 1; }

log "Обновляем dnsmasq конфиг..."
IFACE=$(python3 -c "import json; print(json.load(open('$NETWORK_CONF'))['iface'])")
sed "s/__IFACE__/${IFACE}/g" "$INSTALL_DIR/config/dnsmasq-main.conf" > /etc/dnsmasq.d/main.conf

# ── 7. Перезапускаем сервисы ──────────────────────────────────────────────
# AWG поднимаем ПЕРВЫМ — иначе dnsmasq не сможет забиндить upstream socket
# на awg0 (server=1.1.1.1@awg0 в main.conf, SO_BINDTODEVICE требует
# существующий интерфейс в момент бинда).
log "Перезапускаем AWG..."
systemctl restart awg-quick@awg0 && log "AWG поднят ✓" || warn "AWG не запустился"

# Даём ядру 1с на регистрацию интерфейса
sleep 1

log "Перезапускаем dnsmasq..."
systemctl restart dnsmasq && log "dnsmasq запущен ✓" || warn "dnsmasq не запустился"

log "Перезапускаем zapret2..."
systemctl restart zapret2-nfqws2 && log "zapret2 запущен ✓" || warn "zapret2 не запустился"

# Software flow offload — применяется отдельно от main ruleset (требует UP awg0).
# Идемпотентно: если awg0.conf ещё не обновлён с новым PostUp (после смены
# через Web UI), deploy.sh всё равно поднимет flowtable.
if [[ -f /etc/nftables.d/90_flowtable.nft ]]; then
  log "Применяем flowtable..."
  if nft -f /etc/nftables.d/90_flowtable.nft 2>/dev/null; then
    log "flowtable активна ✓"
  else
    warn "flowtable не применилась (awg0 не готов?)"
  fi
fi

log "Запускаем antigateway-ui..."
systemctl restart antigateway-ui && log "antigateway-ui ✓" || warn "Web UI не перезапустился"

# ── 8. Health check ────────────────────────────────────────────────────────
sleep 2
log "Проверка туннеля..."
if ping -c 2 -W 2 -I awg0 1.1.1.1 &>/dev/null; then
  log "Туннель работает ✓"
else
  warn "Туннель не отвечает на ping"
fi

# ── 9. Итог ───────────────────────────────────────────────────────────────
echo ""
log "Деплой завершён ✓"
for svc in antigateway-ui awg-quick@awg0 dnsmasq zapret2-nfqws2 nftables; do
  st=$(systemctl is-active "$svc" 2>/dev/null || echo "?")
  [[ "$st" == "active" ]] \
    && echo -e "  ${G}●${N} $svc" \
    || echo -e "  ${R}○${N} $svc ($st)"
done

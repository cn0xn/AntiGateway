#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════╗
# ║  AntiGateway Installer                                              ║
# ║  AmneziaWG + zapret2 + dnsmasq + nftables + Web UI                 ║
# ║  Платформы: aarch64, x86_64, armv7l, armv6l                        ║
# ╚══════════════════════════════════════════════════════════════════════╝
set -euo pipefail

REPO_URL="https://github.com/__REPO_OWNER__/antigateway"
INSTALL_DIR="/opt/antigateway"
APP_DIR="/opt/antigateway/app"
ZAP2_VER="v0.9.4.7"
WEBUI_PORT="8080"
LOG="/var/log/antigateway-install.log"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[1;37m'; N='\033[0m'

log()  { echo -e "${G}[+]${N} $*"; echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }
warn() { echo -e "${Y}[!]${N} $*"; echo "[WARN] $*" >> "$LOG"; }
err()  { echo -e "${R}[✗]${N} $*" >&2; echo "[ERR] $*" >> "$LOG"; exit 1; }
step() { echo -e "\n${B}━━━ ${W}$*${N}"; }
ask()  { echo -en "${C}[?]${N} $1: "; }

[[ $EUID -ne 0 ]] && err "Запустите через sudo: sudo bash install.sh"
USER="${SUDO_USER:-$(logname 2>/dev/null || echo 'user')}"

# ═══════════════════════════════════════════════════════════════════════════
# 1. СРЕДА
# ═══════════════════════════════════════════════════════════════════════════
detect_env() {
  step "Определение системы"
  command -v apt-get &>/dev/null || err "Требуется Debian/Ubuntu (apt)"

  ARCH=$(uname -m)
  case "$ARCH" in
    aarch64|arm64) ZAP2_ARCH="linux-arm64"  ; AWG_ARCH="arm64" ;;
    x86_64)        ZAP2_ARCH="linux-x86_64" ; AWG_ARCH="amd64" ;;
    armv7l)        ZAP2_ARCH="linux-arm"    ; AWG_ARCH="armhf" ;;
    armv6l)        ZAP2_ARCH="linux-arm"    ; AWG_ARCH="armel" ;;
    *)             warn "Неизвестная архитектура: $ARCH"; ZAP2_ARCH="linux-x86_64"; AWG_ARCH="amd64" ;;
  esac

  IFACE=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
  GW_IP=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')
  PI_IP=$(ip addr show "$IFACE" 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]; exit}')

  log "Система: $(uname -m), ядро: $(uname -r)"
  log "Интерфейс: $IFACE, шлюз: $GW_IP, IP: $PI_IP"
}

# ═══════════════════════════════════════════════════════════════════════════
# 2. КОНФИГУРАЦИЯ
# ═══════════════════════════════════════════════════════════════════════════
configure() {
  step "Конфигурация"

  echo -e "\n${W}Сетевые настройки (Enter = оставить)${N}"
  echo "  Интерфейс: ${G}$IFACE${N}  Шлюз: ${G}$GW_IP${N}  IP: ${G}$PI_IP${N}"
  echo ""

  ask "Сетевой интерфейс [${IFACE}]";    read -r inp; [[ -n "$inp" ]] && IFACE="$inp"
  ask "IP шлюза (роутер) [${GW_IP}]";    read -r inp; [[ -n "$inp" ]] && GW_IP="$inp"
  ask "IP этой машины   [${PI_IP}]";     read -r inp; [[ -n "$inp" ]] && PI_IP="$inp"
  ask "Порт Web UI       [${WEBUI_PORT}]"; read -r inp; [[ -n "$inp" ]] && WEBUI_PORT="$inp"

  # Валидация
  ip link show "$IFACE" &>/dev/null || err "Интерфейс $IFACE не найден"
  [[ "$PI_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "Некорректный IP: $PI_IP"
  [[ "$GW_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "Некорректный шлюз: $GW_IP"

  echo ""
  echo -e "${W}AmneziaWG конфиг${N}"
  echo "  Можно загрузить сейчас или позже через Web UI."
  ask "Загрузить конфиг AWG сейчас? [y/N]"; read -r yn

  AWG_RAW_CONF=""
  VPN_SERVER_IP=""
  if [[ "${yn,,}" == "y" ]]; then
    echo "  Вставьте содержимое awg0.conf, завершите строкой EOF:"
    while IFS= read -r line; do
      [[ "$line" == "EOF" ]] && break
      AWG_RAW_CONF+="$line"$'\n'
    done
    local ep
    ep=$(echo "$AWG_RAW_CONF" | grep -i "^Endpoint" | sed 's/.*= *//' | head -1)
    VPN_SERVER_IP=$(echo "$ep" | cut -d: -f1)
    [[ -n "$VPN_SERVER_IP" ]] && log "VPN сервер: $ep" || warn "Endpoint не найден в конфиге"
  else
    warn "AWG конфиг пропущен — настройте туннель через Web UI"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# 3. ПАКЕТЫ
# ═══════════════════════════════════════════════════════════════════════════
install_packages() {
  step "Системные пакеты"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq

  local pkgs=(
    curl wget git build-essential pkg-config
    "linux-headers-$(uname -r)" dkms
    nftables iptables iproute2
    dnsmasq
    python3 python3-flask
    netcat-openbsd lsb-release ca-certificates
    libmnl-dev libelf-dev
  )
  [[ "$ARCH" == "aarch64" ]] && dpkg -l | grep -q raspi && pkgs+=(linux-headers-raspi)

  for pkg in "${pkgs[@]}"; do
    dpkg -l "$pkg" &>/dev/null 2>&1 && continue
    log "Установка $pkg…"
    apt-get install -y -qq "$pkg" >> "$LOG" 2>&1 || warn "Не удалось: $pkg"
  done

  grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null \
    || { echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf; sysctl -w net.ipv4.ip_forward=1 >> "$LOG" 2>&1; }

  # BBR + сетевые буферы
  modprobe tcp_bbr 2>/dev/null || true
  echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
  cat > /etc/sysctl.d/99-antigateway-perf.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 5000
net.ipv4.ip_forward = 1
EOF
  sysctl -p /etc/sysctl.d/99-antigateway-perf.conf >> "$LOG" 2>&1
  log "Пакеты установлены"
}

# ═══════════════════════════════════════════════════════════════════════════
# 4. AMNEZIAWG
# ═══════════════════════════════════════════════════════════════════════════
install_amneziawg() {
  step "AmneziaWG"

  if command -v awg &>/dev/null && lsmod | grep -q amneziawg 2>/dev/null; then
    log "AmneziaWG уже установлен"; return 0
  fi

  # Попытка 1: deb-пакет (только x86_64)
  if [[ "$AWG_ARCH" == "amd64" ]]; then
    curl -fsSL "https://repository.amnezia.org/archive.key" \
      | gpg --dearmor -o /usr/share/keyrings/amnezia.gpg >> "$LOG" 2>&1 \
      && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/amnezia.gpg] https://repository.amnezia.org/debian stable main" \
        > /etc/apt/sources.list.d/amnezia.list \
      && apt-get update -qq \
      && apt-get install -y -qq amneziawg >> "$LOG" 2>&1 \
      && { log "AmneziaWG установлен через apt"; return 0; } || warn "apt-установка не удалась, собираем из исходников"
  fi

  # Попытка 2: сборка модуля из исходников
  local build_dir
  build_dir=$(mktemp -d)
  trap "rm -rf $build_dir" RETURN

  log "Сборка AmneziaWG из исходников (может занять 5-15 мин)…"
  git clone --depth=1 https://github.com/amnezia-vpn/amneziawg-linux-kernel-module \
    "$build_dir/module" >> "$LOG" 2>&1 || err "Не удалось клонировать модуль AWG"

  make -C "$build_dir/module/src" -j"$(nproc)" >> "$LOG" 2>&1 \
    || err "Сборка модуля провалилась"

  local ko
  ko=$(find "$build_dir/module" -name "amneziawg.ko" | head -1)
  [[ -n "$ko" ]] || err "amneziawg.ko не найден после сборки"

  local mod_dir="/lib/modules/$(uname -r)/extra"
  mkdir -p "$mod_dir"
  cp "$ko" "$mod_dir/"
  depmod -a
  echo "amneziawg" > /etc/modules-load.d/amneziawg.conf
  modprobe amneziawg >> "$LOG" 2>&1 || err "Не удалось загрузить модуль amneziawg"

  # awg-tools
  git clone --depth=1 https://github.com/amnezia-vpn/amneziawg-tools \
    "$build_dir/tools" >> "$LOG" 2>&1 || err "Не удалось клонировать awg-tools"
  make -C "$build_dir/tools/src" -j"$(nproc)" >> "$LOG" 2>&1 || err "Сборка awg-tools провалилась"
  cp "$build_dir/tools/src/awg" "$build_dir/tools/src/awg-quick" /usr/bin/
  chmod +x /usr/bin/awg /usr/bin/awg-quick

  log "AmneziaWG собран и установлен из исходников"
}

# ═══════════════════════════════════════════════════════════════════════════
# 5. AWG КОНФИГ И СЕРВИС
# ═══════════════════════════════════════════════════════════════════════════
setup_awg() {
  step "AWG конфиг и сервис"
  mkdir -p /etc/amnezia/amneziawg

  # Systemd сервис
  if [[ ! -f /lib/systemd/system/awg-quick@.service ]]; then
    cp "$INSTALL_DIR/systemd/awg-quick@.service" /lib/systemd/system/
  fi

  # Override: idempotent up (ExecStartPre=-awg-quick down)
  mkdir -p /etc/systemd/system/awg-quick@awg0.service.d
  cp "$INSTALL_DIR/systemd/awg-quick-override.conf" \
     /etc/systemd/system/awg-quick@awg0.service.d/override.conf

  if [[ -n "$AWG_RAW_CONF" ]]; then
    _write_awg_conf
    systemctl daemon-reload
    systemctl enable awg-quick@awg0 >> "$LOG" 2>&1
    systemctl start  awg-quick@awg0 >> "$LOG" 2>&1 || warn "AWG не запустился — проверьте конфиг"
  else
    systemctl daemon-reload
    systemctl enable awg-quick@awg0 >> "$LOG" 2>&1
    warn "AWG не запущен — загрузите конфиг через Web UI"
  fi
  log "AWG сервис настроен"
}

_write_awg_conf() {
  local awg_conf="/etc/amnezia/amneziawg/awg0.conf"

  # PostUp/PostDown: в [Interface], ip route replace (идемпотентно), без MASQUERADE (nftables)
  local postup="iptables -t mangle -A FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN \
-j TCPMSS --clamp-mss-to-pmtu; \
sysctl -w net.ipv4.ip_forward=1; \
ip route replace ${VPN_SERVER_IP}/32 via ${GW_IP} dev ${IFACE}; \
ip route replace default dev awg0 table 100; \
ip rule add fwmark 0x1 table 100 priority 100 2>/dev/null || true"

  local postdown="iptables -t mangle -D FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN \
-j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true; \
ip route del ${VPN_SERVER_IP}/32 via ${GW_IP} dev ${IFACE} 2>/dev/null || true; \
ip route del default dev awg0 table 100 2>/dev/null || true; \
ip rule del fwmark 0x1 table 100 priority 100 2>/dev/null || true"

  # Вставляем Table/MTU/PostUp/PostDown внутрь [Interface], перед [Peer]
  echo "$AWG_RAW_CONF" \
    | grep -v -i "^PostUp\|^PostDown\|^Table\|^DNS\|^MTU" \
    | awk -v pu="PostUp = $postup" -v pd="PostDown = $postdown" '
        /^\[Peer\]/ && !done { print pu; print pd; done=1 }
        /^\[Interface\]/     { print; print "Table = off"; print "MTU = 1380"; next }
        { print }
      ' > "$awg_conf"

  chmod 600 "$awg_conf"
  log "AWG конфиг записан: $awg_conf"
}

# ═══════════════════════════════════════════════════════════════════════════
# 6. NFTABLES
# ═══════════════════════════════════════════════════════════════════════════
setup_nftables() {
  step "nftables"
  mkdir -p /etc/nftables.d

  # Подставляем переменные в файлы с плейсхолдерами
  for f in "$INSTALL_DIR/nftables/"*.nft; do
    local dest="/etc/nftables.d/$(basename "$f")"
    sed "s/__IFACE__/${IFACE}/g; s/__PI_IP__/${PI_IP}/g" "$f" > "$dest"
  done

  # Главный nftables.conf (явные include — glob не работает с flush ruleset в v1.0.x)
  cat > /etc/nftables.conf << 'EOF'
#!/usr/sbin/nft -f
flush ruleset
include "/etc/nftables.d/00_gateway_base.nft"
include "/etc/nftables.d/10_nat.nft"
include "/etc/nftables.d/20_dns_intercept.nft"
include "/etc/nftables.d/30_killswitch.nft"
include "/etc/nftables.d/40_ipv6_block.nft"
EOF

  systemctl enable nftables >> "$LOG" 2>&1
  systemctl restart nftables >> "$LOG" 2>&1 || warn "nftables не применились — проверьте конфиги"
  log "nftables настроены (5 файлов в /etc/nftables.d/)"
}

# ═══════════════════════════════════════════════════════════════════════════
# 7. DNSMASQ
# ═══════════════════════════════════════════════════════════════════════════
setup_dnsmasq() {
  step "dnsmasq"

  # Отключить systemd-resolved stub (конфликтует с dnsmasq на порту 53)
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/nostub.conf << 'EOF'
[Resolve]
DNSStubListener=no
EOF
  systemctl restart systemd-resolved >> "$LOG" 2>&1 || true

  # Основной конфиг: подставляем интерфейс
  sed "s/__IFACE__/${IFACE}/g" "$INSTALL_DIR/config/dnsmasq-main.conf" \
    > /etc/dnsmasq.d/main.conf

  # systemd override — убрать конфликт с Type=forking
  mkdir -p /etc/systemd/system/dnsmasq.service.d
  cat > /etc/systemd/system/dnsmasq.service.d/override.conf << 'EOF'
[Service]
Type=simple
PIDFile=
ExecStartPre=
ExecStartPost=
EOF

  systemctl daemon-reload
  systemctl enable  dnsmasq >> "$LOG" 2>&1
  systemctl restart dnsmasq >> "$LOG" 2>&1 || warn "dnsmasq не запустился"
  log "dnsmasq настроен"
}

# ═══════════════════════════════════════════════════════════════════════════
# 8. ZAPRET2
# ═══════════════════════════════════════════════════════════════════════════
install_zapret2() {
  step "zapret2 (nfqws2)"

  local zap2_dir="/opt/zapret2"
  if [[ -f "$zap2_dir/bin/nfqws2" ]]; then
    log "zapret2 уже установлен"; return 0
  fi

  local url="https://github.com/bol-van/zapret/releases/download/${ZAP2_VER}/zapret-${ZAP2_VER}-${ZAP2_ARCH}.tar.gz"
  local tmp
  tmp=$(mktemp)
  trap "rm -f $tmp" RETURN

  log "Скачиваем zapret2 ${ZAP2_VER}…"
  wget -q -O "$tmp" "$url" || err "Не удалось скачать zapret2"

  mkdir -p "$zap2_dir"/{bin,ipset}
  tar -xzf "$tmp" -C "$zap2_dir" --strip-components=1 >> "$LOG" 2>&1 || err "Распаковка zapret2 провалилась"

  # Найти и переименовать бинари
  local nfqws
  nfqws=$(find "$zap2_dir" -name "nfqws" -type f | head -1)
  [[ -n "$nfqws" ]] && cp "$nfqws" "$zap2_dir/bin/nfqws2" && chmod +x "$zap2_dir/bin/nfqws2"

  touch "$zap2_dir/ipset/zapret-hosts-user.txt"

  # Конфиг
  mkdir -p /etc/zapret2
  cat > /etc/zapret2/nfqws2.conf << 'EOF'
--qnum=300
--threads=2
--user=daemon
--pidfile=/run/nfqws2.pid
--dpi-desync=multidisorder
--dpi-desync-split-pos=3
--dpi-desync-fooling=md5sig
--filter-tcp=443 --hostlist=/opt/zapret2/ipset/zapret-hosts-user.txt
--filter-udp=443 --hostlist=/opt/zapret2/ipset/zapret-hosts-user.txt
EOF

  # Systemd сервис
  cat > /lib/systemd/system/zapret2-nfqws2.service << EOF
[Unit]
Description=zapret2 nfqws2 DPI bypass
After=network.target nftables.service

[Service]
Type=forking
PIDFile=/run/nfqws2.pid
ExecStart=${zap2_dir}/bin/nfqws2 @/etc/zapret2/nfqws2.conf
ExecStop=/bin/kill -TERM \$MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable  zapret2-nfqws2 >> "$LOG" 2>&1
  systemctl start   zapret2-nfqws2 >> "$LOG" 2>&1 || warn "zapret2 не запустился"
  log "zapret2 установлен"
}

# ═══════════════════════════════════════════════════════════════════════════
# 9. СКРИПТЫ И CRON
# ═══════════════════════════════════════════════════════════════════════════
setup_scripts() {
  step "Скрипты обновления и watchdog"

  # Подставляем переменные в check-tunnel.sh
  sed "s/__IFACE__/${IFACE}/g; s/__GW_IP__/${GW_IP}/g; s/__VPN_SERVER_IP__/${VPN_SERVER_IP:-0.0.0.0}/g" \
    "$INSTALL_DIR/scripts/check-tunnel.sh" > /usr/local/bin/check-tunnel.sh

  # Остальные скрипты — копируем как есть
  for s in update-lists update-routes.sh update-antizapret.sh; do
    cp "$INSTALL_DIR/scripts/$s" /usr/local/bin/
  done

  chmod +x /usr/local/bin/{check-tunnel.sh,update-lists,update-routes.sh,update-antizapret.sh}

  # apply-awg-conf — утилита для Web UI
  cat > /usr/local/bin/apply-awg-conf << 'EOF'
#!/bin/bash
cat > /etc/amnezia/amneziawg/awg0.conf
chmod 600 /etc/amnezia/amneziawg/awg0.conf
EOF
  chmod +x /usr/local/bin/apply-awg-conf

  # Cron через /etc/cron.d/ — не трогает пользовательский crontab
  cat > /etc/cron.d/antigateway-watchdog << 'EOF'
* * * * * root /usr/local/bin/check-tunnel.sh
EOF
  cat > /etc/cron.d/antigateway-update-routes << 'EOF'
0 4 * * * root /usr/local/bin/update-routes.sh >> /var/log/antigateway-update-routes.log 2>&1
EOF
  cat > /etc/cron.d/antigateway-update-antizapret << 'EOF'
30 4 * * * root /usr/local/bin/update-antizapret.sh >> /var/log/antigateway-update-antizapret.log 2>&1
EOF

  log "Скрипты установлены, cron настроен (в /etc/cron.d/)"
}

# ═══════════════════════════════════════════════════════════════════════════
# 10. WEB UI
# ═══════════════════════════════════════════════════════════════════════════
setup_webui() {
  step "Web UI"

  mkdir -p /etc/antigateway /var/cache/antigateway/lists

  # Токен авторизации (генерируем один раз, не перезаписываем)
  if [[ ! -f /etc/antigateway/auth.conf ]]; then
    local token
    token=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    python3 -c "import json; print(json.dumps({'token': '$token'}))" > /etc/antigateway/auth.conf
    chmod 640 /etc/antigateway/auth.conf
    chown "root:$USER" /etc/antigateway/auth.conf
    log "Токен создан: /etc/antigateway/auth.conf"
  else
    log "auth.conf уже существует — токен не перезаписан"
  fi

  # lists-config.json (только если нет — не затираем пользовательские настройки)
  [[ ! -f /etc/antigateway/lists-config.json ]] \
    && cp "$INSTALL_DIR/config/lists-config.json" /etc/antigateway/lists-config.json

  # network.conf
  cat > /etc/antigateway/network.conf << EOF
{"iface": "$IFACE", "gw_ip": "$GW_IP", "pi_ip": "$PI_IP"}
EOF

  # Симлинки для совместимости (app.py ищет конфиги в /etc/gateway-ui/)
  if [[ ! -d /etc/gateway-ui ]]; then
    ln -s /etc/antigateway /etc/gateway-ui
  fi

  # Права
  chown -R "$USER:$USER" "$APP_DIR" /etc/antigateway /var/cache/antigateway

  # Systemd сервис
  sed "s|__APP_DIR__|${APP_DIR}|g; s|__USER__|${USER}|g; s|__PORT__|${WEBUI_PORT}|g" \
    "$INSTALL_DIR/systemd/gateway-ui.service" > /lib/systemd/system/antigateway-ui.service

  systemctl daemon-reload
  systemctl enable  antigateway-ui >> "$LOG" 2>&1
  systemctl start   antigateway-ui >> "$LOG" 2>&1 || warn "Web UI не запустился"
  log "Web UI запущен на порту $WEBUI_PORT"
}

# ═══════════════════════════════════════════════════════════════════════════
# 11. SUDOERS
# ═══════════════════════════════════════════════════════════════════════════
setup_sudoers() {
  step "sudoers"
  sed "s/__USER__/${USER}/g" "$INSTALL_DIR/config/sudoers.template" \
    > /etc/sudoers.d/antigateway
  chmod 440 /etc/sudoers.d/antigateway
  log "sudoers настроен для пользователя $USER"
}

# ═══════════════════════════════════════════════════════════════════════════
# 12. КЛОНИРОВАНИЕ / ОБНОВЛЕНИЕ РЕПО
# ═══════════════════════════════════════════════════════════════════════════
setup_repo() {
  step "AntiGateway репозиторий"

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    log "Репо уже существует, обновляем…"
    git -C "$INSTALL_DIR" pull --ff-only >> "$LOG" 2>&1 || warn "git pull не удался"
  else
    log "Клонируем $REPO_URL → $INSTALL_DIR…"
    git clone "$REPO_URL" "$INSTALL_DIR" >> "$LOG" 2>&1 || err "Не удалось клонировать репо"
  fi

  log "Репо готово: $INSTALL_DIR"
}

# ═══════════════════════════════════════════════════════════════════════════
# ИТОГ
# ═══════════════════════════════════════════════════════════════════════════
print_summary() {
  local token=""
  [[ -f /etc/antigateway/auth.conf ]] \
    && token=$(python3 -c "import json; print(json.load(open('/etc/antigateway/auth.conf'))['token'])" 2>/dev/null)

  echo ""
  echo -e "${G}╔══════════════════════════════════════════════════════════╗${N}"
  echo -e "${G}║${N}  ${W}AntiGateway установлен${N}"
  echo -e "${G}╠══════════════════════════════════════════════════════════╣${N}"
  echo -e "${G}║${N}  Web UI:     ${C}http://${PI_IP}:${WEBUI_PORT}${N}"
  echo -e "${G}║${N}  Токен:      ${Y}${token}${N}"
  echo -e "${G}║${N}  Лог:        $LOG"
  echo -e "${G}╠══════════════════════════════════════════════════════════╣${N}"

  for svc in awg-quick@awg0 zapret2-nfqws2 dnsmasq nftables antigateway-ui; do
    local st
    st=$(systemctl is-active "$svc" 2>/dev/null || echo "not-found")
    if [[ "$st" == "active" ]]; then
      echo -e "${G}║${N}  ${G}●${N} $svc"
    else
      echo -e "${G}║${N}  ${R}○${N} $svc ${Y}($st)${N}"
    fi
  done

  echo -e "${G}╠══════════════════════════════════════════════════════════╣${N}"
  echo -e "${G}║${N}  Обновить приложение:"
  echo -e "${G}║${N}    ${C}cd $INSTALL_DIR && git pull${N}"
  echo -e "${G}║${N}    ${C}sudo systemctl restart antigateway-ui${N}"
  if [[ -z "$AWG_RAW_CONF" ]]; then
    echo -e "${G}╠══════════════════════════════════════════════════════════╣${N}"
    echo -e "${G}║${N}  ${Y}[!] Загрузите AWG конфиг через Web UI → вкладка VPN${N}"
  fi
  echo -e "${G}╚══════════════════════════════════════════════════════════╝${N}"
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════
main() {
  mkdir -p "$(dirname "$LOG")"
  echo "=== AntiGateway Install $(date) ===" >> "$LOG"

  detect_env
  configure
  install_packages
  install_amneziawg
  setup_repo          # клонирует репо → $INSTALL_DIR
  setup_nftables
  setup_dnsmasq
  install_zapret2
  setup_scripts
  setup_webui
  setup_sudoers
  setup_awg           # после webui — конфиг AWG может прийти позже через UI
  print_summary
}

main "$@"

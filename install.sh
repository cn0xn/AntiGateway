#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════╗
# ║  AntiGateway Installer                                              ║
# ║  AmneziaWG + zapret2 + dnsmasq + nftables + Web UI                 ║
# ║  Платформы: aarch64, x86_64, armv7l, armv6l                        ║
# ╚══════════════════════════════════════════════════════════════════════╝
set -euo pipefail

REPO_URL="https://github.com/cn0xn/AntiGateway"
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
  step "AmneziaWG (через DKMS — модуль пересобирается при apt upgrade ядра)"

  if command -v awg &>/dev/null && lsmod | grep -q amneziawg 2>/dev/null; then
    log "AmneziaWG уже установлен"; return 0
  fi

  # PPA от Amnezia: содержит amneziawg-dkms + amneziawg-tools для всех архитектур.
  # DKMS даёт автоматическую пересборку при apt upgrade ядра — иначе после
  # апдейта kernel модуль исчезает и AWG ложится.
  local codename
  codename=$(lsb_release -cs 2>/dev/null || echo "")

  # Ubuntu PPA работает на ubuntu-derivatives. На Debian/Raspbian PPA не подойдёт —
  # там собираем из исходников через DKMS вручную.
  if command -v add-apt-repository &>/dev/null && [[ -n "$codename" ]] \
     && [[ "$(lsb_release -is 2>/dev/null || echo '')" == "Ubuntu" ]]; then
    log "Подключаем ppa:amnezia/ppa для $codename…"
    add-apt-repository -y ppa:amnezia/ppa >> "$LOG" 2>&1 \
      || warn "add-apt-repository не сработал, fallback на сборку из исходников"
    apt-get update -qq >> "$LOG" 2>&1
    if apt-get install -y -qq amneziawg-dkms amneziawg-tools >> "$LOG" 2>&1; then
      modprobe amneziawg >> "$LOG" 2>&1 || warn "modprobe amneziawg не удался — проверьте dkms status"
      echo "amneziawg" > /etc/modules-load.d/amneziawg.conf
      log "AmneziaWG установлен через DKMS (PPA)"
      return 0
    fi
    warn "PPA-установка не удалась, fallback на сборку"
  fi

  # Fallback: ставим dkms-пакет вручную из upstream-исходников.
  # Это даёт ту же DKMS-инфраструктуру, что и PPA.
  apt-get install -y -qq dkms "linux-headers-$(uname -r)" >> "$LOG" 2>&1 \
    || err "Не удалось поставить dkms / linux-headers"

  local build_dir
  build_dir=$(mktemp -d)
  trap "rm -rf $build_dir" RETURN

  log "Клонируем amneziawg-linux-kernel-module…"
  git clone --depth=1 https://github.com/amnezia-vpn/amneziawg-linux-kernel-module \
    "$build_dir/module" >> "$LOG" 2>&1 || err "git clone module не удался"

  local awg_ver
  awg_ver=$(git -C "$build_dir/module" describe --tags --always 2>/dev/null \
            | sed 's/^v//' || echo "1.0.0")
  local dkms_dir="/usr/src/amneziawg-${awg_ver}"

  mkdir -p "$dkms_dir"
  cp -r "$build_dir/module/src/"* "$dkms_dir/"

  # dkms.conf для пересборки при апгрейде ядра
  cat > "$dkms_dir/dkms.conf" << EOF
PACKAGE_NAME="amneziawg"
PACKAGE_VERSION="${awg_ver}"
BUILT_MODULE_NAME[0]="amneziawg"
DEST_MODULE_LOCATION[0]="/kernel/net"
AUTOINSTALL="yes"
MAKE[0]="make"
CLEAN="make clean"
EOF

  dkms add     -m amneziawg -v "$awg_ver" >> "$LOG" 2>&1 || err "dkms add не удался"
  dkms build   -m amneziawg -v "$awg_ver" >> "$LOG" 2>&1 || err "dkms build не удался"
  dkms install -m amneziawg -v "$awg_ver" >> "$LOG" 2>&1 || err "dkms install не удался"

  echo "amneziawg" > /etc/modules-load.d/amneziawg.conf
  modprobe amneziawg >> "$LOG" 2>&1 || err "modprobe amneziawg провалился"

  # awg-tools (userspace утилиты — отдельно)
  log "Сборка amneziawg-tools…"
  git clone --depth=1 https://github.com/amnezia-vpn/amneziawg-tools \
    "$build_dir/tools" >> "$LOG" 2>&1 || err "git clone tools не удался"
  make -C "$build_dir/tools/src" -j"$(nproc)" >> "$LOG" 2>&1 \
    || err "Сборка awg-tools провалилась"
  install -m 0755 "$build_dir/tools/src/awg"       /usr/bin/
  install -m 0755 "$build_dir/tools/src/awg-quick" /usr/bin/

  log "AmneziaWG установлен через DKMS (модуль пересоберётся при apt upgrade ядра)"
}

# ═══════════════════════════════════════════════════════════════════════════
# 5. AWG КОНФИГ И СЕРВИС
# ═══════════════════════════════════════════════════════════════════════════
setup_awg() {
  step "AWG конфиг и сервис"
  mkdir -p /etc/amnezia/amneziawg

  # awg-quick@.service приходит с пакетом amneziawg-tools — не копируем
  # из репо, иначе при апгрейде пакета будет расхождение версий.
  if [[ ! -f /lib/systemd/system/awg-quick@.service \
     && ! -f /usr/lib/systemd/system/awg-quick@.service ]]; then
    err "awg-quick@.service не найден — установите пакет amneziawg-tools"
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
  # Flowtable применяется отдельно — требует UP awg0.
  local postup="iptables -t mangle -A FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN \
-j TCPMSS --clamp-mss-to-pmtu; \
sysctl -w net.ipv4.ip_forward=1; \
ip route replace ${VPN_SERVER_IP}/32 via ${GW_IP} dev ${IFACE}; \
ip route replace default dev awg0 table 100; \
ip rule add fwmark 0x1 table 100 priority 100 2>/dev/null || true; \
nft -f /etc/nftables.d/90_flowtable.nft 2>/dev/null || true"

  local postdown="iptables -t mangle -D FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN \
-j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true; \
ip route del ${VPN_SERVER_IP}/32 via ${GW_IP} dev ${IFACE} 2>/dev/null || true; \
ip route del default dev awg0 table 100 2>/dev/null || true; \
ip rule del fwmark 0x1 table 100 priority 100 2>/dev/null || true; \
nft delete table inet flowtable_offload 2>/dev/null || true"

  # Срезаем все хуки wg-quick (PreUp/PostUp/PreDown/PostDown) и Table/DNS/MTU —
  # хуки eval'ятся как shell от root, остальное мы перекрываем явно ниже.
  # Вставляем Table/MTU/PostUp/PostDown внутрь [Interface], перед [Peer].
  echo "$AWG_RAW_CONF" \
    | grep -v -iE "^[[:space:]]*(PreUp|PostUp|PreDown|PostDown|Table|DNS|MTU)[[:space:]]*=" \
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

  # Шаблонизация и /etc/nftables.conf — централизованно через render-nftables.
  # Запускаем по пути из репо (а не из /usr/local/bin/) на случай первой
  # установки до setup_scripts.
  python3 "$INSTALL_DIR/scripts/render-nftables" --src "$INSTALL_DIR/nftables" \
    >> "$LOG" 2>&1 || err "render-nftables провалился"

  systemctl enable nftables >> "$LOG" 2>&1
  systemctl restart nftables >> "$LOG" 2>&1 || warn "nftables не применились — проверьте конфиги"
  log "nftables настроены"
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

  # Остальные скрипты — копируем как есть. Helper-скрипты, которым sudoers
  # даёт NOPASSWD, должны принадлежать root и быть невриатеабельны для user
  # (иначе токен Web UI = root через подмену скрипта).
  for s in update-lists update-routes.sh \
           apply-awg-conf apply-dns-records apply-dns-hosts \
           render-nftables antigateway-reset; do
    install -m 0755 -o root -g root "$INSTALL_DIR/scripts/$s" /usr/local/bin/
  done
  chmod 0755 /usr/local/bin/check-tunnel.sh
  chown root:root /usr/local/bin/check-tunnel.sh

  # Удаляем legacy cron-задачу update-antizapret и её артефакты —
  # эту роль теперь играет update-lists.
  rm -f /etc/cron.d/antigateway-update-antizapret
  rm -f /usr/local/bin/update-antizapret.sh
  rm -f /etc/dnsmasq.d/antizapret.conf

  # Cron через /etc/cron.d/ — не трогает пользовательский crontab
  cat > /etc/cron.d/antigateway-watchdog << 'EOF'
* * * * * root /usr/local/bin/check-tunnel.sh
EOF
  cat > /etc/cron.d/antigateway-update-routes << 'EOF'
0 4 * * * root /usr/local/bin/update-routes.sh >> /var/log/antigateway-update-routes.log 2>&1
EOF
  # update-lists обновляет все включённые в lists-config.json списки доменов.
  # Запускаем каждые 6 часов синхронно с runetfreedom upstream (он апдейтится
  # каждые 6ч). +5 минут смещение чтобы не попадать в кратные часы (нагрузка GH).
  cat > /etc/cron.d/antigateway-update-lists << 'EOF'
5 */6 * * * root /usr/local/bin/update-lists >> /var/log/antigateway-update-lists.log 2>&1
EOF

  # logrotate — иначе watchdog/update-* пишут логи бесконечно
  install -m 0644 -o root -g root \
    "$INSTALL_DIR/config/logrotate.conf" /etc/logrotate.d/antigateway

  log "Скрипты установлены, cron + logrotate настроены"
}

# ═══════════════════════════════════════════════════════════════════════════
# 10. WEB UI
# ═══════════════════════════════════════════════════════════════════════════
setup_webui() {
  step "Web UI"

  mkdir -p /etc/antigateway /var/cache/antigateway/lists

  # Токен авторизации (генерируем один раз, не перезаписываем).
  # Пишем атомарно через python -c — иначе SIGINT в момент записи оставит
  # пустой файл и auth уйдёт в fail-closed.
  if [[ ! -f /etc/antigateway/auth.conf ]]; then
    python3 - << 'PY'
import json, os, secrets, tempfile
dst = "/etc/antigateway/auth.conf"
fd, tmp = tempfile.mkstemp(prefix=".auth.", dir=os.path.dirname(dst))
with os.fdopen(fd, "w") as f:
    json.dump({"token": secrets.token_hex(32)}, f)
os.chmod(tmp, 0o640)
os.replace(tmp, dst)
PY
    chown "root:$USER" /etc/antigateway/auth.conf
    log "Токен создан: /etc/antigateway/auth.conf"
  else
    log "auth.conf уже существует — токен не перезаписан"
  fi

  # lists-config.json (только если нет — не затираем пользовательские настройки)
  [[ ! -f /etc/antigateway/lists-config.json ]] \
    && cp "$INSTALL_DIR/config/lists-config.json" /etc/antigateway/lists-config.json

  # network.conf — атомарно (используется и WebUI, и render-nftables)
  python3 - << PY
import json, os, tempfile
dst = "/etc/antigateway/network.conf"
fd, tmp = tempfile.mkstemp(prefix=".network.", dir=os.path.dirname(dst))
with os.fdopen(fd, "w") as f:
    json.dump({"iface": "$IFACE", "gw_ip": "$GW_IP", "pi_ip": "$PI_IP"}, f)
os.chmod(tmp, 0o644)
os.replace(tmp, dst)
PY

  # Права. lists-config.json пишется самим Web UI (как user) — оставляем за user.
  # auth.conf создан выше с root:user 0640. Helper-скрипты пишут dns-records.json
  # и custom-hosts от root через apply-dns-* (mode 0644).
  chown -R "$USER:$USER" "$APP_DIR" /var/cache/antigateway
  chown "$USER:$USER" /etc/antigateway/lists-config.json /etc/antigateway/network.conf

  # Systemd сервис
  sed "s|__APP_DIR__|${APP_DIR}|g; s|__USER__|${USER}|g; s|__PORT__|${WEBUI_PORT}|g" \
    "$INSTALL_DIR/systemd/antigateway-ui.service" > /lib/systemd/system/antigateway-ui.service

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
  setup_dnsmasq
  install_zapret2
  setup_scripts
  setup_webui         # создаёт /etc/antigateway/network.conf (нужен render-nftables)
  setup_nftables      # после webui — рендерит из network.conf
  setup_sudoers
  setup_awg           # после nftables — конфиг AWG может прийти позже через UI
  print_summary
}

main "$@"

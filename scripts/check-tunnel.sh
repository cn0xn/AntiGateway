#!/bin/bash
# AntiGateway watchdog — раз в минуту через cron (см. /etc/cron.d/antigateway-watchdog).
#
# Проверяет:
#   1. policy-routing правила (fwmark 0x1, table 100, маршрут до VPN endpoint)
#   2. awg0 link UP
#   3. Свежесть handshake (>180с = туннель сдох, рестартим awg-quick)
#   4. Реальный ping через awg0 (ловит blackhole, когда link UP но трафика нет)
#
# Переменные __VPN_SERVER_IP__ / __GW_IP__ / __IFACE__ подставляются install.sh.
LOGFILE=/var/log/antigateway-tunnel-check.log
VPN_SERVER_IP="__VPN_SERVER_IP__"
GW_IP="__GW_IP__"
IFACE="__IFACE__"

# Сколько секунд handshake считается свежим. Default WG keepalive — 25с,
# при отсутствии трафика handshake обновляется ~раз в 2 минуты. 180с — порог,
# после которого считаем туннель сдохшим.
HANDSHAKE_MAX_AGE=180

log_msg() { echo "[$(date '+%F %T')] $*" >> "$LOGFILE"; }

restart_awg() {
    log_msg "$1 — restarting awg-quick@awg0"
    systemctl restart awg-quick@awg0 2>>"$LOGFILE" || true
    # dnsmasq держит upstream-сокет привязанным к awg0 (server=1.1.1.1@awg0).
    # После пересоздания awg0 привязка мертва → DNS REFUSED. Рестартим dnsmasq.
    # (systemd PartOf обычно делает это сам, но если awg0 пересоздан без
    #  рестарта unit — это страховка.)
    systemctl restart dnsmasq 2>>"$LOGFILE" || true
}

# 1. fwmark rule
if ! ip rule list | grep -qE 'fwmark 0x1[[:space:]]+'; then
    log_msg "fwmark rule missing, restoring..."
    ip rule add fwmark 0x1 table 100 priority 100 2>/dev/null || true
fi

# 2. Маршрут default через awg0 в table 100
if ! ip route show table 100 | grep -q "awg0"; then
    log_msg "table 100 route missing, restoring..."
    ip route replace default dev awg0 table 100 2>/dev/null || true
fi

# 3. Маршрут к VPN серверу через LAN
if [[ -n "$VPN_SERVER_IP" && "$VPN_SERVER_IP" != "0.0.0.0" ]]; then
    if ! ip route show | grep -q "$VPN_SERVER_IP"; then
        log_msg "VPN endpoint route missing, restoring..."
        ip route replace "${VPN_SERVER_IP}/32" via "$GW_IP" dev "$IFACE" 2>/dev/null || true
    fi
fi

# 4. awg0 link state
if ! ip link show awg0 2>/dev/null | grep -q "UP"; then
    restart_awg "awg0 link DOWN"
    exit 0   # сразу выходим — handshake/ping всё равно бессмыслены
fi

# 5. Свежесть handshake (raw last-handshakes — секунды с epoch)
if command -v awg &>/dev/null; then
    hs_epoch=$(awg show awg0 latest-handshakes 2>/dev/null | awk '{print $2; exit}')
    if [[ -n "$hs_epoch" && "$hs_epoch" =~ ^[0-9]+$ ]]; then
        now=$(date +%s)
        age=$(( now - hs_epoch ))
        if (( hs_epoch == 0 )); then
            restart_awg "no handshake yet (initial)"
            exit 0
        fi
        if (( age > HANDSHAKE_MAX_AGE )); then
            restart_awg "handshake stale (${age}s > ${HANDSHAKE_MAX_AGE}s)"
            exit 0
        fi
    fi
fi

# 6. Реальный ping через awg0 — ловит blackhole (handshake свежий, но трафик не ходит)
if ! ping -c 1 -W 3 -I awg0 1.1.1.1 &>/dev/null; then
    # Один ping может теряться случайно — пробуем повторить через 2с
    sleep 2
    if ! ping -c 2 -W 3 -I awg0 1.1.1.1 &>/dev/null; then
        restart_awg "ping 1.1.1.1 via awg0 failed (blackhole?)"
    fi
fi

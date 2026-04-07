#!/bin/bash
# AntiGateway — watchdog: восстанавливает routing правила если пропали
# Переменные __VPN_SERVER_IP__, __GW_IP__, __IFACE__ подставляются инсталлером

LOGFILE=/var/log/antigateway-tunnel-check.log
VPN_SERVER_IP="__VPN_SERVER_IP__"
GW_IP="__GW_IP__"
IFACE="__IFACE__"

check_and_fix() {
    # fwmark правило
    if ! ip rule show | grep -q "fwmark 0x1"; then
        echo "[$(date)] fwmark rule missing, restoring..." >> $LOGFILE
        ip rule add fwmark 0x1 table 100 priority 100 2>/dev/null || true
    fi

    # Маршрут в table 100
    if ! ip route show table 100 | grep -q "awg0"; then
        echo "[$(date)] table 100 route missing, restoring..." >> $LOGFILE
        ip route replace default dev awg0 table 100 2>/dev/null || true
    fi

    # Маршрут к VPN серверу через LAN
    if [[ -n "$VPN_SERVER_IP" && "$VPN_SERVER_IP" != "0.0.0.0" ]]; then
        if ! ip route show | grep -q "$VPN_SERVER_IP"; then
            echo "[$(date)] VPN endpoint route missing, restoring..." >> $LOGFILE
            ip route replace "${VPN_SERVER_IP}/32" via "$GW_IP" dev "$IFACE" 2>/dev/null || true
        fi
    fi

    # awg0 интерфейс
    if ! ip link show awg0 2>/dev/null | grep -q "UP"; then
        echo "[$(date)] awg0 is down, bringing up..." >> $LOGFILE
        systemctl start awg-quick@awg0 2>/dev/null || true
    fi
}

check_and_fix

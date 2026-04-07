#!/bin/bash
# Обновляет список заблокированных доменов AntiZapret для dnsmasq
# v2: проверка целостности перед заменой

URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst"
DEST="/etc/dnsmasq.d/antizapret.conf"
TMP="/tmp/antizapret-new.lst"

echo "[$(date)] Обновление списка доменов AntiZapret..."
curl -s --max-time 60 "$URL" -o "$TMP" || { echo "[$(date)] Ошибка загрузки"; exit 1; }

COUNT=$(grep -c "nftset" "$TMP" 2>/dev/null || true)
if [ "$COUNT" -eq 0 ]; then
    echo "[$(date)] Файл пустой или не содержит nftset директив, пропускаем"
    rm -f "$TMP"
    exit 1
fi

sed 's|4#inet#fw4#vpn_domains|4#ip#tunnel_routing#blocked_ips|g' "$TMP" > "$DEST"

echo "[$(date)] Обновлено: $COUNT доменов"
rm -f "$TMP"

systemctl reload dnsmasq 2>/dev/null || systemctl restart dnsmasq
echo "[$(date)] dnsmasq перезагружен"

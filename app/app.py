#!/usr/bin/env python3
"""
Pi Gateway Web UI — backend API
v2:
- build_awg_conf: убраны iptables MASQUERADE (теперь в nftables/10_nat.nft)
- run_cmd(): shell=False для команд без shell-фич
- validate_iface/validate_ip: защита от injection в AWG конфиге
- /api/diagnostics: проверки nftables, DNS-интерцепции, kill-switch
- /api/status: TikTok/Telegram/Meta в routing, статус nftables таблиц
"""
import subprocess
import json
import re
import os
import threading
import hmac
from datetime import datetime
from functools import wraps
from flask import Flask, jsonify, request, render_template

app = Flask(__name__)

CONFIG_FILE      = "/etc/gateway-ui/lists-config.json"
NETWORK_CONF     = "/etc/gateway-ui/network.conf"
AWG_CONF_PATH    = "/etc/amnezia/amneziawg/awg0.conf"
UPDATE_LISTS_BIN = "/usr/local/bin/update-lists"
NFTABLES_CONF    = "/etc/nftables.conf"
AUTH_CONF        = "/etc/gateway-ui/auth.conf"

# ── helpers ──────────────────────────────────────────────────────────────────

def run(cmd, timeout=10):
    """shell=True — только для команд с pipe/redirect/glob."""
    try:
        r = subprocess.run(cmd, shell=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=timeout)
        return (r.stdout.decode(errors="replace").strip(),
                r.stderr.decode(errors="replace").strip(),
                r.returncode)
    except subprocess.TimeoutExpired:
        return "", "timeout", 1

def run_cmd(args, timeout=10):
    """shell=False — для команд с фиксированными аргументами."""
    try:
        r = subprocess.run(args,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=timeout)
        return (r.stdout.decode(errors="replace").strip(),
                r.stderr.decode(errors="replace").strip(),
                r.returncode)
    except subprocess.TimeoutExpired:
        return "", "timeout", 1

def systemctl_active(unit):
    _, _, rc = run_cmd(["systemctl", "is-active", "--quiet", unit])
    return rc == 0

def nft_set_count(set_name):
    try:
        r = subprocess.run(
            ["sudo", "-n", "/usr/sbin/nft", "list", "set",
             "ip", "tunnel_routing", set_name],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20
        )
        out = r.stdout.decode(errors="replace")
        n = out.count(",")
        return n + 1 if n > 0 else 0
    except Exception:
        return 0

_nft_tables_cache = {"ts": 0, "tables": set()}

def nft_get_tables():
    """Получить список загруженных nftables таблиц (кэш 5 сек)."""
    now = __import__("time").time()
    if now - _nft_tables_cache["ts"] < 5:
        return _nft_tables_cache["tables"]
    out, _, rc = run_cmd(["sudo", "-n", "/usr/sbin/nft", "list", "tables"])
    tables = set()
    if rc == 0:
        for line in out.splitlines():
            # Формат: "table ip name" или "table ip6 name"
            parts = line.strip().split()
            if len(parts) == 3 and parts[0] == "table":
                tables.add(f"{parts[1]}:{parts[2]}")
    _nft_tables_cache["ts"] = now
    _nft_tables_cache["tables"] = tables
    return tables

def nft_table_exists(family, table):
    """Проверить что nftables таблица загружена."""
    return f"{family}:{table}" in nft_get_tables()

def load_cfg():
    try:
        with open(CONFIG_FILE) as f:
            return json.load(f)
    except Exception:
        return {"lists": {}, "last_sync": None}

def save_cfg(cfg):
    with open(CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)

# ── Auth ─────────────────────────────────────────────────────────────────────

def load_auth_token():
    try:
        with open(AUTH_CONF) as f:
            return json.load(f).get("token", "")
    except Exception:
        return ""

def require_auth(f):
    """Декоратор: проверяет X-Auth-Token для write-операций."""
    @wraps(f)
    def decorated(*args, **kwargs):
        expected = load_auth_token()
        if not expected:
            # Auth не настроен — пропускаем (backward compat)
            return f(*args, **kwargs)
        provided = request.headers.get("X-Auth-Token", "")
        # hmac.compare_digest — защита от timing attack
        if not provided or not hmac.compare_digest(provided, expected):
            return jsonify({"ok": False, "error": "Unauthorized"}), 401
        return f(*args, **kwargs)
    return decorated

def validate_iface(iface):
    """Только безопасные имена интерфейсов."""
    return bool(re.match(r'^[a-zA-Z0-9_.-]{1,15}$', iface))

def validate_ip(ip):
    """Простая проверка IPv4."""
    return bool(re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', ip))

# ── API: status ───────────────────────────────────────────────────────────────

@app.route("/api/status")
def api_status():
    zapret_active = systemctl_active("zapret2-nfqws2")
    zapret_pid = ""
    if zapret_active:
        out, _, _ = run_cmd(["pgrep", "-x", "nfqws2"])
        zapret_pid = out.split("\n")[0]

    awg_out, _, _ = run("ip link show awg0 2>/dev/null")
    awg_up = "UP" in awg_out
    awg_handshake = ""
    if awg_up:
        hs_out, _, _ = run("sudo -n /usr/bin/awg show awg0 2>/dev/null")
        m = re.search(r"latest handshake: (.+)", hs_out)
        awg_handshake = m.group(1) if m else ""

    dnsmasq_active = systemctl_active("dnsmasq")

    awg_rx = awg_tx = ""
    if awg_up:
        out, _, _ = run("sudo -n /usr/bin/awg show awg0 transfer 2>/dev/null")
        m = re.search(r"(\d+)\s+(\d+)", out)
        if m:
            def fmt_bytes(b):
                b = int(b)
                for u in ["B", "KB", "MB", "GB"]:
                    if b < 1024:
                        return f"{b:.1f} {u}"
                    b /= 1024
                return f"{b:.1f} TB"
            awg_rx = fmt_bytes(m.group(1))
            awg_tx = fmt_bytes(m.group(2))

    cfg = load_cfg()
    def list_mode(list_id):
        return cfg["lists"].get(list_id, {}).get("mode", "disabled")

    nft_tables = {
        "tunnel_routing": nft_table_exists("ip", "tunnel_routing"),
        "gateway_nat":    nft_table_exists("ip", "gateway_nat"),
        "dns_intercept":  nft_table_exists("ip", "dns_intercept"),
        "killswitch":     nft_table_exists("ip", "killswitch"),
    }

    return jsonify({
        "services": {
            "zapret2": {"active": zapret_active, "pid": zapret_pid},
            "awg":     {"active": awg_up, "handshake": awg_handshake,
                        "rx": awg_rx, "tx": awg_tx},
            "dnsmasq": {"active": dnsmasq_active},
        },
        "routing": {
            "youtube":  list_mode("svc_youtube"),
            "discord":  list_mode("svc_discord"),
            "tiktok":   list_mode("svc_tiktok"),
            "telegram": list_mode("svc_telegram"),
            "meta":     list_mode("svc_meta"),
            "claude":   list_mode("svc_claude"),
        },
        "nftables": nft_tables,
        "stats": {
            "blocked_ips": nft_set_count("blocked_ips"),
            "zapret_ips":  nft_set_count("zapret_ips"),
        },
        "ts": datetime.now().strftime("%H:%M:%S"),
    })


# ── API: service control ──────────────────────────────────────────────────────

@app.route("/api/service", methods=["POST"])
@require_auth
def api_service():
    data   = request.json or {}
    name   = data.get("name", "")
    action = data.get("action", "")

    unit_map = {
        "zapret":  "zapret2-nfqws2",
        "awg":     "awg-quick@awg0",
        "dnsmasq": "dnsmasq",
    }
    if name not in unit_map:
        return jsonify({"ok": False, "error": f"unknown service: {name}"}), 400
    if action not in ("start", "stop", "restart"):
        return jsonify({"ok": False, "error": f"unknown action: {action}"}), 400

    unit = unit_map[name]
    out, err, rc = run_cmd(
        ["sudo", "-n", "/usr/bin/systemctl", action, unit],
        timeout=15
    )
    return jsonify({"ok": rc == 0, "output": out or err})


# ── API: lists ────────────────────────────────────────────────────────────────

@app.route("/api/lists")
def api_lists():
    cfg = load_cfg()
    return jsonify(cfg)

@app.route("/api/lists/save", methods=["POST"])
@require_auth
def api_lists_save():
    data    = request.json or {}
    updates = data.get("updates", {})

    cfg = load_cfg()
    for list_id, changes in updates.items():
        if list_id not in cfg["lists"]:
            continue
        if "mode" in changes:
            cfg["lists"][list_id]["mode"] = changes["mode"]
        if "enabled" in changes:
            cfg["lists"][list_id]["enabled"] = bool(changes["enabled"])

    save_cfg(cfg)
    return jsonify({"ok": True})


_sync_state = {"running": False, "log": [], "done": False, "error": None}
_sync_lock  = threading.Lock()

@app.route("/api/lists/sync", methods=["POST"])
@require_auth
def api_lists_sync():
    force = (request.json or {}).get("force", False)

    with _sync_lock:
        if _sync_state["running"]:
            return jsonify({"ok": False, "error": "уже выполняется"})
        _sync_state.update({"running": True, "log": [], "done": False, "error": None})

    def run_sync():
        cmd = ["sudo", "-n", "/usr/local/bin/update-lists"]
        if force:
            cmd.append("--force")
        try:
            proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1
            )
            for line in proc.stdout:
                with _sync_lock:
                    _sync_state["log"].append(line.rstrip())
            proc.wait()
            with _sync_lock:
                _sync_state["running"] = False
                _sync_state["done"]    = True
                if proc.returncode != 0:
                    _sync_state["error"] = f"exit {proc.returncode}"
        except Exception as e:
            with _sync_lock:
                _sync_state["running"] = False
                _sync_state["error"]   = str(e)

    threading.Thread(target=run_sync, daemon=True).start()
    return jsonify({"ok": True})


@app.route("/api/lists/sync/status")
def api_lists_sync_status():
    with _sync_lock:
        return jsonify(dict(_sync_state))


# ── API: logs ─────────────────────────────────────────────────────────────────

@app.route("/api/logs")
def api_logs():
    service = request.args.get("service", "zapret2")

    if service == "system":
        out, _, _ = run(
            "sudo -n /usr/bin/journalctl -b -n 80 --no-pager"
            " --output=short-iso -p warning 2>/dev/null",
            timeout=10
        )
        return jsonify({"lines": out.splitlines()})

    unit_map = {
        "zapret2": "zapret2-nfqws2",
        "awg":     "awg-quick@awg0",
        "dnsmasq": "dnsmasq",
    }
    unit = unit_map.get(service, "zapret2-nfqws2")
    out, _, _ = run_cmd(
        ["sudo", "-n", "/usr/bin/journalctl", "-u", unit,
         "-n", "60", "--no-pager", "--output=short-iso"],
        timeout=10
    )
    return jsonify({"lines": out.splitlines()})


# ── API: diagnostics ──────────────────────────────────────────────────────────

@app.route("/api/diagnostics")
def api_diagnostics():
    checks = []

    # 1. AWG tunnel connectivity
    awg_out, _, _ = run("ip link show awg0 2>/dev/null")
    awg_up = "UP" in awg_out
    if awg_up:
        ping_out, _, ping_rc = run("ping -c 2 -W 2 -I awg0 1.1.1.1 2>&1", timeout=10)
        m = re.search(r"(\d+)% packet loss", ping_out)
        loss = int(m.group(1)) if m else 100
        stat_line = ping_out.split("\n")[-1] if ping_out else ""
        checks.append({
            "name": "Туннель AWG",
            "ok": ping_rc == 0 and loss < 100,
            "detail": stat_line if ping_rc == 0 else "нет ответа от 1.1.1.1",
        })
    else:
        checks.append({"name": "Туннель AWG", "ok": False,
                        "detail": "интерфейс awg0 DOWN"})

    # 2. DNS via dnsmasq
    dns_out, _, dns_rc = run_cmd(
        ["dig", "+short", "+time=3", "+tries=1", "youtube.com", "@127.0.0.1"],
        timeout=8
    )
    dns_ok = dns_rc == 0 and bool(dns_out.strip())
    checks.append({
        "name": "DNS (dnsmasq)",
        "ok": dns_ok,
        "detail": f"youtube.com → {dns_out.strip()[:80]}" if dns_ok
                  else "нет ответа от 127.0.0.1",
    })

    # 3. nft blocked_ips
    blocked = nft_set_count("blocked_ips")
    zapret  = nft_set_count("zapret_ips")
    checks.append({
        "name": "nft tunnel_routing",
        "ok": nft_table_exists("ip", "tunnel_routing") and blocked > 0,
        "detail": f"blocked_ips: {blocked:,} IP,  zapret_ips: {zapret:,} IP",
    })

    # 4. NAT (nftables)
    nat_ok = nft_table_exists("ip", "gateway_nat")
    checks.append({
        "name": "nft MASQUERADE (NAT)",
        "ok": nat_ok,
        "detail": "nftables gateway_nat активен" if nat_ok
                  else "MASQUERADE не настроен — интернет у клиентов не работает",
    })

    # 5. DNS-интерцепция
    di_ok = nft_table_exists("ip", "dns_intercept")
    checks.append({
        "name": "nft DNS-интерцепция",
        "ok": di_ok,
        "detail": "port 53 → dnsmasq, DoH заблокирован" if di_ok
                  else "клиенты могут обойти dnsmasq (TikTok, etc.)",
    })

    # 6. Kill-switch
    ks_ok = nft_table_exists("ip", "killswitch")
    checks.append({
        "name": "nft Kill-switch",
        "ok": ks_ok,
        "detail": "утечка при падении VPN заблокирована" if ks_ok
                  else "при падении VPN трафик идёт через ISP",
    })

    # 7. fwmark routing rule
    rules_out, _, _ = run("ip rule list 2>/dev/null")
    has_fwmark = "fwmark 0x1" in rules_out
    checks.append({
        "name": "ip rule fwmark",
        "ok": has_fwmark,
        "detail": "fwmark 0x1 → table 100" if has_fwmark
                  else "правило маршрутизации отсутствует",
    })

    # 8. Default route table 100
    rt_out, _, _ = run("ip route show table 100 2>/dev/null")
    has_default = "default" in rt_out
    checks.append({
        "name": "Маршрут table 100",
        "ok": has_default,
        "detail": rt_out.strip()[:80] if has_default else "нет default в table 100",
    })

    return jsonify({"checks": checks, "ts": datetime.now().strftime("%H:%M:%S")})


# ── API: nftables ─────────────────────────────────────────────────────────────

@app.route("/api/nftables")
def api_nftables():
    out, _, _ = run("sudo -n /usr/sbin/nft list table ip tunnel_routing 2>/dev/null")
    return jsonify({"raw": out})


# ── API: AWG config ───────────────────────────────────────────────────────────

def load_network_conf():
    try:
        with open(NETWORK_CONF) as f:
            return json.load(f)
    except Exception:
        return {}

def save_network_conf(data):
    nc = load_network_conf()
    nc.update(data)
    with open(NETWORK_CONF, "w") as f:
        json.dump(nc, f, indent=2)

def build_awg_conf(raw_conf, iface, gw_ip):
    """
    Собирает AWG конфиг с PostUp/PostDown.
    v2: MASQUERADE убран из PostUp — теперь декларативно в /etc/nftables.d/10_nat.nft.
    PostUp: MSS clamping, ip_forward, static VPN server route, fwmark rule, nftables reload.
    """
    m = re.search(r"Endpoint\s*=\s*(\S+)", raw_conf, re.IGNORECASE)
    endpoint = m.group(1) if m else ""
    vpn_ip   = endpoint.split(":")[0] if endpoint else ""

    parts_up = [
        # MSS clamping — предотвращает фрагментацию через туннель
        "iptables -t mangle -A FORWARD -o awg0 -p tcp "
        "--tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu",
        "sysctl -w net.ipv4.ip_forward=1",
    ]
    if vpn_ip:
        parts_up.append(f"ip route add {vpn_ip}/32 via {gw_ip} dev {iface}")
    parts_up += [
        "ip route add default dev awg0 table 100",
        "ip rule add fwmark 0x1 table 100 priority 100",
        # Загружаем/обновляем nftables (NAT, DNS-intercept, kill-switch)
        f"nft -f {NFTABLES_CONF}",
    ]

    parts_down = [
        "iptables -t mangle -D FORWARD -o awg0 -p tcp "
        "--tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null",
    ]
    if vpn_ip:
        parts_down.append(
            f"ip route del {vpn_ip}/32 via {gw_ip} dev {iface} 2>/dev/null"
        )
    parts_down += [
        "ip route del default dev awg0 table 100 2>/dev/null",
        "ip rule del fwmark 0x1 table 100 priority 100 2>/dev/null",
    ]

    postup   = "; ".join(parts_up)
    postdown = "; ".join(parts_down)

    lines = [l for l in raw_conf.splitlines()
             if not re.match(r"^\s*(PostUp|PostDown|Table|DNS)\s*=", l, re.IGNORECASE)]

    result = []
    for line in lines:
        result.append(line)
        if line.strip() == "[Interface]":
            result.append("Table = off")
    result.append(f"PostUp = {postup}")
    result.append(f"PostDown = {postdown}")

    return "\n".join(result) + "\n"

@app.route("/api/awg/config", methods=["GET"])
def api_awg_config_get():
    nc = load_network_conf()
    out, err, rc = run_cmd(["sudo", "-n", "/bin/cat", AWG_CONF_PATH])
    if rc != 0 or not out:
        return jsonify({"ok": True, "config": "", "network": nc, "has_config": False})
    masked = re.sub(r"(PrivateKey\s*=\s*)\S+", r"\1<hidden>", out)
    masked = re.sub(r"(PresharedKey\s*=\s*)\S+", r"\1<hidden>", masked)
    return jsonify({"ok": True, "config": masked, "network": nc, "has_config": True})

@app.route("/api/awg/config", methods=["POST"])
@require_auth
def api_awg_config_post():
    data     = request.json or {}
    raw_conf = data.get("config", "").strip()
    iface    = data.get("iface", "").strip()
    gw_ip    = data.get("gw_ip", "").strip()

    if not raw_conf:
        return jsonify({"ok": False, "error": "config is empty"}), 400

    if not iface or not gw_ip:
        nc    = load_network_conf()
        iface = iface or nc.get("iface", "")
        gw_ip = gw_ip or nc.get("gw_ip", "")

    if not iface or not gw_ip:
        return jsonify({"ok": False, "error": "iface и gw_ip обязательны"}), 400

    # Валидация — защита от shell/command injection
    if not validate_iface(iface):
        return jsonify({"ok": False, "error": "Недопустимое имя интерфейса"}), 400
    if not validate_ip(gw_ip):
        return jsonify({"ok": False, "error": "Недопустимый IP шлюза"}), 400

    if "[Interface]" not in raw_conf or "[Peer]" not in raw_conf:
        return jsonify({"ok": False,
                        "error": "Неверный конфиг: нет [Interface] или [Peer]"}), 400

    conf = build_awg_conf(raw_conf, iface, gw_ip)

    try:
        proc = subprocess.run(
            ["sudo", "-n", "/usr/local/bin/apply-awg-conf"],
            input=conf, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10
        )
        if proc.returncode != 0:
            return jsonify({"ok": False, "error": proc.stderr or "write failed"})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)})

    save_network_conf({"iface": iface, "gw_ip": gw_ip})

    out, err, rc = run_cmd(
        ["sudo", "-n", "/usr/bin/systemctl", "restart", "awg-quick@awg0"],
        timeout=15
    )
    return jsonify({"ok": rc == 0, "output": out or err or "AWG перезапущен"})


# ── Main ──────────────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return render_template("index.html")

if __name__ == "__main__":
    app.run(
        host="0.0.0.0",
        port=int(os.environ.get("WEBUI_PORT", "8080")),
        debug=False
    )

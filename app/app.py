#!/usr/bin/env python3
"""
AntiGateway Web UI — backend API.

Принципы:
- run_cmd(args)   — единственный способ запускать команды (shell=False)
- require_auth    — на всех write-эндпоинтах + чувствительных read'ах
                    (logs, full nft dump). Fail-closed: если auth.conf
                    отсутствует/повреждён → 503.
- write-операции от root идут через узкие helper-скрипты в /usr/local/bin/
  (sudoers даёт NOPASSWD только им, не на сырой `tee`).
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import hmac
from datetime import datetime
from functools import wraps
from flask import Flask, jsonify, request, render_template

app = Flask(__name__)

# ── Пути ─────────────────────────────────────────────────────────────────────
ETC_DIR          = "/etc/antigateway"
CONFIG_FILE      = f"{ETC_DIR}/lists-config.json"
NETWORK_CONF     = f"{ETC_DIR}/network.conf"
AUTH_CONF        = f"{ETC_DIR}/auth.conf"
DNS_RECORDS_FILE = f"{ETC_DIR}/dns-records.json"
TUNNEL_DEV_FILE  = f"{ETC_DIR}/tunnel-devices.json"
AWG_CONF_PATH    = "/etc/amnezia/amneziawg/awg0.conf"
NFTABLES_CONF    = "/etc/nftables.conf"

# Helper-скрипты (см. sudoers.template)
APPLY_AWG_BIN     = "/usr/local/bin/apply-awg-conf"
APPLY_TUNNEL_DEV_BIN = "/usr/local/bin/apply-tunnel-devices"
APPLY_DNS_REC_BIN = "/usr/local/bin/apply-dns-records"
APPLY_DNS_HST_BIN = "/usr/local/bin/apply-dns-hosts"
RESET_BIN         = "/usr/local/bin/antigateway-reset"
UPDATE_LISTS_BIN  = "/usr/local/bin/update-lists"

# ── Базовый хелпер запуска команд ────────────────────────────────────────────

def run_cmd(args, timeout=10, input_str=None):
    """Единственный способ запускать команды — shell=False всегда."""
    try:
        r = subprocess.run(
            args,
            input=input_str,
            text=input_str is not None,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=timeout,
        )
        out = r.stdout if isinstance(r.stdout, str) else r.stdout.decode(errors="replace")
        err = r.stderr if isinstance(r.stderr, str) else r.stderr.decode(errors="replace")
        return out.strip(), err.strip(), r.returncode
    except subprocess.TimeoutExpired:
        return "", "timeout", 1

def systemctl_active(unit):
    _, _, rc = run_cmd(["systemctl", "is-active", "--quiet", unit])
    return rc == 0

# ── nftables инспекция (через `nft -j`) ─────────────────────────────────────

def nft_json(args, timeout=15):
    """Вызывает `nft -j ...` и парсит JSON. Возвращает None при ошибке."""
    out, _, rc = run_cmd(["sudo", "-n", "/usr/sbin/nft", "-j"] + args, timeout=timeout)
    if rc != 0 or not out:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None

def nft_set_count(set_name):
    """Точное число элементов в сете через JSON output (был count(',') — фрагильно)."""
    data = nft_json(["list", "set", "ip", "tunnel_routing", set_name])
    if not data:
        return 0
    for item in data.get("nftables", []):
        if "set" in item:
            return len(item["set"].get("elem", []) or [])
    return 0

_nft_tables_cache = {"ts": 0.0, "tables": set()}

def nft_get_tables():
    """Список загруженных nftables таблиц (кэш 5с)."""
    now = time.time()
    if now - _nft_tables_cache["ts"] < 5:
        return _nft_tables_cache["tables"]
    data = nft_json(["list", "tables"])
    tables = set()
    if data:
        for item in data.get("nftables", []):
            t = item.get("table")
            if t:
                tables.add(f"{t.get('family')}:{t.get('name')}")
    _nft_tables_cache["ts"] = now
    _nft_tables_cache["tables"] = tables
    return tables

def nft_table_exists(family, table):
    return f"{family}:{table}" in nft_get_tables()

# ── Атомарная запись JSON-конфигов от лица user-а (lists-config) ────────────

def atomic_write_json(path, data):
    """tempfile + fsync + os.replace — не оставляет полпути даже при kill -9."""
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix="." + os.path.basename(path) + ".", dir=d)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.flush(); os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except Exception:
        try: os.unlink(tmp)
        except FileNotFoundError: pass
        raise

def load_cfg():
    try:
        with open(CONFIG_FILE) as f:
            return json.load(f)
    except Exception:
        return {"lists": {}, "last_sync": None}

def save_cfg(cfg):
    atomic_write_json(CONFIG_FILE, cfg)

def load_tunnel_devices():
    """Список устройств, чей весь трафик идёт через VPN (per-device routing)."""
    try:
        with open(TUNNEL_DEV_FILE) as f:
            data = json.load(f)
            return data if isinstance(data, list) else []
    except (FileNotFoundError, json.JSONDecodeError):
        return []

# ── Auth ─────────────────────────────────────────────────────────────────────

def load_auth_token():
    try:
        with open(AUTH_CONF) as f:
            return json.load(f).get("token", "")
    except Exception:
        return ""

def require_auth(f):
    """X-Auth-Token + hmac.compare_digest. Fail-closed: нет/пустой токен → 503."""
    @wraps(f)
    def decorated(*args, **kwargs):
        expected = load_auth_token()
        if not expected:
            # auth.conf отсутствует или содержит пустой токен — Web UI считаем
            # неинициализированным. Раньше тут был fail-open ("backward compat") —
            # это превращало любой битый auth.conf в открытое API.
            return jsonify({"ok": False, "error": "auth not configured"}), 503
        provided = request.headers.get("X-Auth-Token", "")
        if not provided or not hmac.compare_digest(provided, expected):
            return jsonify({"ok": False, "error": "Unauthorized"}), 401
        return f(*args, **kwargs)
    return decorated

def validate_iface(iface):
    return bool(re.match(r'^[a-zA-Z0-9_.-]{1,15}$', iface))

def validate_ip(ip):
    return bool(re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', ip))

def validate_hostname(name):
    return bool(re.match(r'^[a-zA-Z0-9]([a-zA-Z0-9\-\.]{0,61}[a-zA-Z0-9])?$', name))

def sanitize_comment(s):
    """Срезаем control-символы (особенно \\n) — иначе ломают hosts-файл."""
    if not s:
        return ""
    return re.sub(r'[\x00-\x1f\x7f]', ' ', str(s)).strip()[:80]

# ── Security headers ────────────────────────────────────────────────────────

@app.after_request
def _security_headers(resp):
    resp.headers.setdefault("X-Content-Type-Options", "nosniff")
    resp.headers.setdefault("X-Frame-Options", "DENY")
    resp.headers.setdefault("Referrer-Policy", "no-referrer")
    # CSP: всё со self, inline-handlers разрешены (UI на onclick=)
    resp.headers.setdefault(
        "Content-Security-Policy",
        "default-src 'self'; script-src 'self' 'unsafe-inline'; "
        "style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
        "connect-src 'self'; base-uri 'self'; frame-ancestors 'none'"
    )
    return resp

# ── Кэш статуса ─────────────────────────────────────────────────────────────

_status_cache = {"ts": 0.0, "data": None, "lock": threading.Lock()}
# Клиент опрашивает каждые 15с (см. app.js). 5с кэш гарантирует свежие данные
# при повторных запросах от 2-3 клиентов в окне, но не нагружает Pi3.
STATUS_TTL = 5.0

def _build_status():
    """Тяжёлая часть /api/status — 5+ subprocess'ов. Кэшируем."""
    zapret_active = systemctl_active("zapret2-nfqws2")
    zapret_pid = ""
    if zapret_active:
        out, _, _ = run_cmd(["pgrep", "-x", "nfqws2"])
        zapret_pid = out.split("\n")[0] if out else ""

    awg_link, _, _ = run_cmd(["ip", "link", "show", "awg0"])
    awg_up = "UP" in awg_link
    awg_handshake = awg_rx = awg_tx = ""
    if awg_up:
        hs_out, _, _ = run_cmd(["sudo", "-n", "/usr/bin/awg", "show", "awg0"])
        m = re.search(r"latest handshake: (.+)", hs_out)
        awg_handshake = m.group(1) if m else ""

        tr_out, _, _ = run_cmd(["sudo", "-n", "/usr/bin/awg", "show", "awg0", "transfer"])
        m = re.search(r"(\d+)\s+(\d+)", tr_out)
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

    dnsmasq_active = systemctl_active("dnsmasq")

    cfg = load_cfg()
    def list_mode(list_id):
        return cfg["lists"].get(list_id, {}).get("mode", "disabled")

    nft_tables = {
        "tunnel_routing": nft_table_exists("ip", "tunnel_routing"),
        "gateway_nat":    nft_table_exists("ip", "gateway_nat"),
        "dns_intercept":  nft_table_exists("ip", "dns_intercept"),
        "killswitch":     nft_table_exists("ip", "killswitch"),
    }

    return {
        "services": {
            "zapret2": {"active": zapret_active, "pid": zapret_pid},
            "awg":     {"active": awg_up, "handshake": awg_handshake,
                        "rx": awg_rx, "tx": awg_tx},
            "dnsmasq": {"active": dnsmasq_active},
        },
        "routing": {
            "youtube":  list_mode("svc_youtube"),
            "discord":  list_mode("svc_discord"),
            "google":   list_mode("svc_google"),
            "claude":   list_mode("svc_claude"),
            "kinopub":  list_mode("svc_kinopub"),
        },
        "nftables": nft_tables,
        "stats": {
            "blocked_ips": nft_set_count("blocked_ips"),
            "zapret_ips":  nft_set_count("zapret_ips"),
        },
        "tunnel_devices": len(load_tunnel_devices()),
        "ts": datetime.now().strftime("%H:%M:%S"),
    }

@app.route("/api/status")
def api_status():
    now = time.time()
    with _status_cache["lock"]:
        if _status_cache["data"] and (now - _status_cache["ts"] < STATUS_TTL):
            return jsonify(_status_cache["data"])
    # Считаем без лока — параллельные запросы максимум продублируют работу,
    # но потом всё равно увидят свежий кэш.
    data = _build_status()
    with _status_cache["lock"]:
        _status_cache["data"] = data
        _status_cache["ts"] = time.time()
    return jsonify(data)

# ── Service control ─────────────────────────────────────────────────────────

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
        ["sudo", "-n", "/usr/bin/systemctl", action, unit], timeout=15
    )
    return jsonify({"ok": rc == 0, "output": out or err})

# ── Lists ────────────────────────────────────────────────────────────────────

@app.route("/api/lists")
def api_lists():
    return jsonify(load_cfg())

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

# ── Sync (общий шаблон стриминга stdout процесса) ──────────────────────────

class StreamingJob:
    """Запускает команду и копирует stdout в буфер. Один экземпляр на эндпоинт."""
    def __init__(self):
        self.lock    = threading.Lock()
        self.running = False
        self.log     = []
        self.done    = False
        self.error   = None
        self.success = False

    def start(self, argv):
        with self.lock:
            if self.running:
                return False
            self.running = True
            self.log     = []
            self.done    = False
            self.error   = None
            self.success = False
        threading.Thread(target=self._run, args=(argv,), daemon=True).start()
        return True

    def _run(self, argv):
        try:
            proc = subprocess.Popen(
                argv,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1,
            )
            for line in proc.stdout:
                with self.lock:
                    self.log.append(line.rstrip())
            proc.wait()
            with self.lock:
                self.success = (proc.returncode == 0)
                if proc.returncode != 0:
                    self.error = f"exit {proc.returncode}"
        except Exception as e:
            with self.lock:
                self.error = str(e)
        finally:
            with self.lock:
                self.running = False
                self.done    = True

    def snapshot(self):
        with self.lock:
            return {
                "running": self.running, "log": list(self.log),
                "done": self.done, "error": self.error, "success": self.success,
            }

_sync_job  = StreamingJob()
_reset_job = StreamingJob()

@app.route("/api/lists/sync", methods=["POST"])
@require_auth
def api_lists_sync():
    force = (request.json or {}).get("force", False)
    cmd = ["sudo", "-n", UPDATE_LISTS_BIN]
    if force:
        cmd.append("--force")
    if not _sync_job.start(cmd):
        return jsonify({"ok": False, "error": "уже выполняется"})
    return jsonify({"ok": True})

@app.route("/api/lists/sync/status")
def api_lists_sync_status():
    return jsonify(_sync_job.snapshot())

# ── Reset and reapply (через antigateway-reset, стрим stdout) ──────────────

@app.route("/api/reset-apply", methods=["POST"])
@require_auth
def api_reset_apply():
    if not _reset_job.start(["sudo", "-n", RESET_BIN]):
        return jsonify({"ok": False, "error": "уже выполняется"})
    return jsonify({"ok": True})

@app.route("/api/reset-apply/status")
def api_reset_apply_status():
    return jsonify(_reset_job.snapshot())

# ── DNS records ──────────────────────────────────────────────────────────────

def load_dns_records():
    try:
        with open(DNS_RECORDS_FILE) as f:
            data = json.load(f)
            return data if isinstance(data, list) else []
    except (FileNotFoundError, json.JSONDecodeError):
        return []

def write_dns_records_via_helper(records):
    """Пишет dns-records.json + custom-hosts через два sudo-helper'а."""
    payload = json.dumps(records, ensure_ascii=False)
    out1, err1, rc1 = run_cmd(["sudo", "-n", APPLY_DNS_REC_BIN], input_str=payload)
    if rc1 != 0:
        return False, err1 or out1 or "apply-dns-records failed"
    out2, err2, rc2 = run_cmd(["sudo", "-n", APPLY_DNS_HST_BIN], input_str=payload, timeout=15)
    if rc2 != 0:
        return False, err2 or out2 or "apply-dns-hosts failed"
    return True, None

@app.route("/api/dns")
@require_auth
def api_dns_list():
    return jsonify({"records": load_dns_records()})

@app.route("/api/dns", methods=["POST"])
@require_auth
def api_dns_add():
    data    = request.json or {}
    name    = data.get("name", "").strip().lower()
    ip      = data.get("ip", "").strip()
    comment = sanitize_comment(data.get("comment", ""))

    if not name or not ip:
        return jsonify({"ok": False, "error": "name и ip обязательны"}), 400
    if not validate_hostname(name):
        return jsonify({"ok": False, "error": "Недопустимое имя хоста"}), 400
    if not validate_ip(ip):
        return jsonify({"ok": False, "error": "Недопустимый IPv4 адрес"}), 400

    records = load_dns_records()
    if any(r.get("name") == name for r in records):
        return jsonify({"ok": False, "error": f"Запись '{name}' уже существует"}), 409

    records.append({"name": name, "ip": ip, "comment": comment})
    ok, err = write_dns_records_via_helper(records)
    return jsonify({"ok": ok, "error": err, "records": records if ok else None})

@app.route("/api/dns/<name>", methods=["DELETE"])
@require_auth
def api_dns_delete(name):
    name = name.strip().lower()
    if not validate_hostname(name):
        return jsonify({"ok": False, "error": "Недопустимое имя"}), 400
    records = load_dns_records()
    new_records = [r for r in records if r.get("name") != name]
    if len(new_records) == len(records):
        return jsonify({"ok": False, "error": "Запись не найдена"}), 404
    ok, err = write_dns_records_via_helper(new_records)
    return jsonify({"ok": ok, "error": err, "records": new_records if ok else None})

@app.route("/api/dns/<name>", methods=["PUT"])
@require_auth
def api_dns_update(name):
    name = name.strip().lower()
    if not validate_hostname(name):
        return jsonify({"ok": False, "error": "Недопустимое имя"}), 400
    data = request.json or {}
    ip      = data.get("ip", "").strip()
    comment = sanitize_comment(data.get("comment", ""))
    if not validate_ip(ip):
        return jsonify({"ok": False, "error": "Недопустимый IPv4 адрес"}), 400

    records = load_dns_records()
    found = False
    for r in records:
        if r.get("name") == name:
            r["ip"] = ip
            r["comment"] = comment
            found = True
            break
    if not found:
        return jsonify({"ok": False, "error": "Запись не найдена"}), 404
    ok, err = write_dns_records_via_helper(records)
    return jsonify({"ok": ok, "error": err, "records": records if ok else None})

# ── Tunnel devices (per-device VPN routing) ────────────────────────────────

def write_tunnel_devices_via_helper(devices):
    payload = json.dumps(devices, ensure_ascii=False)
    out, err, rc = run_cmd(["sudo", "-n", APPLY_TUNNEL_DEV_BIN],
                           input_str=payload, timeout=15)
    if rc != 0:
        return False, err or out or "apply-tunnel-devices failed"
    return True, None

@app.route("/api/devices")
@require_auth
def api_devices_list():
    return jsonify({"devices": load_tunnel_devices()})

@app.route("/api/devices", methods=["POST"])
@require_auth
def api_devices_add():
    data = request.json or {}
    ip   = data.get("ip", "").strip()
    name = sanitize_comment(data.get("name", ""))
    if not validate_ip(ip):
        return jsonify({"ok": False, "error": "Недопустимый IPv4 адрес"}), 400

    devices = load_tunnel_devices()
    if any(d.get("ip") == ip for d in devices):
        return jsonify({"ok": False, "error": f"{ip} уже в списке"}), 409
    devices.append({"ip": ip, "name": name})
    ok, err = write_tunnel_devices_via_helper(devices)
    return jsonify({"ok": ok, "error": err, "devices": devices if ok else None})

@app.route("/api/devices/<ip>", methods=["DELETE"])
@require_auth
def api_devices_delete(ip):
    ip = ip.strip()
    if not validate_ip(ip):
        return jsonify({"ok": False, "error": "Недопустимый IPv4 адрес"}), 400
    devices = load_tunnel_devices()
    new_devices = [d for d in devices if d.get("ip") != ip]
    if len(new_devices) == len(devices):
        return jsonify({"ok": False, "error": "Устройство не найдено"}), 404
    ok, err = write_tunnel_devices_via_helper(new_devices)
    return jsonify({"ok": ok, "error": err, "devices": new_devices if ok else None})

# ── Logs ─────────────────────────────────────────────────────────────────────

@app.route("/api/logs")
@require_auth
def api_logs():
    service = request.args.get("service", "zapret2")
    if service == "system":
        out, _, _ = run_cmd(
            ["sudo", "-n", "/usr/bin/journalctl", "-b", "-n", "80",
             "--no-pager", "--output=short-iso", "-p", "warning"], timeout=10
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
         "-n", "60", "--no-pager", "--output=short-iso"], timeout=10
    )
    return jsonify({"lines": out.splitlines()})

# ── Diagnostics ─────────────────────────────────────────────────────────────

@app.route("/api/diagnostics")
def api_diagnostics():
    checks = []

    # 1. AWG tunnel
    awg_link, _, _ = run_cmd(["ip", "link", "show", "awg0"])
    awg_up = "UP" in awg_link
    if awg_up:
        ping_out, _, ping_rc = run_cmd(
            ["ping", "-c", "2", "-W", "2", "-I", "awg0", "1.1.1.1"], timeout=10
        )
        m = re.search(r"(\d+)% packet loss", ping_out)
        loss = int(m.group(1)) if m else 100
        stat_line = ping_out.split("\n")[-1] if ping_out else ""
        checks.append({"name": "Туннель AWG",
                       "ok": ping_rc == 0 and loss < 100,
                       "detail": stat_line if ping_rc == 0 else "нет ответа от 1.1.1.1"})
    else:
        checks.append({"name": "Туннель AWG", "ok": False,
                       "detail": "интерфейс awg0 DOWN"})

    # 2. DNS via dnsmasq
    dns_out, _, dns_rc = run_cmd(
        ["dig", "+short", "+time=3", "+tries=1", "youtube.com", "@127.0.0.1"], timeout=8
    )
    dns_ok = dns_rc == 0 and bool(dns_out.strip())
    checks.append({"name": "DNS (dnsmasq)", "ok": dns_ok,
                   "detail": (f"youtube.com → {dns_out.strip()[:80]}" if dns_ok
                              else "нет ответа от 127.0.0.1")})

    # 3. nft tunnel_routing
    blocked = nft_set_count("blocked_ips")
    zapret  = nft_set_count("zapret_ips")
    checks.append({"name": "nft tunnel_routing",
                   "ok": nft_table_exists("ip", "tunnel_routing") and blocked > 0,
                   "detail": f"blocked_ips: {blocked:,} IP, zapret_ips: {zapret:,} IP"})

    # 4. NAT
    nat_ok = nft_table_exists("ip", "gateway_nat")
    checks.append({"name": "nft MASQUERADE (NAT)", "ok": nat_ok,
                   "detail": ("nftables gateway_nat активен" if nat_ok
                              else "MASQUERADE не настроен — интернет у клиентов не работает")})

    # 5. DNS-интерцепция
    di_ok = nft_table_exists("ip", "dns_intercept")
    checks.append({"name": "nft DNS-интерцепция", "ok": di_ok,
                   "detail": ("port 53 → dnsmasq, DoH заблокирован" if di_ok
                              else "клиенты могут обойти dnsmasq (TikTok, etc.)")})

    # 6. Kill-switch
    ks_ok = nft_table_exists("ip", "killswitch")
    checks.append({"name": "nft Kill-switch", "ok": ks_ok,
                   "detail": ("утечка при падении VPN заблокирована" if ks_ok
                              else "при падении VPN трафик идёт через ISP")})

    # 7. fwmark routing rule
    rules_out, _, _ = run_cmd(["ip", "rule", "list"])
    has_fwmark = "fwmark 0x1" in rules_out
    checks.append({"name": "ip rule fwmark", "ok": has_fwmark,
                   "detail": ("fwmark 0x1 → table 100" if has_fwmark
                              else "правило маршрутизации отсутствует")})

    # 8. Default route table 100
    rt_out, _, _ = run_cmd(["ip", "route", "show", "table", "100"])
    has_default = "default" in rt_out
    checks.append({"name": "Маршрут table 100", "ok": has_default,
                   "detail": rt_out.strip()[:80] if has_default else "нет default в table 100"})

    return jsonify({"checks": checks, "ts": datetime.now().strftime("%H:%M:%S")})

# ── nftables full dump (только под auth — раскрывает структуру firewall) ────

@app.route("/api/nftables")
@require_auth
def api_nftables():
    out, _, _ = run_cmd(
        ["sudo", "-n", "/usr/sbin/nft", "list", "table", "ip", "tunnel_routing"]
    )
    return jsonify({"raw": out})

# ── AWG config ──────────────────────────────────────────────────────────────

def load_network_conf():
    try:
        with open(NETWORK_CONF) as f:
            return json.load(f)
    except Exception:
        return {}

def save_network_conf(data):
    nc = load_network_conf()
    nc.update(data)
    atomic_write_json(NETWORK_CONF, nc)

def build_awg_conf(raw_conf, iface, gw_ip):
    """
    Собирает AWG конфиг с PostUp/PostDown.
    MASQUERADE — декларативно в /etc/nftables.d/10_nat.nft.
    """
    m = re.search(r"Endpoint\s*=\s*(\S+)", raw_conf, re.IGNORECASE)
    endpoint = m.group(1) if m else ""
    vpn_ip   = endpoint.split(":")[0] if endpoint else ""

    parts_up = [
        "iptables -t mangle -A FORWARD -o awg0 -p tcp "
        "--tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu",
        "sysctl -w net.ipv4.ip_forward=1",
    ]
    if vpn_ip:
        parts_up.append(f"ip route replace {vpn_ip}/32 via {gw_ip} dev {iface}")
    parts_up += [
        "ip route replace default dev awg0 table 100",
        "ip rule add fwmark 0x1 table 100 priority 100 2>/dev/null || true",
        f"nft -f {NFTABLES_CONF}",
        # Flowtable требует UP awg0 — поэтому применяем отдельно после
        # основного ruleset. || true — не валим AWG если файла нет/ошибка.
        "nft -f /etc/nftables.d/90_flowtable.nft 2>/dev/null || true",
    ]

    parts_down = [
        "iptables -t mangle -D FORWARD -o awg0 -p tcp "
        "--tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true",
    ]
    if vpn_ip:
        parts_down.append(f"ip route del {vpn_ip}/32 via {gw_ip} dev {iface} 2>/dev/null || true")
    parts_down += [
        "ip route del default dev awg0 table 100 2>/dev/null || true",
        "ip rule del fwmark 0x1 table 100 priority 100 2>/dev/null || true",
        # Сносим flowtable таблицу — иначе при следующем up получим конфликт
        "nft delete table inet flowtable_offload 2>/dev/null || true",
    ]

    postup   = "; ".join(parts_up)
    postdown = "; ".join(parts_down)

    # Срезаем все хуки wg-quick (PreUp/PostUp/PreDown/PostDown) — они eval'ятся
    # как shell от root. Принимать их от пользователя нельзя: токен → root.
    # Table/DNS/MTU перекрываются нами явно ниже.
    lines = [l for l in raw_conf.splitlines()
             if not re.match(r"^\s*(PreUp|PostUp|PreDown|PostDown|Table|DNS|MTU)\s*=",
                             l, re.IGNORECASE)]

    result = []
    for line in lines:
        result.append(line)
        if line.strip() == "[Interface]":
            result.append("Table = off")
            result.append("MTU = 1380")
    result.append(f"PostUp = {postup}")
    result.append(f"PostDown = {postdown}")

    return "\n".join(result) + "\n"

@app.route("/api/awg/config", methods=["GET"])
@require_auth
def api_awg_config_get():
    nc = load_network_conf()
    out, _, rc = run_cmd(["sudo", "-n", "/bin/cat", AWG_CONF_PATH])
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

    if not validate_iface(iface):
        return jsonify({"ok": False, "error": "Недопустимое имя интерфейса"}), 400
    if not validate_ip(gw_ip):
        return jsonify({"ok": False, "error": "Недопустимый IP шлюза"}), 400

    if "[Interface]" not in raw_conf or "[Peer]" not in raw_conf:
        return jsonify({"ok": False,
                        "error": "Неверный конфиг: нет [Interface] или [Peer]"}), 400

    conf = build_awg_conf(raw_conf, iface, gw_ip)

    out, err, rc = run_cmd(["sudo", "-n", APPLY_AWG_BIN], input_str=conf, timeout=15)
    if rc != 0:
        return jsonify({"ok": False, "error": err or out or "write failed"})

    save_network_conf({"iface": iface, "gw_ip": gw_ip})

    out, err, rc = run_cmd(
        ["sudo", "-n", "/usr/bin/systemctl", "restart", "awg-quick@awg0"], timeout=20
    )
    return jsonify({"ok": rc == 0, "output": out or err or "AWG перезапущен"})

# ── Index + main ────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return render_template("index.html")

if __name__ == "__main__":
    # Bind по умолчанию только на LAN-интерфейс — Web UI не должен быть
    # доступен со стороны awg0 (VPN-сторона = недоверенный сегмент).
    # Переопределяется WEBUI_BIND. Если привязки нет/невалидна — 127.0.0.1.
    bind = os.environ.get("WEBUI_BIND", "")
    if not bind:
        try:
            with open(NETWORK_CONF) as f:
                bind = json.load(f).get("pi_ip", "127.0.0.1") or "127.0.0.1"
        except Exception:
            bind = "127.0.0.1"
    app.run(
        host=bind,
        port=int(os.environ.get("WEBUI_PORT", "8080")),
        debug=False,
        threaded=True,
    )

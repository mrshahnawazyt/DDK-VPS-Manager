#!/usr/bin/env python3
"""DDK VPS Manager: a small, dependency-free control panel for one owned VPS."""

from __future__ import annotations

import argparse
import base64
from datetime import date, timedelta
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import shutil
import sqlite3
import subprocess
import time
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple, Union
from urllib.parse import parse_qs, quote, urlparse

APP_HOME = Path(os.environ.get("DDK_VPS_MANAGER_HOME", "/opt/ddk-vps-manager"))
DATA_DIR = APP_HOME / "data"
DATABASE = DATA_DIR / "ddk-vps-manager.sqlite3"
SESSION_COOKIE = "ddk_vps_manager_session"
SESSION_TTL_SECONDS = 12 * 60 * 60
SERVICE_CATALOG = (
    ("ddk-vps-manager", "DDK VPS Manager", "This web panel"),
    ("nginx", "Nginx", "Web server / TLS reverse proxy"),
    ("haproxy", "HAProxy", "Optional load balancer"),
    ("ddk-vps-manager-python-proxy", "Python Proxy", "Optional separately-installed Python service"),
)
SESSIONS: Dict[str, Dict[str, Any]] = {}


def connection() -> sqlite3.Connection:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(DATABASE)
    db.row_factory = sqlite3.Row
    return db


def setup_database() -> None:
    with connection() as db:
        db.executescript(
            """
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT UNIQUE NOT NULL,
                role TEXT NOT NULL CHECK(role IN ('viewer','admin','super_admin')),
                password_salt TEXT NOT NULL,
                password_hash TEXT NOT NULL,
                created_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS audit_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at INTEGER NOT NULL,
                username TEXT NOT NULL,
                action TEXT NOT NULL,
                detail TEXT NOT NULL,
                remote_addr TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS ssh_accounts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT UNIQUE NOT NULL,
                expires_on TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                locked INTEGER NOT NULL DEFAULT 0
            );
            """
        )


def get_setting(key: str, default: str = "") -> str:
    with connection() as db:
        row = db.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
        return row["value"] if row else default


def set_setting(key: str, value: str) -> None:
    with connection() as db:
        db.execute(
            "INSERT INTO settings(key, value) VALUES(?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, value),
        )


def password_record(password: str, salt: Optional[bytes] = None) -> Tuple[str, str]:
    raw_salt = salt or secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), raw_salt, 310_000)
    return base64.b64encode(raw_salt).decode(), base64.b64encode(digest).decode()


def verify_password(password: str, salt_b64: str, hash_b64: str) -> bool:
    try:
        salt = base64.b64decode(salt_b64.encode(), validate=True)
        _, computed = password_record(password, salt)
        return hmac.compare_digest(computed, hash_b64)
    except Exception:
        return False


def create_user(username: str, password: str, role: str) -> None:
    salt, digest = password_record(password)
    with connection() as db:
        db.execute(
            "INSERT INTO users(username, role, password_salt, password_hash, created_at) "
            "VALUES(?, ?, ?, ?, ?)",
            (username, role, salt, digest, int(time.time())),
        )


def audit(username: str, action: str, detail: str, remote_addr: str) -> None:
    with connection() as db:
        db.execute(
            "INSERT INTO audit_log(created_at, username, action, detail, remote_addr) VALUES(?, ?, ?, ?, ?)",
            (int(time.time()), username, action, detail[:300], remote_addr[:80]),
        )


def initialize(admin_user: str, admin_password: str, domain: str, port: str) -> int:
    setup_database()
    with connection() as db:
        exists = db.execute("SELECT 1 FROM users LIMIT 1").fetchone()
    if not exists:
        create_user(admin_user, admin_password, "super_admin")
        print("Created first DDK VPS Manager administrator.")
    else:
        print("Existing DDK VPS Manager users retained.")
    set_setting("domain", domain)
    set_setting("port", port)
    return 0


def command(args: List[str], timeout: int = 5) -> Tuple[int, str]:
    try:
        completed = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   timeout=timeout, check=False)
        return completed.returncode, completed.stdout.strip()
    except (subprocess.SubprocessError, OSError) as exc:
        return 1, str(exc)


def command_with_input(args: List[str], value: str, timeout: int = 10) -> Tuple[int, str]:
    try:
        completed = subprocess.run(
            args,
            input=value,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
        return completed.returncode, completed.stdout.strip()
    except (subprocess.SubprocessError, OSError) as exc:
        return 1, str(exc)


def provision_ssh_account(username: str, duration_days: int) -> Tuple[bool, str, str]:
    """Create one local Linux account with a system-enforced expiry date."""
    expires_on = (date.today() + timedelta(days=duration_days)).isoformat()
    exists_rc, _ = command(["id", "-u", username])
    if exists_rc == 0:
        return False, "This Linux username already exists.", ""
    rc, output = command([
        "useradd", "--create-home", "--user-group", "--shell", "/bin/bash",
        "--expiredate", expires_on, username,
    ])
    if rc != 0:
        return False, f"Could not create the Linux account: {output[:120]}", ""
    password = secrets.token_urlsafe(14)
    rc, output = command_with_input(["chpasswd"], f"{username}:{password}\n")
    if rc != 0:
        command(["userdel", "--remove", username])
        return False, f"Could not set the account password: {output[:120]}", ""
    with connection() as db:
        db.execute(
            "INSERT INTO ssh_accounts(username, expires_on, created_at, locked) VALUES(?, ?, ?, 0)",
            (username, expires_on, int(time.time())),
        )
    return True, password, expires_on


def ssh_account_runtime(username: str, expires_on: str, panel_locked: bool) -> Dict[str, Any]:
    """Read the actual local account state instead of trusting panel data alone."""
    record: Dict[str, Any] = {
        "exists": False,
        "home": f"/home/{username}",
        "shell": "—",
        "state": "removed",
        "online": 0,
    }
    rc, passwd_row = command(["getent", "passwd", username])
    if rc != 0 or not passwd_row:
        return record
    fields = passwd_row.split(":")
    record["exists"] = True
    if len(fields) >= 7:
        record["home"] = fields[5] or record["home"]
        record["shell"] = fields[6] or "—"

    locked = panel_locked
    lock_rc, lock_info = command(["passwd", "--status", username])
    if lock_rc == 0:
        status_parts = lock_info.split()
        locked = locked or (len(status_parts) > 1 and status_parts[1].upper().startswith("L"))
    try:
        expired = date.fromisoformat(expires_on) < date.today()
    except ValueError:
        expired = False
    if expired:
        record["state"] = "expired"
    elif locked:
        record["state"] = "locked"
    else:
        record["state"] = "active"

    who_rc, who_output = command(["who"])
    if who_rc == 0 and who_output:
        record["online"] = sum(1 for line in who_output.splitlines() if line.split()[:1] == [username])
    return record


def renew_ssh_account(username: str, current_expiry: str, duration_days: int) -> Tuple[bool, str]:
    """Extend an existing managed Linux account without changing its password."""
    try:
        current = date.fromisoformat(current_expiry)
    except ValueError:
        current = date.today()
    new_expiry = (max(date.today(), current) + timedelta(days=duration_days)).isoformat()
    rc, output = command(["chage", "--expiredate", new_expiry, username], timeout=10)
    if rc != 0:
        return False, output[:120] or "Could not update account expiry."
    with connection() as db:
        db.execute("UPDATE ssh_accounts SET expires_on = ? WHERE username = ?", (new_expiry, username))
    return True, new_expiry


def service_state(unit: str) -> str:
    rc, output = command(["systemctl", "is-active", unit])
    if rc == 0:
        return "running"
    if output == "inactive":
        return "stopped"
    if output == "failed":
        return "failed"
    if output in ("unknown", "not-found") or "not found" in output.lower():
        return "not installed"
    return output or "unknown"


def system_snapshot() -> Dict[str, Union[str, int]]:
    meminfo: Dict[str, int] = {}
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            key, rest = line.split(":", 1)
            meminfo[key] = int(rest.strip().split()[0]) * 1024
    except (OSError, ValueError):
        pass
    memory_total = meminfo.get("MemTotal", 0)
    memory_available = meminfo.get("MemAvailable", 0)
    disk = shutil.disk_usage("/")
    uptime = "Unavailable"
    try:
        seconds = int(float(Path("/proc/uptime").read_text().split()[0]))
        days, rem = divmod(seconds, 86400)
        hours, rem = divmod(rem, 3600)
        minutes = rem // 60
        uptime = f"{days}d {hours}h {minutes}m"
    except (OSError, ValueError, IndexError):
        pass
    try:
        load = Path("/proc/loadavg").read_text().split()[0]
    except (OSError, IndexError):
        load = "—"
    return {
        "cpu": load,
        "memory_used": max(0, memory_total - memory_available),
        "memory_total": memory_total,
        "disk_used": disk.used,
        "disk_total": disk.total,
        "uptime": uptime,
    }


def human_bytes(value: int) -> str:
    units = ("B", "KB", "MB", "GB", "TB")
    amount = float(value)
    for unit in units:
        if amount < 1024 or unit == units[-1]:
            return f"{amount:.1f} {unit}"
        amount /= 1024
    return "—"


def listening_ports() -> List[Tuple[str, str]]:
    rc, output = command(["ss", "-ltnH"], timeout=4)
    if rc != 0:
        return []
    rows: List[Tuple[str, str]] = []
    for line in output.splitlines()[:60]:
        parts = line.split()
        if len(parts) >= 4:
            rows.append((parts[3], parts[0]))
    return rows


def esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def fmt_time(timestamp: int) -> str:
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(timestamp))


CSS = """
:root{color-scheme:dark;--bg:#090d0e;--panel:#12191a;--panel2:#182122;--line:#293637;--text:#e8f1f1;--muted:#8ba2a3;--accent:#52d9dc;--good:#5de28b;--warn:#efbe65;--bad:#fc7d7d}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}.shell{display:grid;grid-template-columns:235px 1fr;min-height:100vh}.brand{padding:21px 18px;border-bottom:1px solid var(--line);letter-spacing:.05em;font-weight:800;color:var(--accent)}.brand span{color:var(--text);font-weight:500}.side{border-right:1px solid var(--line);background:#0c1112}.nav{padding:13px 9px}.nav a{display:block;padding:11px 12px;border-radius:7px;color:var(--muted);text-decoration:none;margin:3px 0}.nav a:hover,.nav a.active{color:var(--accent);background:#132526}.side-foot{position:fixed;bottom:16px;left:18px;color:var(--muted);font-size:12px}.main{min-width:0}.top{height:65px;border-bottom:1px solid var(--line);display:flex;align-items:center;justify-content:space-between;padding:0 28px}.crumb{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.08em}.user{color:var(--muted)}.user b{color:var(--text)}.content{max-width:1300px;margin:auto;padding:26px}.title-row{display:flex;gap:16px;align-items:center;justify-content:space-between;margin-bottom:20px}h1{font-size:21px;margin:0}h2{font-size:13px;text-transform:uppercase;letter-spacing:.1em;color:var(--accent);margin:0 0 15px}.grid{display:grid;gap:15px;grid-template-columns:repeat(4,minmax(0,1fr))}.grid.two{grid-template-columns:repeat(2,minmax(0,1fr))}.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:18px;min-width:0}.metric{font-size:27px;font-weight:700;margin:8px 0}.muted{color:var(--muted);font-size:12px}.status{border-radius:999px;padding:4px 8px;font-size:11px;white-space:nowrap}.running{background:#123523;color:var(--good)}.stopped,.not-installed{background:#272d2d;color:var(--muted)}.failed{background:#482022;color:var(--bad)}.unknown{background:#43351b;color:var(--warn)}.table-wrap{overflow:auto}.table{width:100%;border-collapse:collapse;min-width:580px}.table th{color:var(--muted);font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.07em;text-align:left}.table th,.table td{border-bottom:1px solid var(--line);padding:12px 8px}.table td:first-child,.table th:first-child{padding-left:0}.table td:last-child,.table th:last-child{padding-right:0}.button{border:0;border-radius:7px;padding:9px 12px;background:var(--accent);color:#062123;font-weight:700;cursor:pointer;text-decoration:none;display:inline-block}.button.subtle{background:#253031;color:var(--text)}.button.danger{background:#4c2628;color:#ffdada}.button:disabled{opacity:.45;cursor:not-allowed}.button-row{display:flex;gap:7px;flex-wrap:wrap}.notice{border:1px solid #27585a;background:#113033;color:#b9f7f8;border-radius:8px;padding:11px 13px;margin-bottom:17px}.form-grid{display:grid;grid-template-columns:1fr 1fr;gap:13px}label{display:block;color:var(--muted);font-size:12px;margin-bottom:6px}input,select{width:100%;padding:10px;border-radius:7px;border:1px solid var(--line);background:#0a1011;color:var(--text)}.login{min-height:100vh;display:grid;place-items:center;padding:20px}.login-box{width:min(410px,100%);padding:28px;background:var(--panel);border:1px solid var(--line);border-radius:14px}.login-box h1{color:var(--accent);margin-bottom:8px}.login-box p{color:var(--muted);margin-bottom:22px}.login-box form>*{margin-top:13px}.small{font-size:12px}.pill{font-size:11px;padding:3px 7px;border:1px solid var(--line);border-radius:99px;color:var(--muted)}@media(max-width:850px){.shell{display:block}.side{position:sticky;top:0;z-index:2;border-right:0;border-bottom:1px solid var(--line)}.brand{padding:12px 16px}.nav{display:flex;gap:4px;overflow:auto;padding:7px 9px}.nav a{white-space:nowrap;padding:8px 10px}.side-foot{display:none}.top{height:52px;padding:0 16px}.content{padding:17px}.grid,.grid.two{grid-template-columns:1fr 1fr}.title-row{align-items:flex-start;flex-direction:column}}@media(max-width:500px){.grid,.grid.two,.form-grid{grid-template-columns:1fr}.metric{font-size:23px}.user{font-size:12px}}
"""
CSS += ".status.active{background:#123523;color:var(--good)}.status.locked,.status.expired,.status.removed{background:#482022;color:var(--bad)}.button-row form{display:inline}code{color:#b9f7f8;word-break:break-all}pre.log{white-space:pre-wrap;overflow:auto;max-height:65vh;background:#0a1011;border:1px solid var(--line);padding:14px;border-radius:8px;color:#c9d6d7}"


class PanelHandler(BaseHTTPRequestHandler):
    server_version = "DDK VPS Manager/1.0"

    def log_message(self, fmt: str, *args: object) -> None:
        # systemd journal already records useful lifecycle information; avoid logging passwords/paths.
        return

    def request_path(self) -> str:
        return urlparse(self.path).path

    def form(self) -> Dict[str, str]:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(min(length, 16_384)).decode("utf-8", "replace")
        return {key: values[0] for key, values in parse_qs(raw).items()}

    def session(self) -> Tuple[Optional[str], Optional[Dict[str, Any]]]:
        raw = self.headers.get("Cookie", "")
        jar = cookies.SimpleCookie()
        try:
            jar.load(raw)
        except cookies.CookieError:
            return None, None
        token = jar.get(SESSION_COOKIE)
        if not token:
            return None, None
        session = SESSIONS.get(token.value)
        if not session or session["expires"] < time.time():
            SESSIONS.pop(token.value, None)
            return None, None
        return token.value, session

    def current_user(self) -> Optional[Dict[str, Any]]:
        _, session = self.session()
        if not session:
            return None
        with connection() as db:
            row = db.execute("SELECT id, username, role FROM users WHERE id = ?", (session["user_id"],)).fetchone()
        return dict(row) if row else None

    def set_cookie(self, token: str, expires: int) -> None:
        self.send_header("Set-Cookie", f"{SESSION_COOKIE}={token}; Max-Age={expires}; Path=/; HttpOnly; SameSite=Lax")

    def redirect(self, location: str, cookie: Optional[Tuple[str, int]] = None) -> None:
        self.send_response(303)
        if cookie:
            self.set_cookie(*cookie)
        self.send_header("Location", location)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def send_html(self, body: str, status: int = 200) -> None:
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "same-origin")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(encoded)

    def csrf(self, user: Dict[str, Any]) -> str:
        token, session = self.session()
        if not token or not session:
            return ""
        return session["csrf"]

    def valid_csrf(self, form: Dict[str, str], user: Dict[str, Any]) -> bool:
        return bool(user) and hmac.compare_digest(form.get("csrf", ""), self.csrf(user))

    def page(self, title: str, content: str, user: Optional[Dict[str, Any]] = None, active: str = "") -> str:
        if not user:
            return f"<!doctype html><html><head><meta name=viewport content='width=device-width,initial-scale=1'><title>{esc(title)}</title><style>{CSS}</style></head><body>{content}</body></html>"
        links = (("dashboard", "Dashboard", "/"), ("ssh", "SSH accounts", "/ssh-accounts"), ("services", "Running services", "/services"),
                 ("settings", "Settings", "/settings"), ("admins", "Panel admins", "/admins"),
                 ("activity", "Activity log", "/activity"))
        nav = "".join(f"<a class='{('active' if key == active else '')}' href='{url}'>{label}</a>" for key, label, url in links)
        return f"""<!doctype html><html><head><meta name=viewport content='width=device-width,initial-scale=1'><title>{esc(title)} · DDK VPS Manager</title><style>{CSS}</style></head>
<body><div class='shell'><aside class='side'><div class='brand'>DDK VPS <span>MANAGER</span></div><nav class='nav'>{nav}</nav><div class='side-foot'>Managed locally<br>Use HTTPS for public access</div></aside><main class='main'><header class='top'><div class='crumb'>{esc(title)}</div><div class='user'><b>{esc(user['username'])}</b> · {esc(user['role'])} <form style='display:inline;margin-left:10px' method='post' action='/logout'><input type='hidden' name='csrf' value='{self.csrf(user)}'><button class='button subtle small'>Log out</button></form></div></header><section class='content'>{content}</section></main></div></body></html>"""

    def notice(self) -> str:
        text = parse_qs(urlparse(self.path).query).get("notice", [""])[0]
        _, session = self.session()
        if session and session.get("flash"):
            text = str(session.pop("flash"))
        return f"<div class='notice'>{esc(text)}</div>" if text else ""

    def set_flash(self, text: str) -> None:
        _, session = self.session()
        if session:
            session["flash"] = text

    def require_user(self) -> Optional[Dict[str, Any]]:
        user = self.current_user()
        if not user:
            self.redirect("/login")
        return user

    def require_super_admin(self, user: Dict[str, Any]) -> bool:
        if user["role"] != "super_admin":
            self.redirect("/?notice=" + quote("This action requires a super administrator."))
            return False
        return True

    def do_GET(self) -> None:
        path = self.request_path()
        if path == "/login":
            self.login_page()
            return
        user = self.require_user()
        if not user:
            return
        if path == "/":
            self.dashboard(user)
        elif path == "/ssh-accounts":
            self.ssh_accounts_page(user)
        elif path == "/services":
            self.services_page(user)
        elif path == "/service-logs":
            self.service_logs_page(user)
        elif path == "/settings":
            self.settings_page(user)
        elif path == "/admins":
            self.admins_page(user)
        elif path == "/activity":
            self.activity_page(user)
        else:
            self.send_html(self.page("Not found", "<h1>Page not found</h1>", user), 404)

    def do_POST(self) -> None:
        path = self.request_path()
        form = self.form()
        if path == "/login":
            self.login(form)
            return
        user = self.require_user()
        if not user:
            return
        if not self.valid_csrf(form, user):
            self.redirect("/?notice=" + quote("Your form expired. Please try again."))
            return
        if path == "/logout":
            token, _ = self.session()
            if token:
                SESSIONS.pop(token, None)
            self.redirect("/login", ("deleted", 0))
        elif path == "/service-action":
            self.service_action(user, form)
        elif path == "/settings":
            self.save_settings(user, form)
        elif path == "/python-proxy-port":
            self.save_python_proxy_port(user, form)
        elif path == "/admin-create":
            self.admin_create(user, form)
        elif path == "/ssh-create":
            self.ssh_create(user, form)
        elif path == "/ssh-action":
            self.ssh_action(user, form)
        else:
            self.redirect("/?notice=" + quote("Unknown action."))

    def login_page(self, error: str = "") -> None:
        alert = f"<div class='notice'>{esc(error)}</div>" if error else ""
        body = f"""<main class='login'><section class='login-box'><h1>DDK VPS MANAGER</h1><p>Sign in to manage this server.</p>{alert}<form method='post' action='/login'><label>Username<input name='username' autocomplete='username' required maxlength='32'></label><label>Password<input name='password' type='password' autocomplete='current-password' required></label><button class='button' style='width:100%;margin-top:18px'>Sign in</button></form><p class='small'>This panel is for a server you own or administer.</p></section></main>"""
        self.send_html(self.page("Sign in", body))

    def login(self, form: Dict[str, str]) -> None:
        username = form.get("username", "")[:32]
        password = form.get("password", "")
        with connection() as db:
            row = db.execute("SELECT * FROM users WHERE username = ?", (username,)).fetchone()
        if not row or not verify_password(password, row["password_salt"], row["password_hash"]):
            self.login_page("Incorrect username or password.")
            return
        token = secrets.token_urlsafe(32)
        SESSIONS[token] = {"user_id": row["id"], "csrf": secrets.token_urlsafe(24), "expires": time.time() + SESSION_TTL_SECONDS}
        audit(row["username"], "login", "Signed in to panel", self.client_address[0])
        self.redirect("/", (token, SESSION_TTL_SECONDS))

    def dashboard(self, user: Dict[str, Any]) -> None:
        info = system_snapshot()
        states = [service_state(unit) for unit, _, _ in SERVICE_CATALOG]
        running = sum(1 for state in states if state == "running")
        with connection() as db:
            ssh_total = int(db.execute("SELECT COUNT(*) FROM ssh_accounts").fetchone()[0])
            ssh_locked = int(db.execute("SELECT COUNT(*) FROM ssh_accounts WHERE locked = 1").fetchone()[0])
        mem = f"{human_bytes(int(info['memory_used']))} / {human_bytes(int(info['memory_total']))}"
        disk = f"{human_bytes(int(info['disk_used']))} / {human_bytes(int(info['disk_total']))}"
        service_rows = "".join(
            f"<tr><td><b>{esc(label)}</b><div class='muted'>{esc(unit)}</div></td><td><span class='status {esc(state.replace(' ', '-'))}'>{esc(state)}</span></td><td>{esc(detail)}</td></tr>"
            for (unit, label, detail), state in zip(SERVICE_CATALOG, states)
        )
        content = f"""{self.notice()}<div class='title-row'><div><h1>Dashboard</h1><div class='muted'>Live overview of this VPS</div></div><a class='button subtle' href='/services'>Manage services</a></div>
<div class='grid'><article class='card'><h2>Load average</h2><div class='metric'>{esc(info['cpu'])}</div><div class='muted'>1-minute CPU load</div></article><article class='card'><h2>Memory</h2><div class='metric'>{esc(mem)}</div><div class='muted'>used / total</div></article><article class='card'><h2>Disk</h2><div class='metric'>{esc(disk)}</div><div class='muted'>root filesystem</div></article><article class='card'><h2>Uptime</h2><div class='metric'>{esc(info['uptime'])}</div><div class='muted'>since last reboot</div></article></div>
<div class='grid two' style='margin-top:15px'><article class='card'><h2>Managed services</h2><div class='metric'>{running} / {len(SERVICE_CATALOG)}</div><div class='muted'>running from the approved local list</div></article><article class='card'><h2>SSH accounts</h2><div class='metric'>{ssh_total}</div><div class='muted'>{ssh_locked} locked · <a href='/ssh-accounts'>manage accounts</a></div></article><article class='card'><h2>Panel address</h2><div class='metric' style='font-size:18px'>{esc(get_setting('domain', 'Not set'))}:{esc(get_setting('port', '9090'))}</div><div class='muted'>Set a domain, then add HTTPS before public use.</div></article></div>
<article class='card' style='margin-top:15px'><h2>Services</h2><div class='table-wrap'><table class='table'><thead><tr><th>Service</th><th>Status</th><th>Purpose</th></tr></thead><tbody>{service_rows}</tbody></table></div></article>"""
        self.send_html(self.page("Dashboard", content, user, "dashboard"))

    def ssh_accounts_page(self, user: Dict[str, Any]) -> None:
        with connection() as db:
            accounts = db.execute(
                "SELECT username, expires_on, created_at, locked FROM ssh_accounts ORDER BY id DESC"
            ).fetchall()
        csrf = self.csrf(user)
        can_manage = user["role"] == "super_admin"
        rows = []
        for account in accounts:
            runtime = ssh_account_runtime(account["username"], account["expires_on"], bool(account["locked"]))
            state = runtime["state"]
            actions = "<span class='muted'>View-only role</span>"
            if can_manage:
                action = "unlock" if state == "locked" else "lock"
                caption = "Unlock" if state == "locked" else "Lock"
                actions = (
                    f"<div class='button-row'><form method='post' action='/ssh-action'><input type='hidden' name='csrf' value='{csrf}'>"
                    f"<input type='hidden' name='username' value='{esc(account['username'])}'>"
                    f"<button class='button subtle small' name='action' value='{action}'>{caption}</button></form>"
                    f"<form method='post' action='/ssh-action'><input type='hidden' name='csrf' value='{csrf}'><input type='hidden' name='username' value='{esc(account['username'])}'>"
                    f"<button class='button subtle small' name='action' value='reset-password'>New password</button></form>"
                    f"<form method='post' action='/ssh-action'><input type='hidden' name='csrf' value='{csrf}'><input type='hidden' name='username' value='{esc(account['username'])}'>"
                    f"<input name='days' value='30' inputmode='numeric' aria-label='Additional days' style='width:66px;padding:7px'><button class='button subtle small' name='action' value='renew'>Renew</button></form>"
                    f"<form method='post' action='/ssh-action'><input type='hidden' name='csrf' value='{csrf}'><input type='hidden' name='username' value='{esc(account['username'])}'>"
                    f"<button class='button danger small' name='action' value='remove'>Remove</button></form></div>"
                )
            rows.append(
                f"<tr><td><b>{esc(account['username'])}</b><div class='muted'>SSH port 22 · shell {esc(runtime['shell'])}</div></td>"
                f"<td><code>{esc(runtime['home'])}</code></td><td><span class='status {state}'>{state}</span>"
                f"<div class='muted'>{runtime['online']} session(s) online</div></td><td>{esc(account['expires_on'])}</td>"
                f"<td>{esc(fmt_time(account['created_at']))}</td><td>{actions}</td></tr>"
            )
        table = "".join(rows) or "<tr><td colspan='6' class='muted'>No SSH accounts created from this panel yet.</td></tr>"
        if can_manage:
            create_card = f"""<article class='card'><h2>Create SSH account</h2>
<form method='post' action='/ssh-create'><input type='hidden' name='csrf' value='{csrf}'>
<div class='form-grid'><label>Username<input name='username' placeholder='clientname' maxlength='32' required></label>
<label>Expires after days<input name='days' value='30' inputmode='numeric' required></label></div>
<div class='button-row' style='margin-top:16px'><button class='button'>Create account</button></div></form>
<p class='muted'>A random password is shown once after creation. The expiry date is enforced by Ubuntu for this Linux account.</p></article>"""
        else:
            create_card = "<article class='card'><h2>SSH accounts</h2><p class='muted'>Only a super administrator can create SSH accounts.</p></article>"
        content = f"""{self.notice()}<div class='title-row'><div><h1>SSH accounts</h1><div class='muted'>Manage local SSH users created by DDK VPS Manager.</div></div></div>
<div class='grid two'>{create_card}<article class='card'><h2>Connection details</h2><p class='muted'>Host: <b>{esc(get_setting('domain', 'your-vps-ip'))}</b><br>Port: <b>22</b><br>Each account shows its actual Linux home directory, shell, lock/expiry state and logged-in session count.</p></article></div>
<article class='card' style='margin-top:15px'><h2>Created accounts</h2><div class='table-wrap'><table class='table'><thead><tr><th>Username</th><th>Home directory</th><th>Status</th><th>Expiry</th><th>Created</th><th>Actions</th></tr></thead><tbody>{table}</tbody></table></div></article>"""
        self.send_html(self.page("SSH accounts", content, user, "ssh"))

    def ssh_create(self, user: Dict[str, Any], form: Dict[str, str]) -> None:
        if not self.require_super_admin(user):
            return
        username = form.get("username", "").strip().lower()
        if not re.fullmatch(r"[a-z][a-z0-9_-]{2,31}", username):
            self.redirect("/ssh-accounts?notice=" + quote("Use 3-32 lowercase letters, numbers, dash or underscore; start with a letter."))
            return
        try:
            days = int(form.get("days", "0"))
        except ValueError:
            days = 0
        if not 1 <= days <= 3650:
            self.redirect("/ssh-accounts?notice=" + quote("Expiry must be from 1 to 3650 days."))
            return
        created, result, expiry = provision_ssh_account(username, days)
        if not created:
            self.redirect("/ssh-accounts?notice=" + quote(result))
            return
        audit(user["username"], "ssh_account_create", f"Created SSH account {username}; expiry {expiry}", self.client_address[0])
        self.set_flash(f"SSH account created — username: {username} | password: {result} | expiry: {expiry}. Save this password now.")
        self.redirect("/ssh-accounts")

    def ssh_action(self, user: Dict[str, Any], form: Dict[str, str]) -> None:
        if not self.require_super_admin(user):
            return
        username = form.get("username", "")
        action = form.get("action", "")
        if not re.fullmatch(r"[a-z][a-z0-9_-]{2,31}", username) or action not in {"lock", "unlock", "reset-password", "renew", "remove"}:
            self.redirect("/ssh-accounts?notice=" + quote("That SSH account action is not allowed."))
            return
        with connection() as db:
            account = db.execute("SELECT username, expires_on FROM ssh_accounts WHERE username = ?", (username,)).fetchone()
        if not account:
            self.redirect("/ssh-accounts?notice=" + quote("This account is not managed by DDK VPS Manager."))
            return
        if action in {"lock", "unlock"}:
            flag = "--lock" if action == "lock" else "--unlock"
            rc, output = command(["usermod", flag, username], timeout=10)
            if rc != 0:
                self.redirect("/ssh-accounts?notice=" + quote(f"Could not {action} account: {output[:120]}"))
                return
            with connection() as db:
                db.execute("UPDATE ssh_accounts SET locked = ? WHERE username = ?", (1 if action == "lock" else 0, username))
            audit(user["username"], f"ssh_account_{action}", f"{action.title()}ed SSH account {username}", self.client_address[0])
            self.redirect("/ssh-accounts?notice=" + quote(f"SSH account {username} {action}ed."))
            return
        if action == "reset-password":
            password = secrets.token_urlsafe(14)
            rc, output = command_with_input(["chpasswd"], f"{username}:{password}\n")
            if rc != 0:
                self.redirect("/ssh-accounts?notice=" + quote(f"Could not reset password: {output[:120]}"))
                return
            audit(user["username"], "ssh_account_password_reset", f"Reset SSH account password for {username}", self.client_address[0])
            self.set_flash(f"New password for {username}: {password}. Save it now; it is not shown again.")
            self.redirect("/ssh-accounts")
            return
        if action == "renew":
            try:
                days = int(form.get("days", "0"))
            except ValueError:
                days = 0
            if not 1 <= days <= 3650:
                self.redirect("/ssh-accounts?notice=" + quote("Renewal must be from 1 to 3650 days."))
                return
            updated, result = renew_ssh_account(username, account["expires_on"], days)
            if not updated:
                self.redirect("/ssh-accounts?notice=" + quote(f"Could not renew account: {result}"))
                return
            audit(user["username"], "ssh_account_renew", f"Renewed SSH account {username} until {result}", self.client_address[0])
            self.redirect("/ssh-accounts?notice=" + quote(f"SSH account {username} renewed until {result}. Unlock it too if it was locked."))
            return
        rc, output = command(["userdel", "--remove", username], timeout=20)
        if rc != 0:
            self.redirect("/ssh-accounts?notice=" + quote(f"Could not remove account: {output[:120]}"))
            return
        with connection() as db:
            db.execute("DELETE FROM ssh_accounts WHERE username = ?", (username,))
        audit(user["username"], "ssh_account_remove", f"Removed managed SSH account {username}", self.client_address[0])
        self.redirect("/ssh-accounts?notice=" + quote(f"SSH account {username} and its home directory were removed."))

    def services_page(self, user: Dict[str, Any]) -> None:
        csrf = self.csrf(user)
        can_manage = user["role"] == "super_admin"
        rows = []
        for unit, label, detail in SERVICE_CATALOG:
            state = service_state(unit)
            action_form = ""
            if can_manage:
                buttons = "".join(
                    f"<button class='button {'danger' if action == 'stop' else 'subtle'} small' name='action' value='{action}'>{action.title()}</button>"
                    for action in ("start", "restart", "stop")
                )
                action_form = f"<form method='post' action='/service-action' class='button-row'><input type='hidden' name='csrf' value='{csrf}'><input type='hidden' name='unit' value='{unit}'>{buttons}</form>"
            else:
                action_form = "<span class='muted'>View-only role</span>"
            rows.append(f"<tr><td><b>{esc(label)}</b><div class='muted'>{esc(detail)}</div></td><td><span class='status {esc(state.replace(' ', '-'))}'>{esc(state)}</span></td><td>{action_form} <a class='button subtle small' href='/service-logs?unit={quote(unit)}'>Logs</a></td></tr>")
        port_rows = "".join(f"<tr><td>{esc(addr)}</td><td>{esc(kind)}</td></tr>" for addr, kind in listening_ports()) or "<tr><td colspan='2' class='muted'>No port data available.</td></tr>"
        proxy_form = ""
        if can_manage:
            proxy_form = f"""<form method='post' action='/python-proxy-port'><input type='hidden' name='csrf' value='{csrf}'><label>Service port<input name='port' value='{esc(get_setting('python_proxy_port', '8081'))}' inputmode='numeric' required></label><div class='button-row' style='margin-top:12px'><button class='button'>Save port</button></div></form>"""
        else:
            proxy_form = "<p class='muted'>A super administrator can configure this optional service.</p>"
        content = f"""{self.notice()}<div class='title-row'><div><h1>Running services</h1><div class='muted'>Only the approved local service list can be controlled here.</div></div></div>
<div class='grid two'><article class='card'><h2>Python proxy integration</h2><p class='muted'>Controls the optional <span class='pill'>ddk-vps-manager-python-proxy.service</span> if you have installed and reviewed it. This panel only saves the requested port and controls that named service.</p>{proxy_form}</article><article class='card'><h2>Service control</h2><div class='table-wrap'><table class='table'><thead><tr><th>Service</th><th>Status</th><th>Actions</th></tr></thead><tbody>{''.join(rows)}</tbody></table></div></article></div>
<article class='card' style='margin-top:15px'><h2>Listening TCP ports</h2><div class='table-wrap'><table class='table'><thead><tr><th>Address</th><th>Type</th></tr></thead><tbody>{port_rows}</tbody></table></div></article>"""
        self.send_html(self.page("Running services", content, user, "services"))

    def service_logs_page(self, user: Dict[str, Any]) -> None:
        unit = parse_qs(urlparse(self.path).query).get("unit", [""])[0]
        allowed = {item[0] for item in SERVICE_CATALOG}
        if unit not in allowed:
            self.redirect("/services?notice=" + quote("That service is not in the approved local list."))
            return
        rc, output = command(["journalctl", "-u", unit, "-n", "120", "--no-pager", "-o", "short-iso"], timeout=12)
        if rc != 0 and not output:
            output = "No journal output is available for this service."
        content = f"""<div class='title-row'><div><h1>Service logs</h1><div class='muted'>{esc(unit)} · latest 120 lines</div></div><a class='button subtle' href='/services'>Back to services</a></div><article class='card'><pre class='log'>{esc(output or 'No log entries.')}</pre></article>"""
        self.send_html(self.page("Service logs", content, user, "services"))

    def service_action(self, user: Dict[str, Any], form: Dict[str, str]) -> None:
        if not self.require_super_admin(user):
            return
        unit = form.get("unit", "")
        action = form.get("action", "")
        allowed = {item[0] for item in SERVICE_CATALOG}
        if unit not in allowed or action not in {"start", "stop", "restart"}:
            self.redirect("/services?notice=" + quote("That service action is not allowed."))
            return
        rc, output = command(["systemctl", action, unit], timeout=15)
        result = "completed" if rc == 0 else f"failed: {output[:100]}"
        audit(user["username"], f"service_{action}", f"{unit}: {result}", self.client_address[0])
        self.redirect("/services?notice=" + quote(f"{unit}: {action} {result}"))

    def settings_page(self, user: Dict[str, Any]) -> None:
        csrf = self.csrf(user)
        disabled = "" if user["role"] == "super_admin" else "disabled"
        content = f"""{self.notice()}<div class='title-row'><div><h1>Settings</h1><div class='muted'>Panel address settings. Restart the panel after changing the port.</div></div></div>
<div class='grid two'><article class='card'><h2>Panel address</h2><form method='post' action='/settings'><input type='hidden' name='csrf' value='{csrf}'><div class='form-grid'><label>Domain or VPS IP<input name='domain' value='{esc(get_setting('domain'))}' maxlength='253' required {disabled}></label><label>Panel port<input name='port' value='{esc(get_setting('port','9090'))}' inputmode='numeric' required {disabled}></label></div><div class='button-row' style='margin-top:16px'><button class='button' {disabled}>Save settings</button></div></form><p class='muted'>The panel does not create DNS records. Point your domain to your VPS before using it.</p></article><article class='card'><h2>HTTPS checklist</h2><p class='muted'>For a public server, put this panel behind a trusted HTTPS reverse proxy, use a firewall allow-list, and keep a unique administrator password.</p><p class='muted'>Current panel process: <span class='pill'>ddk-vps-manager.service</span></p></article></div>"""
        self.send_html(self.page("Settings", content, user, "settings"))

    def save_settings(self, user: Dict[str, Any], form: Dict[str, str]) -> None:
        if not self.require_super_admin(user):
            return
        domain = form.get("domain", "").strip()
        port = form.get("port", "").strip()
        if not re.fullmatch(r"[A-Za-z0-9._:-]{1,253}", domain):
            self.redirect("/settings?notice=" + quote("Enter a valid domain name or IP address."))
            return
        if not re.fullmatch(r"[0-9]{2,5}", port) or not 1024 <= int(port) <= 65535:
            self.redirect("/settings?notice=" + quote("Choose a port from 1024 to 65535."))
            return
        set_setting("domain", domain)
        set_setting("port", port)
        audit(user["username"], "settings_update", f"Panel address changed to {domain}:{port}", self.client_address[0])
        self.redirect("/settings?notice=" + quote("Saved. Restart DDK VPS Manager from the VPS menu to use a new port."))

    def save_python_proxy_port(self, user: Dict[str, Any], form: Dict[str, str]) -> None:
        if not self.require_super_admin(user):
            return
        port = form.get("port", "").strip()
        if not re.fullmatch(r"[0-9]{2,5}", port) or not 1024 <= int(port) <= 65535:
            self.redirect("/services?notice=" + quote("Choose a Python proxy port from 1024 to 65535."))
            return
        proxy_file = DATA_DIR / "python-proxy.env"
        proxy_file.write_text(f"DDK_VPS_MANAGER_PROXY_PORT={port}\\n", encoding="utf-8")
        os.chmod(proxy_file, 0o600)
        set_setting("python_proxy_port", port)
        state = service_state("ddk-vps-manager-python-proxy")
        if state == "running":
            command(["systemctl", "restart", "ddk-vps-manager-python-proxy"], timeout=15)
            outcome = "saved and the running service was restarted"
        else:
            outcome = "saved; start the optional service when it is installed"
        audit(user["username"], "python_proxy_port", f"Python proxy port set to {port}", self.client_address[0])
        self.redirect("/services?notice=" + quote(f"Python proxy port {outcome}."))

    def admins_page(self, user: Dict[str, Any]) -> None:
        with connection() as db:
            users = db.execute("SELECT username, role, created_at FROM users ORDER BY id").fetchall()
        rows = "".join(f"<tr><td><b>{esc(row['username'])}</b></td><td><span class='pill'>{esc(row['role'])}</span></td><td>{esc(fmt_time(row['created_at']))}</td></tr>" for row in users)
        csrf = self.csrf(user)
        if user["role"] == "super_admin":
            create_card = f"""<article class='card'><h2>Add panel login</h2><form method='post' action='/admin-create'><input type='hidden' name='csrf' value='{csrf}'><div class='form-grid'><label>Username<input name='username' maxlength='32' required></label><label>Role<select name='role'><option value='viewer'>Viewer</option><option value='admin'>Admin</option></select></label><label>Password<input name='password' type='password' minlength='12' required></label></div><div class='button-row' style='margin-top:16px'><button class='button'>Create login</button></div></form><p class='muted'>Viewers can see status. Admin roles are reserved for later account-management modules. Only super admins can control services.</p></article>"""
        else:
            create_card = "<article class='card'><h2>Roles</h2><p class='muted'>Only a super administrator can create panel logins.</p></article>"
        content = f"""{self.notice()}<div class='title-row'><div><h1>Panel admins</h1><div class='muted'>Access is stored on this VPS only.</div></div></div><div class='grid two'>{create_card}<article class='card'><h2>Existing logins</h2><div class='table-wrap'><table class='table'><thead><tr><th>Username</th><th>Role</th><th>Created</th></tr></thead><tbody>{rows}</tbody></table></div></article></div>"""
        self.send_html(self.page("Panel admins", content, user, "admins"))

    def admin_create(self, user: Dict[str, Any], form: Dict[str, str]) -> None:
        if not self.require_super_admin(user):
            return
        username = form.get("username", "").strip()
        password = form.get("password", "")
        role = form.get("role", "viewer")
        if not re.fullmatch(r"[A-Za-z0-9_.-]{3,32}", username):
            self.redirect("/admins?notice=" + quote("Username must be 3-32 safe characters."))
            return
        if len(password) < 12 or role not in {"viewer", "admin"}:
            self.redirect("/admins?notice=" + quote("Use a 12-character password and a valid role."))
            return
        try:
            create_user(username, password, role)
        except sqlite3.IntegrityError:
            self.redirect("/admins?notice=" + quote("That username already exists."))
            return
        audit(user["username"], "admin_create", f"Created {role} login {username}", self.client_address[0])
        self.redirect("/admins?notice=" + quote(f"Created login for {username}."))

    def activity_page(self, user: Dict[str, Any]) -> None:
        with connection() as db:
            rows = db.execute("SELECT created_at, username, action, detail, remote_addr FROM audit_log ORDER BY id DESC LIMIT 100").fetchall()
        table = "".join(f"<tr><td>{esc(fmt_time(row['created_at']))}</td><td>{esc(row['username'])}</td><td>{esc(row['action'])}</td><td>{esc(row['detail'])}</td><td>{esc(row['remote_addr'])}</td></tr>" for row in rows) or "<tr><td colspan='5' class='muted'>No activity recorded yet.</td></tr>"
        content = f"""<div class='title-row'><div><h1>Activity log</h1><div class='muted'>The latest 100 panel actions. Passwords and tokens are never recorded.</div></div></div><article class='card'><div class='table-wrap'><table class='table'><thead><tr><th>Time</th><th>User</th><th>Action</th><th>Detail</th><th>IP</th></tr></thead><tbody>{table}</tbody></table></div></article>"""
        self.send_html(self.page("Activity log", content, user, "activity"))


def serve() -> int:
    setup_database()
    port = int(get_setting("port", "9090"))
    host = os.environ.get("DDK_VPS_MANAGER_BIND", "0.0.0.0")
    server = ThreadingHTTPServer((host, port), PanelHandler)
    print(f"DDK VPS Manager listening on {host}:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="DDK VPS Manager")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--initialize", action="store_true")
    mode.add_argument("--serve", action="store_true")
    parser.add_argument("--admin-user")
    parser.add_argument("--admin-password")
    parser.add_argument("--domain")
    parser.add_argument("--port")
    args = parser.parse_args()
    if args.initialize:
        missing = [name for name, value in (("--admin-user", args.admin_user), ("--admin-password", args.admin_password), ("--domain", args.domain), ("--port", args.port)) if not value]
        if missing:
            parser.error("Missing " + ", ".join(missing))
        return initialize(args.admin_user, args.admin_password, args.domain, args.port)
    return serve()


if __name__ == "__main__":
    raise SystemExit(main())

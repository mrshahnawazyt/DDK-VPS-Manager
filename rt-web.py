#!/usr/bin/env python3
# ==============================================================================
# DDK VPS Manager Web Panel  (rt-web)
#   Browser se SSH + Xray (VMess/VLESS/Trojan) accounts, Running Services aur
#   Settings manage karein. Sirf Python3 standard library (pip ki zaroorat nahi).
#   Saare kaam menu.sh ke apne functions se hote hain (". menu.sh --lib"),
#   bilkul Telegram bot ki tarah -> limits / expiry / xray sync wahi rehte hain.
#
#   Config : /etc/ddkvps/web.conf   (install-web.sh banata hai)
#   Service: systemctl status rt-web
# ==============================================================================
import os, sys, re, json, time, hmac, hashlib, secrets, subprocess, threading, ssl, shutil, socket
import urllib.request, urllib.parse
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

VERSION = "1.6"
CONF_FILE = os.environ.get("RT_WEB_CONF", "/etc/ddkvps/web.conf")

# ---- paths (menu.sh jaise) -----------------------------------------------------
STATE_DIR = "/var/lib/ddkvps"
LIM_DIR = STATE_DIR + "/limits"
USE_DIR = STATE_DIR + "/usage"
LCK_DIR = STATE_DIR + "/locked"
IPLCK_DIR = STATE_DIR + "/iplocked"
EXPIRY_DIR = STATE_DIR + "/expiry"
EXLCK_DIR = STATE_DIR + "/explocked"
DIS_DIR = STATE_DIR + "/disabled"       # manual lock (power button)
LIVE_FILE = "/run/ddkvps/live.txt"
DOMAIN_FILE = "/etc/ddkvps/domain.conf"
BANNER_FILE = "/etc/issue.net"
QOS_CONF = "/etc/ddkvps/qos.conf"
QOS_CAP_FILE = "/etc/ddkvps/qos-caps.conf"
XR_DIR = STATE_DIR + "/xray"
XR_DB = {"vless": XR_DIR + "/vless.db", "trojan": XR_DIR + "/trojan.db", "vmess": XR_DIR + "/vmess.db"}
XR_USE = XR_DIR + "/usage"
XR_LOCK = XR_DIR + "/iplock"
XR_DIS = XR_DIR + "/disabled"           # <proto>_<user> : manual lock
XR_CONF = "/usr/local/etc/xray/config.json"
XR_LOG = "/var/log/xray/access.log"
XR_IP_WINDOW = 20      # menu.sh jaisa: pichhle 20 second me active IP = connected
GIB = 1073741824
BANNER_MAX = 2000
BOT_CONF = "/etc/ddkvps/bot.conf"
BOT_ADMF = "/etc/ddkvps/bot.admins"   # ID|label|date (rt-bot har update par padhta hai)
BOT_BIN = "/usr/local/bin/rt-bot"
SPEED_HIST = STATE_DIR + "/speedtest.json"   # web panel speedtest history (last 15)
RE_TG_TOKEN = re.compile(r"^[0-9]{5,15}:[A-Za-z0-9_-]{30,64}$")
RE_TG_CHAT = re.compile(r"^-?[0-9]{1,20}$")
RE_TG_ID = re.compile(r"^[0-9]{5,15}$")

SERVICES = [
    ("haproxy", "HAProxy (public 80/443)"),
    ("nginx", "Nginx (TLS / WS)"),
    ("dropbear", "Dropbear SSH"),
    ("ws-proxy", "WS Proxy (SSH-WS)"),
    ("rt-monitor", "SSH Limit Monitor"),
    ("xray", "Xray Core"),
    ("xray-monitor", "Xray Monitor"),
    ("rt-qos", "Ping QoS"),
    ("rt-bot", "Telegram Bot"),
    ("rt-web", "Web Panel"),
]
SERVICE_NAMES = {s for s, _ in SERVICES}
PROTOS = ("vmess", "vless", "trojan")

RE_USER = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_-]{0,30}$")
RE_PANEL_USER = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$")
RE_NUM = re.compile(r"^[0-9]{1,6}$")
RE_DAYS = re.compile(r"^0*[1-9][0-9]{0,4}$")
RE_DOMAIN = re.compile(r"^[A-Za-z0-9.-]{1,253}$")
RE_IP = re.compile(r"^[0-9a-fA-F.:]{2,45}$")
RE_IFACE = re.compile(r"^[A-Za-z0-9_.@-]{1,15}$")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[()][A-Za-z0-9]|\x1b[=>]")
CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")


# ---- config ---------------------------------------------------------------------
def load_conf():
    c = {}
    try:
        with open(CONF_FILE) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                c[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return c


def save_conf(c):
    os.makedirs(os.path.dirname(CONF_FILE), exist_ok=True)
    tmp = CONF_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write("# DDK VPS Manager web panel config (rt-web)\n")
        for k, v in c.items():
            f.write("%s=%s\n" % (k, v))
    os.chmod(tmp, 0o600)
    os.replace(tmp, CONF_FILE)


CONF = load_conf()
MENU = CONF.get("MENU_LIB", "/opt/ddkvps/menu.sh")
PORT = int(CONF.get("PORT", "9090"))
BIND = CONF.get("BIND", "0.0.0.0")
CERT = CONF.get("CERT", "/etc/haproxy/certs/domain.pem")
USE_TLS = CONF.get("TLS", "auto")
SESSION_HOURS = int(CONF.get("SESSION_HOURS", "168"))


def hash_password(pw, salt=None, it=200000):
    salt = salt or secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt.encode(), it).hex()
    return "pbkdf2$%d$%s$%s" % (it, salt, h)


def check_password(pw, stored):
    try:
        _, it, salt, h = stored.split("$")
        return hmac.compare_digest(hash_password(pw, salt, int(it)).split("$")[3], h)
    except Exception:
        return False


def secret_key():
    s = CONF.get("WEB_SECRET")
    if not s:
        s = secrets.token_hex(32)
        CONF["WEB_SECRET"] = s
        save_conf(CONF)
    return s.encode()


# ---- panel admins (multi-login) -------------------------------------------------
USERS_FILE = "/etc/ddkvps/web.users"
AUDIT_FILE = "/var/lib/ddkvps/web-audit.log"
ROLES = {"viewer": 0, "admin": 1, "super": 2}
ROLE_NAMES = {"viewer": "Viewer", "admin": "Admin", "super": "Super Admin"}
USERS_LOCK = threading.RLock()
AUDIT_LOCK = threading.Lock()


def save_users(lst):
    d = os.path.dirname(USERS_FILE)
    os.makedirs(d, exist_ok=True)
    tmp = USERS_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(lst, f, indent=1)
    os.chmod(tmp, 0o600)
    os.replace(tmp, USERS_FILE)


def load_users():
    with USERS_LOCK:
        try:
            with open(USERS_FILE) as f:
                lst = json.load(f)
            if isinstance(lst, list):
                return [u for u in lst if isinstance(u, dict) and u.get("user")]
        except FileNotFoundError:
            pass
        except Exception:
            return []
        # purane version (sirf web.conf mein ek login) se migrate
        if CONF.get("WEB_PASS"):
            lst = [{"user": CONF.get("WEB_USER", "admin"), "pass": CONF["WEB_PASS"], "role": "super",
                    "created": int(time.time()), "sess": secrets.token_hex(8)}]
            try:
                save_users(lst)
            except Exception:
                pass
            return lst
        return []


LOGIN_FILE = "/etc/ddkvps/web.login"   # terminal menu ke liye: line1 = Super Admin user, line2 = password (root-only)


def login_file_sync(name, pw):
    """Panel se password badla aur wo user terminal menu wala login hai -> web.login bhi update (menu sahi password dikhaye)."""
    try:
        with open(LOGIN_FILE) as f:
            cur = f.readline().rstrip("\n")
        if cur != name:
            return
        tmp = LOGIN_FILE + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write("%s\n%s\n" % (name, pw))
        os.replace(tmp, LOGIN_FILE)
    except Exception:
        pass


def find_user(lst, name):
    for u in lst:
        if u.get("user") == name:
            return u
    return None


def active_supers(lst):
    return [u for u in lst if u.get("role") == "super" and not u.get("disabled")]


def public_user(u):
    return {"user": u["user"], "role": u.get("role", "viewer"), "disabled": bool(u.get("disabled")),
            "scope": user_scope(u), "max_acc": int(u.get("max_acc") or 0),
            "created": u.get("created"), "last_login": u.get("last_login"), "last_ip": u.get("last_ip"),
            "note": u.get("note", "")}


def make_token(u):
    exp = int(time.time()) + SESSION_HOURS * 3600
    msg = "%s.%d.%s" % (u["user"], exp, u.get("sess", ""))
    sig = hmac.new(secret_key(), msg.encode(), hashlib.sha256).hexdigest()
    return "%s.%s" % (msg, sig)


def valid_token(tok):
    """Sahi token par user dict wapas, warna None."""
    try:
        user, exp, sess, sig = tok.split(".")
        msg = "%s.%s.%s" % (user, exp, sess)
        good = hmac.new(secret_key(), msg.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, good) or int(exp) < time.time():
            return None
        u = find_user(load_users(), user)
        if not u or u.get("disabled") or not hmac.compare_digest(str(u.get("sess", "")), sess):
            return None
        return u
    except Exception:
        return None


def audit(user, ip, what, detail=""):
    rec = {"t": int(time.time()), "user": user or "-", "ip": ip or "-", "what": what, "detail": detail}
    try:
        with AUDIT_LOCK:
            os.makedirs(os.path.dirname(AUDIT_FILE), exist_ok=True)
            with open(AUDIT_FILE, "a") as f:
                f.write(json.dumps(rec) + "\n")
            if os.path.getsize(AUDIT_FILE) > 1024 * 1024:
                with open(AUDIT_FILE) as f:
                    lines = f.readlines()[-2000:]
                with open(AUDIT_FILE, "w") as f:
                    f.writelines(lines)
            os.chmod(AUDIT_FILE, 0o600)
    except Exception:
        pass


def audit_tail(n=300):
    try:
        with open(AUDIT_FILE) as f:
            lines = f.readlines()[-n:]
    except Exception:
        return []
    out = []
    for ln in reversed(lines):
        try:
            out.append(json.loads(ln))
        except Exception:
            pass
    return out


def safe_params(p):
    out = []
    if not isinstance(p, dict):
        return ""
    for k, v in p.items():
        if re.search(r"pass|token|secret|banner|text", str(k), re.I):
            continue
        out.append("%s=%s" % (k, str(v)[:60]))
    return " ".join(out)[:300]


# ---- reseller mode: account ownership ----------------------------------------------
OWNERS_FILE = "/var/lib/ddkvps/web-owners.json"
OWN_LOCK = threading.RLock()
KINDS = ("ssh",) + PROTOS
# reseller (scope=own) sirf ye kaam kar sakta hai, aur sirf apne accounts par
SCOPED_OK = {"ssh_create", "ssh_delete", "ssh_renew", "ssh_limits", "ssh_reset", "ssh_lock", "ssh_unlock",
             "x_create", "x_delete", "x_renew", "x_limits", "x_reset", "x_lock", "x_unlock", "x_links", "status"}


def user_scope(u):
    """Admin default: sirf apne accounts ("own"). Super / viewer hamesha "all"."""
    if u.get("role") != "admin":
        return "all"
    return "all" if u.get("scope") == "all" else "own"


def is_scoped(me):
    return bool(me) and user_scope(me) == "own"


def load_owners():
    with OWN_LOCK:
        try:
            with open(OWNERS_FILE) as f:
                o = json.load(f)
        except Exception:
            o = {}
        if not isinstance(o, dict):
            o = {}
        for k in KINDS:
            if not isinstance(o.get(k), dict):
                o[k] = {}
        return o


def save_owners(o):
    with OWN_LOCK:
        os.makedirs(os.path.dirname(OWNERS_FILE), exist_ok=True)
        tmp = OWNERS_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(o, f, indent=1)
        os.chmod(tmp, 0o600)
        os.replace(tmp, OWNERS_FILE)


def set_owner(kind, name, owner, only_if_absent=False):
    with OWN_LOCK:
        o = load_owners()
        if only_if_absent and o[kind].get(name):
            return False
        if owner:
            o[kind][name] = owner
        else:
            o[kind].pop(name, None)
        save_owners(o)
        return True


def account_names(kind):
    if kind == "ssh":
        return {u["user"] for u in ssh_users()}
    return {u["user"] for u in xray_users(kind)}


def owned_counts():
    """login -> kitne (maujood) accounts us ke naam hain"""
    o = load_owners(); cnt = {}
    for k in KINDS:
        live = account_names(k)
        for n, w in o[k].items():
            if n in live:
                cnt[w] = cnt.get(w, 0) + 1
    return cnt


def kind_of(act, params):
    if act.startswith("ssh_"):
        return "ssh"
    p = str((params or {}).get("proto", ""))
    return p if p in PROTOS else None


PENDING = {}   # login -> kitne create jobs abhi chal rahe hain (quota ke liye)


def create_done(kind, name, owner):
    def cb(job):
        with OWN_LOCK:
            PENDING[owner] = max(0, PENDING.get(owner, 1) - 1)
        if name in account_names(kind):
            if set_owner(kind, name, owner, only_if_absent=True):
                job["raw"] += "\n(Owner: %s)\n" % owner
    return cb


def delete_done(kind, name):
    def cb(job):
        if name not in account_names(kind):
            set_owner(kind, name, None)
    return cb


# viewer=0 sirf dekh sakta hai, admin=1 accounts/services, super=2 sab kuch
ACTION_ROLE = {
    "ssh_connected": 0, "x_connected": 0, "x_links": 0, "status": 0, "svc_logs": 0, "qos_status": 0,
    "ssh_create": 1, "ssh_delete": 1, "ssh_renew": 1, "ssh_limits": 1, "ssh_reset": 1, "ssh_lock": 1, "ssh_unlock": 1,
    "x_create": 1, "x_delete": 1, "x_renew": 1, "x_limits": 1, "x_reset": 1, "x_lock": 1, "x_unlock": 1,
    "svc": 1, "restart_all": 1, "banner": 1, "speedtest": 1,
}   # baaki sab (domain, ssl, qos, fix, install, bot ...) = super


def admin_op(me, data):
    """Super admin ke liye panel logins manage karna. (message, kya_khud_ka_session_badla)"""
    op = str(data.get("op", ""))
    name = str(data.get("user", "")).strip()
    if not RE_USER.match(name):
        raise ValueError("Username galat (sirf a-z 0-9 _ - , max 31)")
    with USERS_LOCK:
        lst = load_users()
        u = find_user(lst, name)
        if op == "add":
            if u:
                raise ValueError("Ye username pehle se maujood hai")
            pw = str(data.get("password", ""))
            role = str(data.get("role", "admin"))
            if len(pw) < 6:
                raise ValueError("Password kam se kam 6 akshar")
            if role not in ROLES:
                raise ValueError("Role galat")
            if len(lst) >= 50:
                raise ValueError("Zyada se zyada 50 logins")
            lst.append({"user": name, "pass": hash_password(pw), "role": role, "created": int(time.time()),
                        "sess": secrets.token_hex(8), "note": str(data.get("note", ""))[:60],
                        "by": me["user"], "scope": "all" if data.get("scope") == "all" else "own",
                        "max_acc": parse_max(data.get("max_acc"))})
            save_users(lst)
            return "%s (%s) add ho gaya" % (name, ROLE_NAMES[role])
        if not u:
            raise ValueError("Ye login nahi mila")
        self_ = name == me["user"]
        if op == "delete":
            if self_:
                raise ValueError("Apna login delete nahi kar sakte")
            if u.get("role") == "super" and not u.get("disabled") and len(active_supers(lst)) <= 1:
                raise ValueError("Kam se kam ek Super Admin rehna zaroori hai")
            lst.remove(u)
            save_users(lst)
            with OWN_LOCK:   # us ke accounts ab kisi ke naam nahi (Super Admin dekh sakta hai)
                o = load_owners()
                for k in KINDS:
                    o[k] = {n: w for n, w in o[k].items() if w != name}
                save_owners(o)
            return "%s delete ho gaya" % name
        if op == "update":
            changed = []
            if "role" in data and data["role"] != u.get("role"):
                role = str(data["role"])
                if role not in ROLES:
                    raise ValueError("Role galat")
                if self_:
                    raise ValueError("Apna role khud nahi badal sakte")
                if u.get("role") == "super" and not u.get("disabled") and len(active_supers(lst)) <= 1:
                    raise ValueError("Kam se kam ek Super Admin rehna zaroori hai")
                u["role"] = role
                changed.append("role=" + role)
            if "disabled" in data and bool(data["disabled"]) != bool(u.get("disabled")):
                if self_:
                    raise ValueError("Apna login khud disable nahi kar sakte")
                if data["disabled"] and u.get("role") == "super" and len(active_supers(lst)) <= 1:
                    raise ValueError("Kam se kam ek Super Admin rehna zaroori hai")
                u["disabled"] = bool(data["disabled"])
                changed.append("disabled" if u["disabled"] else "enabled")
            if data.get("password"):
                pw = str(data["password"])
                if len(pw) < 6:
                    raise ValueError("Password kam se kam 6 akshar")
                u["pass"] = hash_password(pw)
                login_file_sync(name, pw)
                changed.append("password reset")
            if "scope" in data:
                sc = "all" if data["scope"] == "all" else "own"
                if sc != (u.get("scope") or "own"):
                    u["scope"] = sc
                    changed.append("scope=" + sc)
            if "max_acc" in data:
                mx = parse_max(data["max_acc"])
                if mx != int(u.get("max_acc") or 0):
                    u["max_acc"] = mx
                    changed.append("max_acc=%d" % mx)
            if "note" in data:
                u["note"] = str(data["note"])[:60]
            if not changed and "note" not in data:
                raise ValueError("Kuch badla nahi")
            if any(c.startswith(("role", "disabled", "password")) for c in changed):
                u["sess"] = secrets.token_hex(8)   # us user ke purane sessions khatam
            save_users(lst)
            return "%s update: %s" % (name, ", ".join(changed) or "note")
    raise ValueError("op galat")


def parse_max(v):
    try:
        n = int(str(v or "0").strip() or 0)
    except ValueError:
        raise ValueError("Max accounts sirf number")
    if n < 0 or n > 100000:
        raise ValueError("Max accounts 0-100000")
    return n


def set_user_cli(argv):
    """rt-web.py --set-user NAME [--role super]  (password stdin se)"""
    name = argv[argv.index("--set-user") + 1] if len(argv) > argv.index("--set-user") + 1 else ""
    role = argv[argv.index("--role") + 1] if "--role" in argv and len(argv) > argv.index("--role") + 1 else "super"
    if not RE_USER.match(name) or role not in ROLES:
        print("Username ya role galat"); sys.exit(2)
    pw = sys.stdin.readline().rstrip("\n")
    if len(pw) < 6:
        print("Password kam se kam 6 akshar"); sys.exit(2)
    with USERS_LOCK:
        lst = load_users()
        u = find_user(lst, name)
        if not u:
            u = {"user": name, "created": int(time.time())}
            lst.append(u)
        u.update({"pass": hash_password(pw), "role": role, "disabled": False, "sess": secrets.token_hex(8)})
        save_users(lst)
    audit("cli", "local", "set-user", "%s role=%s" % (name, role))
    print("OK: %s (%s)" % (name, role))


def check_user_cli(argv):
    """rt-web.py --check-user NAME  (password stdin se) -> exit 0 = sahi, 1 = galat / user nahi"""
    i = argv.index("--check-user")
    name = argv[i + 1] if len(argv) > i + 1 else ""
    pw = sys.stdin.readline().rstrip("\n")
    u = find_user(load_users(), name)
    sys.exit(0 if u and not u.get("disabled") and check_password(pw, u.get("pass", "")) else 1)


def del_user_cli(argv):
    """rt-web.py --del-user NAME  (aakhri active Super Admin delete nahi hota)"""
    i = argv.index("--del-user")
    name = argv[i + 1] if len(argv) > i + 1 else ""
    with USERS_LOCK:
        lst = load_users()
        u = find_user(lst, name)
        if not u:
            print("User nahi mila: %s" % name); sys.exit(1)
        if u.get("role") == "super" and not u.get("disabled") and len(active_supers(lst)) <= 1:
            print("Kam se kam ek Super Admin rehna zaroori hai"); sys.exit(2)
        lst.remove(u)
        save_users(lst)
    audit("cli", "local", "del-user", name)
    print("OK: %s delete" % name)


FAILS = {}  # ip -> [timestamps]


def login_blocked(ip):
    now = time.time()
    FAILS[ip] = [t for t in FAILS.get(ip, []) if now - t < 600]
    return len(FAILS[ip]) >= 6


# ---- small helpers -----------------------------------------------------------------
def clean(s):
    return CTRL.sub("", ANSI.sub("", s.replace("\r\n", "\n").replace("\r", "\n")))


def read_first(path, default=""):
    try:
        with open(path) as f:
            return f.readline().strip()
    except Exception:
        return default


def read_int(path):
    parts = read_first(path, "").split()
    v = re.sub(r"[^0-9]", "", parts[0]) if parts else ""
    return int(v or 0)


def get_domain():
    d = read_first(DOMAIN_FILE)
    return d or "No Domain Set"


def run(cmd, timeout=20):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        return p.returncode, p.stdout.decode(errors="replace")
    except Exception as e:
        return 1, str(e)


def fmt_epoch(ep):
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(ep)) if ep else "never"


# ---- jobs (menu.sh functions background me) ----------------------------------------------
JOBS = {}
MUT_LOCK = threading.Lock()
BOT_LOCK = threading.Lock()
def suite_ver():
    """menu.sh ka RT_SUITE_VER (terminal Deploy Suite ke saath same version badge)"""
    try:
        with open(MENU, errors="replace") as f:
            m = re.search(r'^RT_SUITE_VER="([^"]+)"', f.read(), re.M)
        return m.group(1) if m else "7.0"
    except Exception:
        return "7.0"


PRELUDE = ('. "$RT_MENU" --lib >/dev/null 2>&1 || { echo "menu.sh load nahi hua: $RT_MENU"; exit 1; }\n'
           'press_any_key(){ :; }\nclear(){ :; }\n')


def bash_cmd(body, args):
    return ["bash", "-c", PRELUDE + body, "rt-web"] + [str(a) for a in args]


def start_job(title, cmd, mutating=True, timeout=600, extra_env=None, on_done=None):
    for k in [k for k, j in JOBS.items() if j["done"] and time.time() - j["t"] > 3600]:
        JOBS.pop(k, None)
    jid = secrets.token_hex(8)
    job = {"title": title, "raw": "", "done": False, "rc": None, "t": time.time()}
    JOBS[jid] = job
    env = dict(os.environ, RT_MENU=MENU, TERM="dumb", COLUMNS="110", LANG="C.UTF-8", LC_ALL="C.UTF-8",
               DEBIAN_FRONTEND="noninteractive", RT_WEB_UI="1")   # RT_WEB_UI: menu.sh Deploy Suite markers (::rt:...)
    if extra_env:
        env.update(extra_env)

    def worker():
        lock = MUT_LOCK if mutating else None
        if lock:
            if not lock.acquire(blocking=False):
                job["raw"] += "(dusra kaam chal raha hai, intezar...)\n"
                lock.acquire()
        try:
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                 env=env, start_new_session=True)
            killer = threading.Timer(timeout, lambda: p.kill())
            killer.start()
            try:
                while True:
                    chunk = p.stdout.read1(4096) if hasattr(p.stdout, "read1") else p.stdout.read(4096)
                    if not chunk:
                        break
                    job["raw"] += chunk.decode(errors="replace")
                    if len(job["raw"]) > 400000:
                        # Deploy Suite markers (::rt:...) bachao - inhi se browser me progress dashboard banta hai
                        cut = job["raw"][:-300000]
                        keep = "".join(l + "\n" for l in cut.split("\n") if l.startswith("::rt:"))
                        job["raw"] = keep + "...(purana output kaata gaya)...\n" + job["raw"][-300000:]
                p.wait()
            finally:
                killer.cancel()
            job["rc"] = p.returncode
        except Exception as e:
            job["raw"] += "\nERROR: %s\n" % e
            job["rc"] = 1
        finally:
            if on_done:
                try:
                    on_done(job)
                except Exception as e:
                    job["raw"] += "\n(result save nahi hua: %s)\n" % e
            job["done"] = True
            if lock:
                lock.release()

    threading.Thread(target=worker, daemon=True).start()
    return jid


def P(params, key, rx=None, required=True, maxlen=64, default=""):
    v = params.get(key)
    v = "" if v is None else str(v)
    if key not in ("password", "banner"):
        v = v.strip()
    if not v:
        v = default
    if not v and not required:
        return ""
    if not v:
        raise ValueError("'%s' khaali nahi ho sakta" % key)
    if len(v) > maxlen:
        raise ValueError("'%s' bahut lamba hai" % key)
    if rx is not None and not rx.match(v):
        raise ValueError("'%s' galat hai: %s" % (key, v))
    return v


def proto_of(params):
    p = str(params.get("proto", "")).lower()
    if p not in PROTOS:
        raise ValueError("protocol galat")
    return p


def yn(params, key):
    return "y" if str(params.get(key, "")).lower() in ("y", "yes", "1", "true", "on") else "n"


# ---- VPS stats / speedtest ------------------------------------------------------
SPEED_RUNNING = {"on": False}
_GEO = {"t": 0, "v": None}


PING_MAX_MS = 10000   # isse zyada = speedtest-cli ka latency test fail hua (wo 1800000 ms likh deta hai)


def _ping_ok(v):
    try:
        return v is not None and 0 < float(v) < PING_MAX_MS
    except (TypeError, ValueError):
        return False


def speed_history():
    try:
        with open(SPEED_HIST) as f:
            h = json.load(f)
        if not isinstance(h, list):
            return []
        for r in h:
            if isinstance(r, dict) and "ping" in r and not _ping_ok(r["ping"]):
                r["ping"] = None   # purane ghalat (1800000 ms) record "-" dikhenge
        return [r for r in h if isinstance(r, dict)]
    except Exception:
        return []


def speed_parse(out):
    r = {}
    for key, rx in (("ping", r"(?:Ping:|\]:)\s*([\d.]+)\s*ms"), ("down", r"Download:\s*([\d.]+)\s*Mbit/s"), ("up", r"Upload:\s*([\d.]+)\s*Mbit/s")):
        m = re.search(rx, out)
        if m:
            r[key] = float(m.group(1))
    if "ping" in r and not _ping_ok(r["ping"]):
        r["ping"] = None
    m = re.search(r"Hosted by (.+?) \[([\d.]+ km)\]", out)
    if m:
        r["server"] = m.group(1).strip() + " (" + m.group(2) + ")"
    return r


# speedtest-cli ka latency test (khaaskar --secure me) aksar fail hota hai -> ping 1800000 ms aur server bhi
# ghalat (door wala) chun leta hai. Ye helper paas ke 5 servers ka asli TCP ping napta hai, sab se tez
# server chunta hai, phir download / upload karta hai. Output speedtest-cli jaisa hi (speed_parse ke liye).
SPEED_PY = r"""
import socket, statistics, subprocess, sys, time, re
try:
    import speedtest
except Exception:
    sys.exit(3)

def tcp_ping(host, n=5):
    h, _, port = host.rpartition(":")
    if not h:
        h, port = host, "8080"
    v = []
    for _ in range(n):
        try:
            t = time.perf_counter()
            c = socket.create_connection((h, int(port)), timeout=3)
            v.append((time.perf_counter() - t) * 1000.0)
            c.close()
        except Exception:
            pass
        time.sleep(0.15)
    return statistics.median(v) if v else None

def icmp_ping(host):
    try:
        o = subprocess.run(["ping", "-c", "4", "-W", "2", host.rpartition(":")[0] or host],
                           capture_output=True, text=True, timeout=15).stdout
        m = re.search(r"= [\d.]+/([\d.]+)/", o)
        return float(m.group(1)) if m else None
    except Exception:
        return None

def run(secure):
    s = speedtest.Speedtest(secure=secure)
    print("Servers dhoond raha hai (%s)..." % ("https" if secure else "http"), flush=True)
    s.get_servers()
    near = s.get_closest_servers(limit=5)
    cands = []
    for srv in near:
        p = tcp_ping(srv["host"], 3)
        if p is not None:
            cands.append((p, srv))
    if cands:
        cands.sort(key=lambda x: x[0])
        best = cands[0][1]
        ping = tcp_ping(best["host"], 7) or cands[0][0]
    else:
        best = s.get_best_server()
        ping = s.results.ping if 0 < s.results.ping < 10000 else icmp_ping(best["host"])
    best["latency"] = ping
    s._best.update(best)
    s.results.server = best
    s.results.ping = ping or 0
    print("Hosted by %s (%s) [%0.2f km]: %s ms" % (best.get("sponsor", "?"), best.get("name", "?"), float(best.get("d", 0)),
          ("%.1f" % ping) if ping else "-"), flush=True)
    print("Download test chal raha hai...", flush=True)
    s.download()
    print("Download: %0.2f Mbit/s" % (s.results.download / 1e6), flush=True)
    print("Upload test chal raha hai...", flush=True)
    s.upload(pre_allocate=False)
    print("Upload: %0.2f Mbit/s" % (s.results.upload / 1e6), flush=True)

try:
    run(True)
except Exception as e:
    print("(https mode fail: %s -> http mode try kar raha hai...)" % e, flush=True)
    try:
        run(False)
    except Exception as e2:
        print("Speedtest fail: %s" % e2, flush=True)
        sys.exit(1)
"""


def speed_done(job):
    SPEED_RUNNING["on"] = False
    r = speed_parse(clean(job["raw"]))
    if "down" in r and "up" in r:
        r["t"] = int(time.time())
        h = ([r] + speed_history())[:15]
        os.makedirs(os.path.dirname(SPEED_HIST), exist_ok=True)
        with open(SPEED_HIST, "w") as f:
            json.dump(h, f)


def live_stats():
    mem = {}
    try:
        for line in open("/proc/meminfo"):
            k, v = line.split(":", 1); mem[k] = int(v.split()[0]) * 1024
    except Exception:
        pass
    n = net_stats()
    return {"t": time.time(), "cpu": cpu_percent(), "load": list(os.getloadavg()),
            "mem_total": mem.get("MemTotal", 0), "mem_used": mem.get("MemTotal", 0) - mem.get("MemAvailable", 0),
            "swap_total": mem.get("SwapTotal", 0), "swap_used": mem.get("SwapTotal", 0) - mem.get("SwapFree", 0),
            "rx_rate": n["rx_rate"], "tx_rate": n["tx_rate"], "speedtest_running": SPEED_RUNNING["on"]}


def public_geo():
    if _GEO["v"] and time.time() - _GEO["t"] < 3600:
        return _GEO["v"]
    v = {}
    try:
        with urllib.request.urlopen("https://ipinfo.io/json", timeout=5) as r:
            j = json.loads(r.read().decode())
        v = {k: j.get(k, "") for k in ("ip", "city", "region", "country", "org")}
    except Exception:
        pass
    if v:
        _GEO.update(t=time.time(), v=v)
    return v


def vnstat_info():
    if not shutil.which("vnstat"):
        return {"installed": False}
    rc, out = run(["vnstat", "--json"], timeout=10)
    res = {"installed": True, "interfaces": []}
    try:
        j = json.loads(out)
    except Exception:
        res["error"] = out.strip()[:300]
        return res
    v1 = str(j.get("jsonversion", "2")) == "1"
    mul = 1024 if v1 else 1
    for itf in j.get("interfaces", []):
        name = itf.get("name") or itf.get("id") or ""
        tr = itf.get("traffic", {})
        months = tr.get("months" if v1 else "month", []) or []
        days = tr.get("days" if v1 else "day", []) or []
        def fmt(e, kind):
            d = e.get("date", {})
            lbl = "%04d-%02d" % (d.get("year", 0), d.get("month", 0))
            if kind == "day":
                lbl += "-%02d" % d.get("day", 0)
            return {"label": lbl, "rx": int(e.get("rx", 0)) * mul, "tx": int(e.get("tx", 0)) * mul}
        mo = sorted([fmt(e, "m") for e in months], key=lambda x: x["label"], reverse=True)[:12]
        dy = sorted([fmt(e, "day") for e in days], key=lambda x: x["label"], reverse=True)[:14]
        tot = tr.get("total", {})
        res["interfaces"].append({"name": name, "months": mo, "days": dy,
                                  "total": {"rx": int(tot.get("rx", 0)) * mul, "tx": int(tot.get("tx", 0)) * mul}})
    res["interfaces"].sort(key=lambda i: -(i["total"]["rx"] + i["total"]["tx"]))
    return res


def vps_info():
    cpu_model = ""
    try:
        for line in open("/proc/cpuinfo"):
            if line.lower().startswith("model name"):
                cpu_model = line.split(":", 1)[1].strip(); break
    except Exception:
        pass
    os_name = ""
    try:
        for line in open("/etc/os-release"):
            if line.startswith("PRETTY_NAME="):
                os_name = line.split("=", 1)[1].strip().strip('"')
    except Exception:
        pass
    _, virt = run(["systemd-detect-virt"], timeout=5)
    try:
        up = float(open("/proc/uptime").read().split()[0])
    except Exception:
        up = 0
    disks = []
    rc, out = run(["df", "-PT", "-x", "tmpfs", "-x", "devtmpfs", "-x", "squashfs", "-x", "overlay", "-x", "efivarfs"], timeout=10)
    for line in out.splitlines()[1:]:
        p = line.split()
        if len(p) >= 7 and p[2].isdigit():
            disks.append({"dev": p[0], "type": p[1], "total": int(p[2]) * 1024, "used": int(p[3]) * 1024, "mount": p[6]})
    addrs = {}
    rc, out = run(["ip", "-o", "addr", "show"], timeout=5)
    for line in out.splitlines():
        p = line.split()
        if len(p) > 3 and p[2] in ("inet", "inet6") and not p[3].startswith("fe80"):
            addrs.setdefault(p[1], []).append(p[3])
    ifaces = []
    try:
        for line in open("/proc/net/dev").read().splitlines()[2:]:
            name, data = line.split(":", 1); name = name.strip(); d = data.split()
            if name == "lo":
                continue
            ifaces.append({"name": name, "rx": int(d[0]), "tx": int(d[8]), "addr": addrs.get(name, [])})
    except Exception:
        pass
    procs = []
    rc, out = run(["ps", "-eo", "pid=,comm=,pcpu=,pmem=,rss=", "--sort=-pcpu"], timeout=5)
    for line in out.splitlines()[:12]:
        p = line.split()
        if len(p) >= 5:
            procs.append({"pid": p[0], "name": p[1], "cpu": p[2], "mem": p[3], "rss": int(p[4]) * 1024 if p[4].isdigit() else 0})
    return {"cpu_model": cpu_model, "cores": os.cpu_count(), "os": os_name, "kernel": os.uname().release,
            "arch": os.uname().machine, "virt": virt.strip() or "-", "hostname": socket.gethostname(), "uptime": int(up),
            "boot": int(time.time() - up), "geo": public_geo(), "disks": disks, "ifaces": ifaces, "procs": procs,
            "vnstat": vnstat_info(), "speed": speed_history(), "speedtest_cli": bool(shutil.which("speedtest-cli")),
            "live": live_stats()}


# ---- Telegram bot ---------------------------------------------------------------
def read_kv(path):
    c = {}
    try:
        for line in open(path):
            if "=" in line and not line.startswith("#"):
                k, v = line.rstrip("\n").split("=", 1); c[k.strip()] = v.strip()
    except Exception:
        pass
    return c


def bot_admins():
    res = []
    try:
        for line in open(BOT_ADMF):
            p = line.rstrip("\n").split("|")
            if p and RE_TG_ID.match(p[0]):
                res.append({"id": p[0], "label": p[1] if len(p) > 1 else "Admin", "date": p[2] if len(p) > 2 else ""})
    except Exception:
        pass
    return res


def write_bot_admins(rows):
    os.makedirs(os.path.dirname(BOT_ADMF), exist_ok=True)
    with open(BOT_ADMF, "w") as f:      # same inode (bot file ko seedha padhta hai)
        for r in rows:
            f.write("%s|%s|%s\n" % (r["id"], r["label"], r["date"]))
    os.chmod(BOT_ADMF, 0o600)


def tg_call(token, method, data=None, timeout=8):
    try:
        body = urllib.parse.urlencode(data).encode() if data else None
        with urllib.request.urlopen("https://api.telegram.org/bot%s/%s" % (token, method), data=body, timeout=timeout) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode())
        except Exception:
            return {"ok": False, "description": "HTTP %s" % e.code}
    except Exception as e:
        return {"ok": False, "description": str(e)}


_GETME = {}


def bot_info():
    c = read_kv(BOT_CONF)
    tok = c.get("TOKEN", "")
    name = ""
    if tok:
        k = hashlib.sha256(tok.encode()).hexdigest()
        hit = _GETME.get(k)
        if hit and time.time() - hit[0] < 600:
            name = hit[1]
        else:
            r = tg_call(tok, "getMe", timeout=5)
            name = ("@" + r["result"].get("username", "")) if r.get("ok") else ""
            if r.get("ok"):
                _GETME.clear(); _GETME[k] = (time.time(), name)
    masked = (tok.split(":")[0] + ":" + "•" * 6 + tok[-4:]) if tok else ""
    svc = [s for s in services_info() if s["name"] == "rt-bot"][0]
    return {"configured": bool(tok), "token": masked, "username": name, "super_admin": c.get("ADMIN", ""),
            "menu_lib": c.get("MENU_LIB", ""), "script": os.path.isfile(BOT_BIN), "service": svc,
            "admins": bot_admins()}


def bot_admin_op(data):
    c = read_kv(BOT_CONF)
    tok, sa = c.get("TOKEN", ""), c.get("ADMIN", "")
    op = str(data.get("op", "")); aid = str(data.get("id", "")).strip()
    if not RE_TG_ID.match(aid):
        raise ValueError("Sahi numeric Telegram ID chahiye (5-15 digits, @userinfobot se milti hai)")
    rows = bot_admins()
    note = ""
    if op == "add":
        if aid == sa:
            raise ValueError("Ye to Super Admin hi hai")
        if any(r["id"] == aid for r in rows):
            raise ValueError("Ye admin pehle se added hai")
        lb = re.sub(r"[^A-Za-z0-9 _.@-]", "", str(data.get("label", "")))[:24].strip() or "Admin"
        rows.append({"id": aid, "label": lb, "date": time.strftime("%Y-%m-%d")})
        write_bot_admins(rows)
        if data.get("notify") and tok:
            r = tg_call(tok, "sendMessage", {"chat_id": aid, "text": "✅ Aapko DDK VPS Manager bot ka Admin banaya gaya hai. /start bhejein."})
            note = " Telegram message bhej diya." if r.get("ok") else " (Telegram message nahi gaya: user ne abhi bot ko /start nahi kiya hoga.)"
        return "Admin added: %s (%s). Unhe bot ko /start bhejna hoga.%s" % (lb, aid, note)
    if op == "del":
        if not any(r["id"] == aid for r in rows):
            raise ValueError("Ye ID admin list me nahi hai")
        write_bot_admins([r for r in rows if r["id"] != aid])
        for f in ("/run/rt-bot.st." + aid, "/run/rt-bot.mid." + aid):
            try:
                os.remove(f)
            except Exception:
                pass
        if data.get("notify") and tok:
            tg_call(tok, "sendMessage", {"chat_id": aid, "text": "⛔ Aapka DDK VPS Manager bot admin access hata diya gaya hai."})
        return "Admin removed: " + aid
    raise ValueError("operation galat")


BOT_UNIT = """[Unit]
Description=DDK VPS Manager Telegram Bot
After=network-online.target
[Service]
ExecStart=/usr/local/bin/rt-bot
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
"""


def build_action(a, pr):
    """-> (title, cmd, mutating, timeout)"""
    if a == "ssh_create":
        u = P(pr, "user", RE_USER); pw = P(pr, "password", maxlen=64)
        if any(c in pw for c in ":\n\r"):
            raise ValueError("Password me ':' ya new-line nahi chalega")
        args = [u, pw, P(pr, "days", RE_DAYS), P(pr, "gb", RE_NUM, default="0"), P(pr, "ip", RE_NUM, default="0")]
        return ("SSH account: " + u, bash_cmd('printf "%s\\n" "$@" | add_user', args), True, 120)
    if a == "ssh_delete":
        u = P(pr, "user", RE_PANEL_USER)
        return ("Delete SSH: " + u, bash_cmd('printf "%s\\n" "$1" | delete_user', [u]), True, 60)
    if a == "ssh_renew":
        u = P(pr, "user", RE_PANEL_USER)
        args = [u, P(pr, "days", RE_DAYS), yn(pr, "reset")]
        return ("Renew SSH: " + u, bash_cmd('printf "%s\\n" "$@" | renew_user', args), True, 60)
    if a == "ssh_limits":
        u = P(pr, "user", RE_PANEL_USER)
        args = [u, P(pr, "gb", RE_NUM, required=False), P(pr, "ip", RE_NUM, required=False)]
        return ("Limits SSH: " + u, bash_cmd('printf "%s\\n" "$@" | edit_limits', args), True, 60)
    if a == "ssh_reset":
        u = P(pr, "user", RE_PANEL_USER)
        return ("Reset usage: " + u, bash_cmd('printf "%s\\n" "$1" | reset_usage', [u]), True, 60)
    if a in ("ssh_lock", "ssh_unlock"):
        u = P(pr, "user", RE_PANEL_USER)
        on = "1" if a == "ssh_lock" else "0"
        return (("Lock SSH: " if on == "1" else "Unlock SSH: ") + u,
                bash_cmd('ssh_set_disabled "$1" "$2" </dev/null', [u, on]), True, 60)
    if a == "ssh_connected":
        return ("SSH Connected IPs", bash_cmd("render_connected </dev/null", []), False, 60)

    if a.startswith("x_"):
        p = proto_of(pr); pl = p.upper()
        if a == "x_connected":
            return (pl + " Connected IPs", bash_cmd('xray_render_connected "$1" </dev/null', [p]), False, 60)
        u = P(pr, "user", RE_USER)
        if a == "x_create":
            args = [p, u, P(pr, "days", RE_DAYS), P(pr, "gb", RE_NUM, default="0"), P(pr, "ip", RE_NUM, default="0")]
            return (pl + " account: " + u, bash_cmd('p=$1; shift; if [[ "$p" == vmess ]]; then xray_ensure_vmess </dev/null || exit 1; fi; printf "%s\\n" "$@" | xray_create_proto "$p"', args), True, 180)
        if a == "x_delete":
            return ("Delete %s: %s" % (pl, u), bash_cmd('printf "%s\\n" "$2" | xray_delete_proto "$1"', [p, u]), True, 120)
        if a == "x_renew":
            args = [p, u, P(pr, "days", RE_DAYS), yn(pr, "reset")]
            return ("Renew %s: %s" % (pl, u), bash_cmd('p=$1; shift; printf "%s\\n" "$@" | xray_renew_proto "$p"', args), True, 120)
        if a == "x_limits":
            args = [p, u, P(pr, "gb", RE_NUM, required=False), P(pr, "ip", RE_NUM, required=False)]
            return ("Limits %s: %s" % (pl, u), bash_cmd('p=$1; shift; printf "%s\\n" "$@" | xray_edit_limits_proto "$p"', args), True, 120)
        if a == "x_reset":
            return ("Reset %s: %s" % (pl, u), bash_cmd('printf "%s\\n" "$2" | xray_reset_proto "$1"', [p, u]), True, 120)
        if a in ("x_lock", "x_unlock"):
            on = "1" if a == "x_lock" else "0"
            return (("Lock %s: %s" if on == "1" else "Unlock %s: %s") % (pl, u),
                    bash_cmd('xray_set_disabled "$1" "$2" "$3" </dev/null', [p, u, on]), True, 120)
        if a == "x_links":
            return ("%s links: %s" % (pl, u), bash_cmd('printf "%s\\n" "$2" | xray_show_links_proto "$1"', [p, u]), False, 60)

    if a == "status":
        return ("Status & Ports", bash_cmd("status_check </dev/null", []), False, 60)
    if a == "restart_all":
        return ("Restart VPN services", ["bash", "-c", "systemctl restart ws-proxy rt-monitor xray xray-monitor haproxy nginx 2>&1; echo 'Restart done.'"], True, 180)
    if a == "svc":
        name = P(pr, "name"); op = P(pr, "op")
        if name not in SERVICE_NAMES or op not in ("start", "stop", "restart", "enable", "disable"):
            raise ValueError("service / operation galat")
        if name == "rt-web":
            if op != "restart":
                raise ValueError("Web panel ko yahan se band nahi kar sakte")
            return ("Restart rt-web", ["bash", "-c", "echo 'Web panel 2 second me restart hoga, page refresh karein.'; (sleep 2; systemctl restart rt-web) >/dev/null 2>&1 &"], False, 30)
        return ("%s %s" % (op, name), ["bash", "-c", 'systemctl "$1" "$2" 2>&1 && echo "$2: $1 OK"; systemctl is-active "$2"', "rt", op, name], True, 120)
    if a == "svc_logs":
        name = P(pr, "name")
        if name not in SERVICE_NAMES:
            raise ValueError("service galat")
        return ("Logs: " + name, ["journalctl", "-u", name, "-n", "200", "--no-pager", "-o", "short-iso"], False, 30)

    # ---- vps stats ----
    if a == "speedtest":
        if SPEED_RUNNING["on"]:
            raise ValueError("Speedtest pehle se chal raha hai")
        SPEED_RUNNING["on"] = True
        body = ('if ! command -v speedtest-cli >/dev/null 2>&1; then echo "speedtest-cli install ho raha hai..."; '
                'DEBIAN_FRONTEND=noninteractive apt-get install -y speedtest-cli >/dev/null 2>&1 || '
                '{ apt-get update -y >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y speedtest-cli >/dev/null 2>&1; }; fi\n'
                'command -v speedtest-cli >/dev/null 2>&1 || { echo "speedtest-cli install nahi hua"; exit 1; }\n'
                'echo "Speedtest chal raha hai (30-60 second)..."; echo\n'
                'python3 -u -c "$1"; rc=$?; [[ $rc -ne 3 ]] && exit $rc\n'
                'echo "(speedtest python module nahi mila, speedtest-cli se chala raha hai)"\n'
                'speedtest-cli --secure && exit 0\n'
                'echo; echo "(--secure mode fail, normal mode try kar raha hai...)"; speedtest-cli')
        return ("Speedtest", ["bash", "-c", body, "rt-speed", SPEED_PY], False, 240, None, speed_done)
    if a == "vnstat_install":
        body = ('DEBIAN_FRONTEND=noninteractive apt-get install -y vnstat 2>&1 | tail -2 || true; '
                'command -v vnstat >/dev/null || { apt-get update -y >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y vnstat 2>&1 | tail -2; }; '
                'systemctl enable --now vnstat 2>&1; command -v vnstat >/dev/null && echo "vnstat install ho gaya. Data jama hone me 5-10 minute lagenge." || { echo "vnstat install fail"; exit 1; }')
        return ("Install vnstat", ["bash", "-c", body], True, 300)

    # ---- telegram bot ----
    if a == "bot_setup":
        cur = read_kv(BOT_CONF)
        tok = str(pr.get("token", "")).strip() or cur.get("TOKEN", "")
        adm = P(pr, "admin", RE_TG_CHAT, maxlen=21)
        if not RE_TG_TOKEN.match(tok):
            raise ValueError("Bot token ka format galat hai (BotFather wala 123456:ABC... token)")
        r = tg_call(tok, "getMe")
        if not r.get("ok"):
            raise ValueError("Token invalid hai (Telegram ne reject kiya): %s" % r.get("description", ""))
        body = ('[[ -x /usr/local/bin/rt-bot ]] || install_telegram_bot </dev/null || { echo "rt-bot script install fail"; exit 1; }\n'
                'mkdir -p /etc/ddkvps\n'
                'printf "TOKEN=%s\\nADMIN=%s\\nMENU_LIB=%s\\n" "$RT_BOT_TOKEN" "$1" "$RT_MENU" > /etc/ddkvps/bot.conf\n'
                'chmod 600 /etc/ddkvps/bot.conf\n'
                'printf "%s" "$RT_BOT_UNIT" > /etc/systemd/system/rt-bot.service\n'
                'systemctl daemon-reload; systemctl enable rt-bot >/dev/null 2>&1; systemctl restart rt-bot; sleep 1\n'
                'echo "Bot: @$2   Super Admin: $1"\n'
                'systemctl is-active --quiet rt-bot && echo "Bot configured. Telegram me bot ko /start bhejein." || { echo "rt-bot start nahi hua:"; journalctl -u rt-bot -n 15 --no-pager; exit 1; }')
        _GETME.clear()
        return ("Telegram bot setup", bash_cmd(body, [adm, r["result"].get("username", "")]), True, 180,
                {"RT_BOT_TOKEN": tok, "RT_BOT_UNIT": BOT_UNIT})
    if a == "bot_update":
        return ("Update bot script", bash_cmd("install_telegram_bot </dev/null && echo 'Bot script update ho gaya.'", []), True, 180)
    if a == "bot_remove":
        body = ('systemctl disable --now rt-bot 2>/dev/null; '
                'rm -f /etc/systemd/system/rt-bot.service /etc/ddkvps/bot.conf /etc/ddkvps/bot.admins /run/rt-bot.st.* /run/rt-bot.mid.*; '
                'systemctl daemon-reload; echo "Bot removed (service + config + admins)."')
        _GETME.clear()
        return ("Remove Telegram bot", ["bash", "-c", body], True, 60)

    # ---- settings ----
    if a == "domain":
        d = P(pr, "domain", RE_DOMAIN, maxlen=253)
        body = ('mkdir -p /etc/ddkvps; echo "$1" > "$DOMAIN_FILE"; echo "Domain: $1"; apply_nginx_config; '
                '[[ -f /etc/haproxy/haproxy.cfg ]] && install_haproxy; echo "Done. Ab SSL issue karein (Settings > SSL)."')
        return ("Domain: " + d, bash_cmd(body + " </dev/null", [d]), True, 600)
    if a == "ssl":
        return ("Issue SSL", bash_cmd("setup_ssl </dev/null", []), True, 900)
    if a == "banner":
        txt = str(pr.get("banner", ""))
        if pr.get("default"):
            txt = "default"
        if not txt.strip():
            raise ValueError("Banner khaali nahi ho sakta")
        if txt != "default" and len(txt.encode()) > BANNER_MAX:
            raise ValueError("Banner max %d bytes" % BANNER_MAX)
        body = ('if [[ "$1" == default ]]; then write_default_banner; else printf "%s\\n" "$1" > "$BANNER_FILE"; fi; '
                'chmod 644 "$BANNER_FILE"; '
                'if [[ "$(systemctl show dropbear -p KillMode --value 2>/dev/null)" == process ]]; then systemctl restart dropbear && echo "Banner applied."; '
                'else echo "Banner saved. Dropbear restart par apply hoga."; echo "(Abhi restart se connected users kat jayenge; pehle Fix stack chalao.)"; fi')
        return ("SSH Banner", bash_cmd(body, [txt]), True, 60)
    if a == "qos_set":
        ifc = P(pr, "iface", RE_IFACE, default="auto"); bw = P(pr, "bw", RE_DAYS)
        body = ('f=$1; [[ "$f" == auto ]] && f=$(detect_wan_iface); ip link show "$f" >/dev/null 2>&1 || { echo "Interface nahi mila: $f"; exit 1; }; '
                'mkdir -p /etc/ddkvps; printf "IFACE=%s\\nBW_MBIT=%s\\n" "$f" "$((10#$2))" > "$QOS_CONF"; touch "$QOS_CAP_FILE"; '
                'write_qos_scripts; systemctl daemon-reload; systemctl enable rt-qos >/dev/null 2>&1; systemctl restart rt-qos; sleep 2; qos_status')
        return ("QoS setup", bash_cmd(body, [ifc, bw]), True, 120)
    if a == "qos_cap":
        ipa = P(pr, "ip", RE_IP); mb = P(pr, "mbit", RE_NUM)
        body = ('touch "$QOS_CAP_FILE"; grep -v "^$1 " "$QOS_CAP_FILE" > "$QOS_CAP_FILE.tmp"; mv "$QOS_CAP_FILE.tmp" "$QOS_CAP_FILE"; '
                '(( 10#$2 > 0 )) && echo "$1 $((10#$2))" >> "$QOS_CAP_FILE"; systemctl restart rt-qos; echo "Cap updated."')
        return ("QoS cap: " + ipa, bash_cmd(body, [ipa, mb]), True, 60)
    if a == "qos_status":
        return ("QoS status", bash_cmd("qos_status", []), False, 30)
    if a == "qos_off":
        return ("Disable QoS", bash_cmd("remove_qos", []), True, 60)
    if a == "fix":
        return ("Fix SSH-WS / SSL stack", bash_cmd("fix_websocket </dev/null", []), True, 1800)
    if a == "xray_repair":
        fx = os.path.join(os.path.dirname(MENU), "fix-xray-sync.sh")
        if not os.path.isfile(fx):
            raise ValueError("fix-xray-sync.sh nahi mila: " + fx)
        return ("Xray lib upgrade / repair", ["bash", "-c", 'MENU="$1" bash "$2"', "rt", MENU, fx], True, 900)
    if a == "install_all":
        return ("Install All Components", bash_cmd("install_all_components </dev/null", []), True, 3600)
    raise ValueError("Unknown action: " + a)


# ---- data ----------------------------------------------------------------------
def live_sessions():
    ses, ips = {}, {}
    try:
        with open(LIVE_FILE) as f:
            for line in f:
                if line.startswith("#"):
                    continue
                parts = line.rstrip("\n").split("|")
                if len(parts) < 2 or not parts[1]:
                    continue
                u, ip = parts[0], parts[1]
                ses[u] = ses.get(u, 0) + 1
                ips.setdefault(u, set()).add(ip)
    except Exception:
        pass
    return ses, ips


_XLIVE = {"t": 0, "data": {}, "ok": False}
_XLIVE_LOCK = threading.Lock()
_RE_XFROM = re.compile(r"\bfrom\s+(?:tcp:|udp:)?(\[[0-9a-fA-F:.]+\]|[0-9a-fA-F:.]+?)(?::\d+)?\s")
_RE_XEMAIL = re.compile(r"\bemail:\s*(\S+)")


def xray_live(window=XR_IP_WINDOW):
    """menu.sh xray_live() jaisa: access.log se {user: {ip: [last 'HH:MM:SS', requests]}} (3s cache)"""
    with _XLIVE_LOCK:
        if time.time() - _XLIVE["t"] < 3:
            return _XLIVE["data"], _XLIVE["ok"]
        data, ok = {}, os.path.isfile(XR_LOG)
        if ok:
            cut = time.strftime("%Y/%m/%d %H:%M:%S", time.localtime(time.time() - window))
            try:
                with open(XR_LOG, "rb") as f:
                    f.seek(0, 2); size = f.tell()
                    f.seek(max(0, size - 3 * 1024 * 1024))
                    lines = f.read().decode(errors="replace").splitlines()[-20000:]
            except Exception:
                lines = []
            for ln in lines:
                if len(ln) < 19 or ln[:19] < cut:
                    continue
                m1 = _RE_XFROM.search(ln); m2 = _RE_XEMAIL.search(ln)
                if not m1 or not m2:
                    continue
                ip = m1.group(1).strip("[]"); u = m2.group(1)
                d = data.setdefault(u, {}).setdefault(ip, [ln[11:19], 0])
                d[0] = ln[11:19]; d[1] += 1
        _XLIVE.update(t=time.time(), data=data, ok=ok)
        return data, ok


def connected_rows(me, kind):
    """Panel ka apna 'Connected IPs' view (reseller ko sirf apne users)."""
    own = load_owners()[kind]
    scoped = is_scoped(me)
    rows = []
    if kind == "ssh":
        ses, ips = live_sessions()
        for u in ssh_users():
            if scoped and own.get(u["user"]) != me["user"]:
                continue
            if u["sessions"] or u["ips"]:
                rows.append({"user": u["user"], "ips": [{"ip": ip} for ip in u["ips"]], "sessions": u["sessions"],
                             "used": u["used"], "gb": u["gb"], "ip": u["ip"]})
        return {"rows": rows, "log": True, "window": None}
    live, ok = xray_live()
    for u in xray_users(kind):
        if scoped and own.get(u["user"]) != me["user"]:
            continue
        lv = live.get(u["user"])
        if lv:
            rows.append({"user": u["user"], "ips": [{"ip": ip, "last": v[0], "req": v[1]} for ip, v in sorted(lv.items())],
                         "used": u["used"], "gb": u["gb"], "ip": u["ip"], "status": u["status"]})
    return {"rows": rows, "log": ok, "window": XR_IP_WINDOW}


def limits(u):
    try:
        a = open(os.path.join(LIM_DIR, u)).read().split()
    except Exception:
        a = []
    g = int(re.sub(r"\D", "", a[0]) or 0) if len(a) > 0 else 0
    i = int(re.sub(r"\D", "", a[1]) or 0) if len(a) > 1 else 0
    return g, i


def ssh_users():
    now = time.time()
    ses, ips = live_sessions()
    shadow = {}
    try:
        with open("/etc/shadow") as f:
            for line in f:
                p = line.split(":")
                if len(p) > 7:
                    shadow[p[0]] = p
    except Exception:
        pass
    out = []
    with open("/etc/passwd") as f:
        for line in f:
            p = line.split(":")
            if len(p) < 7:
                continue
            u = p[0]
            try:
                uid = int(p[2])
            except ValueError:
                continue
            if not (1000 <= uid < 60000) or not RE_PANEL_USER.match(u):
                continue
            sh = shadow.get(u, [])
            pw = sh[1] if len(sh) > 1 else ""
            exp_days = sh[7] if len(sh) > 7 else ""
            ex = read_int(os.path.join(EXPIRY_DIR, u))
            if not ex and exp_days.isdigit():
                ex = int(exp_days) * 86400 + 86399
            status = "active"
            dis = os.path.exists(os.path.join(DIS_DIR, u))
            if ex and ex <= now:
                status = "expired"
            if dis:
                status = "locked"
            elif pw.startswith("!"):
                if os.path.exists(os.path.join(LCK_DIR, u)):
                    status = "gb-limit"
                elif os.path.exists(os.path.join(IPLCK_DIR, u)):
                    status = "ip-limit"
                elif os.path.exists(os.path.join(EXLCK_DIR, u)):
                    status = "expired"
                else:
                    status = "locked"
            g, i = limits(u)
            out.append({"user": u, "expiry": ex, "expiry_txt": fmt_epoch(ex), "gb": g, "ip": i,
                        "used": read_int(os.path.join(USE_DIR, u)), "sessions": ses.get(u, 0),
                        "ips": sorted(ips.get(u, [])), "status": status, "disabled": dis})
    return out


def xray_users(proto):
    now = time.time()
    out = []
    try:
        lines = open(XR_DB[proto]).read().splitlines()
    except Exception:
        lines = []
    for line in lines:
        p = line.split()
        if not p:
            continue
        n = p[0]; uid = p[1] if len(p) > 1 else ""; exp = p[2] if len(p) > 2 else ""
        gb = int(re.sub(r"\D", "", p[3]) or 0) if len(p) > 3 else 0
        ipl = int(re.sub(r"\D", "", p[4]) or 0) if len(p) > 4 else 0
        e = exp if "T" in exp else (exp + "T23:59:59" if exp else "")
        try:
            ep = int(time.mktime(time.strptime(e, "%Y-%m-%dT%H:%M:%S")))
        except Exception:
            ep = 0
        used = read_int(os.path.join(XR_USE, n))
        lock = read_int(os.path.join(XR_LOCK, n))
        status = "active"
        dis = os.path.exists(os.path.join(XR_DIS, proto + "_" + n))
        if dis:
            status = "locked"
        elif ep and ep <= now:
            status = "expired"
        elif gb > 0 and used >= gb * GIB:
            status = "gb-limit"
        elif lock > now:
            status = "ip-limit"
        out.append({"user": n, "id": uid, "expiry": ep, "expiry_txt": fmt_epoch(ep), "gb": gb, "ip": ipl,
                    "used": used, "status": status, "disabled": dis})
    return out


_CPU = {"t": None}
_NET = {"t": None}


def cpu_percent():
    def sample():
        with open("/proc/stat") as f:
            v = [int(x) for x in f.readline().split()[1:]]
        return sum(v), v[3] + (v[4] if len(v) > 4 else 0)
    tot, idle = sample()
    prev = _CPU["t"]
    if prev is None:
        time.sleep(0.25)
        prev = (tot, idle)
        tot, idle = sample()
    _CPU["t"] = (tot, idle)
    dt = tot - prev[0]
    return round(100.0 * (dt - (idle - prev[1])) / dt, 1) if dt > 0 else 0.0


def net_stats():
    rx = tx = 0
    try:
        for line in open("/proc/net/dev").read().splitlines()[2:]:
            name, data = line.split(":", 1)
            name = name.strip()
            if name == "lo" or name.startswith(("ifb", "docker", "veth")):
                continue
            d = data.split()
            rx += int(d[0]); tx += int(d[8])
    except Exception:
        pass
    now = time.time(); prev = _NET["t"]; _NET["t"] = (now, rx, tx)
    rr = tr = 0
    if prev and now > prev[0]:
        rr = max(0, (rx - prev[1]) / (now - prev[0])); tr = max(0, (tx - prev[2]) / (now - prev[0]))
    return {"rx": rx, "tx": tx, "rx_rate": rr, "tx_rate": tr}


def services_info():
    names = [s for s, _ in SERVICES]
    rc, out = run(["systemctl", "show"] + [n + ".service" for n in names] +
                  ["-p", "Id,LoadState,ActiveState,SubState,UnitFileState,MainPID,MemoryCurrent,ActiveEnterTimestampMonotonic"])
    blocks = {}
    cur = {}
    for line in (out + "\n").splitlines():
        if not line.strip():
            if cur.get("Id"):
                blocks[cur["Id"].replace(".service", "")] = cur
            cur = {}
            continue
        if "=" in line:
            k, v = line.split("=", 1); cur[k] = v
    if cur.get("Id"):
        blocks[cur["Id"].replace(".service", "")] = cur
    try:
        up = float(open("/proc/uptime").read().split()[0])
    except Exception:
        up = 0
    res = []
    for n, label in SERVICES:
        b = blocks.get(n, {})
        mono = int(b.get("ActiveEnterTimestampMonotonic", "0") or 0)
        mem = b.get("MemoryCurrent", "")
        res.append({"name": n, "label": label, "installed": b.get("LoadState") == "loaded",
                    "active": b.get("ActiveState", "unknown"), "sub": b.get("SubState", ""),
                    "enabled": b.get("UnitFileState", ""), "pid": int(b.get("MainPID", "0") or 0),
                    "memory": int(mem) if mem.isdigit() else 0,
                    "uptime": int(up - mono / 1e6) if (mono and b.get("ActiveState") == "active") else 0})
    return res


def listening_ports():
    rc, out = run(["ss", "-Htlnp"])
    res = []
    if rc != 0:
        return res
    for line in out.splitlines():
        p = line.split()
        if len(p) < 4:
            continue
        local = p[3]
        port = local.rsplit(":", 1)[-1]
        addr = local.rsplit(":", 1)[0]
        m = re.search(r'users:\(\("([^"]+)"', line)
        res.append({"addr": addr, "port": int(port) if port.isdigit() else 0, "proc": m.group(1) if m else ""})
    seen, uniq = set(), []
    for r in sorted(res, key=lambda r: (r["port"], r["addr"])):
        k = (r["port"], r["proc"], r["addr"])
        if k not in seen:
            seen.add(k); uniq.append(r)
    return uniq


def overview(me=None):
    mem = {}
    try:
        for line in open("/proc/meminfo"):
            k, v = line.split(":", 1); mem[k] = int(v.split()[0]) * 1024
    except Exception:
        pass
    du = shutil.disk_usage("/")
    try:
        up = float(open("/proc/uptime").read().split()[0])
    except Exception:
        up = 0
    os_name = ""
    try:
        for line in open("/etc/os-release"):
            if line.startswith("PRETTY_NAME="):
                os_name = line.split("=", 1)[1].strip().strip('"')
    except Exception:
        pass
    su = ssh_users()
    xr = {p: xray_users(p) for p in PROTOS}
    ses, _ = live_sessions()
    if is_scoped(me):
        o = load_owners()
        su = [u for u in su if o["ssh"].get(u["user"]) == me["user"]]
        xr = {p: [u for u in v if o[p].get(u["user"]) == me["user"]] for p, v in xr.items()}
        ses = {u["user"]: u["sessions"] for u in su}
    return {
        "domain": get_domain(), "hostname": socket.gethostname(), "os": os_name, "uptime": int(up),
        "load": list(os.getloadavg()), "cpu": cpu_percent(), "cores": os.cpu_count(),
        "mem_total": mem.get("MemTotal", 0), "mem_used": mem.get("MemTotal", 0) - mem.get("MemAvailable", 0),
        "disk_total": du.total, "disk_used": du.used, "net": net_stats(),
        "ssh": {"total": len(su), "active": sum(1 for u in su if u["status"] == "active"), "online": sum(ses.values())},
        "xray": {p: {"total": len(v), "active": sum(1 for u in v if u["status"] == "active")} for p, v in xr.items()},
        "xray_installed": os.path.isfile(XR_CONF),
        "services": services_info(),
    }


def settings_info():
    q = {}
    try:
        for line in open(QOS_CONF):
            if "=" in line:
                k, v = line.strip().split("=", 1); q[k] = v
    except Exception:
        pass
    caps = []
    try:
        for line in open(QOS_CAP_FILE):
            p = line.split()
            if len(p) >= 2:
                caps.append({"ip": p[0], "mbit": p[1]})
    except Exception:
        pass
    try:
        banner = open(BANNER_FILE, errors="replace").read()
    except Exception:
        banner = ""
    dom = get_domain()
    return {"domain": dom, "banner": banner, "banner_max": BANNER_MAX,
            "ssl": os.path.isfile("/etc/letsencrypt/live/%s/fullchain.pem" % dom),
            "qos": {"iface": q.get("IFACE", ""), "bw": q.get("BW_MBIT", ""), "caps": caps},
            "panel": {"port": PORT, "tls": TLS_ACTIVE, "menu": MENU,
                      "menu_found": os.path.isfile(MENU), "version": VERSION},
            "xray_repair": os.path.isfile(os.path.join(os.path.dirname(MENU), "fix-xray-sync.sh"))}


# ---- HTTP -----------------------------------------------------------------------
HTML = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>DDK VPS Manager</title>
<style>
:root{--bg:#070707;--panel:#111111;--panel2:#181818;--line:#242424;--txt:#e6edf3;--mut:#8b949e;--pri:#5fd7d7;--pri2:#3fb5b5;--ok:#7ee787;--warn:#f0a35e;--bad:#ff6b6b;--info:#5fd7d7;--ink:#070707;--mono:ui-monospace,"JetBrains Mono","SFMono-Regular","Cascadia Mono",Menlo,Consolas,"Liberation Mono",monospace}
*{box-sizing:border-box}html,body{margin:0;height:100%}
body{font-family:var(--mono);background-color:var(--bg);background-image:linear-gradient(45deg,rgba(255,255,255,.012) 25%,transparent 25%,transparent 75%,rgba(255,255,255,.012) 75%),linear-gradient(45deg,rgba(255,255,255,.012) 25%,transparent 25%,transparent 75%,rgba(255,255,255,.012) 75%);background-size:6px 6px;background-position:0 0,3px 3px;background-attachment:fixed;color:var(--txt);font-size:12px;letter-spacing:.01em}
::selection{background:rgba(95,215,215,.3)}
::-webkit-scrollbar{width:10px;height:10px}::-webkit-scrollbar-thumb{background:#2a2a2a;border-radius:6px}::-webkit-scrollbar-track{background:transparent}
a{color:var(--pri)}button,input,select,textarea{font:inherit;color:inherit}
.hidden{display:none!important}
/* login */
#login{min-height:100%;display:flex;align-items:center;justify-content:center;padding:20px;background:radial-gradient(circle at 50% 0,rgba(95,215,215,.07) 0,transparent 55%),var(--bg)}
.lbox{width:100%;max-width:380px;background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:28px;box-shadow:0 20px 60px rgba(0,0,0,.45)}
.brand{display:inline-flex;align-items:stretch;font-family:var(--mono);font-size:13px;letter-spacing:.04em;line-height:1;white-space:nowrap}
.brand b{background:var(--pri);color:var(--ink);font-weight:800;padding:6px 8px}
.brand i{font-style:normal;background:#1e1e1e;color:var(--pri);padding:6px 8px;font-weight:600}
.brand small{align-self:center;color:var(--mut);font-size:11px;margin-left:8px;letter-spacing:0}
.lsub{color:var(--mut);margin:12px 0 22px;font-size:11.5px}
.lsub:after{content:"";display:block;height:1px;background:var(--line);margin-top:16px}
/* layout */
#app{display:flex;min-height:100%}
#side{width:230px;background:#0c0c0c;box-shadow:6px 0 24px rgba(0,0,0,.5);border-right:1px solid var(--line);padding:18px 12px;position:fixed;top:0;bottom:0;left:0;display:flex;flex-direction:column;z-index:20;transition:transform .2s}
#side .brand{padding:4px 10px 18px}
.nav{display:flex;flex-direction:column;gap:4px}
.nav button{all:unset;cursor:pointer;padding:10px 12px;border-radius:10px;color:var(--mut);display:flex;gap:10px;align-items:center}
.nav button:hover{background:var(--panel2);color:var(--txt)}
.nav button.on{background:rgba(95,215,215,.10);color:var(--pri);box-shadow:inset 2px 0 0 var(--pri);border-radius:0 8px 8px 0}
.nav .ic{width:20px;text-align:center}
#side .foot{margin-top:auto;color:var(--mut);font-size:11px;padding:10px}
#main{flex:1;margin-left:230px;min-width:0}
#top{display:flex;align-items:center;gap:12px;padding:14px 22px;border-bottom:1px solid var(--line);position:sticky;top:0;background:rgba(7,7,7,.86);backdrop-filter:blur(6px);z-index:10}
#top h1{font-size:13px;margin:0;flex:1;text-transform:uppercase;letter-spacing:.08em;color:var(--pri)}
#menuBtn{display:none}
.content{padding:22px}
@media(max-width:860px){#side{transform:translateX(-100%)}#side.open{transform:none}#main{margin-left:0}#menuBtn{display:inline-flex}.content{padding:14px}}
/* ui */
.btn{border:1px solid var(--line);background:var(--panel2);padding:8px 14px;border-radius:9px;cursor:pointer;display:inline-flex;align-items:center;gap:6px;white-space:nowrap}
.btn:hover{border-color:var(--pri)}
.btn.pri{background:var(--pri);border:1px solid var(--pri);color:var(--ink);font-weight:700}
.btn.pri:hover{background:#7fe3e3;border-color:#7fe3e3}
.btn.bad{background:rgba(255,107,107,.12);border-color:rgba(255,107,107,.45);color:#ffaaaa}
.btn.ok{background:rgba(126,231,135,.12);border-color:rgba(126,231,135,.45);color:#a7f3b5}
.btn.sm{padding:5px 9px;font-size:11px;border-radius:7px}
.btn:disabled{opacity:.5;cursor:not-allowed}
.card{background:linear-gradient(180deg,#141414,#0f0f0f);border:1px solid var(--line);border-radius:20px;padding:16px;box-shadow:0 10px 28px rgba(0,0,0,.6),0 2px 6px rgba(0,0,0,.45),inset 0 1px 0 rgba(255,255,255,.04);transition:transform .18s,box-shadow .18s,border-color .18s}
.card.stat:hover{transform:translateY(-2px);border-color:#2f2f2f;box-shadow:0 16px 36px rgba(0,0,0,.7),0 0 0 1px rgba(95,215,215,.08),inset 0 1px 0 rgba(255,255,255,.05)}
.card h3{margin:0 0 12px;font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--pri)}
.grid{display:grid;gap:14px}
.g4{grid-template-columns:repeat(auto-fill,minmax(230px,1fr))}
.g2{grid-template-columns:repeat(auto-fill,minmax(340px,1fr))}
.stat .k{color:var(--pri);font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;font-weight:700}
.stat.sr{display:flex;align-items:center;gap:14px;padding:14px 16px}.stat.sr .tx{min-width:0;flex:1}
.stat.sr .v{margin:3px 0 1px}.stat.sr .s{line-height:1.45}
.ring{position:relative;width:66px;height:66px;flex:none;border-radius:50%;background:radial-gradient(circle,#161616 55%,#0c0c0c 100%);box-shadow:0 4px 14px rgba(0,0,0,.6),inset 0 0 0 1px #1d1d1d}
.ring svg{width:100%;height:100%;transform:rotate(-90deg);display:block}
.ring circle{fill:none;stroke-width:3}.ring .tr{stroke:#222}
.ring .fg{stroke:var(--pri);stroke-linecap:round;transition:stroke-dasharray .6s ease;filter:drop-shadow(0 0 3px rgba(95,215,215,.45))}
.ring.w .fg{stroke:var(--warn);filter:drop-shadow(0 0 3px rgba(240,163,94,.45))}.ring.b .fg{stroke:var(--bad);filter:drop-shadow(0 0 3px rgba(255,107,107,.45))}
.ring.g .fg{stroke:var(--ok);filter:drop-shadow(0 0 3px rgba(126,231,135,.4))}
.ring .s1{stroke:#5fd7d7}.ring .s2{stroke:#7ee787}.ring .s3{stroke:#f0a35e}.ring .s1,.ring .s2,.ring .s3{stroke-linecap:butt}
.ring>b,.ring>span{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:700;letter-spacing:0}
.ring>span{color:var(--pri)}.ring>span svg{width:24px;height:24px;transform:none}
.dot3{display:inline-block;width:6px;height:6px;border-radius:50%;margin:0 4px 1px 0;vertical-align:middle}
@media(max-width:600px){.g4{grid-template-columns:1fr 1fr;gap:10px}.stat.sr{flex-direction:column;align-items:flex-start;gap:10px;padding:13px}
 .stat.sr .ring{width:56px;height:56px}.stat.sr .v{font-size:15px}.stat.sr .ring>b{font-size:11px}
 .row>*{min-width:150px}.svci{padding:7px 10px}#top{gap:8px;padding:10px 12px}.who .rp{display:none}
 #top h1{overflow:hidden}.sbadge{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
 .big{gap:6px!important}.big b{font-size:14px!important}}
.svci{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:8px 12px;background:#161616;border:1px solid #1f1f1f;border-radius:14px;box-shadow:0 3px 10px rgba(0,0,0,.4)}
.stat .v{font-size:17px;font-weight:700;margin:6px 0 2px;letter-spacing:-.01em}
.stat .s{color:var(--mut);font-size:11px}
.bar{height:4px;background:#1e1e1e;border-radius:2px;overflow:hidden;margin-top:10px}
.bar>i{display:block;height:100%;background:var(--pri);border-radius:2px}
.bar.w>i{background:var(--warn)}.bar.b>i{background:var(--bad)}
.toolbar{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:14px}
.toolbar .sp{flex:1}
.input,select,textarea{background:#0b0b0b;border:1px solid var(--line);border-radius:9px;padding:9px 11px;width:100%;outline:none}
.input:focus,select:focus,textarea:focus{border-color:var(--pri)}
textarea{min-height:120px;font-family:ui-monospace,Consolas,monospace;font-size:12px}
label.f{display:block;margin-bottom:12px}label.f span{display:block;color:var(--mut);font-size:11px;margin-bottom:5px}
.help{color:var(--mut);font-size:11px;margin-top:4px}
.tblw{overflow-x:auto;border:1px solid var(--line);border-radius:16px;background:var(--panel);box-shadow:0 6px 18px rgba(0,0,0,.45)}
table{width:100%;border-collapse:collapse;min-width:720px}
th,td{padding:10px 12px;text-align:left;border-bottom:1px solid var(--line);vertical-align:middle}
th{color:var(--mut);font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.04em;background:var(--panel2)}
tr:last-child td{border-bottom:0}
td .acts{display:flex;gap:5px;flex-wrap:wrap}
.pill{display:inline-flex;align-items:center;gap:5px;padding:3px 9px;border-radius:99px;font-size:11px;font-weight:600}
.pill:before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor}
.p-ok{background:rgba(126,231,135,.12);color:#7ee787}.p-bad{background:rgba(255,107,107,.12);color:#ff8585}
.p-warn{background:rgba(240,163,94,.12);color:#ffb86b}.p-mut{background:rgba(139,148,158,.12);color:var(--mut)}
.tabs{display:flex;gap:6px;margin-bottom:14px;flex-wrap:wrap}
.tabs button{border:1px solid var(--line);background:var(--panel);padding:8px 16px;border-radius:99px;cursor:pointer}
.tabs button.on{background:var(--pri);border-color:var(--pri);color:var(--ink);font-weight:700}
.mono{font-family:var(--mono);font-size:11px}
.muted{color:var(--mut)}.empty{padding:30px;text-align:center;color:var(--mut)}
pre.out{background:#0b0b0b;border:1px solid var(--line);border-radius:10px;padding:12px;max-height:55vh;overflow:auto;white-space:pre-wrap;word-break:break-word;font-size:11.5px;margin:0}
/* modal */
#ov{position:fixed;inset:0;background:rgba(0,0,0,.75);display:flex;align-items:flex-start;justify-content:center;padding:5vh 12px;z-index:50;overflow:auto}
.modal{background:var(--panel);border:1px solid var(--line);border-radius:22px;box-shadow:0 30px 80px rgba(0,0,0,.8);width:100%;max-width:520px;padding:20px}
.modal.wide{max-width:820px}
.modal h2{margin:0 0 14px;font-size:15px;display:flex;align-items:center;gap:10px}
.mfoot{display:flex;gap:8px;justify-content:flex-end;margin-top:14px;flex-wrap:wrap}
.err{background:rgba(255,107,107,.12);border:1px solid rgba(255,107,107,.4);color:#ffaaaa;padding:9px 12px;border-radius:9px;margin-bottom:12px}
.spin{width:16px;height:16px;border:2px solid var(--line);border-top-color:var(--pri);border-radius:50%;animation:sp 1s linear infinite;display:inline-block}
@keyframes sp{to{transform:rotate(360deg)}}
.links .lk{background:#0b0b0b;border:1px solid var(--line);border-radius:10px;padding:10px;margin-top:8px}
.links .lk .t{display:flex;justify-content:space-between;align-items:center;gap:8px;margin-bottom:6px;color:var(--mut);font-size:11px}
.links .lk .u{word-break:break-all;font-family:ui-monospace,Consolas,monospace;font-size:11px}
.qr{background:#fff;padding:10px;border-radius:10px;display:inline-block;margin-top:8px}
#toast{position:fixed;bottom:18px;right:18px;z-index:80;display:flex;flex-direction:column;gap:8px}
#toast div{background:var(--panel2);border:1px solid var(--line);padding:10px 14px;border-radius:10px;box-shadow:0 8px 30px rgba(0,0,0,.4)}
.svcrow td:first-child b{display:block}.row{display:flex;gap:10px;flex-wrap:wrap}.row>*{flex:1;min-width:190px}
.sec{margin-bottom:14px}
body.lv0 .r1,body.lv0 .r2,body.lv1 .r2,body.own .ra,body:not(.own) .ro{display:none!important}
.lvip{display:inline-block;margin:2px 6px 2px 0;padding:2px 8px;border-radius:7px;background:var(--panel2);font-size:11.5px}
/* SSH + Xray users: ek hi table design (live) */
.ut td{white-space:nowrap}
.ut .uname{font-weight:700}
.ut .acts{flex-wrap:nowrap;gap:2px;justify-content:flex-end}
.ut .ib{width:32px;height:32px;padding:0;justify-content:center;border-radius:8px;background:transparent;border:1px solid transparent;color:var(--mut)}
.ut .ib:hover{background:var(--panel2);border-color:var(--line);color:var(--txt)}
.ut .ib.bad:hover{color:#ff8585;border-color:rgba(255,107,107,.4)}
.ut .ib.xs{width:22px;height:22px;border-radius:6px}
.ut .ib svg{display:block}
.cred{display:flex;align-items:center;gap:2px;margin-top:2px}.cred .mono{color:var(--mut);max-width:96px;overflow:hidden;text-overflow:ellipsis}
.onp{display:inline-flex;align-items:center;gap:6px;padding:4px 11px;border-radius:99px;font-size:11px;font-weight:700;background:rgba(139,148,158,.12);color:var(--mut);transition:background .3s,color .3s}
.onp i{width:7px;height:7px;border-radius:50%;background:currentColor;display:inline-block}
.onp.on{background:rgba(126,231,135,.13);color:#7ee787;box-shadow:inset 0 0 0 1px rgba(126,231,135,.35)}.onp.on i{box-shadow:0 0 7px #7ee787}
.onp.over{background:rgba(255,107,107,.13);color:#ff8585;box-shadow:inset 0 0 0 1px rgba(255,107,107,.35)}
.ut .ipl{display:flex;flex-wrap:wrap;max-width:270px;white-space:normal}.ut .ipl .lvip{margin:2px 4px 2px 0}
.ut .bar{width:120px;margin-top:6px}.ut .bar>i{background:var(--ok);transition:width .6s ease}.ut .bar.w>i{background:var(--warn)}.ut .bar.b>i{background:var(--bad)}
.ut .exp-x{color:#ff8585}
.ut .ib.off{color:#ff8585;background:rgba(255,107,107,.12);border-color:rgba(255,107,107,.35)}.ut .ib.off:hover{color:#7ee787;border-color:rgba(126,231,135,.4);background:rgba(126,231,135,.10)}
.ut tr.dis td:not(:last-child){opacity:.55}
.livep{display:inline-flex;align-items:center;gap:6px;padding:4px 10px;border-radius:99px;font-size:11px;background:rgba(126,231,135,.10);color:#7ee787}
.livep i{width:7px;height:7px;border-radius:50%;background:#7ee787;animation:lvp 1.6s infinite}.livep.off{background:rgba(139,148,158,.12);color:var(--mut)}.livep.off i{background:var(--mut);animation:none}
@keyframes lvp{0%{box-shadow:0 0 0 0 rgba(126,231,135,.6)}70%{box-shadow:0 0 0 7px rgba(126,231,135,0)}100%{box-shadow:0 0 0 0 rgba(126,231,135,0)}}
.ucnt{font-weight:800;font-size:14px;margin-right:4px}
.who{display:flex;align-items:center;gap:8px;font-size:12px;color:var(--mut);margin-left:auto}.who b{color:var(--txt)}
.rp{font-size:10.5px;padding:2px 8px;border-radius:99px;background:var(--panel2);border:1px solid #2f3742}
.rp.super{color:#ffb86b;border-color:#5c4120}.rp.admin{color:#8be9e9;border-color:#1f5252}.rp.viewer{color:#a3a3a3}
.audit td{font-size:11.5px}
.chart{width:100%;height:170px;display:block}
.legend{display:flex;gap:14px;font-size:11px;color:var(--mut);margin-bottom:6px;flex-wrap:wrap}.legend i{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:5px;vertical-align:-1px}
.big{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin:6px 0 12px}.big div{background:radial-gradient(circle,#171717 55%,#0d0d0d 100%);border:2px solid #1f1f1f;border-radius:50%;aspect-ratio:1;max-width:128px;width:100%;margin:0 auto;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;box-shadow:0 6px 18px rgba(0,0,0,.55),inset 0 0 0 3px rgba(95,215,215,.12)}
.big div:nth-child(2){box-shadow:0 6px 18px rgba(0,0,0,.55),inset 0 0 0 3px rgba(126,231,135,.22)}.big div:nth-child(3){box-shadow:0 6px 18px rgba(0,0,0,.55),inset 0 0 0 3px rgba(240,163,94,.22)}
.big b{display:block;font-size:17px;margin:2px 0}.big span{color:var(--mut);font-size:10px}
.kv{display:grid;grid-template-columns:120px 1fr;gap:7px 12px}.kv span:nth-child(odd){color:var(--mut)}
/* ---- Deploy Suite (terminal jaisa): section badge + breadcrumb, job dashboard ---- */
#top h1{display:flex;align-items:center;gap:10px;flex-wrap:wrap;min-width:0}
.sbadge{background:#1e1e1e;color:var(--pri);padding:5px 8px;font-size:12px;font-weight:700;letter-spacing:.06em}
.crumb2{color:var(--mut);font-size:11px;text-transform:none;letter-spacing:0;font-weight:400;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
@media(max-width:640px){.crumb2{display:none}}
.dsh{display:flex;align-items:center;gap:10px;margin-bottom:6px}.dsh .sp{flex:1}
.dsh .brand i{text-transform:uppercase;max-width:420px;overflow:hidden;text-overflow:ellipsis}
.crumb{color:var(--mut);font-size:11px;margin:0 0 12px}
.ds{font-size:11.5px}
.ds-kv{display:grid;grid-template-columns:64px 1fr;gap:4px 10px}.ds-kv span{color:var(--mut)}.ds-kv b{font-weight:500;word-break:break-all}
.ds-hr{height:1px;background:var(--line);margin:12px 0}
.ds-prog{display:flex;align-items:center;gap:12px}.ds-prog .lab{color:var(--pri);letter-spacing:.06em;min-width:96px}.ds-prog .pc{min-width:44px;text-align:right}
.ds-bar{flex:1;height:6px;background:#1e1e1e;border-radius:3px;overflow:hidden}.ds-bar i{display:block;height:100%;background:var(--pri);transition:width .6s ease}
.ds.ok .ds-bar i{background:var(--ok)}.ds.ok .lab{color:var(--ok)}.ds.fail .ds-bar i{background:var(--bad)}.ds.fail .lab{color:var(--bad)}
.ds-ph{display:flex;flex-wrap:wrap;gap:6px 16px;margin:12px 0 10px}
.ds-ph .d:before{content:"\2713  ";color:var(--ok)}.ds-ph .a{color:var(--warn);font-weight:700}.ds-ph .a:before{content:"\25C9  "}
.ds-ph .w{color:var(--mut)}.ds-ph .w:before{content:"\25CB  "}
.ds-steps{display:flex;flex-direction:column;gap:2px;max-height:44vh;overflow:auto}
.ds-st{display:grid;grid-template-columns:16px 24px 1fr auto;gap:8px;align-items:center;padding:2px 0}
.ds-st .no,.ds-st .tm{color:var(--mut)}.ds-st .ic{text-align:center}
.ds-st.ok .ic{color:var(--ok)}.ds-st.warn .ic,.ds-st.warn .tm{color:#ffd75f}.ds-st.skip,.ds-st.wait{color:var(--mut)}
.ds-st.run .ic,.ds-st.run .no,.ds-st.run .tm{color:var(--pri)}.ds-st.run .t{font-weight:700;color:#fff}
.ds-st .spin{width:11px;height:11px;border-width:2px}
.ds.fail .ds-st.run .ic,.ds.fail .ds-st.run .tm{color:var(--bad)}
.ds-last{grid-column:3/5;color:var(--mut);font-size:11px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:-2px}
.ds-foot{color:var(--mut)}.ds-foot b{color:var(--txt);font-weight:600}.ds-foot .y{color:#ffd75f}.ds-foot .g{color:var(--ok)}
.ds-ready{background:var(--pri);color:var(--ink);font-weight:800;padding:3px 8px;margin-right:10px;letter-spacing:.04em}
details.dlog>summary{cursor:pointer;color:var(--mut);margin:12px 0 8px;font-size:11px}details.dlog.plain>summary{display:none}
</style>
</head>
<body>
<div id="login" class="hidden">
  <form class="lbox" id="lform">
    <div class="brand" style="font-size:14px"><b>DDK VPS MANAGER</b><i>PANEL</i><small>v__RT_SUITE__</small></div>
    <p class="lsub">SSH / WS / SSL / Xray &middot; login karein</p>
    <div id="lerr" class="err hidden"></div>
    <label class="f"><span>Username</span><input class="input" id="lu" autocomplete="username" required></label>
    <label class="f"><span>Password</span><input class="input" id="lp" type="password" autocomplete="current-password" required></label>
    <button class="btn pri" style="width:100%;justify-content:center;padding:11px">Login</button>
  </form>
</div>

<div id="app" class="hidden">
  <aside id="side">
    <div class="brand"><b>DDK VPS MANAGER</b><i>PANEL</i><small>v__RT_SUITE__</small></div>
    <nav class="nav" id="nav">
      <button data-p="dash"><span class="ic">&#9673;</span>Dashboard</button>
      <button data-p="ssh"><span class="ic">&#128100;</span>SSH Accounts</button>
      <button data-p="xray"><span class="ic">&#9889;</span>Xray Accounts</button>
      <button data-p="svc"><span class="ic">&#9881;</span>Running Services</button>
      <button data-p="stats"><span class="ic">&#128200;</span>VPS Stats</button>
      <button data-p="bot" class="r1 ra"><span class="ic">&#9992;</span>Telegram Bot</button>
      <button data-p="set"><span class="ic">&#128295;</span>Settings</button>
      <button data-p="adm" class="r2"><span class="ic">&#128273;</span>Panel Admins</button>
    </nav>
    <div class="foot"><div id="sdom" class="mono"></div><button class="btn sm" style="margin-top:10px" id="logout">Logout</button></div>
  </aside>
  <main id="main">
    <div id="top"><button class="btn sm" id="menuBtn">&#9776;</button><h1 id="ttl">Dashboard</h1><span class="who" id="who"></span><button class="btn sm" id="refresh">&#8635; Refresh</button></div>
    <div class="content" id="view"></div>
  </main>
</div>
<div id="ov" class="hidden"></div>
<div id="toast"></div>

<script>
"use strict";
const $=s=>document.querySelector(s);
const esc=s=>String(s==null?"":s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[c]));
const fmtB=b=>{b=+b||0;if(b<0)b=0;if(b<1023.5)return Math.round(b)+" B";b=Math.max(b,1024);const u=["B","KB","MB","GB","TB"];let i=0;while(b>=1024&&i<4){b/=1024;i++}return b.toFixed(b<10?2:1)+" "+u[i]};
const fmtDur=s=>{s=+s||0;const d=Math.floor(s/86400),h=Math.floor(s%86400/3600),m=Math.floor(s%3600/60);return d?`${d}d ${h}h`:h?`${h}h ${m}m`:`${m}m ${s%60}s`};
const left=ep=>{if(!ep)return "";const s=ep-Date.now()/1000;if(s<=0)return "khatam";return fmtDur(s)+" baqi"};
function toast(m){const d=document.createElement("div");d.textContent=m;$("#toast").appendChild(d);setTimeout(()=>d.remove(),3200)}
async function api(path,body){
  const o=body===undefined?{}:{method:"POST",headers:{"Content-Type":"application/json","X-RT":"1"},body:JSON.stringify(body)};
  const r=await fetch(path,Object.assign({credentials:"same-origin"},o));
  let j={};try{j=await r.json()}catch(e){}
  if(r.status===401){showLogin();throw new Error("login chahiye")}
  if(!r.ok)throw new Error(j.error||("HTTP "+r.status));
  return j;
}
async function copy(t){try{await navigator.clipboard.writeText(t)}catch(e){const a=document.createElement("textarea");a.value=t;document.body.appendChild(a);a.select();document.execCommand("copy");a.remove()}toast("Copy ho gaya")}

/* ---------- modal ---------- */
function modal(html,wide){const ov=$("#ov");ov.innerHTML=`<div class="modal ${wide?"wide":""}">${html}</div>`;ov.classList.remove("hidden");return ov.firstChild}
function closeModal(){$("#ov").classList.add("hidden");$("#ov").innerHTML="";if(POLL){clearTimeout(POLL);POLL=null}}
$("#ov").addEventListener("mousedown",e=>{if(e.target.id==="ov"&&!RUNNING)closeModal()});
function form(title,fields,submitTxt,onSubmit,note){
  const m=modal(`<h2>${esc(title)}</h2>${note?`<p class="muted" style="margin-top:-6px">${note}</p>`:""}<div class="err hidden" id="ferr"></div><form id="fm">${fields.map(f=>{
    const v=f.value==null?"":f.value;let inp;
    if(f.type==="select")inp=`<select name="${f.name}">${f.options.map(o=>`<option value="${esc(o[0])}" ${String(o[0])===String(v)?"selected":""}>${esc(o[1])}</option>`).join("")}</select>`;
    else if(f.type==="textarea")inp=`<textarea name="${f.name}" placeholder="${esc(f.ph||"")}">${esc(v)}</textarea>`;
    else if(f.type==="check")return `<label class="f" style="display:flex;gap:8px;align-items:center"><input type="checkbox" name="${f.name}" ${v?"checked":""}> ${esc(f.label)}</label>`;
    else inp=`<input class="input" name="${f.name}" type="${f.type||"text"}" value="${esc(v)}" placeholder="${esc(f.ph||"")}" ${f.req?"required":""} ${f.ro?"readonly":""} autocomplete="off">`;
    return `<label class="f"><span>${esc(f.label)}</span>${inp}${f.help?`<div class="help">${f.help}</div>`:""}</label>`}).join("")}
    <div class="mfoot"><button type="button" class="btn" id="fcancel">Cancel</button><button class="btn pri">${esc(submitTxt||"Save")}</button></div></form>`);
  $("#fcancel").onclick=closeModal;
  const first=m.querySelector("input:not([readonly]),textarea,select");if(first)first.focus();
  $("#fm").onsubmit=async e=>{e.preventDefault();const d={};new FormData(e.target);fields.forEach(f=>{const el=e.target.elements[f.name];d[f.name]=f.type==="check"?el.checked:el.value});
    try{await onSubmit(d)}catch(er){const x=$("#ferr");x.textContent=er.message;x.classList.remove("hidden")}};
}
function confirmBox(title,msg,btn,fn){const m=modal(`<h2>${esc(title)}</h2><p>${msg}</p><div class="mfoot"><button class="btn" id="cn">Cancel</button><button class="btn bad" id="cy">${esc(btn)}</button></div>`);$("#cn").onclick=closeModal;$("#cy").onclick=fn}

/* ---------- jobs (Deploy Suite style: terminal jaisa badge header + progress dashboard) ---------- */
const SUITE="__RT_SUITE__";
let POLL=null,RUNNING=false;
const mmss=t=>{t=Math.max(0,Math.round(t||0));const h=Math.floor(t/3600),m=Math.floor(t%3600/60),s=t%60,p=v=>String(v).padStart(2,"0");return h?`${h}:${p(m)}:${p(s)}`:`${p(m)}:${p(s)}`};
function rtParse(out){   // menu.sh ke ::rt: markers -> plan / phases / steps; baaki lines = log
  const P={plan:null,ph:[],st:[],done:null,log:[]};
  (out||"").split("\n").forEach(l=>{
    const m=l.match(/^::rt:([a-z]+):(.*)$/);if(!m){P.log.push(l);return}
    const k=m[1],v=m[2],a=v.split(":");
    if(k==="plan"){const x=v.split("|");P.plan={badge:x[0],sub:x[1],lab:x[2],done:x[3],t0:+x[4]||0,ver:x[5]}}
    else if(k==="phases")P.ph=v.split(",");
    else if(k==="step")P.st[+a[0]]={i:+a[0],p:+a[1],e:+a[2]||1,t:a.slice(3).join(":"),s:"wait",a:0,z:0,ll:0,le:-1};
    else if(k==="run"){const s=P.st[+a[0]];if(s){s.s="run";s.a=+a[1]||0;s.ll=P.log.length}}
    else if(k==="end"){const s=P.st[+a[0]];if(s){s.s=a[1];s.z=+a[2]||0;s.le=P.log.length}}
    else if(k==="done")P.done=+v||0;
  });
  P.st=P.st.filter(Boolean);return P;
}
function rtLast(P,s){for(let i=P.log.length-1;i>=s.ll;i--){const t=P.log[i].replace(/^[\s\u2714\u2718!\u2192\u2022>-]+/,"").trim();if(t&&!/^=====/.test(t))return t}return ""}
function rtSuite(P,now,jdone,rc){
  const n=P.st.length;let tot=0,dn=0,rem=0,fin=0,warn=0,cur=-1,lastZ=0;
  P.st.forEach(s=>{const w=s.e;tot+=w;if(s.z>lastZ)lastZ=s.z;
    if(s.s==="ok"||s.s==="skip"){dn+=w;fin++}
    else if(s.s==="warn"){dn+=w;fin++;warn++}
    else if(s.s==="run"){cur=s.i;const el=now-s.a;dn+=Math.min(Math.max(el,0),w*.95);rem+=Math.max(w-el,3)}
    else rem+=w});
  let pct=tot?Math.floor(dn*100/tot):0;const all=n>0&&fin===n;if(all){pct=100;rem=0}
  const stopped=jdone&&!all;
  const lab=all?P.plan.done:stopped?"RUKA":P.plan.lab;
  const ph=P.ph.map((name,pi)=>{const ss=P.st.filter(s=>s.p===pi);if(!ss.length)return "";
    const d=ss.every(s=>["ok","warn","skip"].includes(s.s)),a=ss.some(s=>s.s!=="wait");
    return `<span class="${d?"d":a?"a":"w"}">${esc(name)}</span>`}).join("");
  const rows=P.st.map(s=>{const no=String(s.i+1).padStart(2,"0");let ic="&middot;",tm="";
    if(s.s==="ok"){ic="&#10003;";tm=mmss(s.z-s.a)}else if(s.s==="warn"){ic="!";tm=mmss(s.z-s.a)}else if(s.s==="skip"){ic="-";tm="skip"}
    else if(s.s==="run"){ic=jdone?"&#10007;":'<span class="spin"></span>';tm=mmss(now-s.a)}
    const last=s.s==="run"?rtLast(P,s):"";
    return `<div class="ds-st ${s.s}"><span class="ic">${ic}</span><span class="no">${no}</span><span class="t">${esc(s.t)}</span><span class="tm">${tm}</span>${last?`<div class="ds-last">&boxur; ${esc(last)}</div>`:""}</div>`}).join("");
  const el=(all&&lastZ?lastZ:now)-(P.plan.t0||now);
  const foot=all?`elapsed <b>${mmss(el)}</b> &nbsp; ${warn?`<span class="y">${warn} warning</span>`:'<span class="g">sab steps OK</span>'}`
    :stopped?`elapsed <b>${mmss(el)}</b> &nbsp; <span class="y">job beech me ruk gaya${rc!=null?" (rc "+rc+")":""} - neeche log dekhein</span>`
    :`elapsed <b>${mmss(el)}</b> &nbsp; remaining <b>~${mmss(rem)}</b>`;
  const host=($("#sdom")&&$("#sdom").textContent)||location.hostname;
  return `<div class="ds ${all?(warn?"":"ok"):stopped?"fail":""}">
    <div class="ds-kv"><span>host</span><b>${esc(host)}</b><span>steps</span><b>${n} &middot; ${esc(P.ph.join(" / "))}</b></div>
    <div class="ds-hr"></div>
    <div class="ds-prog"><b class="lab">${esc(lab)}</b><div class="ds-bar"><i style="width:${pct}%"></i></div><b class="pc">${pct}%</b></div>
    <div class="ds-ph">${ph}</div>
    <div class="ds-steps">${rows}</div>
    <div class="ds-hr"></div>
    <div class="ds-foot">${all?`<span class="ds-ready">READY</span>`:""}${foot}</div></div>`;
}
async function runAction(action,params,opt){
  opt=opt||{};
  const r=await api("/api/action",{action,params});
  RUNNING=true;let suite=false;
  modal(`<div class="dsh"><div class="brand"><b>DDK VPS MANAGER</b><i id="jb">${esc(r.title)}</i><small>v${esc(SUITE)}</small></div><span class="sp"></span><span class="spin" id="jsp"></span></div>
    <div class="crumb" id="jt">${esc((PAGES[PAGE]||["Panel"])[0])} &rsaquo; ${esc(r.title)}</div>
    <div id="jds" class="hidden"></div>
    <details class="dlog plain" id="jdl" open><summary>full log</summary><pre class="out" id="jo">Shuru ho raha hai...</pre></details>
    <div id="jx"></div><div class="mfoot"><button class="btn" id="jcopy">Copy output</button><button class="btn pri" id="jclose">Close</button></div>`,true);
  $("#jclose").onclick=()=>{RUNNING=false;closeModal();if(opt.after)opt.after()};
  $("#jcopy").onclick=()=>copy($("#jo").textContent);
  const tick=async()=>{
    let j;try{j=await api("/api/job?id="+r.job)}catch(e){$("#jo").textContent+="\n"+e.message;return}
    const o=$("#jo");if(!o)return;const atEnd=o.scrollTop+o.clientHeight>=o.scrollHeight-30;
    const P=rtParse(j.out),txt=P.log.join("\n").replace(/^\n+/,"");
    o.textContent=txt||"(koi output nahi)";if(atEnd)o.scrollTop=o.scrollHeight;
    if(P.plan&&P.st.length){
      if(!suite){suite=true;$("#jdl").classList.remove("plain");$("#jdl").open=false;$("#jds").classList.remove("hidden");
        $("#jb").textContent=P.plan.badge;$("#jt").textContent=P.plan.sub+" \u00b7 "+r.title}
      $("#jds").innerHTML=rtSuite(P,j.now||Date.now()/1000,j.done,j.rc);
    }
    if(j.done){RUNNING=false;const sp=$("#jsp");if(sp)sp.outerHTML=j.rc===0?'<span class="pill p-ok">done</span>':'<span class="pill p-warn">rc '+esc(j.rc)+'</span>';showLinks(txt);if(opt.after)opt.after()}
    else POLL=setTimeout(tick,800);
  };tick();
}
function showLinks(out){
  const box=$("#jx");if(!box)return;
  const lines=(out||"").split("\n");const links=[];let label="";
  lines.forEach(l=>{const t=l.trim();const m=t.match(/^(Link [A-Z]+(?: [A-Z]+)*)\s*:/);if(m)label=m[1];if(/^(vmess|vless|trojan):\/\//.test(t))links.push([label||t.split(":")[0].toUpperCase(),t])});
  let html="";
  if(links.length){html+=`<div class="links" style="margin-top:12px"><b>Links</b>${links.map((l,i)=>`<div class="lk"><div class="t"><span>${esc(l[0])}</span><span><button class="btn sm" data-c="${i}">Copy</button> <button class="btn sm" data-q="${i}">QR</button></span></div><div class="u">${esc(l[1])}</div><div id="qr${i}"></div></div>`).join("")}</div>`}
  if(/ACCOUNT CREATED/.test(out)){const p=(out.match(/PAYLOAD[^\n]*\n([^\n]+)/)||[])[1];if(p)html+=`<div class="links" style="margin-top:12px"><div class="lk"><div class="t"><span>Payload</span><button class="btn sm" id="cpay">Copy</button></div><div class="u">${esc(p)}</div></div></div>`;
    setTimeout(()=>{const b=$("#cpay");if(b)b.onclick=()=>copy(p)},0)}
  box.innerHTML=html;
  box.querySelectorAll("[data-c]").forEach(b=>b.onclick=()=>copy(links[+b.dataset.c][1]));
  box.querySelectorAll("[data-q]").forEach(b=>b.onclick=()=>qr("qr"+b.dataset.q,links[+b.dataset.q][1]));
}
let QRLIB=null;
function qr(id,text){const el=document.getElementById(id);if(el.innerHTML){el.innerHTML="";return}
  const draw=()=>{el.innerHTML='<div class="qr"></div>';new QRCode(el.firstChild,{text,width:220,height:220,correctLevel:QRCode.CorrectLevel.L})};
  if(window.QRCode)return draw();
  el.innerHTML='<span class="muted">QR load ho raha hai...</span>';
  const s=document.createElement("script");s.src="https://cdn.jsdelivr.net/npm/qrcodejs@1.0.0/qrcode.min.js";s.onload=draw;s.onerror=()=>{el.innerHTML='<span class="muted">QR library load nahi hui (internet?). Link copy kar lein.</span>'};document.head.appendChild(s)}

/* ---------- helpers ---------- */
const ST={active:["p-ok","Active"],expired:["p-bad","Expired"],"gb-limit":["p-warn","GB limit"],"ip-limit":["p-warn","IP limit"],locked:["p-bad","Locked"]};
const pill=s=>{const x=ST[s]||["p-mut",s];return `<span class="pill ${x[0]}">${esc(x[1])}</span>`};
function usage(used,gb){const lim=gb>0?gb*1073741824:0;const pc=lim?Math.min(100,used*100/lim):0;
  return `<div class="mono">${fmtB(used)} / ${gb>0?gb+" GB":"&infin;"}</div>${lim?`<div class="bar ${pc>90?"b":pc>70?"w":""}" style="width:120px"><i style="width:${pc}%"></i></div>`:""}`}
const daysF=()=>({name:"days",label:"Days",type:"number",value:30,req:true});
const gbF=v=>({name:"gb",label:"GB limit (0 = unlimited)",type:"number",value:v==null?0:v});
const ipF=v=>({name:"ip",label:"IP limit (0 = unlimited)",type:"number",value:v==null?0:v});

/* ---------- pages ---------- */
let PAGE="dash",TIMER=null,XP="vmess",FILTER="";
const CRUMB={dash:"overview \u00b7 live status",ssh:"04 \u203a SSH accounts, limits, live IPs",xray:"04 \u203a 09 \u203a VMess / VLESS / Trojan",
  svc:"05 \u203a services + ports",stats:"08 \u203a CPU / RAM / network / speedtest",bot:"09 \u203a bot setup, admins",
  set:"02 / 03 / 06 / 07 \u203a domain, SSL, banner, QoS, maintenance",adm:"10 \u203a panel logins + audit log"};
const PAGES={dash:["Dashboard",dash],ssh:["SSH Accounts",ssh],xray:["Xray Accounts",xray],svc:["Running Services",svc],stats:["VPS Stats & Speedtest",statsPage],bot:["Telegram Bot",botPage],set:["Settings",settingsPage],adm:["Panel Admins",admPage]};
let ME={user:"",role:"viewer"};const LV={viewer:0,admin:1,super:2},RN={viewer:"Viewer",admin:"Admin",super:"Super Admin"};
const can=l=>(LV[ME.role]||0)>=l;
function setMe(j){ME={user:j.user||"",role:j.role||"viewer",scope:j.scope||"all"};document.body.className="lv"+(LV[ME.role]||0)+(ME.scope==="own"?" own":"");
  $("#who").innerHTML=`&#128100; <b>${esc(ME.user)}</b> <span class="rp ${esc(ME.role)}">${esc(RN[ME.role]||ME.role)}${ME.scope==="own"?" &middot; reseller":""}</span>`}
function go(p){if((p==="adm"&&!can(2))||(p==="bot"&&(!can(1)||ME.scope==="own")))p="dash";PAGE=p;location.hash=p;document.querySelectorAll("#nav button").forEach(b=>b.classList.toggle("on",b.dataset.p===p));$("#ttl").innerHTML=`<span class="sbadge">${esc(PAGES[p][0].toUpperCase())}</span><span class="crumb2">menu &rsaquo; ${esc(CRUMB[p]||"")}</span>`;$("#side").classList.remove("open");if(TIMER){clearInterval(TIMER);TIMER=null}FILTER="";SPD_PREV=null;$("#view").innerHTML='<div class="empty"><span class="spin"></span></div>';PAGES[p][1]()}
function reload(){PAGES[PAGE][1](true)}
function fail(e){$("#view").innerHTML=`<div class="err">${esc(e.message)}</div>`}

/* circular stat gauges (SVG ring) */
const ring=(p,c,lab)=>{p=Math.max(0,Math.min(100,+p||0));return `<div class="ring ${c||""}"><svg viewBox="0 0 36 36"><circle class="tr" cx="18" cy="18" r="15.5"/><circle class="fg" cx="18" cy="18" r="15.5" pathLength="100" stroke-dasharray="${p.toFixed(1)} 100"/></svg><b>${esc(lab)}</b></div>`};
const ringSeg=(parts,lab)=>{const t=parts.reduce((a,b)=>a+b,0);let o=0;const segs=t?parts.map((v,i)=>{const w=v*100/t,g=parts.filter(Boolean).length>1&&w>0?1.2:0;const c=w>0?`<circle class="s${i+1}" cx="18" cy="18" r="15.5" pathLength="100" stroke-dasharray="${Math.max(w-g,0).toFixed(1)} 100" stroke-dashoffset="${(-o).toFixed(1)}"/>`:"";o+=w;return c}).join(""):"";return `<div class="ring"><svg viewBox="0 0 36 36"><circle class="tr" cx="18" cy="18" r="15.5"/>${segs}</svg><b>${esc(lab)}</b></div>`};
const ringIc=ic=>`<div class="ring"><svg viewBox="0 0 36 36"><circle class="tr" cx="18" cy="18" r="15.5"/></svg><span>${ic}</span></div>`;
const ICN={net:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M7 4v13"/><path d="M3 13l4 4 4-4"/><path d="M17 20V7"/><path d="M13 11l4-4 4 4"/></svg>',
  srv:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/></svg>'};
async function dash(silent){
  let d;try{d=await api("/api/overview")}catch(e){return fail(e)}
  if(PAGE!=="dash")return;
  $("#sdom").textContent=d.domain;
  const mp=d.mem_total?d.mem_used*100/d.mem_total:0,dp=d.disk_total?d.disk_used*100/d.disk_total:0;
  const bc=p=>p>90?"b":p>70?"w":"";
  const x=d.xray,svcOn=d.services.filter(s=>s.installed&&s.active==="active").length,svcAll=d.services.filter(s=>s.installed).length;
  $("#view").innerHTML=`
  <div class="grid g4">
    <div class="card stat sr">${ring(d.cpu,bc(d.cpu),Math.round(d.cpu)+"%")}<div class="tx"><div class="k">CPU</div><div class="v">${d.cpu}%</div><div class="s">${d.cores} cores &middot; load ${d.load.map(v=>v.toFixed(2)).join(" ")}</div></div></div>
    <div class="card stat sr">${ring(mp,bc(mp),mp.toFixed(0)+"%")}<div class="tx"><div class="k">RAM</div><div class="v">${fmtB(d.mem_used)}</div><div class="s">of ${fmtB(d.mem_total)}</div></div></div>
    <div class="card stat sr">${ring(dp,bc(dp),dp.toFixed(0)+"%")}<div class="tx"><div class="k">Disk</div><div class="v">${fmtB(d.disk_used)}</div><div class="s">of ${fmtB(d.disk_total)}</div></div></div>
    <div class="card stat sr">${ringIc(ICN.net)}<div class="tx"><div class="k">Network</div><div class="v" style="font-size:13px">&darr; ${fmtB(d.net.rx_rate)}/s<br>&uarr; ${fmtB(d.net.tx_rate)}/s</div><div class="s">total &darr; ${fmtB(d.net.rx)} &middot; &uarr; ${fmtB(d.net.tx)}</div></div></div>
    <div class="card stat sr">${ring(d.ssh.total?d.ssh.active*100/d.ssh.total:0,"g",d.ssh.active+"/"+d.ssh.total)}<div class="tx"><div class="k">SSH Accounts</div><div class="v">${d.ssh.active} <span class="muted" style="font-size:12px;font-weight:400">active</span></div><div class="s">${d.ssh.total} total &middot; ${d.ssh.online} online</div></div></div>
    <div class="card stat sr">${ringSeg([x.vmess.total,x.vless.total,x.trojan.total],x.vmess.total+x.vless.total+x.trojan.total)}<div class="tx"><div class="k">Xray Accounts</div><div class="v">${x.vmess.total+x.vless.total+x.trojan.total}</div><div class="s"><i class="dot3" style="background:#5fd7d7"></i>VMess ${x.vmess.total} <i class="dot3" style="background:#7ee787;margin-left:6px"></i>VLESS ${x.vless.total} <i class="dot3" style="background:#f0a35e;margin-left:6px"></i>Trojan ${x.trojan.total}</div></div></div>
    <div class="card stat sr">${ring(svcAll?svcOn*100/svcAll:0,svcOn<svcAll?"w":"g",svcOn+"/"+svcAll)}<div class="tx"><div class="k">Services</div><div class="v">${svcOn} / ${svcAll}</div><div class="s">running / installed</div></div></div>
    <div class="card stat sr">${ringIc(ICN.srv)}<div class="tx"><div class="k">Server</div><div class="v" style="font-size:13px;word-break:break-all">${esc(d.domain)}</div><div class="s">${esc(d.hostname)} &middot; ${esc(d.os)} &middot; up ${fmtDur(d.uptime)}</div></div></div>
  </div>
  <div class="card" style="margin-top:14px"><h3>Services</h3><div class="row">${d.services.filter(s=>s.installed).map(s=>`<div class="svci"><span>${esc(s.label)}</span>${s.active==="active"?'<span class="pill p-ok">running</span>':`<span class="pill p-bad">${esc(s.active)}</span>`}</div>`).join("")||'<span class="muted">Koi service install nahi. Settings &rarr; Install All Components.</span>'}</div></div>`;
  if(!TIMER)TIMER=setInterval(()=>{if(!RUNNING&&$("#ov").classList.contains("hidden"))dash(true)},5000);
}

/* ---------- SSH + Xray users: ek hi table (same columns / badges / actions) + live update ----------
   SSH har 5s, Xray har 8s: sirf usage / online / connected IPs / status / expiry cells badalte hain (page reload nahi,
   modal / search box ko nahi chheda jata). Tab chhupa ho (background) to poll ruk jata hai. */
const SVG=p=>`<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${p}</svg>`;
const IC={
  link:SVG('<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>'),
  edit:SVG('<path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4z"/>'),
  cal:SVG('<rect x="3" y="4" width="18" height="18" rx="2"/><path d="M16 2v4M8 2v4M3 10h18M12 14v4M10 16h4"/>'),
  reset:SVG('<path d="M23 4v6h-6M1 20v-6h6"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/>'),
  own:SVG('<path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/>'),
  pwr:SVG('<path d="M18.36 6.64a9 9 0 1 1-12.73 0"/><path d="M12 2v10"/>'),
  del:SVG('<path d="M3 6h18M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/>'),
  copy:SVG('<rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>')};
const LIVE_MS={ssh:5000,xray:8000};
let UT={kind:"",d:{users:[]}},UBUSY=false,ULAST=0;
const uOnline=u=>{const n=(u.ips||[]).length;return n||(u.sessions?1:0)};
function onPill(u){const n=uOnline(u),lim=+u.ip||0;
  const t=(u.sessions?u.sessions+" session, ":"")+n+" IP online"+(lim>0?" (max "+lim+")":" (IP limit nahi)");
  return n>0?`<span class="onp on${lim>0&&n>lim?" over":""}" title="${esc(t)}"><i></i>${n} / ${lim>0?lim:"&infin;"}</span>`:`<span class="onp" title="${esc(lim>0?"Max "+lim+" IP":"IP limit nahi")}"><i></i>offline</span>`}
function ipList(u){const ips=u.ips||[];if(!ips.length)return '<span class="muted">&mdash;</span>';
  return `<div class="ipl">${ips.slice(0,3).map(x=>`<span class="lvip mono">${esc(x)}</span>`).join("")}${ips.length>3?`<span class="lvip mono" title="${esc(ips.slice(3).join(", "))}">+${ips.length-3}</span>`:""}</div>`}
function useParts(u){const gb=+u.gb||0,lim=gb>0?gb*1073741824:0,pc=lim?Math.min(100,u.used*100/lim):0;
  return {txt:`${fmtB(u.used)} / ${gb>0?gb+" GB":"\u221e"}`,lim:!!lim,pc,cls:"bar"+(pc>90?" b":pc>70?" w":"")}}
function useCell(u){const p=useParts(u);return `<div class="mono ut-t">${esc(p.txt)}</div>${p.lim?`<div class="${p.cls}"><i style="width:${p.pc}%"></i></div>`:""}`}
function expCell(u){const now=Date.now()/1000;
  if(u.status==="expired"||(u.expiry&&u.expiry<=now))return `<span class="exp-x">Expired</span>`;
  if(!u.expiry)return '<span class="muted">Never</span>';
  const sod=t=>{const x=new Date(t);x.setHours(0,0,0,0);return x.getTime()};const dd=Math.round((sod(u.expiry*1000)-sod(Date.now()))/86400000);return `${esc(String(u.expiry_txt||"").slice(0,10))} <span class="muted">(${dd}d)</span>`}
function uCells(u){return {"c-st":pill(u.status),"c-on":onPill(u),"c-ip":ipList(u),"c-exp":expCell(u)}}
function uRow(kind,u){const c=uCells(u);
  const cred=kind!=="ssh"&&u.id?`<div class="cred"><span class="mono" title="${esc(u.id)}">${esc(u.id)}</span><button class="btn ib xs" data-a="copy" title="Copy ${kind==="trojan"?"password":"UUID"}">${IC.copy}</button></div>`:"";
  const b=(a,ic,t,cls)=>`<button class="btn ib ${cls||""}" data-a="${a}" title="${t}">${IC[ic]}</button>`;
  return `<tr data-k="${esc(u.user)}"${u.disabled?' class="dis"':""}><td class="c-st">${c["c-st"]}</td><td><div class="uname">${esc(u.user)}</div>${cred}${ownTag(u)}</td><td class="c-on">${c["c-on"]}</td><td class="c-ip">${c["c-ip"]}</td><td class="c-use">${useCell(u)}</td><td class="c-exp">${c["c-exp"]}</td>
    <td class="c-act">${uActs(kind,u)}</td></tr>`}
function uActs(kind,u){const b=(a,ic,t,cls)=>`<button class="btn ib ${cls||""}" data-a="${a}" title="${t}">${IC[ic]}</button>`;
  return `<div class="acts">${b("links","link",kind==="ssh"?"Account details":"Links / QR")}${b("lim","edit","Limits (GB / IP)","r1")}${b("renew","cal","Renew","r1")}${b("pwr","pwr",u.disabled?"Locked hai - Unlock karein":"Lock (band) karein","r1"+(u.disabled?" off":""))}${b("reset","reset","Reset usage","r1")}${b("own","own","Owner","r2")}${b("del","del","Delete","bad r1")}</div>`}
function uBind(tr){const kind=UT.kind;tr.querySelectorAll("[data-a]").forEach(b=>b.onclick=()=>{
    const u=UT.d.users.find(x=>x.user===tr.dataset.k);if(!u)return;const a=b.dataset.a;
    if(a==="copy")return copy(u.id);if(a==="pwr")return uPower(kind,u);kind==="ssh"?sshAct(a,u):xAct(a,u)})}
function uPower(kind,u){const ssh=kind==="ssh",pl=ssh?"SSH":kind.toUpperCase(),act=(ssh?"ssh_":"x_")+(u.disabled?"unlock":"lock"),pr=ssh?{user:u.user}:{proto:kind,user:u.user};
  if(u.disabled)return runAction(act,pr,{after:reload});
  confirmBox("Lock "+pl+" account",`<b>${esc(u.user)}</b> ko lock (band) karein? Login band ho jayega aur connected ${ssh?"sessions":"connection"} kat ${ssh?"jayenge":"jayega"}. Unlock karne tak band rahega (auto-delete nahi hoga).${ssh?"":"<br><span class=\"muted\" style=\"font-size:11px\">Xray user hataane ke liye Xray restart hota hai: baaki users 1-2 second ke liye reconnect ho sakte hain.</span>"}`,"Lock",()=>runAction(act,pr,{after:reload}))}
function uFiltered(){const f=FILTER.toLowerCase();return UT.d.users.filter(u=>u.user.toLowerCase().includes(f))}
function uDraw(){const tb=$("#tb");if(!tb)return;const kind=UT.kind,rows=uFiltered();
  tb.innerHTML=rows.length?rows.map(u=>uRow(kind,u)).join(""):`<tr><td colspan="7" class="empty">${FILTER?"Is naam ka koi account nahi":"Koi "+esc(UT.label)+" account nahi"}</td></tr>`;
  tb.querySelectorAll("tr[data-k]").forEach((tr,i)=>{tr._h=uCells(rows[i]);tr._dis=!!rows[i].disabled;uBind(tr)});
  uCount()}
function uCount(){const c=$("#ucnt");if(c)c.textContent=UT.d.users.length+(UT.d.users.length===1?" account":" accounts")}
/* sirf badle hue cells update (row / buttons / modal waise hi rehte hain) */
function uPatch(){const tb=$("#tb");if(!tb)return false;const rows=uFiltered(),trs=tb.querySelectorAll("tr[data-k]");
  if(trs.length!==rows.length)return false;for(let i=0;i<rows.length;i++)if(trs[i].dataset.k!==rows[i].user)return false;
  rows.forEach((u,i)=>{const tr=trs[i],c=uCells(u);tr._h=tr._h||{};
    for(const k in c){if(tr._h[k]===c[k])continue;const td=tr.querySelector("."+k);if(td){td.innerHTML=c[k];tr._h[k]=c[k]}}
    if(tr._dis!==!!u.disabled){tr._dis=!!u.disabled;tr.classList.toggle("dis",tr._dis);const ac=tr.querySelector(".c-act");if(ac){ac.innerHTML=uActs(UT.kind,u);uBind(tr)}}
    const td=tr.querySelector(".c-use");if(!td)return;const p=useParts(u),bar=td.querySelector(".bar");
    if(p.lim!==!!bar){td.innerHTML=useCell(u);return}
    const t=td.querySelector(".ut-t");if(t&&t.textContent!==p.txt)t.textContent=p.txt;
    if(bar){if(bar.className!==p.cls)bar.className=p.cls;const w=p.pc+"%";if(bar.firstChild.style.width!==w)bar.firstChild.style.width=w}});
  uCount();return true}
function uStamp(ok){const l=$("#ulive");if(!l)return;l.classList.toggle("off",!ok);
  l.title=ok?"Aakhri update: "+new Date().toLocaleTimeString():"Update nahi hua, agli baar dobara koshish";}
async function uPoll(force){const kind=UT.kind,pg=kind==="ssh"?"ssh":"xray";
  if(PAGE!==pg||UBUSY||(document.hidden&&!force))return;
  if(kind!=="ssh"&&kind!==XP)return;
  UBUSY=true;
  try{const d=await api(kind==="ssh"?"/api/ssh/users":"/api/xray/users?proto="+kind);
    if(PAGE!==pg||UT.kind!==kind||!$("#tb"))return;
    UT.d.users=d.users||[];if(d.quota!==undefined)UT.d.quota=d.quota;
    if(!uPatch())uDraw();ULAST=Date.now();uStamp(true)}
  catch(e){uStamp(false)}finally{UBUSY=false}}
function userPage(kind,label,d,btns,pre){
  UT={kind,label,d};
  const sec=LIVE_MS[kind==="ssh"?"ssh":"xray"]/1000;
  $("#view").innerHTML=`${pre||""}<div class="toolbar"><span class="ucnt" id="ucnt"></span><span class="livep" id="ulive" title="Live"><i></i>Live &middot; har ${sec}s</span>${quotaPill(d.quota)}<span class="sp"></span><input class="input" style="max-width:220px" id="flt" placeholder="Search user..." value="${esc(FILTER)}">${btns}</div>
  <div class="tblw ut"><table><thead><tr><th>Status</th><th>User</th><th>Online</th><th>Connected IPs</th><th>Usage</th><th>Expiry</th><th style="text-align:right">Actions</th></tr></thead><tbody id="tb"></tbody></table></div>`;
  uDraw();uStamp(true);ULAST=Date.now();
  $("#flt").oninput=e=>{FILTER=e.target.value;uDraw()};
  if(TIMER){clearInterval(TIMER);TIMER=null}
  TIMER=setInterval(()=>uPoll(false),LIVE_MS[kind==="ssh"?"ssh":"xray"]);
}
/* tab wapas khula -> foran ek update (background me poll band rehta hai) */
document.addEventListener("visibilitychange",()=>{if(document.hidden)return;if((PAGE==="ssh"||PAGE==="xray")&&Date.now()-ULAST>2000)uPoll(true)});
function sshInfo(u){const dm=(UT.d&&UT.d.domain)||location.hostname;
  modal(`<h2>SSH: ${esc(u.user)}</h2><div class="tblw ut"><table><tbody>
  <tr><td class="muted">Host</td><td class="mono">${esc(dm)}</td></tr><tr><td class="muted">Username</td><td class="mono">${esc(u.user)}</td></tr>
  <tr><td class="muted">Status</td><td>${pill(u.status)}</td></tr><tr><td class="muted">Expiry</td><td>${expCell(u)}</td></tr>
  <tr><td class="muted">Usage</td><td>${useCell(u)}</td></tr><tr><td class="muted">Online</td><td>${onPill(u)}</td></tr>
  <tr><td class="muted">Connected IPs</td><td>${ipList(u)}</td></tr></tbody></table></div>
  <p class="muted" style="font-size:11px">Password panel me save nahi hota (sirf hash). Bhool gaye to Renew / naya account banayein.</p>
  <div class="mfoot"><button class="btn" id="sih">Copy host</button><button class="btn pri" id="six">Close</button></div>`);
  $("#six").onclick=closeModal;$("#sih").onclick=()=>copy(dm)}

async function ssh(){
  let d;try{d=await api("/api/ssh/users")}catch(e){return fail(e)}
  if(PAGE!=="ssh")return;
  userPage("ssh","SSH",d,`<button class="btn ra" id="uconn">&#128268; Connected IPs</button><button class="btn ro" id="uconn2">&#128268; Connected IPs</button><button class="btn pri r1" id="uadd">+ Add account</button>`);
  $("#uconn").onclick=()=>runAction("ssh_connected",{});
  $("#uconn2").onclick=()=>liveModal("ssh","SSH");
  $("#uadd").onclick=()=>form("Create SSH Account",[{name:"user",label:"Username",req:true,ph:"a-z, 0-9, _ -",help:"Sirf a-z A-Z 0-9 _ - (kam se kam 1 letter, max 31)"},{name:"password",label:"Password",req:true},daysF(),gbF(),ipF()],"Create",async v=>{await runAction("ssh_create",v,{after:reload})});
}
const ownTag=u=>u.owner===undefined?"":`<div class="muted" style="font-size:11px" title="Kis login ne banaya">&#128100; ${u.owner?esc(u.owner):"&mdash;"}</div>`;
const quotaPill=q=>q?`<span class="pill p-mut" title="Reseller mode: sirf aap ke banaye accounts dikh rahe hain">Mere accounts: ${q.used}${q.max?" / "+q.max:""}</span>`:"";
async function ownerForm(kind,u){let d;try{d=await api("/api/admins")}catch(e){return toast(e.message)}
  form("Owner: "+u.user,[{name:"owner",label:"Panel login",type:"select",options:[["","— koi nahi (sirf Super/Admin-all dekhenge)"]].concat(d.users.map(x=>[x.user,x.user+" ("+(RN[x.role]||x.role)+(x.scope==="own"?", reseller":"")+")"])),value:u.owner||""}],"Save",
    async v=>{const r=await api("/api/owner",{kind,user:u.user,owner:v.owner});closeModal();toast(r.message);reload()},"Menu / Telegram bot se bane accounts ka koi owner nahi hota. Yahan kisi reseller ko de sakte hain.")}
/* reseller ke liye panel ka apna connected-IPs view (sirf apne users, har 3s refresh) */
let LVT=null;
function liveModal(kind,label){
  modal(`<h2>&#128268; ${esc(label)} Connected IPs <span class="spin" id="lvsp"></span></h2><p class="muted" id="lvh" style="margin-top:-6px"></p><div id="lvb"><div class="empty"><span class="spin"></span></div></div><div class="mfoot"><button class="btn pri" id="lvx">Close</button></div>`,true);
  $("#lvx").onclick=closeModal;
  const lim=(n,x)=>x>0?`${n} / ${x}`:`${n} / &infin;`;
  const tick=async()=>{if(!$("#lvb"))return;let d;try{d=await api("/api/connected?kind="+kind)}catch(e){if($("#lvb"))$("#lvb").innerHTML=`<div class="err">${esc(e.message)}</div>`;return}
    const b=$("#lvb");if(!b)return;const sp=$("#lvsp");if(sp)sp.style.visibility="hidden";
    const nIp=d.rows.reduce((a,r)=>a+r.ips.length,0);
    $("#lvh").innerHTML=(d.window?`Real client IP jo pichhle ${d.window} second me active tha`:"Abhi khule SSH sessions")+` &middot; ${d.rows.length} user, ${nIp} IP &middot; har 3 second update`+(ME.scope==="own"?" &middot; sirf aap ke accounts":"");
    if(!d.log){b.innerHTML='<div class="err">Xray access log nahi mila. Super Admin se kahein: Settings &rarr; Fix SSH-WS / SSL stack.</div>'}
    else if(!d.rows.length){b.innerHTML=`<div class="empty">Abhi aap ka koi ${esc(label)} user connected nahi hai.</div>`}
    else b.innerHTML=`<div class="tblw"><table style="min-width:520px"><thead><tr><th>User</th><th>IPs / Limit</th><th>Connected IPs</th><th>Data</th></tr></thead><tbody>${d.rows.map(r=>`<tr><td><b>${esc(r.user)}</b>${r.sessions?`<div class="muted" style="font-size:11px">${r.sessions} session</div>`:""}</td>
      <td>${r.ip>0&&r.ips.length>r.ip?`<span class="pill p-bad">${lim(r.ips.length,r.ip)}</span>`:lim(r.ips.length,r.ip)}</td>
      <td>${r.ips.map(x=>`<span class="lvip mono" title="${x.last?"last "+esc(x.last)+" &middot; "+x.req+" requests":""}">${esc(x.ip)}${x.last?` <span class="muted">${esc(x.last)}</span>`:""}</span>`).join("")}</td>
      <td>${usage(r.used,r.gb)}</td></tr>`).join("")}</tbody></table></div>`;
    clearTimeout(LVT);LVT=setTimeout(tick,3000)};
  tick();
}
function sshAct(a,u){
  if(a==="links")return sshInfo(u);
  if(a==="own")return ownerForm("ssh",u);
  if(a==="del")return confirmBox("Delete SSH account",`<b>${esc(u.user)}</b> delete karein? Is ke connected sessions bhi kat jayenge.`,"Delete",()=>runAction("ssh_delete",{user:u.user},{after:reload}));
  if(a==="renew")return form("Renew: "+u.user,[{name:"days",label:"Additional days (aaj se)",type:"number",value:30,req:true},{name:"reset",label:"Data usage bhi reset karein (0 GB se shuru)",type:"check",value:false}],"Renew",async v=>{await runAction("ssh_renew",{user:u.user,days:v.days,reset:v.reset},{after:reload})});
  if(a==="lim")return form("Limits: "+u.user,[gbF(u.gb),ipF(u.ip)],"Save",async v=>{await runAction("ssh_limits",{user:u.user,gb:v.gb,ip:v.ip},{after:reload})},`Abhi: ${u.gb||"&infin;"} GB, ${u.ip||"&infin;"} IP &middot; used ${fmtB(u.used)}`);
  if(a==="reset")return confirmBox("Reset usage",`<b>${esc(u.user)}</b> ka data usage 0 karein? (GB-limit lock ho to unlock bhi hoga)`,"Reset",()=>runAction("ssh_reset",{user:u.user},{after:reload}));
}

async function xray(){
  let d;try{d=await api("/api/xray/users?proto="+XP)}catch(e){return fail(e)}
  if(PAGE!=="xray")return;
  const P={vmess:"VMess",vless:"VLESS",trojan:"Trojan"};
  const pre=`<div class="tabs">${Object.keys(P).map(k=>`<button data-x="${k}" class="${k===XP?"on":""}">${P[k]}</button>`).join("")}</div>
  ${d.installed?"":'<div class="err">Xray install nahi hai. Settings &rarr; Install All Components chalayein.</div>'}`;
  userPage(XP,P[XP],d,`<button class="btn ra" id="uconn">&#128268; Connected IPs</button><button class="btn ro" id="uconn2">&#128268; Connected IPs</button><button class="btn pri r1" id="uadd">+ Add account</button>`,pre);
  document.querySelectorAll("[data-x]").forEach(b=>b.onclick=()=>{if(b.dataset.x===XP)return;XP=b.dataset.x;FILTER="";if(TIMER){clearInterval(TIMER);TIMER=null}xray()});
  $("#uconn").onclick=()=>runAction("x_connected",{proto:XP});
  $("#uconn2").onclick=()=>liveModal(XP,P[XP]);
  $("#uadd").onclick=()=>form("Create "+P[XP]+" Account",[{name:"user",label:"Username",req:true,ph:"a-z, 0-9, _ -",help:"Sirf a-z A-Z 0-9 _ - (kam se kam 1 letter). UUID/password khud banega."},daysF(),gbF(),ipF()],"Create",async v=>{v.proto=XP;await runAction("x_create",v,{after:reload})});
}
function xAct(a,u){const p=XP,pl=p.toUpperCase();
  if(a==="own")return ownerForm(p,u);
  if(a==="links")return runAction("x_links",{proto:p,user:u.user});
  if(a==="del")return confirmBox("Delete "+pl+" account",`<b>${esc(u.user)}</b> delete karein?`,"Delete",()=>runAction("x_delete",{proto:p,user:u.user},{after:reload}));
  if(a==="renew")return form("Renew "+pl+": "+u.user,[{name:"days",label:"Additional days (aaj se)",type:"number",value:30,req:true},{name:"reset",label:"Data usage bhi reset karein",type:"check",value:false}],"Renew",async v=>{await runAction("x_renew",{proto:p,user:u.user,days:v.days,reset:v.reset},{after:reload})});
  if(a==="lim")return form("Limits "+pl+": "+u.user,[gbF(u.gb),ipF(u.ip)],"Save",async v=>{await runAction("x_limits",{proto:p,user:u.user,gb:v.gb,ip:v.ip},{after:reload})},`Abhi: ${u.gb||"&infin;"} GB, ${u.ip||"&infin;"} IP &middot; used ${fmtB(u.used)}`);
  if(a==="reset")return confirmBox("Reset usage",`<b>${esc(u.user)}</b> ka data usage 0 karein? (GB-limit / IP-lock hat jayega)`,"Reset",()=>runAction("x_reset",{proto:p,user:u.user},{after:reload}));
}

async function svc(){
  let d;try{d=await api("/api/services")}catch(e){return fail(e)}
  if(PAGE!=="svc")return;
  $("#view").innerHTML=`<div class="toolbar"><button class="btn pri r1 ra" id="rall">&#8635; Restart all VPN services</button><button class="btn" id="stat">&#128202; Status &amp; Ports report</button></div>
  <div class="tblw sec"><table><thead><tr><th>Service</th><th>Status</th><th>Boot</th><th>Uptime</th><th>Memory</th><th>PID</th><th>Actions</th></tr></thead><tbody>${d.services.map(s=>`<tr class="svcrow"><td><b>${esc(s.label)}</b><span class="muted mono">${esc(s.name)}</span></td>
   <td>${!s.installed?'<span class="pill p-mut">not installed</span>':s.active==="active"?`<span class="pill p-ok">${esc(s.sub||"running")}</span>`:`<span class="pill p-bad">${esc(s.active)}</span>`}</td>
   <td>${esc(s.enabled||"-")}</td><td>${s.uptime?fmtDur(s.uptime):"-"}</td><td>${s.memory?fmtB(s.memory):"-"}</td><td class="mono">${s.pid||"-"}</td>
   <td><div class="acts">${s.installed?(s.name==="rt-web"?`<button class="btn sm r1 ra" data-o="restart" data-n="${s.name}">Restart</button>`:`${s.active==="active"?`<button class="btn sm r1 ra" data-o="restart" data-n="${s.name}">Restart</button><button class="btn sm bad r1 ra" data-o="stop" data-n="${s.name}">Stop</button>`:`<button class="btn sm ok r1 ra" data-o="start" data-n="${s.name}">Start</button>`}`)+`<button class="btn sm ra" data-l="${s.name}">Logs</button>`:""}</div></td></tr>`).join("")}</tbody></table></div>
  <div class="card"><h3>Listening ports (TCP)</h3><div class="tblw"><table style="min-width:400px"><thead><tr><th>Port</th><th>Address</th><th>Process</th></tr></thead><tbody>${d.ports.map(p=>`<tr><td class="mono"><b>${p.port}</b></td><td class="mono">${esc(p.addr)}</td><td>${esc(p.proc)}</td></tr>`).join("")||'<tr><td colspan="3" class="empty">-</td></tr>'}</tbody></table></div></div>`;
  $("#rall").onclick=()=>confirmBox("Restart all","ws-proxy, rt-monitor, xray, xray-monitor, haproxy, nginx restart honge. Connected users thodi der ke liye disconnect ho sakte hain.","Restart",()=>runAction("restart_all",{},{after:reload}));
  $("#stat").onclick=()=>runAction("status",{});
  document.querySelectorAll("[data-o]").forEach(b=>b.onclick=()=>{const n=b.dataset.n,o=b.dataset.o;
    const go=()=>runAction("svc",{name:n,op:o},{after:reload});
    if(o==="start")go();else confirmBox(o+" "+n,`<b>${esc(n)}</b> ${o} karein?${["haproxy","nginx","dropbear","ws-proxy","xray"].includes(n)?" Is service ke connected users disconnect ho jayenge.":""}`,o==="stop"?"Stop":"Restart",go)});
  document.querySelectorAll("[data-l]").forEach(b=>b.onclick=()=>runAction("svc_logs",{name:b.dataset.l}));
  if(!TIMER)TIMER=setInterval(()=>{if(!RUNNING&&$("#ov").classList.contains("hidden"))svc()},10000);
}

async function settingsPage(){
  let d;try{d=await api("/api/settings")}catch(e){return fail(e)}
  if(PAGE!=="set")return;
  $("#view").innerHTML=`<div class="grid g2">
  <div class="card r2"><h3>&#127760; Domain</h3><p class="muted" style="margin-top:0">Abhi: <b class="mono">${esc(d.domain)}</b> ${d.ssl?'<span class="pill p-ok">SSL</span>':'<span class="pill p-warn">no SSL</span>'}</p>
    <div class="row"><input class="input" id="dom" placeholder="sub.example.com" value="${d.domain==="No Domain Set"?"":esc(d.domain)}"><button class="btn pri" style="flex:0" id="sdomb">Save</button></div>
    <div class="help">Domain badalne ke baad SSL issue karein. Domain ka A record is VPS ki IP par hona chahiye.</div>
    <div style="margin-top:12px"><button class="btn" id="ssl">&#128274; Issue SSL Certificate</button></div></div>
  <div class="card"><h3>&#128444; SSH Banner</h3><textarea id="ban" maxlength="${d.banner_max}">${esc(d.banner)}</textarea><div class="help">HTML chalta hai, max ${d.banner_max} bytes.</div>
    <div class="mfoot" style="justify-content:flex-start"><button class="btn pri r1 ra" id="banb">Save banner</button><button class="btn r1 ra" id="band">Default banner</button></div></div>
  <div class="card r2"><h3>&#128678; Ping QoS (anti-bufferbloat)</h3><p class="muted" style="margin-top:0">${d.qos.iface?`Active: <b>${esc(d.qos.iface)}</b> @ <b>${esc(d.qos.bw)} Mbit/s</b>`:"QoS configure nahi hai"}</p>
    <div class="row"><input class="input" id="qi" placeholder="Interface (auto)" value="${esc(d.qos.iface||"auto")}"><input class="input" id="qb" type="number" placeholder="Bandwidth Mbit/s" value="${esc(d.qos.bw)}"><button class="btn pri" style="flex:0" id="qset">Apply</button></div>
    <div class="help">Bandwidth = VPS ki REAL speed (Mbit/s).</div>
    <h3 style="margin-top:16px">Per-client caps</h3>
    ${d.qos.caps.length?`<div class="tblw"><table style="min-width:300px"><tbody>${d.qos.caps.map(c=>`<tr><td class="mono">${esc(c.ip)}</td><td>${esc(c.mbit)} Mbit/s</td><td><button class="btn sm bad" data-cap="${esc(c.ip)}">Remove</button></td></tr>`).join("")}</tbody></table></div>`:'<p class="muted">Koi cap nahi</p>'}
    <div class="row" style="margin-top:10px"><input class="input" id="cip" placeholder="Client IP"><input class="input" id="cmb" type="number" placeholder="Max Mbit/s"><button class="btn" style="flex:0" id="cadd">Add cap</button></div>
    <div class="mfoot" style="justify-content:flex-start"><button class="btn" id="qst">Status</button><button class="btn bad" id="qoff">Disable QoS</button></div></div>
  <div class="card r2"><h3>&#128736; Maintenance</h3>
    <div class="sec"><button class="btn" id="fix">&#128295; Fix SSH-WS / SSL stack</button><div class="help">Dropbear, ws-proxy, nginx, haproxy, monitor aur xray dobara configure karta hai.</div></div>
    ${d.xray_repair?`<div class="sec"><button class="btn" id="xrep">&#9889; Xray lib upgrade / repair</button><div class="help">fix-xray-sync.sh chalata hai (connected users ko nahi chhedta).</div></div>`:""}
    <div class="sec"><button class="btn" id="inst">&#128230; Install All Components</button><div class="help">Fresh VPS ke liye. Kaafi time lagta hai.</div></div></div>
  <div class="card"><h3>&#128272; My account</h3>
    <p class="muted" style="margin-top:0">Login: <b class="mono">${esc(ME.user)}</b> <span class="rp ${esc(ME.role)}">${esc(RN[ME.role]||ME.role)}</span></p>
    <label class="f"><span>Purana password</span><input class="input" id="po" type="password" autocomplete="current-password"></label>
    <label class="f"><span>Naya password (min 6)</span><input class="input" id="pn" type="password" autocomplete="new-password"></label>
    <button class="btn pri" id="pch">Change password</button><div class="help">Password badalne par aap ke baaki devices logout ho jayenge.</div>
    <div class="help" style="margin-top:12px">Port ${d.panel.port} &middot; ${d.panel.tls?"HTTPS":"HTTP (cert nahi mila)"} &middot; menu: <span class="mono">${esc(d.panel.menu)}</span> ${d.panel.menu_found?"":'<b style="color:#ff8585">NAHI MILA</b>'} &middot; v${esc(d.panel.version)}</div></div>
  </div>`;
  const A=(a,p,after)=>runAction(a,p,{after:after||reload}).catch(e=>toast(e.message));
  $("#sdomb").onclick=()=>{const v=$("#dom").value.trim();if(!v)return toast("Domain likhein");confirmBox("Domain change",`Domain <b>${esc(v)}</b> set karein? Nginx/HAProxy dobara configure honge.`,"Save",()=>A("domain",{domain:v}))};
  $("#ssl").onclick=()=>confirmBox("Issue SSL",`<b>${esc(d.domain)}</b> ke liye Let's Encrypt cert. HAProxy thodi der ke liye band hoga (port 80 chahiye) - users ek dafa disconnect honge.`,"Issue SSL",()=>A("ssl",{}));
  $("#banb").onclick=()=>A("banner",{banner:$("#ban").value});
  $("#band").onclick=()=>A("banner",{default:true});
  $("#qset").onclick=()=>A("qos_set",{iface:$("#qi").value.trim()||"auto",bw:$("#qb").value.trim()});
  $("#cadd").onclick=()=>A("qos_cap",{ip:$("#cip").value.trim(),mbit:$("#cmb").value.trim()});
  document.querySelectorAll("[data-cap]").forEach(b=>b.onclick=()=>A("qos_cap",{ip:b.dataset.cap,mbit:"0"}));
  $("#qst").onclick=()=>A("qos_status",{},()=>{});
  $("#qoff").onclick=()=>confirmBox("Disable QoS","QoS aur saare caps hat jayenge.","Disable",()=>A("qos_off",{}));
  $("#fix").onclick=()=>confirmBox("Fix stack","Poora SSH-WS / SSL stack dobara banega. Connected users disconnect ho sakte hain.","Run fix",()=>A("fix",{}));
  if($("#xrep"))$("#xrep").onclick=()=>confirmBox("Xray repair","fix-xray-sync.sh chalayein?","Run",()=>A("xray_repair",{}));
  $("#inst").onclick=()=>confirmBox("Install All Components","Saare components install / reinstall honge. Ye kaafi time leta hai.","Install",()=>A("install_all",{}));
  $("#pch").onclick=async()=>{try{await api("/api/password",{old:$("#po").value,new:$("#pn").value});toast("Password badal gaya");settingsPage()}catch(e){toast(e.message)}};
}

/* ---------- VPS stats ---------- */
let HIST=[];const HMAX=150;
function drawChart(cv,series,maxFix,fmt){
  if(!cv)return;const dpr=window.devicePixelRatio||1,w=cv.clientWidth,h=cv.clientHeight;cv.width=w*dpr;cv.height=h*dpr;
  const c=cv.getContext("2d");c.scale(dpr,dpr);c.clearRect(0,0,w,h);
  let mx=maxFix||Math.max(1,...series.flatMap(s=>s.data))*1.15;const L=48,B=6,T=6,W=w-L-4,H=h-T-B;
  c.font="11px system-ui";c.fillStyle="#8b949e";c.strokeStyle="#2a2a2a";c.lineWidth=1;
  for(let i=0;i<=4;i++){const y=T+H*i/4;c.beginPath();c.moveTo(L,y);c.lineTo(L+W,y);c.stroke();c.fillText(fmt(mx*(1-i/4)),2,y+4)}
  series.forEach(s=>{const d=s.data;if(d.length<2)return;c.strokeStyle=s.color;c.lineWidth=2;c.beginPath();
    d.forEach((v,i)=>{const x=L+W*(i+HMAX-d.length)/(HMAX-1),y=T+H*(1-Math.min(v,mx)/mx);i?c.lineTo(x,y):c.moveTo(x,y)});c.stroke();
    c.lineTo(L+W,T+H);c.lineTo(L+W*(HMAX-d.length)/(HMAX-1),T+H);c.closePath();c.fillStyle=s.color+"22";c.fill()});
}
const mbit=b=>(b*8/1e6);
const fmtMb=v=>v>=100?v.toFixed(0):v>=10?v.toFixed(1):v.toFixed(2);
function drawAll(){
  drawChart($("#cv1"),[{color:"#5fd7d7",data:HIST.map(h=>h.cpu)},{color:"#7ee787",data:HIST.map(h=>h.mem_total?h.mem_used*100/h.mem_total:0)}],100,v=>v.toFixed(0)+"%");
  drawChart($("#cv2"),[{color:"#5fd7d7",data:HIST.map(h=>mbit(h.rx_rate))},{color:"#f0a35e",data:HIST.map(h=>mbit(h.tx_rate))}],0,v=>fmtMb(v));
}
function liveText(l){const e=$("#livet");if(!e)return;
  e.innerHTML=`CPU <b>${l.cpu}%</b> &middot; RAM <b>${fmtB(l.mem_used)}</b> / ${fmtB(l.mem_total)} &middot; Swap ${fmtB(l.swap_used)} / ${fmtB(l.swap_total)} &middot; Load ${l.load.map(v=>v.toFixed(2)).join(" ")} &middot; &darr; <b>${fmtMb(mbit(l.rx_rate))}</b> &uarr; <b>${fmtMb(mbit(l.tx_rate))}</b> Mbit/s`}
let SPD_PREV=null,SPD_LAST=0;   /* SPD_PREV: speedtest chalane se pehle ka aakhri result time (null = speedtest nahi chalaya) */
async function statsPage(refresh){
  if(refresh===true)SPD_PREV=null;   /* Refresh button -> sirf history */
  let d;try{d=await api("/api/vps")}catch(e){return fail(e)}
  if(PAGE!=="stats")return;
  const g=d.geo||{},sp=d.speed||[],last=sp[0],vn=d.vnstat;
  SPD_LAST=last?last.t:0;
  const fresh=SPD_PREV!==null&&!!last&&last.t>SPD_PREV;   /* sirf naya result (server ka apna time, clock farq se fark nahi) */
  const dbar=x=>{const p=x.total?x.used*100/x.total:0;return `<div class="bar ${p>90?"b":p>75?"w":""}" style="width:140px;display:inline-block;vertical-align:middle;margin:0 8px 0 0"><i style="width:${p}%"></i></div>${p.toFixed(0)}%`};
  let vnHtml;
  if(!vn.installed)vnHtml=`<p class="muted">vnstat install nahi hai. Ye roz / mahine ka bandwidth record rakhta hai (reboot ke baad bhi).</p><button class="btn r2" id="vni">Install vnstat</button>`;
  else if(!vn.interfaces||!vn.interfaces.length)vnHtml=`<p class="muted">${esc(vn.error||"Abhi data jama ho raha hai, 5-10 minute baad dekhein.")}</p>`;
  else{const i=vn.interfaces[0];const row=x=>`<tr><td class="mono">${esc(x.label)}</td><td>${fmtB(x.rx)}</td><td>${fmtB(x.tx)}</td><td><b>${fmtB(x.rx+x.tx)}</b></td></tr>`;
    vnHtml=`<p class="muted" style="margin-top:0">Interface <b class="mono">${esc(i.name)}</b> &middot; total ${fmtB(i.total.rx+i.total.tx)}</p>
    <div class="tabs" id="vtabs"><button class="on" data-v="m">Monthly</button><button data-v="d">Daily</button></div>
    <div class="tblw"><table style="min-width:360px"><thead><tr><th>Period</th><th>&darr; Download</th><th>&uarr; Upload</th><th>Total</th></tr></thead><tbody id="vtb">${i.months.map(row).join("")||'<tr><td colspan="4" class="empty">-</td></tr>'}</tbody></table></div>`;
    setTimeout(()=>document.querySelectorAll("[data-v]").forEach(b=>b.onclick=()=>{document.querySelectorAll("[data-v]").forEach(x=>x.classList.toggle("on",x===b));$("#vtb").innerHTML=(b.dataset.v==="m"?i.months:i.days).map(row).join("")||'<tr><td colspan="4" class="empty">-</td></tr>'}),0)}
  $("#view").innerHTML=`
  <div class="grid g2">
    <div class="card"><h3>&#128421; Server</h3><div class="kv">
      <span>Hostname</span><span class="mono">${esc(d.hostname)}</span>
      <span>Public IP</span><span class="mono">${esc(g.ip||"-")}</span>
      <span>Location</span><span>${esc([g.city,g.region,g.country].filter(Boolean).join(", ")||"-")}</span>
      <span>Provider</span><span>${esc(g.org||"-")}</span>
      <span>OS</span><span>${esc(d.os)}</span>
      <span>Kernel</span><span class="mono">${esc(d.kernel)} (${esc(d.arch)})</span>
      <span>Virtualization</span><span>${esc(d.virt)}</span>
      <span>CPU</span><span>${esc(d.cpu_model||"-")} &middot; ${d.cores} cores</span>
      <span>Uptime</span><span>${fmtDur(d.uptime)} <span class="muted">(boot ${new Date(d.boot*1000).toLocaleString()})</span></span></div></div>
    <div class="card"><h3>&#9889; Speedtest</h3>
      ${fresh?`<div class="big"><div><span>Ping</span><b>${last.ping!=null?last.ping.toFixed(1):"-"}</b><span>ms</span></div><div><span>&darr; Download</span><b>${fmtMb(last.down)}</b><span>Mbit/s</span></div><div><span>&uarr; Upload</span><b>${fmtMb(last.up)}</b><span>Mbit/s</span></div></div>
      <p class="muted" style="margin:-4px 0 10px;font-size:11px">${new Date(last.t*1000).toLocaleString()}${last.server?" &middot; "+esc(last.server):""}</p>`:sp.length?"":'<p class="muted">Abhi tak koi speedtest nahi hua.</p>'}
      <button class="btn pri r1 ra" id="spd" ${d.live.speedtest_running?"disabled":""}>&#9654; Run Speedtest</button>
      <div class="help">speedtest.net (speedtest-cli${d.speedtest_cli?"":", pehli dafa khud install hoga"}). 30-60 second lagte hain aur us dauraan VPN users ki speed thodi kam ho sakti hai.</div>
      ${!fresh&&sp.length?`<div class="tblw" style="margin-top:12px"><table style="min-width:380px"><thead><tr><th>Time</th><th>Ping</th><th>Down</th><th>Up</th></tr></thead><tbody>${sp.map(x=>`<tr><td>${new Date(x.t*1000).toLocaleString()}</td><td>${x.ping!=null?x.ping.toFixed(1)+" ms":"-"}</td><td>${fmtMb(x.down)} Mbit/s</td><td>${fmtMb(x.up)} Mbit/s</td></tr>`).join("")}</tbody></table></div>`:""}</div>
  </div>
  <div class="card" style="margin-top:14px"><h3>&#128200; Live (har 2 second, pichhle 5 minute)</h3><div id="livet" class="muted" style="margin-bottom:10px"></div>
    <div class="grid g2"><div><div class="legend"><span><i style="background:#5fd7d7"></i>CPU %</span><span><i style="background:#7ee787"></i>RAM %</span></div><canvas class="chart" id="cv1"></canvas></div>
    <div><div class="legend"><span><i style="background:#5fd7d7"></i>Download Mbit/s</span><span><i style="background:#f0a35e"></i>Upload Mbit/s</span></div><canvas class="chart" id="cv2"></canvas></div></div></div>
  <div class="grid g2" style="margin-top:14px">
    <div class="card"><h3>&#128190; Disks</h3><div class="tblw"><table style="min-width:420px"><thead><tr><th>Mount</th><th>Used / Total</th><th>Usage</th></tr></thead><tbody>${d.disks.map(x=>`<tr><td class="mono"><b>${esc(x.mount)}</b><div class="muted">${esc(x.dev)} &middot; ${esc(x.type)}</div></td><td>${fmtB(x.used)} / ${fmtB(x.total)}</td><td>${dbar(x)}</td></tr>`).join("")}</tbody></table></div></div>
    <div class="card"><h3>&#127760; Network interfaces</h3><div class="tblw"><table style="min-width:420px"><thead><tr><th>Interface</th><th>&darr; RX</th><th>&uarr; TX</th></tr></thead><tbody>${d.ifaces.map(x=>`<tr><td><b class="mono">${esc(x.name)}</b><div class="muted mono">${esc(x.addr.join(" "))}</div></td><td>${fmtB(x.rx)}</td><td>${fmtB(x.tx)}</td></tr>`).join("")}</tbody></table></div><div class="help">Boot se ab tak ka total.</div></div>
    <div class="card"><h3>&#128202; Bandwidth usage (vnstat)</h3>${vnHtml}</div>
    <div class="card"><h3>&#9881; Top processes (CPU)</h3><div class="tblw"><table style="min-width:400px"><thead><tr><th>PID</th><th>Process</th><th>CPU</th><th>MEM</th></tr></thead><tbody>${d.procs.map(x=>`<tr><td class="mono">${esc(x.pid)}</td><td>${esc(x.name)}</td><td>${esc(x.cpu)}%</td><td>${esc(x.mem)}% <span class="muted">(${fmtB(x.rss)})</span></td></tr>`).join("")}</tbody></table></div></div>
  </div>`;
  $("#spd").onclick=()=>{const t0=SPD_LAST;runAction("speedtest",{},{after:()=>{SPD_PREV=t0;statsPage()}}).catch(e=>toast(e.message))};
  if($("#vni"))$("#vni").onclick=()=>runAction("vnstat_install",{},{after:statsPage}).catch(e=>toast(e.message));
  if(!HIST.length||Date.now()/1000-HIST[HIST.length-1].t>10)HIST=[];
  HIST.push(d.live);liveText(d.live);drawAll();
  if(!TIMER)TIMER=setInterval(async()=>{if(PAGE!=="stats")return;try{const l=await api("/api/stats");HIST.push(l);if(HIST.length>HMAX)HIST.shift();liveText(l);drawAll()}catch(e){}},2000);
}
window.addEventListener("resize",()=>{if(PAGE==="stats")drawAll()});

/* ---------- Panel admins (super only) ---------- */
const ROLE_HELP={viewer:"Sirf dekh sakta hai: accounts list, connected IPs, links, services status/logs, stats. Kuch badal nahi sakta.",
  admin:"Reseller (default): sirf apne banaye SSH/Xray accounts dekhe aur manage kare, max accounts limit ke saath. 'Sab accounts' scope: saare accounts + services restart, banner, speedtest. Domain/SSL/QoS/install/bot/admins kabhi nahi.",
  super:"Sab kuch, panel admins manage karna bhi."};
const ago=t=>{if(!t)return "-";const s=Date.now()/1000-t;return s<60?"abhi":s<3600?Math.floor(s/60)+" min pehle":s<86400?Math.floor(s/3600)+" ghante pehle":Math.floor(s/86400)+" din pehle"};
const SCOPE_F=v=>({name:"scope",label:"Admin scope (sirf Admin role par lagta hai)",type:"select",options:[["own","Reseller - sirf apne banaye accounts"],["all","Sab accounts + services"]],value:v});
const MAX_F=v=>({name:"max_acc",label:"Max accounts (reseller, 0 = unlimited)",type:"number",value:v||0,help:"SSH + Xray mila kar. Sirf reseller par lagta hai."});
async function admPage(){
  let d;try{d=await api("/api/admins")}catch(e){return fail(e)}
  if(PAGE!=="adm")return;
  const W={"login":"&#9989; Login","login-fail":"&#10060; Galat login","login-blocked":"&#9940; Disabled login","password-change":"&#128272; Password change"};
  $("#view").innerHTML=`
  <div class="toolbar"><button class="btn pri" id="aadd">+ Add panel login</button><span class="muted" style="font-size:11px">${d.users.length} login(s)</span></div>
  <div class="tblw sec"><table><thead><tr><th>Username</th><th>Role</th><th>Accounts</th><th>Status</th><th>Last login</th><th>Created</th><th>Actions</th></tr></thead><tbody>${d.users.map(u=>{const me=u.user===ME.user;return `<tr>
    <td><b>${esc(u.user)}</b>${me?' <span class="pill p-mut">aap</span>':""}${u.note?`<div class="muted" style="font-size:11px">${esc(u.note)}</div>`:""}</td>
    <td><span class="rp ${esc(u.role)}">${esc(RN[u.role]||u.role)}</span>${u.role==="admin"?`<div class="muted" style="font-size:11px;margin-top:3px">${u.scope==="own"?"&#128274; Reseller (sirf apne)":"&#127760; Sab accounts"}</div>`:""}</td>
    <td>${u.accounts}${u.role==="admin"&&u.scope==="own"&&u.max_acc?` / ${u.max_acc}`:""}</td>
    <td>${u.disabled?'<span class="pill p-bad">disabled</span>':'<span class="pill p-ok">active</span>'}</td>
    <td>${u.last_login?`${ago(u.last_login)}<div class="muted mono" style="font-size:11px">${esc(u.last_ip||"")}</div>`:'<span class="muted">kabhi nahi</span>'}</td>
    <td>${u.created?new Date(u.created*1000).toLocaleDateString():"-"}</td>
    <td><div class="acts">${me?'<span class="muted" style="font-size:11px">Settings &rarr; My account</span>':`<button class="btn sm" data-m="role" data-u="${esc(u.user)}">Edit</button><button class="btn sm" data-m="pw" data-u="${esc(u.user)}">Password</button><button class="btn sm ${u.disabled?"ok":""}" data-m="dis" data-u="${esc(u.user)}">${u.disabled?"Enable":"Disable"}</button><button class="btn sm bad" data-m="del" data-u="${esc(u.user)}">Delete</button>`}</div></td></tr>`}).join("")}</tbody></table></div>
  <div class="grid g2 sec">${Object.keys(RN).map(k=>`<div class="card" style="padding:12px 14px"><span class="rp ${k}">${RN[k]}</span><div class="help" style="margin-top:6px">${ROLE_HELP[k]}</div></div>`).join("")}</div>
  <div class="card"><h3>&#128220; Activity log</h3><div class="toolbar" style="margin-top:-4px"><input class="input" style="max-width:240px" id="aflt" placeholder="Filter (user, action, IP)..."></div>
    <div class="tblw"><table class="audit" style="min-width:560px"><thead><tr><th>Time</th><th>User</th><th>Kaam</th><th>Detail</th><th>IP</th></tr></thead><tbody id="atb"></tbody></table></div><div class="help">Aakhri 300 entries. Passwords / tokens kabhi log nahi hote.</div></div>`;
  const drawA=()=>{const f=($("#aflt").value||"").toLowerCase();const rows=d.audit.filter(a=>!f||JSON.stringify(a).toLowerCase().includes(f));
    $("#atb").innerHTML=rows.map(a=>`<tr><td style="white-space:nowrap">${new Date(a.t*1000).toLocaleString()}</td><td><b>${esc(a.user)}</b></td><td>${W[a.what]||`<span class="mono">${esc(a.what)}</span>`}</td><td class="mono" style="word-break:break-all">${esc(a.detail||"")}</td><td class="mono">${esc(a.ip)}</td></tr>`).join("")||'<tr><td colspan="5" class="empty">Koi entry nahi</td></tr>'};
  drawA();$("#aflt").oninput=drawA;
  const op=async(body,inForm)=>{try{const r=await api("/api/admins",body);closeModal();toast(r.message||"OK");admPage()}catch(e){if(inForm)throw e;closeModal();toast(e.message)}};
  $("#aadd").onclick=()=>form("Add panel login",[{name:"user",label:"Username",req:true,ph:"a-z, 0-9, _ -"},{name:"password",label:"Password (min 6)",req:true},
    {name:"role",label:"Role",type:"select",options:Object.keys(RN).map(k=>[k,RN[k]]),value:"admin"},SCOPE_F("own"),MAX_F(0),{name:"note",label:"Note (optional)",ph:"e.g. reseller Ali"}],"Add",
    async v=>{await op({op:"add",user:v.user,password:v.password,role:v.role,scope:v.scope,max_acc:v.max_acc||0,note:v.note||""},1)},"Admin (reseller) = sirf apne accounts. Viewer = sirf dekhna. Super Admin = sab kuch.");
  document.querySelectorAll("[data-m]").forEach(b=>b.onclick=()=>{const u=d.users.find(x=>x.user===b.dataset.u),m=b.dataset.m;
    if(m==="role")return form("Edit: "+u.user,[{name:"role",label:"Role",type:"select",options:Object.keys(RN).map(k=>[k,RN[k]]),value:u.role},SCOPE_F(u.scope==="all"?"all":"own"),MAX_F(u.max_acc),{name:"note",label:"Note",value:u.note||""}],"Save",
      async v=>{const b={op:"update",user:u.user,scope:v.scope,max_acc:v.max_acc||0,note:v.note||""};if(v.role!==u.role)b.role=v.role;await op(b,1)},"Role badalne par is user ke sessions logout ho jayenge. Scope / limit foran lagte hain.");
    if(m==="pw")return form("Reset password: "+u.user,[{name:"password",label:"Naya password (min 6)",req:true}],"Reset",async v=>{await op({op:"update",user:u.user,password:v.password},1)},"Is user ke sab devices logout ho jayenge.");
    if(m==="dis")return confirmBox(u.disabled?"Enable login":"Disable login",`<b>${esc(u.user)}</b> ${u.disabled?"dobara enable karein?":"disable karein? Woh foran logout ho jayega aur login nahi kar sakega."}`,u.disabled?"Enable":"Disable",()=>op({op:"update",user:u.user,disabled:!u.disabled}));
    if(m==="del")return confirmBox("Delete login",`<b>${esc(u.user)}</b> ka panel login delete karein? (SSH/Xray accounts par koi asar nahi)`,"Delete",()=>op({op:"delete",user:u.user}));
  });
}

async function botPage(){
  let d;try{d=await api("/api/bot")}catch(e){return fail(e)}
  if(PAGE!=="bot")return;
  const s=d.service,on=s.active==="active";
  $("#view").innerHTML=`<div class="grid g2">
  <div class="card"><h3>&#9992; Bot status</h3>
    <div class="grid" style="grid-template-columns:130px 1fr;gap:8px 12px;margin-bottom:14px">
      <span class="muted">Service</span><span>${!s.installed?'<span class="pill p-mut">not installed</span>':on?`<span class="pill p-ok">running</span> <span class="muted">${s.uptime?fmtDur(s.uptime):""}</span>`:`<span class="pill p-bad">${esc(s.active)}</span>`}</span>
      <span class="muted">Bot</span><span>${d.username?`<a href="https://t.me/${esc(d.username.slice(1))}" target="_blank" rel="noopener">${esc(d.username)}</a>`:d.configured?'<span class="muted">token check nahi hua</span>':'<span class="muted">setup nahi hua</span>'}</span>
      <span class="muted">Token</span><span class="mono">${esc(d.token||"-")}</span>
      <span class="muted">Super Admin ID</span><span class="mono">${esc(d.super_admin||"-")}</span>
    </div>
    <div class="toolbar" style="margin:0">
      <button class="btn pri r2" id="bset">${d.configured?"Change token / Super Admin":"Setup bot"}</button>
      ${s.installed?(on?'<button class="btn r2" id="brs">Restart</button><button class="btn bad r2" id="bstop">Stop</button>':'<button class="btn ok r2" id="bstart">Start</button>'):""}
      ${s.installed?'<button class="btn" id="blog">Logs</button>':""}
      ${d.script?'<button class="btn r2" id="bupd">Update bot script</button>':""}
      ${d.configured||s.installed?'<button class="btn bad r2" id="brm">Remove bot</button>':""}
    </div>
    <div class="help" style="margin-top:12px">Token @BotFather se milta hai. Super Admin ID (@userinfobot se) ko hi admin management aur uninstall ka access hota hai.</div></div>
  <div class="card"><h3>&#128101; Bot admins</h3>
    <div class="toolbar"><button class="btn pri r2" id="badd" ${d.configured?"":"disabled"}>+ Add admin</button><span class="muted" style="font-size:11px">List bot har message par padhta hai, restart ki zaroorat nahi</span></div>
    <div class="tblw"><table style="min-width:420px"><thead><tr><th>Naam</th><th>Telegram ID</th><th>Added</th><th></th></tr></thead><tbody>
      ${d.super_admin?`<tr><td><b>Super Admin</b> <span class="pill p-ok">owner</span></td><td class="mono">${esc(d.super_admin)}</td><td>-</td><td class="muted" style="font-size:11px">Setup se badlein</td></tr>`:""}
      ${d.admins.map(a=>`<tr><td><b>${esc(a.label)}</b></td><td class="mono">${esc(a.id)}</td><td>${esc(a.date)}</td><td><button class="btn sm bad r2" data-rm="${esc(a.id)}" data-lb="${esc(a.label)}">Remove</button></td></tr>`).join("")}
      ${!d.super_admin&&!d.admins.length?'<tr><td colspan="4" class="empty">Pehle bot setup karein</td></tr>':""}
      ${d.super_admin&&!d.admins.length?'<tr><td colspan="4" class="empty">Koi extra admin nahi</td></tr>':""}
    </tbody></table></div></div>
  </div>`;
  const R=()=>botPage();
  $("#bset").onclick=()=>form(d.configured?"Change token / Super Admin":"Setup Telegram bot",[
    {name:"token",label:"Bot token",ph:d.configured?"Khaali chhodein = purana token":"123456789:AAH...",req:!d.configured,help:"@BotFather se. Panel token ko kabhi wapas nahi dikhata."},
    {name:"admin",label:"Super Admin chat ID",value:d.super_admin,req:true,help:"Numeric ID (@userinfobot). Sirf isko admin management + uninstall milega."}],
    "Save & start",async v=>{await runAction("bot_setup",v,{after:R})});
  const sv=op=>runAction("svc",{name:"rt-bot",op},{after:R});
  if($("#brs"))$("#brs").onclick=()=>sv("restart");
  if($("#bstart"))$("#bstart").onclick=()=>sv("start");
  if($("#bstop"))$("#bstop").onclick=()=>confirmBox("Stop bot","Telegram bot band ho jayega (VPN users par asar nahi).","Stop",()=>sv("stop"));
  if($("#blog"))$("#blog").onclick=()=>runAction("svc_logs",{name:"rt-bot"});
  if($("#bupd"))$("#bupd").onclick=()=>runAction("bot_update",{},{after:R});
  if($("#brm"))$("#brm").onclick=()=>confirmBox("Remove bot","Bot service, token config aur saare bot admins hat jayenge. VPN users par asar nahi.","Remove",()=>runAction("bot_remove",{},{after:R}));
  $("#badd").onclick=()=>form("Add bot admin",[
    {name:"id",label:"Telegram User ID (numeric)",req:true,ph:"123456789",help:"Naye admin ko @userinfobot se apni ID milegi."},
    {name:"label",label:"Naam / label",ph:"Admin"},
    {name:"notify",label:"Telegram par message bhejo",type:"check",value:true}],
    "Add",async v=>{const r=await api("/api/bot/admin",{op:"add",id:v.id,label:v.label,notify:v.notify});closeModal();toast(r.message);R()},
    "Admin users / accounts manage kar sakega. Admin management aur uninstall sirf Super Admin ke paas rehta hai.");
  document.querySelectorAll("[data-rm]").forEach(b=>b.onclick=()=>{const id=b.dataset.rm;
    const m=modal(`<h2>Remove admin</h2><p><b>${esc(b.dataset.lb)}</b> (<span class="mono">${esc(id)}</span>) ka bot access hata dein?</p><label class="f" style="display:flex;gap:8px;align-items:center"><input type="checkbox" id="rmn" checked> Telegram par message bhejo</label><div class="err hidden" id="rme"></div><div class="mfoot"><button class="btn" id="cn">Cancel</button><button class="btn bad" id="cy">Remove</button></div>`);
    $("#cn").onclick=closeModal;
    $("#cy").onclick=async()=>{try{const r=await api("/api/bot/admin",{op:"del",id,notify:$("#rmn").checked});closeModal();toast(r.message);R()}catch(e){const x=$("#rme");x.textContent=e.message;x.classList.remove("hidden")}}});
}

/* ---------- boot ---------- */
function showLogin(){$("#app").classList.add("hidden");$("#login").classList.remove("hidden");closeModal();if(TIMER){clearInterval(TIMER);TIMER=null}}
function showApp(){$("#login").classList.add("hidden");$("#app").classList.remove("hidden");const h=location.hash.slice(1);go(PAGES[h]?h:"dash")}
$("#lform").onsubmit=async e=>{e.preventDefault();$("#lerr").classList.add("hidden");try{const j=await api("/api/login",{user:$("#lu").value.trim(),password:$("#lp").value});$("#lp").value="";setMe(j);showApp()}catch(er){$("#lerr").textContent=er.message;$("#lerr").classList.remove("hidden")}};
$("#nav").onclick=e=>{const b=e.target.closest("button");if(b)go(b.dataset.p)};
$("#refresh").onclick=reload;
$("#menuBtn").onclick=()=>$("#side").classList.toggle("open");
$("#logout").onclick=async()=>{try{await api("/api/logout",{})}catch(e){}showLogin()};
document.addEventListener("keydown",e=>{if(e.key==="Escape"&&!RUNNING)closeModal()});
fetch("/api/me").then(r=>r.json()).then(j=>{if(j.auth){setMe(j);showApp()}else showLogin()}).catch(showLogin);
</script>
</body>
</html>
'''
TLS_ACTIVE = False


class Handler(BaseHTTPRequestHandler):
    server_version = "rt-web"
    sys_version = ""

    def log_message(self, fmt, *args):
        pass

    def client_ip(self):
        return self.client_address[0]

    def send_json(self, obj, code=200, cookie=None):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        if cookie is not None:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(body)

    def cookie_str(self, tok, age):
        return "rtw=%s; Path=/; HttpOnly; SameSite=Strict; Max-Age=%d%s" % (tok, age, "; Secure" if TLS_ACTIVE else "")

    def authed(self):
        for part in self.headers.get("Cookie", "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == "rtw":
                u = valid_token(v)
                if u:
                    return u
        return None

    def scope_list(self, me, kind, users):
        o = load_owners()[kind]
        if is_scoped(me):
            return [u for u in users if o.get(u["user"]) == me["user"]]
        for u in users:
            u["owner"] = o.get(u["user"], "")
        return users

    def quota(self, me):
        if not is_scoped(me):
            return None
        return {"used": owned_counts().get(me["user"], 0), "max": int(me.get("max_acc") or 0)}

    def need(self, me, level):
        if ROLES.get(me.get("role"), 0) >= level:
            return True
        self.send_json({"error": "Aap ke role (%s) ko iski ijazat nahi" % ROLE_NAMES.get(me.get("role"), "?")}, 403)
        return False

    def body_json(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        if n > 65536:
            raise ValueError("request bahut badi hai")
        raw = self.rfile.read(n) if n else b"{}"
        return json.loads(raw.decode() or "{}")

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        if url.path in ("/", "/index.html"):
            body = HTML.replace("__RT_SUITE__", suite_ver()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if not url.path.startswith("/api/"):
            return self.send_json({"error": "not found"}, 404)
        if url.path == "/api/me":
            me = self.authed()
            return self.send_json({"auth": bool(me), "user": me["user"] if me else None,
                                   "role": me.get("role") if me else None,
                                   "scope": user_scope(me) if me else None, "version": VERSION})
        me = self.authed()
        if not me:
            return self.send_json({"error": "login chahiye"}, 401)
        try:
            if url.path == "/api/overview":
                return self.send_json(overview(me))
            if url.path == "/api/ssh/users":
                return self.send_json({"users": self.scope_list(me, "ssh", ssh_users()), "domain": get_domain(),
                                       "quota": self.quota(me)})
            if url.path == "/api/xray/users":
                p = q.get("proto", "vless")
                if p not in PROTOS:
                    return self.send_json({"error": "protocol galat"}, 400)
                users = self.scope_list(me, p, xray_users(p))
                live, _ = xray_live()
                for u in users:
                    u["ips"] = sorted(live.get(u["user"], {}).keys())
                return self.send_json({"users": users, "installed": os.path.isfile(XR_CONF), "quota": self.quota(me)})
            if url.path == "/api/connected":
                k = q.get("kind", "")
                if k not in KINDS:
                    return self.send_json({"error": "kind galat"}, 400)
                return self.send_json(connected_rows(me, k))
            if url.path == "/api/services":
                return self.send_json({"services": services_info(), "ports": listening_ports()})
            if url.path == "/api/settings":
                return self.send_json(settings_info())
            if url.path == "/api/bot":
                if not self.need(me, 1):
                    return
                if is_scoped(me):
                    return self.send_json({"error": "Reseller login ko bot ki ijazat nahi"}, 403)
                return self.send_json(bot_info())
            if url.path == "/api/admins":
                if not self.need(me, 2):
                    return
                cnt = owned_counts()
                us = []
                for u in load_users():
                    x = public_user(u); x["accounts"] = cnt.get(u["user"], 0); us.append(x)
                return self.send_json({"users": us, "audit": audit_tail(), "roles": ROLE_NAMES})
            if url.path == "/api/stats":
                return self.send_json(live_stats())
            if url.path == "/api/vps":
                return self.send_json(vps_info())
            if url.path == "/api/job":
                j = JOBS.get(q.get("id", ""))
                if not j:
                    return self.send_json({"error": "job nahi mila"}, 404)
                return self.send_json({"title": j["title"], "out": clean(j["raw"]), "done": j["done"], "rc": j["rc"],
                                       "now": time.time()})
        except Exception as e:
            return self.send_json({"error": str(e)}, 500)
        return self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        url = urlparse(self.path)
        if self.headers.get("X-RT") != "1":
            return self.send_json({"error": "bad request"}, 400)
        try:
            data = self.body_json()
        except Exception as e:
            return self.send_json({"error": str(e)}, 400)
        if url.path == "/api/login":
            ip = self.client_ip()
            if login_blocked(ip):
                return self.send_json({"error": "Bahut zyada galat koshishein. 10 minute baad try karein."}, 429)
            name = str(data.get("user", "")).strip()[:40]
            with USERS_LOCK:
                lst = load_users()
                u = find_user(lst, name)
                ok = bool(u) and check_password(str(data.get("password", "")), u.get("pass", ""))
                if ok and u.get("disabled"):
                    audit(name, ip, "login-blocked", "disabled account")
                    return self.send_json({"error": "Ye login disable hai. Super Admin se rabta karein."}, 403)
                if ok:
                    if not u.get("sess"):
                        u["sess"] = secrets.token_hex(8)
                    u["last_login"] = int(time.time())
                    u["last_ip"] = ip
                    try:
                        save_users(lst)
                    except Exception:
                        pass
            if ok:
                FAILS.pop(ip, None)
                audit(name, ip, "login")
                return self.send_json({"ok": True, "user": u["user"], "role": u.get("role"), "scope": user_scope(u)},
                                      cookie=self.cookie_str(make_token(u), SESSION_HOURS * 3600))
            FAILS.setdefault(ip, []).append(time.time())
            audit(name if RE_USER.match(name) else "?", ip, "login-fail")
            time.sleep(1)
            return self.send_json({"error": "Username ya password galat"}, 403)
        if url.path == "/api/logout":
            return self.send_json({"ok": True}, cookie=self.cookie_str("x", 0))
        me = self.authed()
        if not me:
            return self.send_json({"error": "login chahiye"}, 401)
        ip = self.client_ip()
        if url.path == "/api/action":
            act = str(data.get("action", ""))
            if not self.need(me, ACTION_ROLE.get(act, 2)):
                return
            params = data.get("params") or {}
            if not isinstance(params, dict):
                return self.send_json({"error": "params galat"}, 400)
            kind = kind_of(act, params) if act in SCOPED_OK and act != "status" else None
            name = str(params.get("user", ""))
            if is_scoped(me) and act not in SCOPED_OK:
                return self.send_json({"error": "Reseller login sirf apne accounts manage kar sakta hai"}, 403)
            if kind and act not in ("ssh_create", "x_create") and is_scoped(me):
                if load_owners()[kind].get(name) != me["user"]:
                    return self.send_json({"error": "Ye account aap ka nahi"}, 403)
            if kind and act in ("ssh_create", "x_create"):
                if not RE_USER.match(name):
                    return self.send_json({"error": "Username galat"}, 400)
                if name in account_names(kind):
                    return self.send_json({"error": "Ye username pehle se maujood hai"}, 400)
                set_owner(kind, name, None)   # purana (stale) owner hatao
                with OWN_LOCK:
                    mx = int(me.get("max_acc") or 0) if is_scoped(me) else 0
                    if mx and owned_counts().get(me["user"], 0) + PENDING.get(me["user"], 0) >= mx:
                        return self.send_json({"error": "Aap ki limit puri ho gayi (%d accounts). Super Admin se baat karein." % mx}, 403)
                    PENDING[me["user"]] = PENDING.get(me["user"], 0) + 1
            try:
                spec = build_action(act, params)
            except ValueError as e:
                if kind and act in ("ssh_create", "x_create"):
                    with OWN_LOCK:
                        PENDING[me["user"]] = max(0, PENDING.get(me["user"], 1) - 1)
                return self.send_json({"error": str(e)}, 400)
            title, cmd, mut, tmo = spec[:4]
            env = spec[4] if len(spec) > 4 else None
            done_cb = spec[5] if len(spec) > 5 else None
            if kind and act in ("ssh_create", "x_create"):
                done_cb = create_done(kind, name, me["user"])
            elif kind and act in ("ssh_delete", "x_delete"):
                done_cb = delete_done(kind, name)
            if ACTION_ROLE.get(act, 2) > 0 or act in ("x_links",):
                audit(me["user"], ip, act, safe_params(data.get("params") or {}))
            return self.send_json({"job": start_job(title, cmd, mut, tmo, env, done_cb), "title": title})
        if url.path == "/api/bot/admin":
            if not self.need(me, 2):
                return
            try:
                with BOT_LOCK:
                    msg = bot_admin_op(data)
            except ValueError as e:
                return self.send_json({"error": str(e)}, 400)
            audit(me["user"], ip, "bot-admin", safe_params(data))
            return self.send_json({"ok": True, "message": msg})
        if url.path == "/api/owner":
            if not self.need(me, 2):
                return
            kind, name, owner = str(data.get("kind", "")), str(data.get("user", "")), str(data.get("owner", "") or "")
            if kind not in KINDS or not RE_PANEL_USER.match(name):
                return self.send_json({"error": "account galat"}, 400)
            if name not in account_names(kind):
                return self.send_json({"error": "Ye account nahi mila"}, 404)
            if owner and not find_user(load_users(), owner):
                return self.send_json({"error": "Ye panel login nahi mila"}, 400)
            set_owner(kind, name, owner or None)
            audit(me["user"], ip, "owner", "%s %s -> %s" % (kind, name, owner or "-"))
            return self.send_json({"ok": True, "message": "%s ab %s ke naam" % (name, owner) if owner else "%s ka owner hata diya" % name})
        if url.path == "/api/admins":
            if not self.need(me, 2):
                return
            try:
                msg = admin_op(me, data)
            except ValueError as e:
                return self.send_json({"error": str(e)}, 400)
            audit(me["user"], ip, "panel-admin " + str(data.get("op", ""))[:10], msg)
            return self.send_json({"ok": True, "message": msg})
        if url.path == "/api/password":
            old, new = str(data.get("old", "")), str(data.get("new", ""))
            if len(new) < 6:
                return self.send_json({"error": "Naya password kam se kam 6 akshar"}, 400)
            with USERS_LOCK:
                lst = load_users()
                u = find_user(lst, me["user"])
                if not u or not check_password(old, u.get("pass", "")):
                    time.sleep(1)
                    return self.send_json({"error": "Purana password galat"}, 403)
                u["pass"] = hash_password(new)
                u["sess"] = secrets.token_hex(8)   # doosre devices logout
                save_users(lst)
            login_file_sync(me["user"], new)
            audit(me["user"], ip, "password-change")
            return self.send_json({"ok": True}, cookie=self.cookie_str(make_token(u), SESSION_HOURS * 3600))
        return self.send_json({"error": "not found"}, 404)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    ctx = None

    def finish_request(self, request, client_address):
        if self.ctx is not None:
            try:
                request.settimeout(15)
                request = self.ctx.wrap_socket(request, server_side=True)
                request.settimeout(None)
            except Exception:
                try:
                    request.close()
                except Exception:
                    pass
                return
        self.RequestHandlerClass(request, client_address, self)


def tls_context():
    if USE_TLS == "off" or not os.path.isfile(CERT):
        return None
    try:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(CERT)
        return ctx
    except Exception as e:
        print("TLS load fail (%s): %s -> plain HTTP" % (CERT, e), flush=True)
        return None


def cert_watcher(srv):
    last = os.path.getmtime(CERT) if os.path.isfile(CERT) else 0
    while True:
        time.sleep(3600)
        try:
            m = os.path.getmtime(CERT)
            if m != last and srv.ctx is not None:
                srv.ctx.load_cert_chain(CERT); last = m
                print("TLS cert reloaded", flush=True)
        except Exception:
            pass


def main():
    global TLS_ACTIVE
    if len(sys.argv) > 1 and sys.argv[1] == "--hash":
        pw = sys.stdin.readline().rstrip("\n")
        print(hash_password(pw)); return
    if os.geteuid() != 0 and not os.environ.get("RT_WEB_DEV"):
        print("root chahiye"); sys.exit(1)
    if "--set-user" in sys.argv:
        return set_user_cli(sys.argv)
    if "--check-user" in sys.argv:
        return check_user_cli(sys.argv)
    if "--del-user" in sys.argv:
        return del_user_cli(sys.argv)
    if "--list-users" in sys.argv:
        for u in load_users():
            print("%-20s %-8s %s" % (u["user"], u.get("role"), "DISABLED" if u.get("disabled") else "active"))
        return
    if not load_users():
        print("Koi login set nahi hai. Pehle: bash install-web.sh"); sys.exit(1)
    srv = Server((BIND, PORT), Handler)
    srv.ctx = tls_context()
    TLS_ACTIVE = srv.ctx is not None
    if TLS_ACTIVE:
        threading.Thread(target=cert_watcher, args=(srv,), daemon=True).start()
    print("rt-web %s listening on %s:%d (%s)" % (VERSION, BIND, PORT, "HTTPS" if TLS_ACTIVE else "HTTP"), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()

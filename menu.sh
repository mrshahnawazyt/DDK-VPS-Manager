#!/bin/bash
# ==============================================================================
# DDK VPS Manager SSH Panel — SSH Direct / SSH-WS / SSH-WS-SSL / SSH-SSL + VMess / VLESS / Trojan
# Architecture : HAProxy (public 80/443, TCP inspect) -> Nginx (TLS term) -> 
#                Rust ws-proxy (WS handshake) -> Dropbear (raw SSH, port 109)
#                HAProxy terminates TLS itself (your domain cert) for SSH-SSL + SSH-WS-SSL
#
# NEW in this version
#   * Real client IP for EVERY protocol: HAProxy -> PROXY protocol -> ws-proxy, which
#     records "real ip + protocol" per connection. (Dropbear alone only ever sees 127.0.0.1.)
#   * rt-monitor service (every 3 s): per-user GB usage + GB limit + IP limit,
#     works on all protocols because every protocol ends in Dropbear.
#   * Manage Users menu: GB/IP limit on Add User, Edit Limits, Reset Usage,
#     Connected IPs (live, with country) and Custom Banner (server message).
#   * Xray-core: VLESS + Trojan over WebSocket on public 80/443 (paths /vless, /trojan),
#     Own menu (Manage Users -> 9): create / delete / renew / list / connected IPs /
#     limits (GB + IP) / reset usage. Xray accounts are separate from SSH accounts.
#
# V2Ray (UDP 8443) aur DNSTT: RESERVED, filhal disabled (see bottom notes).
# ==============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PANEL_NAME="DDK VPS Manager"
BANNER_FILE="/etc/issue.net"
CUSTOM_PATH="/ddkvps"
DOMAIN_FILE="/etc/ddkvps/domain.conf"
SSH_IDENT="SSH-2.0-Raretriccks"

# Internal-only ports (never exposed directly; HAProxy/Nginx sit in front)
DROPBEAR_RAW_PORT=109        # raw dropbear, used by ws-proxy and HAProxy
WSPROXY_PORT=2082            # Rust ws-proxy: HTTP Upgrade -> raw relay to dropbear:109   (label WS)
NGINX_HTTP_PORT=8080         # nginx internal plain HTTP (WS traffic from HAProxy, PROXY protocol)
HAPROXY_TLS_PORT=8444        # HAProxy internal TLS-termination frontend (behind public 443)
HAPROXY_CERT_DIR="/etc/haproxy/certs"
HAPROXY_CERT="${HAPROXY_CERT_DIR}/domain.pem"   # fullchain + privkey of YOUR domain

# Real-IP relay ports (all loopback only). One port per protocol so the panel knows
# which protocol a session used.
WSPROXY_TLS_PORT=2085        # ws-proxy: WebSocket that came through TLS      (label WS-SSL)
RAW_PORT=2083                # ws-proxy: raw relay, SSH Direct on 80/443      (label SSH-Direct)
RAW_TLS_PORT=2084            # ws-proxy: raw relay, SSH-SSL                   (label SSH-SSL)
NGINX_TLS_HTTP_PORT=8081     # nginx internal HTTP for TLS-terminated WS traffic

# Xray (VMess / VLESS / Trojan over WebSocket, behind nginx on 80/443)
XRAY_VLESS_PORT=20001        # loopback, nginx /vless  -> xray
XRAY_TROJAN_PORT=20003       # loopback, nginx /trojan -> xray
XRAY_API_PORT=10085          # loopback, stats API (per-user GB usage)
# Xray direct TLS transports (public ports) = sirf TCP. NOTE: 8444 HAProxy ka internal TLS port hai -> Trojan TCP ke liye 8446
# XHTTP ab loopback par hai (8443/8445/8448): nginx /vless-xhttp /trojan-xhttp /vmess-xhttp -> public 443 (TLS) + 80 (non-TLS)
XRAY_VTCP_PORT=8442          # VLESS  TCP+TLS
XRAY_VXH_PORT=8443           # VLESS  XHTTP (loopback, 80 + 443 nginx se)
XRAY_TXH_PORT=8445           # Trojan XHTTP (loopback, 80 + 443 nginx se)
XRAY_TTCP_PORT=8446          # Trojan TCP+TLS
XRAY_VMESS_PORT=20002        # loopback, nginx /vmess -> xray (VMess WS)
XRAY_MTCP_PORT=8447          # VMess  TCP+TLS
XRAY_MXH_PORT=8448           # VMess  XHTTP (loopback, 80 + 443 nginx se)
XRAY_LIB="/usr/local/lib/rt-xray.sh"
[[ -f "$XRAY_LIB" ]] && . "$XRAY_LIB"

# --- Ping Stability (QoS / anti-bufferbloat) ---
# CAKE AQM on the WAN interface keeps ping flat even when the link is 100% busy
# with downloads. Config: interface + total bandwidth. Optional per-client caps.
QOS_CONF="/etc/ddkvps/qos.conf"            # IFACE=... / BW_MBIT=...
QOS_CAP_FILE="/etc/ddkvps/qos-caps.conf"   # "<client ip> <mbit>" lines
QOS_BIN="/usr/local/bin/rt-qos"

# Limits / monitor
STATE_DIR="/var/lib/ddkvps"
LIM_DIR="${STATE_DIR}/limits"    # <user> : "GB_LIMIT IP_LIMIT"   (0 = unlimited)
USE_DIR="${STATE_DIR}/usage"     # <user> : bytes used (written by rt-monitor)
LCK_DIR="${STATE_DIR}/locked"    # <user> : flag = account locked because GB quota is over
GEO_DIR="${STATE_DIR}/geo"       # country cache for the Connected IPs screen
EXPIRY_DIR="${STATE_DIR}/expiry"    # <user> : EXACT expiry (unix time) = asli expiry (create time + days*24h)
EXLCK_DIR="${STATE_DIR}/explocked"  # <user> : flag = account expiry ki wajah se locked
DEAD_DIR="${STATE_DIR}/dead"        # <user> : unix time jab account expired / locked hua
DIS_DIR="${STATE_DIR}/disabled"     # <user> : panel / menu se MANUAL lock (power button). Unlock tak band; auto-delete NAHI hota
DEAD_GRACE_SECS=3600                # expired / locked account itne seconds baad list se AUTO-DELETE (dubara create karna padega)
RUN_DIR="/run/ddkvps"
LIVE_FILE="${RUN_DIR}/live.txt"  # written by rt-monitor every cycle
MONITOR_BIN="/usr/local/bin/rt-monitor"
MONITOR_CONF="/etc/ddkvps/monitor.conf"
MONITOR_INTERVAL=3               # seconds between limit checks
BANNER_MAX=2000                  # dropbear refuses banner files bigger than this
GIB=1073741824

# --- Reserved for later (DNSTT) — not wired up yet ---
# DNSTT_HTTP_PORT / DNSTT_HTTPS_PORT ...

# apt / dpkg kabhi sawal na pooche (needrestart dialog, conffile prompt) - install beech me atakta nahi
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="/usr/local/sbin:/usr/local/bin:$PATH" ;; esac

if [[ $EUID -ne 0 ]]; then
    # FIX: non-root user (ubuntu / debian / admin) "menu" likhe to error ki jagah khud sudo se khulta hai
    if [[ "${BASH_SOURCE[0]}" == "$0" ]] && command -v sudo >/dev/null 2>&1; then
        exec sudo bash "$(readlink -f "$0")" "$@"
    fi
    echo -e "${RED}[ERROR] Root chahiye: pehle 'sudo -i' chalayein, phir: menu${NC}"
    return 1 2>/dev/null || exit 1
fi

get_domain() {
    [[ -f "$DOMAIN_FILE" ]] && tr -d '\r\n' < "$DOMAIN_FILE" || echo "No Domain Set"
}

press_any_key() {
    # install.sh (RT_NO_PAUSE=1) ya non-interactive run me ENTER ka intezar nahi
    [[ -n "${RT_NO_PAUSE:-}" || ! -t 0 ]] && return 0
    printf '\n  \033[38;5;80m›\033[0m \033[38;5;245mPress [ENTER] to continue...\033[0m'

    read -r
}

# ------------------------------------------------------------------------------
# apt helpers - FIX: fresh VPS par unattended-upgrades / cloud-init pehle 5-15 minute apt/dpkg lock
# pakde rakhte hain. Pehle "apt install" chupchaap fail ho jata tha => unzip / jq missing =>
# Xray install fail (aur dobara "Install All" chalane par hi lagta tha). Ab: lock ka intezar + dpkg
# repair + 3 koshish.
# ------------------------------------------------------------------------------
APT_OPTS=(-y -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
apt_busy() {
    if command -v fuser >/dev/null 2>&1; then
        fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1 && return 0
    fi
    pgrep -x 'apt|apt-get|dpkg|aptitude' >/dev/null 2>&1 && return 0
    pgrep -f 'apt\.systemd\.daily|/usr/bin/unattended-upgrade( |$)' >/dev/null 2>&1
}
apt_wait_lock() {   # [max seconds] -> apt/dpkg free hone tak intezar
    local max=${1:-600} t=0 shown=0
    while apt_busy; do
        (( shown )) || { echo -e "${YELLOW}   … apt/dpkg busy hai (system updates chal rahe hain) - intezar kar raha hoon...${NC}"; shown=1; }
        sleep 5; t=$(( t + 5 ))
        (( t >= max )) && { echo -e "${YELLOW}   ! ${max}s baad bhi apt busy - phir bhi koshish${NC}"; return 1; }
    done
    return 0
}
apt_run() {   # apt_run update | apt_run install pkg...   (3 koshish)
    local try
    for try in 1 2 3; do
        apt_wait_lock 600
        dpkg --configure -a >/dev/null 2>&1
        if [[ "$1" == update ]]; then apt-get "${APT_OPTS[@]}" update && return 0
        else apt-get "${APT_OPTS[@]}" install "${@:2}" && return 0; fi
        echo -e "${YELLOW}   ! apt $1 fail (koshish $try/3) - 10s baad dobara...${NC}"; sleep 10
        [[ "$1" == install ]] && apt-get "${APT_OPTS[@]}" update >/dev/null 2>&1
    done
    return 1
}
pkg_ensure() {   # cmd:package ...  -> jo command missing ho uska package install. 0 = sab mil gaye
    local x miss=()
    for x in "$@"; do command -v "${x%%:*}" >/dev/null 2>&1 || miss+=("${x#*:}"); done
    (( ${#miss[@]} )) || return 0
    apt_run install "${miss[@]}" >/dev/null 2>&1
    for x in "$@"; do command -v "${x%%:*}" >/dev/null 2>&1 || return 1; done
}

# ------------------------------------------------------------------------------
# SSH tunnel users: koi shell / command nahi (sirf tunnel). FIX: pehle users /bin/bash ke saath bante the
# => koi bhi SSH user VPS par command chala sakta tha (DDoS / abuse). Ab shell = /bin/false, group rtvpn,
# OpenSSH (port 22) par ForceCommand + no TTY, Dropbear + OpenSSH dono me remote port-forward band.
# Tunnel (direct-tcpip / -N) pehle jaisa chalta hai.
# ------------------------------------------------------------------------------
RT_NOSHELL="/bin/false"
RT_SSH_GROUP="rtvpn"
ensure_noshell() {   # dropbear sirf /etc/shells wale shell ko login deta hai -> /bin/false wahan hona chahiye
    grep -qxF "$RT_NOSHELL" /etc/shells 2>/dev/null || echo "$RT_NOSHELL" >> /etc/shells
    getent group "$RT_SSH_GROUP" >/dev/null 2>&1 || groupadd -r "$RT_SSH_GROUP" 2>/dev/null || groupadd "$RT_SSH_GROUP" 2>/dev/null
    return 0
}
harden_openssh() {   # OpenSSH (agar chal raha ho): group rtvpn = sirf tunnel
    local cfg=/etc/ssh/sshd_config sshd bak
    [[ -f "$cfg" ]] || return 0
    sshd=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd); [[ -x "$sshd" ]] || return 0
    bak=$(mktemp); cp -a "$cfg" "$bak"
    # Match block hamesha sshd_config ke AAKHIR me (warna neeche wali global settings bhi Match me chali jati hain)
    sed -i '/^# >>> ddkvps-ssh-users >>>/,/^# <<< ddkvps-ssh-users <<</d' "$cfg"
    cat >> "$cfg" << SSHD_EOF
# >>> ddkvps-ssh-users >>>
# DDK VPS Manager: SSH tunnel users (group ${RT_SSH_GROUP}) - koi shell / command / TTY nahi, sirf tunnel
Match Group ${RT_SSH_GROUP}
    ForceCommand ${RT_NOSHELL}
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    PermitTunnel no
    GatewayPorts no
    AllowTcpForwarding local
# <<< ddkvps-ssh-users <<<
SSHD_EOF
    if "$sshd" -t 2>/tmp/sshd-test.log; then
        systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1
        echo -e "${GREEN}   ✔ OpenSSH: ${RT_SSH_GROUP} users ke liye shell / TTY / remote-forward band${NC}"
    else
        cp -a "$bak" "$cfg"
        echo -e "${YELLOW}   ! OpenSSH config test fail - wapas purana rakha (log: /tmp/sshd-test.log)${NC}"
    fi
    rm -f "$bak"
}
harden_ssh_users() {   # maujooda + naye SSH users: shell band. Connected users nahi katte.
    local f u cur n=0 unit=/etc/systemd/system/dropbear.service
    echo -e "${BLUE}   → SSH users: shell / command access band (sirf tunnel)...${NC}"
    ensure_noshell
    for f in "$EXPIRY_DIR"/* "$LIM_DIR"/*; do   # sirf panel ke banaye users (admin ka apna user nahi chheda jata)
        [[ -f "$f" ]] || continue
        u=$(basename "$f"); is_panel_user "$u" || continue
        cur=$(getent passwd "$u" | cut -d: -f7)
        [[ "$cur" == "$RT_NOSHELL" ]] || { usermod -s "$RT_NOSHELL" "$u" 2>/dev/null && n=$(( n + 1 )); }
        id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qxF "$RT_SSH_GROUP" || usermod -aG "$RT_SSH_GROUP" "$u" 2>/dev/null
    done
    echo -e "${GREEN}   ✔ ${n} purane user(s) ka shell band kiya (naye users khud band bante hain)${NC}"
    harden_openssh
    # Dropbear: -k = remote port forwarding band (user VPS par port nahi khol sakta). KillMode=process => users nahi katte
    if [[ -f "$unit" ]] && grep -q '^ExecStart=/usr/sbin/dropbear ' "$unit" && ! grep -qE '^ExecStart=/usr/sbin/dropbear .* -k( |$)' "$unit"; then
        sed -i -E '/^ExecStart=\/usr\/sbin\/dropbear /s/$/ -k/' "$unit"
        systemctl daemon-reload; systemctl restart dropbear
        echo -e "${GREEN}   ✔ Dropbear: remote port forwarding band${NC}"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# "menu" command - FIX: launcher non-root par error deta tha / pehle se koi "menu" ho to banta hi nahi tha
# ------------------------------------------------------------------------------
RT_LAUNCHER_MARK="# ddkvps-launcher"
write_menu_launcher() {   # $1 = launcher path, $2 = menu.sh path
    cat > "$1" << 'LAUNCH_EOF'
#!/bin/bash
# ddkvps-launcher
M="__RT_MENU__"
if [[ ! -f "$M" ]]; then
    for c in /opt/ddkvps/menu.sh /root/menu.sh; do [[ -f "$c" ]] && { M="$c"; break; }; done
fi
if [[ ! -f "$M" ]]; then
    echo "menu.sh nahi mila ($M) - install.sh dobara chalayein."; exit 1
fi
[[ -z "${TERM:-}" || "$TERM" == dumb || "$TERM" == unknown ]] && export TERM=xterm
if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 && exec sudo TERM="$TERM" bash "$M" "$@"
    echo "Root chahiye: pehle 'sudo -i' (ya 'su -') chalayein, phir: menu"; exit 1
fi
grep -q $'\r' "$M" 2>/dev/null && sed -i 's/\r$//' "$M"   # Windows (CRLF) line-endings wali upload theek
exec bash "$M" "$@"
LAUNCH_EOF
    sed -i "s|__RT_MENU__|$2|" "$1"; chmod 755 "$1"
}
ensure_menu_cmd() {   # "menu" + "ddkvps" command hamesha kaam karein
    local self f tgt
    self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)
    [[ -n "$self" && -f "$self" && "$self" != /dev/* && "$self" != /proc/* && "$self" != /tmp/* ]] || return 0
    for f in /usr/local/bin/menu /usr/local/bin/ddkvps; do
        if [[ -e "$f" ]] && ! grep -q "$RT_LAUNCHER_MARK" "$f" 2>/dev/null; then
            mkdir -p /etc/ddkvps/backup; mv -f "$f" "/etc/ddkvps/backup/$(basename "$f").$(date +%s)" 2>/dev/null
        fi
        if [[ -f "$f" ]]; then   # hamara launcher: target sahi ho aur naye format ka ho to chhod do
            tgt=$(sed -n 's/^M="\(.*\)"$/\1/p' "$f" | head -1)
            [[ -n "$tgt" && -f "$tgt" ]] && grep -q 'exec sudo' "$f" && continue
        fi
        write_menu_launcher "$f" "$self"
    done
    return 0
}

# ------------------------------------------------------------------------------
# Dropbear core — raw SSH only, no banner tricks needed beyond identity/ports.
# Listens ONLY on 109 (WS/SSL backend) + 22/447 (direct legacy access).
# Public 80/443 SSH-Direct traffic is routed by HAProxy -> ws-proxy (raw) -> 109.
# ------------------------------------------------------------------------------
build_custom_dropbear() {
    if [[ -x /usr/local/sbin/dropbear-custom ]]; then
        echo -e "${GREEN}   ✔ Custom Dropbear already built.${NC}"
        return
    fi
    echo -e "${BLUE}   → Building Dropbear with identity: ${SSH_IDENT}${NC}"
    apt install -y build-essential zlib1g-dev libssl-dev autoconf wget >/dev/null 2>&1
    local WORKDIR="/usr/src/dropbear-build"
    rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"; cd "$WORKDIR" || return
    if ! wget -q https://matt.ucc.asn.au/dropbear/releases/dropbear-2024.85.tar.bz2; then
        echo -e "${RED}   ✘ Download fail, apt version use hogi.${NC}"; cd /; return
    fi
    tar -xjf dropbear-2024.85.tar.bz2
    cd dropbear-2024.85 || { cd /; return; }
    sed -i "s/#define LOCAL_IDENT \"SSH-2.0-dropbear_\" DROPBEAR_VERSION/#define LOCAL_IDENT \"${SSH_IDENT}\"/" src/sysoptions.h 2>/dev/null
    ./configure >/dev/null 2>&1
    make PROGRAMS="dropbear dbclient dropbearkey dropbearconvert scp" >/dev/null 2>&1
    if [[ -f dropbear ]]; then
        cp -f dropbear /usr/sbin/dropbear
        cp -f dropbear /usr/local/sbin/dropbear-custom
        echo -e "${GREEN}   ✔ Custom Dropbear installed (identity: ${SSH_IDENT}).${NC}"
    else
        echo -e "${RED}   ✘ Build fail, apt version rahegi.${NC}"
    fi
    cd /
}

fix_dropbear_core() {
    mkdir -p /etc/dropbear; chmod 700 /etc/dropbear
    [[ -f /etc/dropbear/dropbear_rsa_host_key ]]     || dropbearkey -t rsa     -f /etc/dropbear/dropbear_rsa_host_key     &>/dev/null
    [[ -f /etc/dropbear/dropbear_ecdsa_host_key ]]   || dropbearkey -t ecdsa   -f /etc/dropbear/dropbear_ecdsa_host_key   &>/dev/null
    [[ -f /etc/dropbear/dropbear_ed25519_host_key ]] || dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key &>/dev/null
    chmod 600 /etc/dropbear/*_host_key 2>/dev/null

    build_custom_dropbear
    rm -rf /etc/systemd/system/dropbear.service.d

    # -p 22 direct legacy, -p 447 direct legacy, -p 109 backend for WS/SSL layers
    cat << DB_CONF > /etc/default/dropbear
NO_START=0
DROPBEAR_PORT=22
DROPBEAR_EXTRA_ARGS="-p ${DROPBEAR_RAW_PORT} -p 447 -b /etc/issue.net -k"
DROPBEAR_BANNER="/etc/issue.net"
DROPBEAR_RECEIVE_WINDOW=65536
DB_CONF

    # Own unit file (same ports/banner as above), because the panel needs two things:
    #  -E            : Dropbear logs to journald -> rt-monitor reads "auth succeeded for 'user'"
    #                  lines from there to know which user owns which session.
    #  KillMode=process : "systemctl restart dropbear" (e.g. after a banner change) does NOT
    #                  disconnect users that are already connected.
    cat << DB_UNIT > /etc/systemd/system/dropbear.service
[Unit]
Description=Dropbear SSH server (DDK VPS Manager)
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/dropbear -EF -p 22 -p ${DROPBEAR_RAW_PORT} -p 447 -b ${BANNER_FILE} -W 65536 -k
KillMode=process
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
DB_UNIT

    systemctl daemon-reload
    systemctl enable dropbear
    systemctl restart dropbear
}

# ------------------------------------------------------------------------------
# TLS cert for HAProxy (SSH-SSL + SSH-WS-SSL both terminate here).
# Uses the Let's Encrypt cert of YOUR domain (fullchain + privkey concatenated).
# If no LE cert exists yet, a self-signed cert for the same domain is used so
# HAProxy can still start; re-run "Issue SSL" to replace it with the real one.
# Client SNI/Host = your domain (any other SNI/bug-host also works, same cert).
# ------------------------------------------------------------------------------
build_haproxy_cert() {
    local DOM; DOM=$(get_domain)
    [[ "$DOM" == "No Domain Set" || -z "$DOM" ]] && DOM="ddkvps.local"
    mkdir -p "$HAPROXY_CERT_DIR"; chmod 700 "$HAPROXY_CERT_DIR"

    local LE="/etc/letsencrypt/live/${DOM}"
    if [[ -f "${LE}/fullchain.pem" && -f "${LE}/privkey.pem" ]]; then
        cat "${LE}/fullchain.pem" "${LE}/privkey.pem" > "$HAPROXY_CERT"
        chmod 600 "$HAPROXY_CERT"
        echo -e "${GREEN}   ✔ HAProxy cert: Let's Encrypt (${DOM})${NC}"
    else
        openssl req -new -x509 -days 3650 -nodes -newkey rsa:2048 \
            -keyout /tmp/hp.key -out /tmp/hp.crt -subj "/CN=${DOM}" >/dev/null 2>&1
        cat /tmp/hp.crt /tmp/hp.key > "$HAPROXY_CERT"
        rm -f /tmp/hp.key /tmp/hp.crt
        chmod 600 "$HAPROXY_CERT"
        echo -e "${YELLOW}   ! Self-signed cert for ${DOM} (Issue SSL se real cert lein).${NC}"
    fi

    # auto-renew: ek hi deploy hook (rt-cert-sync) HAProxy + Xray + Web panel sab ko naya cert deta hai,
    # aur pre/post hooks renewal ke waqt port 80 ka conflict khud sambhalte hain (write_cert_tools)
    write_cert_tools
}

# ------------------------------------------------------------------------------
# Rust ws-proxy (replaces python ws-proxy.py) — now also the "real IP registrar".
#
#   usage: ws-proxy <dropbear host:port> <label:mode:listen_addr> [...]
#     mode ws  : HTTP -> "101 Switching Protocols" (or "200" for CONNECT), then raw relay
#     mode raw : no handshake, straight raw relay (SSH Direct / SSH-SSL from HAProxy)
#
#   Real client IP comes from
#     * PROXY protocol v1 line sent by HAProxy (send-proxy)      -> raw listeners, CONNECT
#     * X-Real-IP header set by nginx (nginx got it via PROXY)   -> WebSocket listeners
#   (X-Forwarded-For is deliberately NOT trusted: clients can fake it.)
#
#   For every relayed connection it writes  /run/ddkvps/map/<local-port>
#   containing "<real ip> <label>". <local-port> is the source port of the connection
#   to dropbear, which is exactly the "127.0.0.1:port" peer dropbear logs -> rt-monitor
#   can therefore turn "127.0.0.1:port" into the real IP + protocol.
# ------------------------------------------------------------------------------
build_rust_wsproxy() {
    echo -e "${BLUE}   → Building Rust ws-proxy (WebSocket handshake + relay + real-IP map)...${NC}"
    if ! command -v rustc &>/dev/null; then
        apt install -y rustc >/dev/null 2>&1
    fi
    if ! command -v rustc &>/dev/null; then
        echo -e "${RED}   ✘ rustc install fail. 'apt install rustc' manually try karein.${NC}"
        return 1
    fi

    mkdir -p /usr/src/ws-proxy-rs
    cat << 'RS_EOF' > /usr/src/ws-proxy-rs/ws_proxy.rs
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{IpAddr, Shutdown, TcpListener, TcpStream};
use std::thread;
use std::time::{Duration, SystemTime};

const MAP_DIR: &str = "/run/ddkvps/map";

fn valid_ip(s: &str) -> bool {
    s.parse::<IpAddr>().is_ok()
}

fn log_ip(ip: &str, label: &str) {
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open("/var/log/ws-proxy.log") {
        let ts = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let _ = writeln!(f, "{} - {} REAL_IP:{}", ts, label, ip);
    }
}

// If the connection starts with a PROXY protocol v1 line, consume it and return the client IP.
fn read_proxy_header(client: &mut TcpStream) -> Option<String> {
    let mut sig = [0u8; 6];
    let n = client.peek(&mut sig).ok()?;
    if n < 6 || &sig != b"PROXY " {
        return None;
    }
    let mut line: Vec<u8> = Vec::with_capacity(108);
    let mut b = [0u8; 1];
    while line.len() < 108 {
        match client.read(&mut b) {
            Ok(1) => line.push(b[0]),
            _ => return None,
        }
        if line.ends_with(b"\r\n") {
            break;
        }
    }
    let s = String::from_utf8_lossy(&line).to_string();
    let p: Vec<&str> = s.trim_end().split(' ').collect();
    if p.len() >= 3 && (p[1] == "TCP4" || p[1] == "TCP6") && valid_ip(p[2]) {
        Some(p[2].to_string())
    } else {
        None
    }
}

fn handle(mut client: TcpStream, target_addr: String, mode: String, label: String) {
    let _ = client.set_nodelay(true);
    let _ = client.set_read_timeout(Some(Duration::from_secs(10)));

    let mut real_ip = client.peer_addr().map(|a| a.ip().to_string()).unwrap_or_default();
    let mut trusted = false; // real IP already given by PROXY protocol
    if let Some(ip) = read_proxy_header(&mut client) {
        real_ip = ip;
        trusted = true;
    }

    let mut leftover: Vec<u8> = Vec::new();
    let mut is_connect = false;

    if mode == "ws" {
        let clone = match client.try_clone() {
            Ok(c) => c,
            Err(_) => return,
        };
        let mut reader = BufReader::new(clone);
        let mut first_line = String::new();
        if reader.read_line(&mut first_line).unwrap_or(0) == 0 {
            return;
        }
        is_connect = first_line.to_uppercase().starts_with("CONNECT");
        // Drain the remaining headers; only X-Real-IP (set by nginx) is used.
        loop {
            let mut line = String::new();
            match reader.read_line(&mut line) {
                Ok(0) | Err(_) => break,
                Ok(_) => {
                    let t = line.trim_end();
                    if t.is_empty() {
                        break;
                    }
                    if !trusted && t.to_lowercase().starts_with("x-real-ip:") {
                        if let Some(v) = t.splitn(2, ':').nth(1) {
                            let ip = v.trim();
                            if valid_ip(ip) {
                                real_ip = ip.to_string();
                            }
                        }
                    }
                }
            }
        }
        // bytes the client already sent behind the headers must not get lost
        leftover = reader.buffer().to_vec();
    }

    let target = match TcpStream::connect(&target_addr) {
        Ok(t) => t,
        Err(_) => {
            if mode == "ws" {
                let _ = client.write_all(b"HTTP/1.1 502 Bad Gateway\r\n\r\n");
            }
            return;
        }
    };
    let _ = target.set_nodelay(true);

    // register real IP for this session (key = our source port towards dropbear)
    let lport = target.local_addr().map(|a| a.port()).unwrap_or(0);
    let mapfile = format!("{}/{}", MAP_DIR, lport);
    let _ = fs::write(&mapfile, format!("{} {}\n", real_ip, label));
    log_ip(&real_ip, &label);

    if mode == "ws" {
        let resp: &[u8] = if is_connect {
            b"HTTP/1.1 200 Connection Established\r\n\r\n"
        } else {
            b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
        };
        if client.write_all(resp).is_err() {
            let _ = fs::remove_file(&mapfile);
            return;
        }
    }
    let _ = client.set_read_timeout(None);

    let mut c_r = match client.try_clone() {
        Ok(c) => c,
        Err(_) => {
            let _ = fs::remove_file(&mapfile);
            return;
        }
    };
    let mut t_w = match target.try_clone() {
        Ok(t) => t,
        Err(_) => {
            let _ = fs::remove_file(&mapfile);
            return;
        }
    };
    if !leftover.is_empty() {
        let _ = t_w.write_all(&leftover);
    }
    let mut t_r = target;
    let mut c_w = client;

    let h1 = thread::spawn(move || {
        let mut buf = [0u8; 32768];
        loop {
            match c_r.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if t_w.write_all(&buf[..n]).is_err() {
                        break;
                    }
                }
            }
        }
        let _ = t_w.shutdown(Shutdown::Both);
    });
    let h2 = thread::spawn(move || {
        let mut buf = [0u8; 32768];
        loop {
            match t_r.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if c_w.write_all(&buf[..n]).is_err() {
                        break;
                    }
                }
            }
        }
        let _ = c_w.shutdown(Shutdown::Both);
    });
    let _ = h1.join();
    let _ = h2.join();
    let _ = fs::remove_file(&mapfile);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: ws-proxy <dropbear host:port> <label:mode:listen_addr> [...]");
        std::process::exit(1);
    }
    let target = args[1].clone();

    // fresh map dir (old sessions died together with the previous process)
    let _ = fs::remove_dir_all(MAP_DIR);
    let _ = fs::create_dir_all(MAP_DIR);

    let mut handles = Vec::new();
    for spec in &args[2..] {
        let mut it = spec.splitn(3, ':');
        let label = it.next().unwrap_or("").to_string();
        let mode = it.next().unwrap_or("").to_string();
        let addr = it.next().unwrap_or("").to_string();
        if label.is_empty() || (mode != "ws" && mode != "raw") || addr.is_empty() {
            eprintln!("bad listener spec: {}", spec);
            std::process::exit(1);
        }
        let listener = TcpListener::bind(&addr).expect("bind failed");
        let target = target.clone();
        handles.push(thread::spawn(move || {
            for stream in listener.incoming() {
                if let Ok(s) = stream {
                    let (t, m, l) = (target.clone(), mode.clone(), label.clone());
                    thread::spawn(move || handle(s, t, m, l));
                }
            }
        }));
    }
    for h in handles {
        let _ = h.join();
    }
}
RS_EOF

    rustc -O -o /usr/local/bin/ws-proxy /usr/src/ws-proxy-rs/ws_proxy.rs 2>/tmp/ws-proxy-build.log
    if [[ -x /usr/local/bin/ws-proxy ]]; then
        echo -e "${GREEN}   ✔ Rust ws-proxy built at /usr/local/bin/ws-proxy${NC}"
    else
        echo -e "${RED}   ✘ Build fail. Log: /tmp/ws-proxy-build.log${NC}"
        return 1
    fi
}

install_wsproxy_service() {
    build_rust_wsproxy || return 1
    cat << SVC_EOF > /etc/systemd/system/ws-proxy.service
[Unit]
Description=DDK VPS Manager Rust WebSocket Proxy + real-IP relay
After=network.target dropbear.service

[Service]
ExecStartPre=/bin/mkdir -p ${RUN_DIR}
ExecStart=/usr/local/bin/ws-proxy 127.0.0.1:${DROPBEAR_RAW_PORT} WS:ws:127.0.0.1:${WSPROXY_PORT} WS-SSL:ws:127.0.0.1:${WSPROXY_TLS_PORT} SSH-Direct:raw:127.0.0.1:${RAW_PORT} SSH-SSL:raw:127.0.0.1:${RAW_TLS_PORT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
SVC_EOF
    systemctl daemon-reload
    systemctl enable ws-proxy >/dev/null 2>&1
    systemctl restart ws-proxy
    echo -e "${GREEN}   ✔ ws-proxy active: WS ${WSPROXY_PORT} | WS-SSL ${WSPROXY_TLS_PORT} | SSH-Direct ${RAW_PORT} | SSH-SSL ${RAW_TLS_PORT} -> dropbear:${DROPBEAR_RAW_PORT}${NC}"
}

# ------------------------------------------------------------------------------
# Nginx: internal-only, PLAIN HTTP on 127.0.0.1 (PROXY protocol from HAProxy).
# TLS is already terminated by HAProxy, so nginx never touches certificates.
# Two listeners: 8080 = WS (came in on plain :80/:443), 8081 = WS-SSL (came through TLS).
# It just forwards the Upgrade request to the matching Rust ws-proxy port and tells it
# the real client IP via X-Real-IP.
# /vless, /trojan and /vmess are forwarded to Xray (loopback) instead of ws-proxy.
# ------------------------------------------------------------------------------
nginx_xhttp_loc() {   # $1 = path, $2 = xray loopback port  (XHTTP: Upgrade nahi, buffering band, lamba timeout)
    cat << XH_EOF
    location $1 {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$2;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Connection "";
        proxy_set_header X-Forwarded-For \$real_client_ip;
        proxy_set_header X-Real-IP \$real_client_ip;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
        client_body_timeout 3600s;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
XH_EOF
}

nginx_vhost() {   # $1 = nginx listen port, $2 = ws-proxy port, $3 = server_name
    cat << NGX_VHOST
server {
    listen 127.0.0.1:$1 proxy_protocol default_server;
    server_name $3 _;
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    # \$remote_addr is now the peer HAProxy saw (send-proxy). If that peer is a known
    # Cloudflare edge IP, trust the CF-Connecting-IP header for the true client IP instead;
    # otherwise (direct / non-CF traffic) keep \$remote_addr as-is. See cf-realip.conf
    # (written by apply_nginx_config) for the \$cf_trusted geo map this depends on.
    set \$real_client_ip \$remote_addr;
    if (\$cf_trusted) {
        set \$real_client_ip \$http_cf_connecting_ip;
    }
    if (\$real_client_ip = "") {
        set \$real_client_ip \$remote_addr;
    }

    # Let's Encrypt HTTP-01 (webroot): cert issue / renew bina HAProxy band kiye (port 80 conflict nahi)
    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        default_type text/plain;
        try_files \$uri =404;
    }

    # XHTTP (VLESS / Trojan / VMess): public 443 (TLS) aur 80 (non-TLS) dono par; real IP X-Forwarded-For se
$(nginx_xhttp_loc /vless-xhttp  "${XRAY_VXH_PORT}")
$(nginx_xhttp_loc /trojan-xhttp "${XRAY_TXH_PORT}")
$(nginx_xhttp_loc /vmess-xhttp  "${XRAY_MXH_PORT}")

    location /vless {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${XRAY_VLESS_PORT};
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$real_client_ip;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$real_client_ip;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location /trojan {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${XRAY_TROJAN_PORT};
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$real_client_ip;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$real_client_ip;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location /vmess {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${XRAY_VMESS_PORT};
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$real_client_ip;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$real_client_ip;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location / {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$2;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$real_client_ip;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location ${CUSTOM_PATH} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$2;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$real_client_ip;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGX_VHOST
}

write_cf_realip_conf() {
    # Cloudflare's published edge IPv4 + IPv6 ranges (https://www.cloudflare.com/ips/).
    # $cf_trusted = 1 only when the connecting peer (as HAProxy/nginx see it) is inside
    # one of these ranges, so CF-Connecting-IP is trusted ONLY when the traffic really
    # came via Cloudflare — anyone hitting the origin IP directly can't spoof this header.
    cat << 'CF_EOF' > /etc/nginx/conf.d/cf-realip.conf
geo $cf_trusted {
    default         0;
    173.245.48.0/20 1;
    103.21.244.0/22 1;
    103.22.200.0/22 1;
    103.31.4.0/22   1;
    141.101.64.0/18 1;
    108.162.192.0/18 1;
    190.93.240.0/20 1;
    188.114.96.0/20 1;
    197.234.240.0/22 1;
    198.41.128.0/17 1;
    162.158.0.0/15  1;
    104.16.0.0/13   1;
    104.24.0.0/14   1;
    172.64.0.0/13   1;
    131.0.72.0/22   1;
    2400:cb00::/32  1;
    2606:4700::/32  1;
    2803:f800::/32  1;
    2405:b500::/32  1;
    2405:8100::/32  1;
    2a06:98c0::/29  1;
    2c0f:f248::/32  1;
}
CF_EOF
}

apply_nginx_config() {
    local MY_DOMAIN; MY_DOMAIN=$(get_domain)
    [[ "$MY_DOMAIN" == "No Domain Set" || -z "$MY_DOMAIN" ]] && MY_DOMAIN="_"

    write_cf_realip_conf
    mkdir -p "${ACME_ROOT}/.well-known/acme-challenge"

    {
        nginx_vhost "${NGINX_HTTP_PORT}"     "${WSPROXY_PORT}"     "${MY_DOMAIN}"
        nginx_vhost "${NGINX_TLS_HTTP_PORT}" "${WSPROXY_TLS_PORT}" "${MY_DOMAIN}"
    } > /etc/nginx/conf.d/vpn.conf

    # default site would grab public :80 and block HAProxy
    rm -f /etc/nginx/sites-enabled/default
    if nginx -t 2>/tmp/nginx-test.log; then
        systemctl enable nginx >/dev/null 2>&1
        if systemctl is-active --quiet nginx; then systemctl reload nginx; else systemctl restart nginx; fi
        sleep 1
        if ss -tln | grep -q "127.0.0.1:${NGINX_HTTP_PORT}"; then
            echo -e "${GREEN}   ✔ Nginx listening on 127.0.0.1:${NGINX_HTTP_PORT} (WS) + ${NGINX_TLS_HTTP_PORT} (WS-SSL)${NC}"
        else
            echo -e "${RED}   ✘ Nginx start hua lekin ${NGINX_HTTP_PORT} par listen nahi kar raha:${NC}"
            journalctl -u nginx -n 15 --no-pager
            return 1
        fi
    else
        echo -e "${RED}   ✘ nginx config test FAIL (SSH-WS/WS-SSL isi wajah se chalte nahi):${NC}"
        cat /tmp/nginx-test.log
        return 1
    fi
}

# ------------------------------------------------------------------------------
# HAProxy: single public entry on 80/443.
#
#   80  : "SSH-" banner -> ws-proxy raw relay (SSH Direct)
#         CONNECT       -> ws-proxy WS
#         else          -> nginx:8080             (SSH-WS, VLESS, Trojan)
#
#   443 : "SSH-" banner -> ws-proxy raw relay     (SSH Direct)
#         plain HTTP    -> nginx:8080             (SSH-WS on 443, no TLS)
#         TLS (any SNI) -> internal TLS frontend :8444, which terminates TLS
#                          with YOUR domain cert, then looks at decrypted bytes:
#                            HTTP request -> nginx:8081 -> ws-proxy   (SSH-WS-SSL, VLESS-TLS, Trojan-TLS)
#                            anything else (SSH banner) -> ws-proxy raw (SSH-SSL)
#
# Every hop towards Dropbear uses the PROXY protocol, so ws-proxy learns the REAL client
# IP and records it for rt-monitor. SNI is NOT used for routing, so clients just set
# SNI/Host = your domain (or any bug host). UDP/QUIC 8443 (V2Ray) intentionally NOT bound yet.
# ------------------------------------------------------------------------------
install_haproxy() {
    echo -e "${BLUE}   → Installing HAProxy multiplexer (80/443)...${NC}"
    apt install -y haproxy >/dev/null 2>&1
    build_haproxy_cert

    cat << HAPROXY_EOF > /etc/haproxy/haproxy.cfg
global
    maxconn 20000
    log /dev/log local0
    daemon
    tune.ssl.default-dh-param 2048
    ssl-default-bind-options ssl-min-ver TLSv1.2

defaults
    mode tcp
    log global
    option tcplog
    timeout connect 5s
    timeout client 6h
    timeout server 6h
    timeout tunnel 6h

# ---------------- PUBLIC :80 ----------------
frontend ft_http
    bind *:80
    tcp-request inspect-delay 3s
    tcp-request content accept if { req.len ge 4 }
    acl is_ssh req.payload(0,4) -m str SSH-
    acl is_connect req.payload(0,7) -m str CONNECT
    use_backend bk_ssh_direct if is_ssh
    use_backend bk_ws_direct  if is_connect
    default_backend bk_http_ws

# ---------------- PUBLIC :443 ----------------
frontend ft_https
    bind *:443
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.len ge 4 }
    acl is_ssh  req.payload(0,4) -m str SSH-
    acl is_tls  req_ssl_hello_type 1
    acl is_http req.proto_http
    acl is_connect req.payload(0,7) -m str CONNECT
    use_backend bk_ssh_direct if is_ssh
    use_backend bk_tls_term   if is_tls
    use_backend bk_ws_direct  if is_connect
    use_backend bk_http_ws    if is_http
    default_backend bk_ssh_direct

# ---------------- INTERNAL TLS TERMINATION ----------------
frontend ft_tls_internal
    bind 127.0.0.1:${HAPROXY_TLS_PORT} ssl crt ${HAPROXY_CERT} accept-proxy alpn http/1.1
    tcp-request inspect-delay 8s
    tcp-request content accept if HTTP or { req.payload(0,4) -m str SSH- }
    acl is_http_method method GET POST HEAD PUT OPTIONS
    acl is_http_proto req.proto_http
    acl is_connect req.payload(0,7) -m str CONNECT
    use_backend bk_ws_direct_tls if is_connect
    use_backend bk_http_ws_tls if is_http_method or is_http_proto
    default_backend bk_ssh_tls

# ---------------- BACKENDS ----------------
# SSH Direct on 80/443 -> ws-proxy raw relay (records real IP) -> dropbear
backend bk_ssh_direct
    server relay_ssh 127.0.0.1:${RAW_PORT} send-proxy

# SSH-SSL (decrypted by HAProxy) -> ws-proxy raw relay -> dropbear
backend bk_ssh_tls
    server relay_ssh_tls 127.0.0.1:${RAW_TLS_PORT} send-proxy

# CONNECT-style handshake, plain / through TLS
backend bk_ws_direct
    server ws_proxy 127.0.0.1:${WSPROXY_PORT} send-proxy

backend bk_ws_direct_tls
    server ws_proxy_tls 127.0.0.1:${WSPROXY_TLS_PORT} send-proxy

# HTTP Upgrade websocket via nginx, plain / through TLS
backend bk_http_ws
    server nginx_http 127.0.0.1:${NGINX_HTTP_PORT} send-proxy-v2

backend bk_http_ws_tls
    server nginx_http_tls 127.0.0.1:${NGINX_TLS_HTTP_PORT} send-proxy-v2

backend bk_tls_term
    server tls_internal 127.0.0.1:${HAPROXY_TLS_PORT} send-proxy-v2

# --- Reserved for later ---
# frontend ft_v2ray_udp
#     bind quic4@:8443 ...
HAPROXY_EOF

    if ! haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1; then
        echo -e "${RED}   ✘ haproxy.cfg invalid:${NC}"
        haproxy -c -f /etc/haproxy/haproxy.cfg
        return 1
    fi

    systemctl daemon-reload
    systemctl enable haproxy >/dev/null 2>&1
    systemctl restart haproxy

    if systemctl is-active --quiet haproxy; then
        echo -e "${GREEN}   ✔ HAProxy active — SSH Direct + SSH-WS + SSH-WS-SSL + SSH-SSL multiplexed.${NC}"
    else
        echo -e "${RED}   ✘ HAProxy start fail. 'journalctl -u haproxy -n 40' check karein.${NC}"
        echo -e "${YELLOW}     Common cause: port 80/443 busy (ss -tlnp | grep -E ':80|:443').${NC}"
    fi
}

# ------------------------------------------------------------------------------
# rt-monitor : the limit engine. Runs as a systemd service, one cycle every 3 s.
#
#  Why this works for ALL protocols: SSH Direct, SSH-SSL, SSH-WS and SSH-WS-SSL all end
#  in the same Dropbear. So the monitor looks at Dropbear's own sockets:
#    * traffic  : `ss -i` gives bytes_received + bytes_acked of every Dropbear session
#    * user     : Dropbear's log line "auth succeeded for 'user' from 127.0.0.1:PORT"
#    * real IP  : PORT -> /run/ddkvps/map/PORT written by ws-proxy (see above);
#                 sessions on the direct ports 22/447/109 already show the real IP.
#  GB limit : usage >= limit  -> usermod -L (login blocked) + live sessions killed.
#             Raising the limit / resetting usage / renewing unlocks automatically.
#  IP limit : more distinct real IPs than allowed -> the NEWEST IPs are kicked, the
#             oldest ones stay connected.
# ------------------------------------------------------------------------------
install_monitor_service() {
    echo -e "${BLUE}   → Installing rt-monitor (GB + IP limit, every ${MONITOR_INTERVAL}s)...${NC}"
    mkdir -p /etc/ddkvps "$LIM_DIR" "$USE_DIR" "$LCK_DIR" "$GEO_DIR" "$EXPIRY_DIR" "$EXLCK_DIR" "$DEAD_DIR" "$RUN_DIR"
    cat << MONCONF_EOF > "$MONITOR_CONF"
INTERVAL=${MONITOR_INTERVAL}
DB_PORTS="22 ${DROPBEAR_RAW_PORT} 447"
DEAD_GRACE=${DEAD_GRACE_SECS}
MONCONF_EOF

    cat << 'MON_EOF' > "$MONITOR_BIN"
#!/bin/bash
# rt-monitor - DDK VPS Manager limit monitor (see install_monitor_service in the panel script)
# rt-monitor-v2-disable : manual lock (DIS_DIR) support
CONF="/etc/ddkvps/monitor.conf"
STATE_DIR="/var/lib/ddkvps"
LIM_DIR="$STATE_DIR/limits"; USE_DIR="$STATE_DIR/usage"; LCK_DIR="$STATE_DIR/locked"; IPL_DIR="$STATE_DIR/iplocked"
EXPIRY_DIR="$STATE_DIR/expiry"; EXLCK_DIR="$STATE_DIR/explocked"; DEAD_DIR="$STATE_DIR/dead"; DIS_DIR="$STATE_DIR/disabled"
RUN_DIR="/run/ddkvps";  MAP_DIR="$RUN_DIR/map";     AUTH_DIR="$RUN_DIR/auth"
LIVE="$RUN_DIR/live.txt"
INTERVAL=3
DEAD_GRACE=3600
DB_PORTS="22 109 447"
GIB=1073741824
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"

mkdir -p "$LIM_DIR" "$USE_DIR" "$LCK_DIR" "$IPL_DIR" "$EXPIRY_DIR" "$EXLCK_DIR" "$DEAD_DIR" "$DIS_DIR" "$MAP_DIR" "$AUTH_DIR"

FILTER="("; sep=""
for p in $DB_PORTS; do FILTER+="$sep sport = :$p"; sep=" or"; done
FILTER+=" )"

# ss output -> one line per dropbear session:  <local port> <peer ip:port> <pid|-> <bytes rx+tx>
SS_AWK='
function flush(   n,i,f,c,loc,peer,pid,rx,tx) {
  if (cur == "") return
  n = split(cur, f, /[ \t]+/); c = 0; loc = ""; peer = ""
  for (i = 1; i <= n; i++) if (f[i] ~ /:[0-9]+$/ && c < 2) { if (c == 0) loc = f[i]; else peer = f[i]; c++ }
  if (peer != "") {
    sub(/.*:/, "", loc)
    pid = "-"; rx = 0; tx = 0
    if (match(cur, /pid=[0-9]+/))            pid = substr(cur, RSTART + 4,  RLENGTH - 4)
    if (match(cur, /bytes_received:[0-9]+/)) rx  = substr(cur, RSTART + 15, RLENGTH - 15)
    if (match(cur, /bytes_acked:[0-9]+/))    tx  = substr(cur, RSTART + 12, RLENGTH - 12)
    printf "%s %s %s %.0f\n", loc, peer, pid, rx + tx
  }
  cur = ""
}
/^(State|Recv-Q|Netid)/ { next }
/^[ \t]/ { cur = cur " " $0; next }
{ flush(); cur = $0 }
END { flush() }
'

# ---- who owns which session: read Dropbear's auth log lines -----------------
parse_auth() {
    local l="$1" ip
    local re="auth succeeded for '([^']+)'.* from ([^ ]+):([0-9]+)[[:space:]]*\$"
    [[ "$l" =~ $re ]] || return
    ip="${BASH_REMATCH[2]}"; ip="${ip#[}"; ip="${ip%]}"
    printf '%s' "${BASH_REMATCH[1]}" > "$AUTH_DIR/${ip//:/_}_${BASH_REMATCH[3]}"
}

follow_auth() {
    local from=(--since "-7 days")      # first run also back-fills already open sessions
    while true; do
        journalctl -u dropbear "${from[@]}" -f -o cat --no-pager 2>/dev/null \
            | grep --line-buffered 'auth succeeded' \
            | while IFS= read -r l; do parse_auth "$l"; done
        from=(-n 0)
        sleep 2
    done
}

cleanup_auth() {     # remove auth records of sessions that are long gone
    local f k
    while IFS= read -r -d '' f; do
        k=${f##*/}
        [[ -z "${SEEN[$k]}" ]] && rm -f "$f"
    done < <(find "$AUTH_DIR" -type f -mmin +2 -print0 2>/dev/null)
}

# manual lock (power button) wala account kabhi auto-unlock nahi hota
unlock_u() { [[ -e "$DIS_DIR/$1" ]] || usermod -U "$1" 2>/dev/null; }

kill_session() {     # $1 = session key, $2 = reason ; TERM first, KILL if it survives a cycle
    local key="$1" pid="${S_PID[$1]}"
    [[ -z "$pid" ]] && return
    if [[ -n "${KILLED[$key]}" ]]; then kill -9 "$pid" 2>/dev/null
    else kill "$pid" 2>/dev/null; KILLED[$key]=$now; fi
    echo "KICK: $2 (pid $pid, ${S_IP[$key]})"
}

# ---- expiry: EXACT time (create time + days*24h). Dropbear shadow-expiry check nahi karta, isliye
#      monitor khud enforce karta hai: expired -> lock + live sessions kill.
migrate_expiry() {   # purane accounts (sirf shadow expire date) -> exact expiry file (us date ke din ke END tak)
    local u e uid
    while IFS=: read -r u _ _ _ _ _ _ e _; do
        [[ "$e" =~ ^[0-9]+$ ]] || continue
        [[ -e "$EXPIRY_DIR/$u" ]] && continue
        uid=$(id -u "$u" 2>/dev/null) || continue
        (( uid >= 1000 && uid < 60000 )) || continue
        echo $(( e * 86400 + 86399 )) > "$EXPIRY_DIR/$u"
    done < /etc/shadow
}

enforce_expiry() {
    local f u e key
    (( first || ncycle % 100 == 50 )) && migrate_expiry
    for f in "$EXPIRY_DIR"/*; do
        [[ -e "$f" ]] || continue
        u=${f##*/}; e=0
        read -r e 2>/dev/null < "$f"; e=${e//[!0-9]/}; e=$((10#${e:-0}))
        if (( e > 0 && now >= e )); then
            if [[ ! -e "$EXLCK_DIR/$u" ]]; then
                : > "$EXLCK_DIR/$u"; usermod -L "$u" 2>/dev/null
                echo "EXPIRED: $u -> account locked"
            fi
            for key in ${U_KEYS[$u]}; do kill_session "$key" "account expired $u"; done
        elif [[ -e "$EXLCK_DIR/$u" ]]; then
            [[ -e "$LCK_DIR/$u" || -e "$IPL_DIR/$u" ]] || unlock_u "$u"
            rm -f "$EXLCK_DIR/$u"; echo "EXUNLOCK: $u (renewed)"
        fi
    done
}

# ---- expired / locked (GB-limit, IP-limit, expiry) account -> DEAD_GRACE (1 ghanta) baad AUTO-DELETE.
#      Is dauran renew / limit badhane / usage reset se account bach sakta hai; delete ke baad dubara create karna padega.
reap_dead() {
    local f u uid e eds lds ds cur key
    local -A cand=()
    for f in "$EXPIRY_DIR"/* "$LCK_DIR"/* "$IPL_DIR"/* "$EXLCK_DIR"/* "$DEAD_DIR"/* "$DIS_DIR"/*; do
        [[ -e "$f" ]] && cand[${f##*/}]=1
    done
    for u in "${!cand[@]}"; do
        if ! uid=$(id -u "$u" 2>/dev/null); then       # user pehle hi delete ho chuka: bacha hua state saaf karo
            rm -f "$EXPIRY_DIR/$u" "$LCK_DIR/$u" "$IPL_DIR/$u" "$EXLCK_DIR/$u" "$DEAD_DIR/$u" "$DIS_DIR/$u" "$LIM_DIR/$u" "$USE_DIR/$u"
            continue
        fi
        (( uid >= 1000 && uid < 60000 )) || continue
        eds=""; lds=""; cur=""
        e=0; [[ -r "$EXPIRY_DIR/$u" ]] && read -r e 2>/dev/null < "$EXPIRY_DIR/$u"
        e=${e//[!0-9]/}; e=$((10#${e:-0}))
        (( e > 0 && now >= e )) && eds=$e                 # expired: expiry ke waqt se ginti
        if [[ -e "$LCK_DIR/$u" || -e "$IPL_DIR/$u" || -e "$EXLCK_DIR/$u" ]]; then
            [[ -r "$DEAD_DIR/$u" ]] && read -r lds 2>/dev/null < "$DEAD_DIR/$u"
            lds=${lds//[!0-9]/}; [[ -z "$lds" ]] && lds=$now   # locked: pehli baar dikhne ke waqt se ginti
        fi
        ds=""
        if   [[ -n "$eds" && -n "$lds" ]]; then ds=$(( eds < lds ? eds : lds ))
        elif [[ -n "$eds" ]]; then ds=$eds
        elif [[ -n "$lds" ]]; then ds=$lds; fi
        if [[ -z "$ds" ]]; then rm -f "$DEAD_DIR/$u"; continue; fi     # account phir se theek ho gaya
        [[ -r "$DEAD_DIR/$u" ]] && read -r cur 2>/dev/null < "$DEAD_DIR/$u"
        [[ "$cur" == "$ds" ]] || printf '%s\n' "$ds" > "$DEAD_DIR/$u"
        (( now - ds >= DEAD_GRACE )) || continue
        for key in ${U_KEYS[$u]}; do kill_session "$key" "reap $u"; done
        pkill -KILL -u "$u" 2>/dev/null
        userdel -f "$u" 2>/dev/null
        rm -f "$EXPIRY_DIR/$u" "$LCK_DIR/$u" "$IPL_DIR/$u" "$EXLCK_DIR/$u" "$DEAD_DIR/$u" "$DIS_DIR/$u" "$LIM_DIR/$u" "$USE_DIR/$u"
        echo "REAPED: $u (expired/locked $(( (now - ds) / 60 )) min pehle) -> account auto-delete"
    done
}

declare -A LAST=() SINCE=() IPSEEN=() IPLAST=() KILLED=() BOOT=()
declare -A S_USER=() S_IP=() S_LBL=() S_PID=() U_DELTA=() U_KEYS=() U_IPS=() SEEN=()
first=1; ncycle=0

follow_auth &
trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM INT

echo "rt-monitor started: every ${INTERVAL}s, dropbear ports: ${DB_PORTS}"

while true; do
    printf -v now '%(%s)T' -1
    S_USER=(); S_IP=(); S_LBL=(); S_PID=(); U_DELTA=(); U_KEYS=(); U_IPS=(); SEEN=()
    live_out=""

    # ---------- 1) unlock users whose quota is fine again (limit raised / usage reset) ----------
    for f in "$LCK_DIR"/*; do
        [[ -e "$f" ]] || continue
        u=${f##*/}; gbl=0; cur=0
        [[ -r "$LIM_DIR/$u" ]] && read -r gbl _ 2>/dev/null < "$LIM_DIR/$u"
        [[ -r "$USE_DIR/$u" ]] && read -r cur 2>/dev/null < "$USE_DIR/$u"
        gbl=${gbl//[!0-9]/}; gbl=$((10#${gbl:-0})); cur=${cur//[!0-9]/}; cur=$((10#${cur:-0}))
        if (( gbl == 0 || cur < gbl * GIB )); then
            [[ -e "$IPL_DIR/$u" || -e "$EXLCK_DIR/$u" ]] || unlock_u "$u"; rm -f "$f"; echo "UNLOCK: $u"
        fi
    done

    # ---------- 1b) IP-limit locks: GB ya IP limit change hote hi unlock ----------
    for f in "$IPL_DIR"/*; do
        [[ -e "$f" ]] || continue
        u=${f##*/}; sg=""; si=""
        read -r sg si 2>/dev/null < "$f"
        gbl=0; ipl=0
        [[ -r "$LIM_DIR/$u" ]] && read -r gbl ipl 2>/dev/null < "$LIM_DIR/$u"
        gbl=${gbl//[!0-9]/}; gbl=$((10#${gbl:-0})); ipl=${ipl//[!0-9]/}; ipl=$((10#${ipl:-0}))
        sg=${sg//[!0-9]/}; si=${si//[!0-9]/}
        if (( gbl != 10#${sg:-0} || ipl != 10#${si:-0} )) || ! id "$u" &>/dev/null; then
            [[ -e "$LCK_DIR/$u" || -e "$EXLCK_DIR/$u" ]] || unlock_u "$u"
            rm -f "$f"; echo "IPUNLOCK: $u (limit changed)"
        fi
    done

    # ---------- 2) snapshot of all dropbear sessions ----------
    while read -r lport peer pid bytes; do
        [[ -z "$bytes" ]] && continue
        pip="${peer%:*}"; pport="${peer##*:}"
        pip="${pip#[}"; pip="${pip%]}"; pip="${pip#::ffff:}"
        key="${pip//:/_}_${pport}"
        SEEN[$key]=1
        (( first )) && BOOT[$key]=1      # already open when the monitor started: its old bytes are not counted
        [[ "$pid" == "-" ]] && pid=""

        user=""; [[ -r "$AUTH_DIR/$key" ]] && read -r user 2>/dev/null < "$AUTH_DIR/$key"
        [[ -z "$user" ]] && continue

        if [[ "$pip" == "127.0.0.1" || "$pip" == "::1" ]]; then
            rip=""; lbl=""
            [[ -r "$MAP_DIR/$pport" ]] && read -r rip lbl 2>/dev/null < "$MAP_DIR/$pport"
            [[ -z "$rip" ]] && continue          # ws-proxy has not registered it yet -> next cycle
        else
            rip="$pip"; lbl="Direct:$lport"      # 22 / 447 / 109 reached directly: real IP is visible
        fi

        if [[ -z "${LAST[$key]+x}" ]]; then
            SINCE[$key]=$now
            if [[ -n "${BOOT[$key]}" ]]; then LAST[$key]=$bytes; else LAST[$key]=0; fi
        fi
        delta=$(( bytes - ${LAST[$key]} )); (( delta < 0 )) && delta=0
        LAST[$key]=$bytes

        S_USER[$key]=$user; S_IP[$key]=$rip; S_LBL[$key]=$lbl; S_PID[$key]=$pid
        U_KEYS[$user]+=" $key"
        U_DELTA[$user]=$(( ${U_DELTA[$user]:-0} + delta ))
        [[ " ${U_IPS[$user]} " == *" $rip "* ]] || U_IPS[$user]+=" $rip"
        ik="$user@$rip"
        [[ -z "${IPSEEN[$ik]+x}" ]] && IPSEEN[$ik]=${SINCE[$key]}
        IPLAST[$ik]=$now
        live_out+="$user|$rip|$lbl|${SINCE[$key]}|$bytes|$pid"$'\n'
    done < <(ss -tinpH state established "$FILTER" 2>/dev/null | awk "$SS_AWK")

    # ---------- 2b) expiry (exact time): expired -> lock + sessions kill ----------
    enforce_expiry

    # ---------- 3) per user: usage, GB limit, IP limit ----------
    for u in "${!U_KEYS[@]}"; do
        cur=0; [[ -r "$USE_DIR/$u" ]] && read -r cur 2>/dev/null < "$USE_DIR/$u"
        cur=${cur//[!0-9]/}; cur=$((10#${cur:-0}))
        d=${U_DELTA[$u]:-0}
        if (( d > 0 )); then cur=$(( cur + d )); printf '%s\n' "$cur" > "$USE_DIR/$u"; fi

        gbl=0; ipl=0
        [[ -r "$LIM_DIR/$u" ]] && read -r gbl ipl 2>/dev/null < "$LIM_DIR/$u"
        gbl=${gbl//[!0-9]/}; gbl=$((10#${gbl:-0})); ipl=${ipl//[!0-9]/}; ipl=$((10#${ipl:-0}))

        # manual lock (panel power button): login band + jo bhi session bacha ho wo kaat do
        if [[ -e "$DIS_DIR/$u" ]]; then
            for key in ${U_KEYS[$u]}; do kill_session "$key" "manual lock $u"; done
            continue
        fi

        # GB limit
        if (( gbl > 0 && cur >= gbl * GIB )) || [[ -e "$LCK_DIR/$u" ]]; then
            if [[ ! -e "$LCK_DIR/$u" ]]; then
                : > "$LCK_DIR/$u"; usermod -L "$u" 2>/dev/null
                echo "QUOTA: $u used $cur bytes >= ${gbl} GB -> locked"
            fi
            for key in ${U_KEYS[$u]}; do kill_session "$key" "GB limit $u"; done
            continue
        fi

        # IP limit -> account PERMANENT lock (GB ya IP limit change hone par unlock)
        if [[ -e "$IPL_DIR/$u" ]]; then
            for key in ${U_KEYS[$u]}; do kill_session "$key" "IP-lock $u"; done
            continue
        fi
        if (( ipl > 0 )); then
            set -- ${U_IPS[$u]}
            if (( $# > ipl )); then
                echo "$gbl $ipl" > "$IPL_DIR/$u"
                usermod -L "$u" 2>/dev/null
                echo "IPLOCK: $u connected from $# IPs, limit $ipl -> account locked"
                for key in ${U_KEYS[$u]}; do kill_session "$key" "IP-lock $u"; done
            fi
        fi
    done

    # ---------- 3c) expired / locked accounts -> 1 ghante baad auto-delete ----------
    reap_dead

    # ---------- 4) housekeeping ----------
    for k in "${!IPSEEN[@]}"; do
        (( now - ${IPLAST[$k]:-0} > 60 )) && { unset "IPSEEN[$k]" "IPLAST[$k]"; }
    done
    for k in "${!LAST[@]}"; do
        [[ -z "${SEEN[$k]}" ]] && unset "LAST[$k]" "SINCE[$k]" "KILLED[$k]"
    done
    for k in "${!BOOT[@]}"; do
        [[ -z "${SEEN[$k]}" ]] && unset "BOOT[$k]"
    done
    (( ++ncycle % 20 == 0 )) && cleanup_auth

    { printf '# %s\n' "$now"; printf '%s' "$live_out"; } > "$LIVE.tmp" && mv -f "$LIVE.tmp" "$LIVE"

    first=0
    sleep "$INTERVAL"
done
MON_EOF
    chmod +x "$MONITOR_BIN"

    cat << MONSVC_EOF > /etc/systemd/system/rt-monitor.service
[Unit]
Description=DDK VPS Manager limit monitor (GB + IP limit, real IP)
After=network.target dropbear.service ws-proxy.service

[Service]
ExecStart=${MONITOR_BIN}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
MONSVC_EOF
    systemctl daemon-reload
    systemctl enable rt-monitor >/dev/null 2>&1
    systemctl restart rt-monitor
    if systemctl is-active --quiet rt-monitor; then
        echo -e "${GREEN}   ✔ rt-monitor active (checks every ${MONITOR_INTERVAL}s).${NC}"
    else
        echo -e "${RED}   ✘ rt-monitor start fail: journalctl -u rt-monitor -n 30${NC}"
    fi
}

# ------------------------------------------------------------------------------
# Xray (VLESS + Trojan over WebSocket on 80/443) - installer + helpers
# ------------------------------------------------------------------------------
xray_ready() { declare -F xray_lib_v4 >/dev/null && [[ -f /usr/local/etc/xray/config.json ]]; }

write_xray_lib() {
    mkdir -p /usr/local/lib "${STATE_DIR}/xray/usage"
    cat << 'XLIB_EOF' > "$XRAY_LIB"
# rt-xray.sh (v4) - shared Xray helpers; VMess, VLESS aur Trojan ke liye ALAG-ALAG databases
XR_DIR="/var/lib/ddkvps/xray"
XR_VDB="$XR_DIR/vless.db"         # name uuid expiry(YYYY-MM-DDTHH:MM:SS) gb_limit ip_limit   (VLESS)
XR_TDB="$XR_DIR/trojan.db"        # name password expiry(YYYY-MM-DD) gb_limit ip_limit (Trojan)
XR_MDB="$XR_DIR/vmess.db"         # name uuid expiry(YYYY-MM-DDTHH:MM:SS) gb_limit ip_limit   (VMess)
XR_USE="$XR_DIR/usage"            # <user> : bytes used
XR_LOCK="$XR_DIR/iplock"          # <user> : unix time until which the user is blocked (IP limit exceeded)
XR_LOG="/var/log/xray/access.log"
XR_CONF="/usr/local/etc/xray/config.json"
XR_API="127.0.0.1:10085"
XR_GIB=1073741824
XR_IP_WINDOW=20                   # an IP counts as "connected" if it was active in the last N seconds
XR_IP_LOCK_SECS=300               # block time after the IP limit was exceeded
XR_DEAD="$XR_DIR/dead"            # <proto>_<user> : unix time jab account expired / locked hua
XR_DEAD_GRACE=3600                # expired / locked account itne seconds baad list se AUTO-DELETE
XR_DIS="$XR_DIR/disabled"         # <proto>_<user> : panel / menu se MANUAL lock (power button); auto-delete NAHI hota

xray_lib_v2() { :; }
xray_lib_v4() { :; }   # VMess support wala lib
xray_lib_v5() { :; }   # no-restart-on-add: sync lock + race-safe API add + sorted comm
xray_lib_v6() { :; }   # manual lock / unlock (XR_DIS)
xray_proto_of_db() { case "$1" in "$XR_TDB") echo trojan;; "$XR_MDB") echo vmess;; *) echo vless;; esac; }
xray_is_disabled() { [[ -e "$XR_DIS/${1}_$2" ]]; }   # $1=proto $2=name

# $1 = "vmess" | "vless" | "trojan"  ->  us protocol ki DB file
xray_db_for() { case "$1" in trojan) echo "$XR_TDB";; vmess) echo "$XR_MDB";; *) echo "$XR_VDB";; esac; }
xray_proto_label() { case "$1" in trojan) echo "Trojan";; vmess) echo "VMess";; *) echo "VLESS";; esac; }

# one-time migration: purani combined users.db dono nayi DBs me copy ho jati hai
xray_migrate_dbs() {
    local old="$XR_DIR/users.db" n id exp gb ipl
    mkdir -p "$XR_USE"; touch "$XR_VDB" "$XR_TDB" "$XR_MDB"
    if [[ -f "$old" ]]; then
        while read -r n id exp gb ipl; do
            [[ -z "$n" ]] && continue
            grep -q "^${n} " "$XR_VDB" 2>/dev/null || echo "$n $id $exp ${gb:-0} ${ipl:-0}" >> "$XR_VDB"
            grep -q "^${n} " "$XR_TDB" 2>/dev/null || echo "$n $id $exp ${gb:-0} ${ipl:-0}" >> "$XR_TDB"
        done < "$old"
        mv -f "$old" "${old}.migrated"
    fi
}

xray_usage_of() {
    local a=0
    [[ -r "$XR_USE/$1" ]] && read -r a < "$XR_USE/$1"
    a=${a//[!0-9]/}; echo $(( 10#${a:-0} ))
}

# add traffic since the last call (the API counters are reset on every query)
xray_collect_usage() {
    command -v xray >/dev/null 2>&1 || return 0
    mkdir -p "$XR_USE"
    xray api statsquery -s "$XR_API" -pattern "user>>>" -reset 2>/dev/null | jq -r '
      [.stat[]? | {n:(.name|split(">>>")[1]), v:((.value // 0)|tonumber)}]
      | group_by(.n) | map({n:.[0].n, v:(map(.v)|add)}) | .[] | "\(.n) \(.v)"' 2>/dev/null |
    while read -r n v; do
        [[ "$n" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ && "$v" =~ ^[0-9]+$ ]] || continue
        (( v > 0 )) || continue
        echo $(( $(xray_usage_of "$n") + v )) > "$XR_USE/$n"
    done
}

# who was active in the last N seconds (from the xray access log; nginx passes the real IP)
# output: "<user> <real ip> <last seen HH:MM:SS> <requests>"
xray_live() {
    local w=${1:-$XR_IP_WINDOW} cut
    [[ -r "$XR_LOG" ]] || return 0
    cut=$(date -d "-${w} seconds" '+%Y/%m/%d %H:%M:%S')
    tail -n 20000 "$XR_LOG" 2>/dev/null | awk -v cut="$cut" '
      ($1 " " $2) >= cut {
        ip = ""; em = ""
        for (i = 3; i <= NF; i++) {
          if ($i == "from") { a = $(i + 1); sub(/^(tcp|udp):/, "", a); sub(/:[0-9]+$/, "", a); gsub(/^\[|\]$/, "", a); ip = a }
          if ($i == "email:") em = $(i + 1)
        }
        if (ip != "" && em != "") { k = em " " ip; n[k]++; t[k] = $2 }
      }
      END { for (k in n) print k, t[k], n[k] }'
}

# IP limit: more distinct real IPs than allowed -> the user is blocked for a few minutes
# (dono protocols ki DBs check hoti hain; lock naam par lagta hai, dono protocols par lagoo)
xray_ip_enforce() {
    local live n id exp gb ipl cnt now db
    live=$(xray_live "$XR_IP_WINDOW")
    [[ -z "$live" ]] && return 0
    now=$(date +%s); mkdir -p "$XR_LOCK"
    for db in "$XR_VDB" "$XR_TDB" "$XR_MDB"; do
        [[ -r "$db" ]] || continue
        while read -r n id exp gb ipl; do
            [[ -z "$n" ]] && continue
            ipl=${ipl//[!0-9]/}; ipl=$(( 10#${ipl:-0} ))
            (( ipl > 0 )) || continue
            [[ -e "$XR_LOCK/$n" ]] && continue
            cnt=$(printf '%s\n' "$live" | awk -v n="$n" '$1==n' | wc -l)
            if (( cnt > ipl )); then echo 9999999999 > "$XR_LOCK/$n"; fi
        done < "$db"
    done
}

xray_trim_log() {     # keep the access log small
    [[ -f "$XR_LOG" ]] || return 0
    (( $(stat -c %s "$XR_LOG" 2>/dev/null || echo 0) > 20971520 )) && : > "$XR_LOG"
    return 0
}

# jab account expired / locked hua (unix time). Khaali = account theek hai.
# expired -> expiry ke waqt se; GB-limit / IP-lock -> pehli baar dikhne ke waqt se (dono ho to jo pehle)
xray_dead_since() {   # $1=proto $2=name $3=expiry $4=gb_limit
    local proto="$1" n="$2" exp="$3" gb="${4:-0}" e nowts now f ds="" eds="" lu lockd=0
    nowts=$(date +%Y-%m-%dT%H:%M:%S); now=$(date +%s)
    gb=${gb//[!0-9]/}; gb=$(( 10#${gb:-0} ))
    f="$XR_DEAD/${proto}_$n"
    [[ -r "$f" ]] && read -r ds < "$f"; ds=${ds//[!0-9]/}
    e=$exp; [[ "$e" == *T* ]] || e="${e}T23:59:59"
    if [[ ! "$e" > "$nowts" ]]; then eds=$(date -d "${e/T/ }" +%s 2>/dev/null); fi
    (( gb > 0 && $(xray_usage_of "$n") >= gb * XR_GIB )) && lockd=1
    if [[ -r "$XR_LOCK/$n" ]]; then read -r lu < "$XR_LOCK/$n"; lu=${lu//[!0-9]/}; (( 10#${lu:-0} > now )) && lockd=1; fi
    if [[ -n "$eds" ]]; then
        if [[ -n "$ds" ]] && (( ds < eds )); then :; else ds=$eds; fi
    elif (( lockd )); then
        [[ -n "$ds" ]] || ds=$now
    else
        ds=""
    fi
    printf '%s' "$ds"
}

# expired / locked accounts ko XR_DEAD_GRACE (1 ghanta) baad DB se hata do (dubara create karna padega).
# Ye accounts pehle se inactive hote hain, isliye xray restart nahi hota.
xray_reap_dead() {
    local proto db n id exp gb ipl ds f keep drop now other o
    now=$(date +%s); mkdir -p "$XR_DEAD"
    for proto in vless trojan vmess; do
        db=$(xray_db_for "$proto"); [[ -s "$db" ]] || continue
        keep=$(mktemp); drop=0
        while read -r n id exp gb ipl; do
            [[ -z "$n" ]] && continue
            f="$XR_DEAD/${proto}_$n"
            ds=$(xray_dead_since "$proto" "$n" "$exp" "$gb")
            if [[ -z "$ds" ]]; then
                rm -f "$f"
            else
                [[ "$(cat "$f" 2>/dev/null)" == "$ds" ]] || echo "$ds" > "$f"
                if (( now - ds >= XR_DEAD_GRACE )); then
                    drop=1; rm -f "$f"
                    other=0
                    for o in "$XR_VDB" "$XR_TDB" "$XR_MDB"; do
                        [[ "$o" == "$db" ]] && continue
                        awk -v n="$n" '$1==n{f=1} END{exit !f}' "$o" 2>/dev/null && other=1
                    done
                    (( other )) || rm -f "$XR_USE/$n" "$XR_LOCK/$n"
                    echo "XRAY-REAPED: $proto $n"
                    continue
                fi
            fi
            echo "$n $id $exp ${gb:-0} ${ipl:-0}" >> "$keep"
        done < "$db"
        (( drop )) && cat "$keep" > "$db"
        rm -f "$keep"
    done
}

# active (non-expired / under-quota / not IP-locked) clients of ONE db
# output: "<name> <uuid-or-password>" lines
xray_active_list() {
    local db="$1" nowts now n id exp gb ipl used lu e pr
    nowts=$(date +%Y-%m-%dT%H:%M:%S); now=$(date +%s)
    [[ -r "$db" ]] || return 0
    pr=$(xray_proto_of_db "$db")
    while read -r n id exp gb ipl; do
        [[ -z "$n" ]] && continue
        [[ -e "$XR_DIS/${pr}_$n" ]] && continue               # manual lock (power button)
        gb=${gb//[!0-9]/}; gb=$(( 10#${gb:-0} ))
        used=$(xray_usage_of "$n")
        e=$exp; [[ "$e" == *T* ]] || e="${e}T23:59:59"        # purane accounts: date ke din ke end tak
        [[ "$e" > "$nowts" ]] || continue                     # expiry ka exact time aa gaya
        (( gb > 0 && used >= gb * XR_GIB )) && continue
        if [[ -r "$XR_LOCK/$n" ]]; then
            read -r lu < "$XR_LOCK/$n"; lu=${lu//[!0-9]/}
            if (( 10#${lu:-0} > now )); then continue; else rm -f "$XR_LOCK/$n"; fi
        fi
        printf '%s %s\n' "$n" "$id"
    done < "$db"
}

# rebuild both client lists in the xray config from the two DBs.
# NAYE / wapas-active clients runtime API se add hote hain (xray RESTART NAHI hota => connected users
# disconnect nahi hote). Sirf hataane (delete / expired / limit / IP-lock) par restart hota hai, taaki
# unke chalu connections bhi kat jayein. API na chale to fallback restart.
xray_api_add() {   # $1=proto $2=name $3=uuid/password
    local p="$1" n="$2" id="$3" t tmp rc=0 cnt=0 aout ar try ok
    tmp=$(mktemp --suffix=.json)
    while read -r t; do
        [[ -z "$t" ]] && continue
        cnt=$(( cnt + 1 ))
        if [[ "$p" == "trojan" ]]; then
            jq -n --arg t "$t" --arg n "$n" --arg id "$id" '{inbounds:[{tag:$t,listen:"127.0.0.1",port:1,protocol:"trojan",settings:{clients:[{password:$id,email:$n}]}}]}' > "$tmp"
        elif [[ "$p" == "vmess" ]]; then
            jq -n --arg t "$t" --arg n "$n" --arg id "$id" '{inbounds:[{tag:$t,listen:"127.0.0.1",port:1,protocol:"vmess",settings:{clients:[{id:$id,email:$n}]}}]}' > "$tmp"
        else
            jq -n --arg t "$t" --arg n "$n" --arg id "$id" '{inbounds:[{tag:$t,listen:"127.0.0.1",port:1,protocol:"vless",settings:{clients:[{id:$id,email:$n}],decryption:"none"}}]}' > "$tmp"
        fi
        # FIX: adu ka exit code bharosemand nahi tha (fail hone par bhi 0). Ab output check hota hai aur
        # user ko inbound me wapas query karke verify kiya jata hai. Kuch bhi gadbad => rc=1 => sirf tab restart.
        # Poora output /var/log/xray/adu.log me save hota hai (debug ke liye).
        # FIX: Xray 26.x adu ke JSON me listen/port maangta hai (warna "Listen on AnyIP but no Port(s)" => Added 0 => restart).
        # Port sirf config-build ke liye hai, asli inbound ka port nahi badalta.
        # FIX (restart-on-create): pehle ek hi koshish thi; koi bhi hiccup => rc=1 => poora xray RESTART => sab
        # connected users disconnect. Ab: (a) "already exists" = user runtime me pehle se hai => success
        # (monitor aur menu ek saath add karein to doosre ko yehi error aata tha), (b) 3 koshish (1s gap),
        # (c) verify bhi retry hota hai. Restart tabhi jab teeno koshish fail.
        ok=0
        for try in 1 2 3; do
            aout=$(xray api adu -s "$XR_API" "$tmp" 2>&1); ar=$?
            echo "$(date '+%F %T') adu $p $n $t try=$try rc=$ar :: $aout" >> /var/log/xray/adu.log 2>/dev/null
            if grep -qiE 'already exist' <<< "$aout"; then ok=1; break; fi
            if (( ar == 0 )) && grep -qE 'Added[[:space:]]+[1-9]' <<< "$aout"; then
                if xray api inbounduser -h >/dev/null 2>&1; then
                    xray api inbounduser -s "$XR_API" -tag "$t" -email "$n" 2>/dev/null | grep -qF "$n" && { ok=1; break; }
                else
                    ok=1; break
                fi
            fi
            sleep 1
        done
        (( ok )) || rc=1
    done < <(jq -r --arg p "$p" '.inbounds[] | select(.tag|startswith($p + "-")) | .tag' "$XR_CONF")
    rm -f "$tmp"
    (( cnt > 0 )) || return 1
    return $rc
}

# FIX (restart-on-create): xray_sync menu (create/delete/renew) aur xray-monitor (har 5s) DONO chalate the, bina lock ke.
# Dono ek saath "added" dekh kar adu chalate => doosra fail => restart. Ab flock se ek waqt me ek hi sync chalta hai.
xray_sync() {
    local rc
    mkdir -p "$XR_DIR" 2>/dev/null
    if command -v flock >/dev/null 2>&1; then
        ( flock -w 180 9 || exit 1; _xray_sync_run ) 9> "$XR_DIR/sync.lock"
        rc=$?
    else
        _xray_sync_run; rc=$?
    fi
    return $rc
}

_xray_sync_run() {
    [[ -f "$XR_CONF" ]] || return 0
    local want cur vl_act tr_act vm_act vl tr vm want_list newf oldf="$XR_DIR/active.list" restart=0 p n id added removed
    vl_act=$(xray_active_list "$XR_VDB")
    tr_act=$(xray_active_list "$XR_TDB")
    vm_act=$(xray_active_list "$XR_MDB")
    want_list=$( { printf '%s\n' "$vl_act" | awk 'NF{print "vless " $0}'; printf '%s\n' "$tr_act" | awk 'NF{print "trojan " $0}'; printf '%s\n' "$vm_act" | awk 'NF{print "vmess " $0}'; } | LC_ALL=C sort )
    want=$(printf '%s\n' "$want_list" | md5sum | cut -d' ' -f1)
    cur=$(cat "$XR_DIR/active.md5" 2>/dev/null)
    [[ "$want" == "$cur" ]] && return 0
    jq -e '.api.services // [] | index("HandlerService")' "$XR_CONF" >/dev/null 2>&1 || restart=1   # API me runtime-add service nahi
    [[ -f "$oldf" ]] || restart=1
    systemctl is-active --quiet xray || restart=1
    vl=$(printf '%s\n' "$vl_act" | jq -Rn '[inputs | select(length>0) | split(" ") | {id:.[1], email:.[0]}]')
    tr=$(printf '%s\n' "$tr_act" | jq -Rn '[inputs | select(length>0) | split(" ") | {password:.[1], email:.[0]}]')
    vm=$(printf '%s\n' "$vm_act" | jq -Rn '[inputs | select(length>0) | split(" ") | {id:.[1], email:.[0]}]')
    jq --argjson v "$vl" --argjson t "$tr" --argjson m "$vm" '
        (.api.services) = (((.api.services // []) + ["HandlerService"]) | unique) |
        (.inbounds[] | select(.tag|startswith("vless-")) | .settings.clients) = $v |
        (.inbounds[] | select(.tag|startswith("trojan-")) | .settings.clients) = $t |
        (.inbounds[] | select(.tag|startswith("vmess-")) | .settings.clients) = $m' \
        "$XR_CONF" > "$XR_CONF.tmp" && mv "$XR_CONF.tmp" "$XR_CONF" || return 1
    newf=$(mktemp); printf '%s\n' "$want_list" | sed '/^$/d' > "$newf"
    if (( ! restart )); then
        removed=$(LC_ALL=C sort "$oldf" | LC_ALL=C comm -23 - "$newf" 2>/dev/null)
        added=$(LC_ALL=C sort "$oldf" | LC_ALL=C comm -13 - "$newf" 2>/dev/null)
        if [[ -n "$removed" ]]; then
            restart=1                        # kisi ko hataana hai: restart (uske live connections bhi katenge)
        else
            while read -r p n id; do
                [[ -z "$n" ]] && continue
                xray_api_add "$p" "$n" "$id" || { restart=1; break; }
            done <<< "$added"
        fi
    fi
    mv -f "$newf" "$oldf"
    echo "$want" > "$XR_DIR/active.md5"
    (( restart )) && systemctl restart xray
    return 0
}

xray_add_client() {   # proto name uuid expiry gb ip
    local db; db=$(xray_db_for "$1"); shift
    mkdir -p "$XR_USE"; touch "$db"
    rm -f "$XR_DIS/$(xray_proto_of_db "$db")_$1"
    awk -v n="$1" '$1!=n' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
    echo "$1 $2 $3 ${4:-0} ${5:-0}" >> "$db"
    echo 0 > "$XR_USE/$1"; rm -f "$XR_LOCK/$1"
    xray_sync
}
xray_del_client() {   # proto name
    local db; db=$(xray_db_for "$1"); rm -f "$XR_DIS/${1}_$2"; shift
    awk -v n="$1" '$1!=n' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
    rm -f "$XR_USE/$1" "$XR_LOCK/$1"; xray_sync
}
xray_set_disabled_client() {   # proto name 1|0  -> 1 = lock (config se hatao), 0 = unlock (wapas add)
    mkdir -p "$XR_DIS"
    if [[ "$3" == 1 ]]; then date +%s > "$XR_DIS/${1}_$2"; else rm -f "$XR_DIS/${1}_$2"; fi
    xray_sync
}
xray_set_exp() {      # proto name expiry
    local db; db=$(xray_db_for "$1"); shift
    awk -v n="$1" -v e="$2" '$1==n{$3=e}1' "$db" > "$db.tmp" && mv "$db.tmp" "$db"; xray_sync
}
xray_set_gb() {       # proto name gb
    local db; db=$(xray_db_for "$1"); shift
    [[ "$(awk -v n="$1" '$1==n{print $4+0}' "$db")" != "$(( 10#${2:-0} ))" ]] && rm -f "$XR_LOCK/$1"; awk -v n="$1" -v g="$2" '$1==n{$4=g}1' "$db" > "$db.tmp" && mv "$db.tmp" "$db"; xray_sync
}
xray_set_ip() {       # proto name ip_limit
    local db; db=$(xray_db_for "$1"); shift
    [[ "$(awk -v n="$1" '$1==n{print $5+0}' "$db")" != "$(( 10#${2:-0} ))" ]] && rm -f "$XR_LOCK/$1"; awk -v n="$1" -v i="$2" '$1==n{$5=i}1' "$db" > "$db.tmp" && mv "$db.tmp" "$db"; xray_sync
}
xray_reset_usage() {  # proto name (also lifts an IP-limit block)
    local db; db=$(xray_db_for "$1"); shift
    [[ -n "$(awk -v n="$1" '$1==n' "$db")" ]] && echo 0 > "$XR_USE/$1"
    rm -f "$XR_LOCK/$1"; xray_sync
}
XLIB_EOF
}

# purana lib (VMess ke bina) mile to khud naya likh do. Xray / connected users ko nahi chhedta.
if [[ -f "$XRAY_LIB" ]] && ! grep -q 'xray_lib_v6' "$XRAY_LIB" 2>/dev/null; then
    write_xray_lib && . "$XRAY_LIB"
    systemctl is-active --quiet xray-monitor && systemctl restart xray-monitor
fi
# purana rt-monitor (manual lock support ke bina) -> naya likh do (connected users disconnect nahi hote)
if [[ $EUID -eq 0 && -f "$MONITOR_BIN" ]] && ! grep -q 'rt-monitor-v2-disable' "$MONITOR_BIN" 2>/dev/null; then
    install_monitor_service >/dev/null 2>&1
fi

xray_add_transports() {   # VMess/VLESS/Trojan: TCP+TLS aur XHTTP+TLS inbounds + VMess WS (idempotent + self-healing)
    # FIX: (1) cert na milne par ab HAProxy ka cert (self-signed bhi) use hota hai, function fail nahi hota
    #      (2) purane inbound ka galat port / cert ab theek ho jata hai (pehle sirf "tag hai to skip")
    #      (3) inbounds banne ke baad maujooda users in naye inbounds me load hote hain (pehle clients:[] reh jate the
    #          kyunki xray_sync "list badli nahi" soch kar return kar deta tha => "invalid request user id")
    #      (4) port kisi aur service ke paas ho to config chheda hi nahi jata (warna poora xray start nahi hota)
    local d cert key xd user p tls tmp pi att src
    local vt=${XRAY_VTCP_PORT:-8442} vx=${XRAY_VXH_PORT:-8443} tt=${XRAY_TTCP_PORT:-8446} tx=${XRAY_TXH_PORT:-8445}
    local vm=${XRAY_VMESS_PORT:-20002} mt=${XRAY_MTCP_PORT:-8447} mx=${XRAY_MXH_PORT:-8448}
    local vw=${XRAY_VLESS_PORT:-20001} tw=${XRAY_TROJAN_PORT:-20003}
    [[ -f /usr/local/etc/xray/config.json ]] || { echo -e "${RED}   ✘ Xray config nahi mila (pehle install_xray)${NC}"; return 1; }
    command -v jq >/dev/null 2>&1 || apt install -y jq >/dev/null 2>&1
    d=$(get_domain)
    xd=/usr/local/etc/xray/cert
    mkdir -p "$xd"
    local oldsum certchg=0; oldsum=$(cat "$xd/fullchain.pem" "$xd/privkey.pem" 2>/dev/null | md5sum)
    cert=/etc/letsencrypt/live/$d/fullchain.pem; key=/etc/letsencrypt/live/$d/privkey.pem
    if [[ -f "$cert" && -f "$key" ]]; then
        cp -L "$cert" "$xd/fullchain.pem"; cp -L "$key" "$xd/privkey.pem"; src="Let's Encrypt ($d)"
    elif [[ -s "$HAPROXY_CERT" ]] && sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$HAPROXY_CERT" > "$xd/fullchain.pem" \
         && openssl pkey -in "$HAPROXY_CERT" -out "$xd/privkey.pem" 2>/dev/null && [[ -s "$xd/fullchain.pem" && -s "$xd/privkey.pem" ]]; then
        src="HAProxy cert (self-signed ho sakta hai; Issue SSL ke baad apne-aap real cert lag jayega)"
        cert=""   # LE nahi => renewal hook ki zaroorat nahi
    else
        echo -e "${RED}   ✘ TLS cert nahi mila (na Let's Encrypt, na HAProxy). Pehle domain set + Install/Issue SSL karein.${NC}"; return 1
    fi
    user=$(systemctl show xray -p User --value 2>/dev/null)
    [[ -n "$user" ]] && chown -R "$user" "$xd"
    chmod 755 "$xd"; chmod 644 "$xd/fullchain.pem"; chmod 600 "$xd/privkey.pem"
    echo -e "${GREEN}   ✔ Xray TLS cert: ${src}${NC}"
    [[ "$(cat "$xd/fullchain.pem" "$xd/privkey.pem" 2>/dev/null | md5sum)" != "$oldsum" ]] && certchg=1
    # renewal: rt-cert-sync (deploy hook) Xray ko bhi naya cert deta hai
    [[ -n "$cert" ]] && write_cert_tools
    # port conflict check (xray ke apne ports theek hain)
    for p in $vt $vx $tt $tx $mt $mx $vm; do
        pi=$(ss -tlnpH "sport = :$p" 2>/dev/null | grep -v '"xray"' | head -1)
        if [[ -n "$pi" ]]; then
            echo -e "${RED}   ✘ Port $p pehle se kisi aur service ke paas hai:${NC} $pi"
            echo -e "${RED}     Config nahi badla (warna poora Xray band ho jata). Us service ko hatayein ya XRAY_*_PORT badlein.${NC}"
            return 1
        fi
    done
    tls=$(jq -n --arg c "$xd/fullchain.pem" --arg k "$xd/privkey.pem" '{security:"tls",tlsSettings:{certificates:[{certificateFile:$c,keyFile:$k}]}}')
    # REAL IP: WS + XHTTP inbounds nginx ke peeche (loopback) hain; nginx X-Forwarded-For me asli client IP deta hai.
    # Naya Xray ye header tabhi padhta hai jab sockopt.trustedXForwardedFor set ho (purana Xray default me padhta hai).
    local sk='{"sockopt":{"trustedXForwardedFor":["X-Forwarded-For"]}}'
    for att in 1 2; do
        tmp=$(mktemp --suffix=.json)   # Xray 26.x: bina .json extension ke "unsupported config file extension"
        jq --argjson tls "$tls" --argjson sk "$sk" --argjson vt $vt --argjson vx $vx --argjson tt $tt --argjson tx $tx --argjson vm $vm --argjson mt $mt --argjson mx $mx --argjson vw $vw --argjson tw $tw '
          def up($o): if any(.inbounds[]; .tag==$o.tag)
              then (.inbounds |= map(if .tag==$o.tag then (.listen=$o.listen | .port=$o.port | .streamSettings=$o.streamSettings) else . end))
              else .inbounds += [$o] end;
          up({tag:"vless-ws",listen:"127.0.0.1",port:$vw,protocol:"vless",settings:{clients:[],decryption:"none"},streamSettings:({network:"ws",wsSettings:{path:"/vless"}}+$sk)}) |
          up({tag:"trojan-ws",listen:"127.0.0.1",port:$tw,protocol:"trojan",settings:{clients:[]},streamSettings:({network:"ws",wsSettings:{path:"/trojan"}}+$sk)}) |
          up({tag:"vmess-ws",listen:"127.0.0.1",port:$vm,protocol:"vmess",settings:{clients:[]},streamSettings:({network:"ws",wsSettings:{path:"/vmess"}}+$sk)}) |
          up({tag:"vless-tcp",listen:"0.0.0.0",port:$vt,protocol:"vless",settings:{clients:[],decryption:"none"},streamSettings:({network:"tcp"}+$tls)}) |
          up({tag:"trojan-tcp",listen:"0.0.0.0",port:$tt,protocol:"trojan",settings:{clients:[]},streamSettings:({network:"tcp"}+$tls)}) |
          up({tag:"vmess-tcp",listen:"0.0.0.0",port:$mt,protocol:"vmess",settings:{clients:[]},streamSettings:({network:"tcp"}+$tls)}) |
          up({tag:"vless-xhttp",listen:"127.0.0.1",port:$vx,protocol:"vless",settings:{clients:[],decryption:"none"},streamSettings:({network:"xhttp",xhttpSettings:{path:"/vless-xhttp",mode:"auto"}}+$sk)}) |
          up({tag:"trojan-xhttp",listen:"127.0.0.1",port:$tx,protocol:"trojan",settings:{clients:[]},streamSettings:({network:"xhttp",xhttpSettings:{path:"/trojan-xhttp",mode:"auto"}}+$sk)}) |
          up({tag:"vmess-xhttp",listen:"127.0.0.1",port:$mx,protocol:"vmess",settings:{clients:[]},streamSettings:({network:"xhttp",xhttpSettings:{path:"/vmess-xhttp",mode:"auto"}}+$sk)})
        ' /usr/local/etc/xray/config.json > "$tmp" || { rm -f "$tmp"; echo -e "${RED}   ✘ jq fail${NC}"; return 1; }
        if xray run -test -format json -config "$tmp" >/tmp/xray-test.log 2>&1; then break; fi
        rm -f "$tmp"; tmp=""
        # XHTTP purane Xray version me nahi hota -> ek baar latest Xray install karke dobara try
        if (( att == 1 )) && grep -qiE 'xhttp|unknown|unsupported|network' /tmp/xray-test.log; then
            echo -e "${YELLOW}   ! Config test fail (shayad purana Xray: $(xray version 2>/dev/null | head -1)). Latest Xray install kar raha hoon...${NC}"
            bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/tmp/xray-install.log 2>&1
            continue
        fi
        break
    done
    if [[ -z "$tmp" ]]; then
        echo -e "${RED}   ✘ Config test fail (config nahi badla). Log: /tmp/xray-test.log${NC}"; return 1
    fi
    # FIX: inbounds pehle se sahi hon (config me koi badlaav nahi) to na config chheda jata hai, na state reset,
    # na xray restart => connected users disconnect nahi hote (pehle har baar rm active.* + xray_sync => restart).
    local same=0
    [[ "$(jq -S . "$tmp" 2>/dev/null)" == "$(jq -S . /usr/local/etc/xray/config.json 2>/dev/null)" ]] && same=1
    if (( same )); then
        rm -f "$tmp"
    else
        cp -a /usr/local/etc/xray/config.json "/usr/local/etc/xray/config.json.bak-$(date +%s)" 2>/dev/null
        mv "$tmp" /usr/local/etc/xray/config.json
        chmod 644 /usr/local/etc/xray/config.json
    fi
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        for p in $vt $tt $mt; do ufw allow "$p"/tcp >/dev/null 2>&1; done
    fi
    # maujooda users ko naye inbounds me daalo: sync-state reset => xray_sync poori list likhta hai + restart
    if ! declare -F xray_sync >/dev/null 2>&1 && [[ -f "$XRAY_LIB" ]]; then . "$XRAY_LIB"; fi
    if (( ! same )) || [[ ! -f "${STATE_DIR}/xray/active.list" ]]; then
        rm -f "${STATE_DIR}/xray/active.md5" "${STATE_DIR}/xray/active.list"
    fi
    if declare -F xray_sync >/dev/null 2>&1; then xray_sync; fi
    # FIX: config same ho lekin cert naya (self-signed -> Let's Encrypt) to xray purana cert hi serve karta tha
    if (( same && certchg )) && systemctl is-active --quiet xray; then
        echo -e "${BLUE}   → Naya cert: Xray restart${NC}"; systemctl restart xray
    fi
    systemctl is-active --quiet xray || systemctl restart xray
    sleep 2
    local okp=1
    for p in $vt $vx $tt $tx $mt $mx $vm; do
        if ss -tlnH "sport = :$p" 2>/dev/null | grep -q .; then :; else
            okp=0; echo -e "${RED}   ✘ Port $p listen nahi kar raha (journalctl -u xray -n 30)${NC}"; fi
    done
    (( okp )) && echo -e "${GREEN}   ✔ Xray: VMess TCP $mt | VLESS TCP $vt | Trojan TCP $tt (direct TLS) + WS/XHTTP loopback (nginx ke peeche, public 443 TLS / 80 non-TLS) - sab listen kar rahe hain${NC}"
    return $(( 1 - okp ))
}
xray_bin_ok() { [[ -x /usr/local/bin/xray ]] && /usr/local/bin/xray version >/dev/null 2>&1; }

xray_write_unit() {   # official installer jaisa systemd unit (agar maujood na ho)
    systemctl cat xray.service >/dev/null 2>&1 && return 0
    cat > /etc/systemd/system/xray.service << 'XUNIT_EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
XUNIT_EOF
    systemctl daemon-reload
}

# FIX: pehle sirf EK koshish thi (official script: GitHub API + unzip). Fresh VPS par apt lock / API
# rate-limit / network hiccup => Xray install hi nahi hota tha. Ab: lock intezar + 2 koshish + fallback
# (seedha release zip, API ke bina) + systemd unit ki guarantee.
xray_install_binary() {
    local try arch url tmp f
    if xray_bin_ok; then xray_write_unit; return 0; fi
    pkg_ensure curl:curl unzip:unzip || echo -e "${YELLOW}   ! curl/unzip install nahi hue (apt busy?) - phir bhi koshish${NC}"
    : > /tmp/xray-install.log
    for try in 1 2; do
        apt_wait_lock 600
        echo -e "${BLUE}   → Xray-core download (official installer, koshish ${try}/2)...${NC}"
        bash -c "$(curl -fsSL --retry 3 --retry-delay 3 -m 60 https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >>/tmp/xray-install.log 2>&1
        if xray_bin_ok; then xray_write_unit; return 0; fi
        sleep 5
    done
    case "$(uname -m)" in
        x86_64|amd64) arch=64 ;; aarch64|arm64|armv8*) arch=arm64-v8a ;; armv7*) arch=arm32-v7a ;;
        i386|i686) arch=32 ;; s390x) arch=s390x ;; riscv64) arch=riscv64 ;; *) arch=64 ;;
    esac
    url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
    echo -e "${BLUE}   → Fallback: seedha release download (${arch})...${NC}"
    tmp=$(mktemp -d)
    if curl -fL --retry 4 --retry-delay 3 -m 240 -o "$tmp/xray.zip" "$url" >>/tmp/xray-install.log 2>&1; then
        unzip -oq "$tmp/xray.zip" -d "$tmp" 2>>/tmp/xray-install.log \
          || python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$tmp/xray.zip" "$tmp" 2>>/tmp/xray-install.log
        if [[ -f "$tmp/xray" ]]; then
            install -m 755 "$tmp/xray" /usr/local/bin/xray
            mkdir -p /usr/local/share/xray
            for f in geoip.dat geosite.dat; do [[ -f "$tmp/$f" ]] && install -m 644 "$tmp/$f" "/usr/local/share/xray/$f"; done
        fi
    fi
    rm -rf "$tmp"
    xray_bin_ok || return 1
    xray_write_unit
    return 0
}

install_xray() {
    echo -e "${BLUE}   → Installing Xray-core (VMess + VLESS + Trojan)...${NC}"
    pkg_ensure curl:curl jq:jq unzip:unzip || echo -e "${YELLOW}   ! curl / jq / unzip me se kuch missing (apt busy?)${NC}"
    if ! xray_install_binary; then
        echo -e "${RED}   ✘ Xray install fail (3 tareeqe try kiye). Log: /tmp/xray-install.log${NC}"; return 1
    fi
    command -v jq >/dev/null 2>&1 || { echo -e "${RED}   ✘ jq nahi hai (apt install jq) - Xray config nahi ban sakta${NC}"; return 1; }
    mkdir -p "${STATE_DIR}/xray/usage"
    write_xray_lib
    . "$XRAY_LIB"
    xray_migrate_dbs            # purani users.db -> vless.db + trojan.db (ek hi baar)

    mkdir -p /usr/local/etc/xray /var/log/xray
    touch /var/log/xray/access.log
    chown -R "$(systemctl show xray -p User --value 2>/dev/null | grep . || echo nobody)" /var/log/xray 2>/dev/null
    cat << XR_CONF_EOF > /usr/local/etc/xray/config.json
{
  "log": {"loglevel": "warning", "access": "/var/log/xray/access.log"},
  "stats": {},
  "api": {"tag": "api", "services": ["StatsService", "HandlerService"]},
  "policy": {"levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}}},
  "inbounds": [
    {"tag": "api", "listen": "127.0.0.1", "port": ${XRAY_API_PORT}, "protocol": "dokodemo-door",
     "settings": {"address": "127.0.0.1"}},
    {"tag": "vless-ws", "listen": "127.0.0.1", "port": ${XRAY_VLESS_PORT}, "protocol": "vless",
     "settings": {"clients": [], "decryption": "none"},
     "streamSettings": {"network": "ws", "wsSettings": {"path": "/vless"}, "sockopt": {"trustedXForwardedFor": ["X-Forwarded-For"]}}},
    {"tag": "trojan-ws", "listen": "127.0.0.1", "port": ${XRAY_TROJAN_PORT}, "protocol": "trojan",
     "settings": {"clients": []},
     "streamSettings": {"network": "ws", "wsSettings": {"path": "/trojan"}, "sockopt": {"trustedXForwardedFor": ["X-Forwarded-For"]}}},
    {"tag": "vmess-ws", "listen": "127.0.0.1", "port": ${XRAY_VMESS_PORT}, "protocol": "vmess",
     "settings": {"clients": []},
     "streamSettings": {"network": "ws", "wsSettings": {"path": "/vmess"}, "sockopt": {"trustedXForwardedFor": ["X-Forwarded-For"]}}}
  ],
  "outbounds": [{"protocol": "freedom"}],
  "routing": {"rules": [{"type": "field", "inboundTag": ["api"], "outboundTag": "api"}]}
}
XR_CONF_EOF

    cat << 'XMON_EOF' > /usr/local/bin/xray-monitor
#!/bin/bash
. /usr/local/lib/rt-xray.sh
while true; do
    xray_collect_usage
    xray_ip_enforce
    xray_reap_dead
    xray_sync
    xray_trim_log
    sleep 5
done
XMON_EOF
    chmod +x /usr/local/bin/xray-monitor
    cat << 'XSVC_EOF' > /etc/systemd/system/xray-monitor.service
[Unit]
Description=DDK VPS Manager Xray usage/expiry monitor
After=xray.service

[Service]
ExecStart=/usr/local/bin/xray-monitor
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
XSVC_EOF

    systemctl daemon-reload
    systemctl enable xray xray-monitor >/dev/null 2>&1
    rm -f "${STATE_DIR}/xray/active.md5" "${STATE_DIR}/xray/active.list"
    xray_add_transports || true
    xray_sync                       # writes existing accounts back + restarts xray
    systemctl is-active --quiet xray || systemctl restart xray
    sleep 2
    systemctl restart xray-monitor
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}   ✔ Xray active: VMess ${XRAY_VMESS_PORT} (/vmess) | VLESS ${XRAY_VLESS_PORT} (/vless) | Trojan ${XRAY_TROJAN_PORT} (/trojan) -> nginx -> 80/443${NC}"
        return 0
    fi
    echo -e "${RED}   ✘ Xray start fail:${NC}"
    /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json 2>&1 | tail -5
    journalctl -u xray -n 15 --no-pager 2>/dev/null
    return 1
}

rt_verify_stack() {   # install ke baad: SSH + Xray services check, jo band ho use theek karo. 0 = sab OK
    local s p t bad=0
    echo -e "${BLUE}[✓] Final check: SSH + Xray...${NC}"
    for t in 1 2; do   # Xray binary / config / service me kuch bhi missing => dobara install
        if xray_bin_ok && [[ -f /usr/local/etc/xray/config.json ]] && systemctl is-active --quiet xray; then break; fi
        echo -e "${YELLOW}   ! Xray theek nahi chal raha - dobara install (koshish ${t}/2)...${NC}"
        sleep 5; install_xray
    done
    [[ -x /usr/local/bin/ws-proxy ]] || install_wsproxy_service
    for s in dropbear ws-proxy nginx haproxy rt-monitor xray xray-monitor; do
        if ! systemctl cat "$s.service" >/dev/null 2>&1; then
            printf "   %-13s ${RED}INSTALL NAHI${NC}\n" "$s"; bad=1; continue
        fi
        systemctl is-active --quiet "$s" || { systemctl restart "$s" 2>/dev/null; sleep 2; }
        if systemctl is-active --quiet "$s"; then printf "   %-13s ${GREEN}OK${NC}\n" "$s"
        else printf "   %-13s ${RED}FAIL${NC} (journalctl -u %s -n 30)\n" "$s" "$s"; bad=1; fi
    done
    for p in 80 443 "$DROPBEAR_RAW_PORT" "$WSPROXY_PORT" "$XRAY_VLESS_PORT" "$XRAY_VMESS_PORT" "$XRAY_TROJAN_PORT"; do
        ss -Htln "sport = :$p" 2>/dev/null | grep -q . || { echo -e "${RED}   ✘ port $p listen nahi kar raha${NC}"; bad=1; }
    done
    (( bad )) || echo -e "${GREEN}   ✔ SSH (Direct / WS / SSL) + Xray (VMess / VLESS / Trojan) sab chal rahe hain${NC}"
    return $bad
}

xray_links() {   # $1 = proto (vless|trojan), $2 = name, $3 = uuid/password
    local d L vt vx tt tx; d=$(get_domain); L="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    vt=${XRAY_VTCP_PORT:-8442}; vx=${XRAY_VXH_PORT:-8443}; tt=${XRAY_TTCP_PORT:-8446}; tx=${XRAY_TXH_PORT:-8445}
    echo -e "${CYAN}━━━━━━━━━━  LINKS  ━━━━━━━━━━${NC}"
    if [[ "$1" == "trojan" ]]; then
        echo -e " 🔒 Trojan WS TLS 443"
        echo -e "trojan://$3@${d}:443?type=ws&security=tls&path=%2Ftrojan&host=${d}&sni=${d}#$2-trojan-443"
        echo
        echo -e " 🔓 Trojan WS 80"
        echo -e "trojan://$3@${d}:80?type=ws&security=none&path=%2Ftrojan&host=${d}#$2-trojan-80"
        echo
        echo -e " 🔒 Trojan TCP TLS ${tt}"
        echo -e "trojan://$3@${d}:${tt}?security=tls&type=tcp&headerType=none&sni=${d}#$2-trojan-tcp-${tt}"
        echo
        echo -e " 🚀 Trojan XHTTP TLS 443"
        echo -e "trojan://$3@${d}:443?security=tls&type=xhttp&path=%2Ftrojan-xhttp&host=${d}&sni=${d}&alpn=http%2F1.1&mode=auto#$2-trojan-xhttp-tls"
        echo
        echo -e " 🚀 Trojan XHTTP NTLS 80"
        echo -e "trojan://$3@${d}:80?security=none&type=xhttp&path=%2Ftrojan-xhttp&host=${d}&mode=auto#$2-trojan-xhttp-ntls"
    else
        echo -e " 🔒 VLESS WS TLS 443"
        echo -e "vless://$3@${d}:443?encryption=none&type=ws&security=tls&path=%2Fvless&host=${d}&sni=${d}#$2-vless-443"
        echo
        echo -e " 🔓 VLESS WS 80"
        echo -e "vless://$3@${d}:80?encryption=none&type=ws&security=none&path=%2Fvless&host=${d}#$2-vless-80"
        echo
        echo -e " 🔒 VLESS TCP TLS ${vt}"
        echo -e "vless://$3@${d}:${vt}?encryption=none&security=tls&type=tcp&headerType=none&sni=${d}#$2-vless-tcp-${vt}"
        echo
        echo -e " 🚀 VLESS XHTTP TLS 443"
        echo -e "vless://$3@${d}:443?encryption=none&security=tls&type=xhttp&path=%2Fvless-xhttp&host=${d}&sni=${d}&alpn=http%2F1.1&mode=auto#$2-vless-xhttp-tls"
        echo
        echo -e " 🚀 VLESS XHTTP NTLS 80"
        echo -e "vless://$3@${d}:80?encryption=none&security=none&type=xhttp&path=%2Fvless-xhttp&host=${d}&mode=auto#$2-vless-xhttp-ntls"
    fi
    echo -e "${CYAN}${L}${NC}"
}
xray_valid_name() { valid_username "$1"; }
xray_row() { local db; db=$(xray_db_for "$1"); awk -v n="$2" '$1==n' "$db"; }     # -> "name uuid exp gb ip"

vm_link() {   # ps add port id net type host path tls sni -> vmess://base64(json)
    local j
    j=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"%s","type":"%s","host":"%s","path":"%s","tls":"%s","sni":"%s","alpn":"%s"}' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11:-}")
    printf 'vmess://%s' "$(printf '%s' "$j" | base64 -w0)"
}

xray_show_info() {   # proto name uuid/password exp gb ip -> simple ACCOUNT format (VMess + VLESS + Trojan, ek jaisa)
    local proto="$1" n="$2" id="$3" d xe gbt ipt vt vx wp xp idl pu L sch enc
    d=$(get_domain)
    case "$proto" in
        trojan) pu=Trojan; idl="Password"; wp=/trojan; xp=/trojan-xhttp; sch=trojan; enc=""
                vt=${XRAY_TTCP_PORT:-8446}; vx=${XRAY_TXH_PORT:-8445};;
        vmess)  pu=VMess;  idl="UUID/ID";  wp=/vmess;  xp=/vmess-xhttp;  sch=vmess;  enc=""
                vt=${XRAY_MTCP_PORT:-8447}; vx=${XRAY_MXH_PORT:-8448};;
        *)      pu=VLESS;  idl="UUID/ID";  wp=/vless;  xp=/vless-xhttp;  sch=vless;  enc="encryption=none&"
                vt=${XRAY_VTCP_PORT:-8442}; vx=${XRAY_VXH_PORT:-8443};;
    esac
    L="──────────────────────────────"
    xe=${4/T/ }; xe=${xe:0:16}
    if (( ${5:-0} > 0 )); then gbt="${5} GB"; else gbt="Unlimited"; fi
    if (( ${6:-0} > 0 )); then ipt="${6}"; else ipt="Unlimited"; fi
    local -a F=( "Remarks" "$n" "Domain" "$d" "Port Tls" "443" "Port Ntls" "80" "Port TCP" "$vt" "Port XHTTP" "443 TLS / 80 NTLS" "$idl" "$id" )
    [[ "$proto" == vmess ]] && F+=( "AlterID" "0" "Security" "auto" )
    F+=( "Path" "$wp" "XHTTP Path" "$xp" "Data Limit" "$gbt" "IP Limit" "$ipt" )
    if rt_tty; then   # terminal: Deploy Suite card (bot / web panel ke liye neeche wala plain format)
        local k lt ln lc lx lxn
        if [[ "$proto" == vmess ]]; then
            lt=$(vm_link "$n" "$d" 443 "$id" ws none "$d" "$wp" tls "$d"); ln=$(vm_link "$n" "$d" 80 "$id" ws none "$d" "$wp" "" "")
            lc=$(vm_link "${n}-tcp" "$d" "$vt" "$id" tcp none "" "" tls "$d")
            lx=$(vm_link "${n}-xhttp-tls" "$d" 443 "$id" xhttp auto "$d" "$xp" tls "$d" "http/1.1"); lxn=$(vm_link "${n}-xhttp-ntls" "$d" 80 "$id" xhttp auto "$d" "$xp" "" "")
        else
            lt="${sch}://${id}@${d}:443?path=${wp//\//%2F}&security=tls&${enc}type=ws&host=${d}&sni=${d}#${n}"
            ln="${sch}://${id}@${d}:80?path=${wp//\//%2F}&security=none&${enc}type=ws&host=${d}#${n}"
            lc="${sch}://${id}@${d}:${vt}?${enc}security=tls&type=tcp&headerType=none&sni=${d}#${n}-tcp"
            lx="${sch}://${id}@${d}:443?${enc}security=tls&type=xhttp&path=${xp//\//%2F}&host=${d}&sni=${d}&alpn=http%2F1.1&mode=auto#${n}-xhttp-tls"
            lxn="${sch}://${id}@${d}:80?${enc}security=none&type=xhttp&path=${xp//\//%2F}&host=${d}&mode=auto#${n}-xhttp-ntls"
        fi
        rt_card_top "${pu^^} ACCOUNT"
        for (( k = 0; k < ${#F[@]}; k += 2 )); do
            case ${F[k]} in "$idl") rt_card_kv "${F[k],,}" "${F[k+1]}" "$U_O" ;; *) rt_card_kv "${F[k],,}" "${F[k+1]}" ;; esac
        done
        rt_card_kv "expired on" "$xe" "$U_Y"
        rt_card_sec "LINK TLS";   printf '%s%s%s\n' "$U_T" "$lt" "$U_R"
        rt_card_sec "LINK NTLS";  printf '%s%s%s\n' "$U_T" "$ln" "$U_R"
        rt_card_sec "LINK TCP";   printf '%s%s%s\n' "$U_T" "$lc" "$U_R"
        rt_card_sec "LINK XHTTP TLS";  printf '%s%s%s\n' "$U_T" "$lx" "$U_R"
        rt_card_sec "LINK XHTTP NTLS"; printf '%s%s%s\n' "$U_T" "$lxn" "$U_R"
        printf '%s\n' "$SUB_HR"
        return 0
    fi
    echo "$L"
    echo "    ${pu^^} ACCOUNT"
    echo "$L"
    echo
    printf '%-11s : %s\n' "${F[@]}"
    echo "$L"
    echo
    echo "Link TLS   :"
    if [[ "$proto" == vmess ]]; then vm_link "$n" "$d" 443 "$id" ws none "$d" "$wp" tls "$d"; echo
    else echo "${sch}://${id}@${d}:443?path=${wp//\//%2F}&security=tls&${enc}type=ws&host=${d}&sni=${d}#${n}"; fi
    echo "$L"
    echo
    echo "Link NTLS  :"
    if [[ "$proto" == vmess ]]; then vm_link "$n" "$d" 80 "$id" ws none "$d" "$wp" "" ""; echo
    else echo "${sch}://${id}@${d}:80?path=${wp//\//%2F}&security=none&${enc}type=ws&host=${d}#${n}"; fi
    echo "$L"
    echo
    echo "Link TCP   :"
    if [[ "$proto" == vmess ]]; then vm_link "${n}-tcp" "$d" "$vt" "$id" tcp none "" "" tls "$d"; echo
    else echo "${sch}://${id}@${d}:${vt}?${enc}security=tls&type=tcp&headerType=none&sni=${d}#${n}-tcp"; fi
    echo "$L"
    echo
    echo "Link XHTTP TLS :"
    if [[ "$proto" == vmess ]]; then vm_link "${n}-xhttp-tls" "$d" 443 "$id" xhttp auto "$d" "$xp" tls "$d" "http/1.1"; echo
    else echo "${sch}://${id}@${d}:443?${enc}security=tls&type=xhttp&path=${xp//\//%2F}&host=${d}&sni=${d}&alpn=http%2F1.1&mode=auto#${n}-xhttp-tls"; fi
    echo "$L"
    echo
    echo "Link XHTTP NTLS :"
    if [[ "$proto" == vmess ]]; then vm_link "${n}-xhttp-ntls" "$d" 80 "$id" xhttp auto "$d" "$xp" "" ""; echo
    else echo "${sch}://${id}@${d}:80?${enc}security=none&type=xhttp&path=${xp//\//%2F}&host=${d}&mode=auto#${n}-xhttp-ntls"; fi
    echo "$L"
    echo
    echo "Expired On : ${xe}"
    echo "$L"
}
xray_ensure_vmess() {   # purane install par VMess inbounds + nginx /vmess khud bana do
    if jq -e '[.inbounds[]?.tag] | (index("vmess-ws") != null and index("vmess-tcp") != null and index("vmess-xhttp") != null) and ([.inbounds[]? | select(.tag=="vmess-xhttp") | .listen] | first == "127.0.0.1")' \
         /usr/local/etc/xray/config.json >/dev/null 2>&1 && grep -q 'location /vmess-xhttp' /etc/nginx/conf.d/vpn.conf 2>/dev/null; then
        return 0
    fi
    echo -e "${YELLOW}   ! VMess inbounds + nginx /vmess setup ho raha hai...${NC}"
    apply_nginx_config >/dev/null 2>&1
    xray_add_transports
}

xray_create_proto() {   # $1 = proto (vmess|vless|trojan)
    local proto="$1" pl u days gb ipl exp id
    pl=$(xray_proto_label "$proto")
    rt_act_head "ADD ${pl^^}" "menu › 04 › 09 › naya ${pl} account"
    if [[ "$proto" == vmess ]]; then xray_ensure_vmess || { press_any_key; return; }; fi
    read -rp "$(rt_q "${pl} username (a-z, 0-9, _ -): ")" u
    if ! xray_valid_name "$u"; then
        rt_err "Username me sirf a-z, A-Z, 0-9, _ - chalega (max 31, kam se kam 1 letter)."; press_any_key; return
    fi
    if [[ -n "$(xray_row "$proto" "$u")" ]]; then
        rt_err "${pl} user '${u}' pehle se maujood hai."; press_any_key; return
    fi
    read -rp "$(rt_q "Days: ")" days
    if [[ ! "$days" =~ ^[0-9]*[1-9][0-9]*$ ]]; then rt_err "Days number hona chahiye (kam se kam 1)."; press_any_key; return; fi
    read -rp "$(rt_q "GB limit (0 = unlimited): ")" gb;  gb=${gb:-0}
    read -rp "$(rt_q "IP limit (0 = unlimited): ")" ipl; ipl=${ipl:-0}
    if [[ ! "$gb" =~ ^[0-9]+$ || ! "$ipl" =~ ^[0-9]+$ ]]; then
        rt_err "GB / IP limit number hona chahiye."; press_any_key; return
    fi
    exp=$(date -d "+$days days" +%Y-%m-%dT%H:%M:%S)      # EXACT: abhi + days*24h
    id=$(cat /proc/sys/kernel/random/uuid)
    xray_add_client "$proto" "$u" "$id" "$exp" "$(( 10#$gb ))" "$(( 10#$ipl ))"
    xray_show_info "$proto" "$u" "$id" "$exp" "$(( 10#$gb ))" "$(( 10#$ipl ))"
    press_any_key
}

xray_delete_proto() {   # $1 = proto
    local proto="$1" pl u
    pl=$(xray_proto_label "$proto")
    rt_act_head "DELETE ${pl^^}" "menu › 04 › 09 › ${pl} account hatao"
    read -rp "$(rt_q "${pl} username to delete: ")" u
    if [[ -z "$(xray_row "$proto" "$u")" ]]; then rt_err "${pl} user nahi mila."; press_any_key; return; fi
    xray_del_client "$proto" "$u"
    rt_ok "Deleted."; press_any_key
}

xray_renew_proto() {   # $1 = proto
    local proto="$1" pl u r_days new_exp rs
    pl=$(xray_proto_label "$proto")
    rt_act_head "RENEW ${pl^^}" "menu › 04 › 09 › ${pl} expiry badhao"
    read -rp "$(rt_q "${pl} username: ")" u
    read -rp "$(rt_q "Additional days: ")" r_days
    if [[ -n "$(xray_row "$proto" "$u")" && "$r_days" =~ ^[0-9]*[1-9][0-9]*$ ]]; then
        new_exp=$(date -d "+$r_days days" +%Y-%m-%dT%H:%M:%S)
        xray_set_exp "$proto" "$u" "$new_exp"
        rt_ok "Renewed to ${new_exp/T/ }"
        read -rp "$(rt_q "Data usage bhi reset karein (0 GB se shuru)? [y/N]: ")" rs
        if [[ "$rs" =~ ^[Yy]$ ]]; then xray_reset_usage "$proto" "$u"; rt_ok "Usage reset."; fi
    else
        rt_err "User not found / days galat."
    fi
    press_any_key
}

xray_edit_limits_proto() {   # $1 = proto
    local proto="$1" pl u row id exp gb ipl ngb nip
    pl=$(xray_proto_label "$proto")
    rt_act_head "LIMITS ${pl^^}" "menu › 04 › 09 › ${pl} GB / IP limit"
    read -rp "$(rt_q "${pl} username: ")" u
    row=$(xray_row "$proto" "$u")
    if [[ -z "$row" ]]; then rt_err "${pl} user nahi mila."; press_any_key; return; fi
    read -r _ id exp gb ipl <<< "$row"; gb=${gb:-0}; ipl=${ipl:-0}
    echo -e "${CYAN}Abhi: GB limit=${gb} (0=unlimited) | IP limit=${ipl} (0=unlimited) | used=$(fmt_bytes "$(xray_usage_of "$u")")${NC}"
    read -rp "$(rt_q "Naya GB limit [Enter = same]: ")" ngb;  ngb=${ngb:-$gb}
    read -rp "$(rt_q "Naya IP limit [Enter = same]: ")" nip;  nip=${nip:-$ipl}
    if [[ ! "$ngb" =~ ^[0-9]+$ || ! "$nip" =~ ^[0-9]+$ ]]; then
        rt_err "Number hona chahiye."; press_any_key; return
    fi
    xray_set_gb "$proto" "$u" "$(( 10#$ngb ))"; xray_set_ip "$proto" "$u" "$(( 10#$nip ))"
    rt_ok "Saved: GB=$(( 10#$ngb )) IP=$(( 10#$nip ))."
    press_any_key
}

xray_reset_proto() {   # $1 = proto
    local proto="$1" pl u
    pl=$(xray_proto_label "$proto")
    rt_act_head "RESET ${pl^^}" "menu › 04 › 09 › ${pl} data usage 0 karo"
    read -rp "$(rt_q "${pl} username (data usage 0 karne ke liye): ")" u
    if [[ -z "$(xray_row "$proto" "$u")" ]]; then rt_err "${pl} user nahi mila."; press_any_key; return; fi
    xray_reset_usage "$proto" "$u"
    rt_ok "Usage reset (GB-limit ya IP-lock se band tha to wapas chalu)."
    press_any_key
}

xray_show_links_proto() {   # $1 = proto
    local proto="$1" pl u row id exp gb ipl
    pl=$(xray_proto_label "$proto")
    rt_act_head "${pl^^} LINKS" "menu › 04 › 09 › existing user ke links"
    read -rp "$(rt_q "${pl} username: ")" u
    row=$(xray_row "$proto" "$u")
    if [[ -z "$row" ]]; then rt_err "${pl} user nahi mila."; press_any_key; return; fi
    read -r _ id exp gb ipl <<< "$row"
    xray_show_info "$proto" "$u" "$id" "$exp" "$gb" "$ipl"
    press_any_key
}

xray_list_proto() {   # $1 = proto
    local proto="$1" pl db n id exp gb ipl used st nowts now lu lim iplim e ex_txt ds rem W uw
    W=$(rt_width)
    nowts=$(date +%Y-%m-%dT%H:%M:%S); now=$(date +%s)
    pl=$(xray_proto_label "$proto"); db=$(xray_db_for "$proto")
    rt_tty || echo -e "${CYAN}--- ${pl} Users ---${NC}"
    if (( W >= 80 )); then
        printf " ${RT_TH:-$BOLD}%-12s %-17s %-19s %-7s %s${NC}\n" USER EXPIRY "USED / GB-LIMIT" "IP-LIM" STATUS
    elif (( W >= 52 )); then
        uw=$(rt_clamp $(( W - 43 )) 6 12)
        printf " ${RT_TH:-$BOLD}%-*s %-11s %-14s %-7s %s${NC}\n" "$uw" USER EXPIRY "USED/LIMIT" "IP-LIM" STATUS
    else
        uw=$(rt_clamp $(( W - 34 )) 4 12)
        printf " ${RT_TH:-$BOLD}%-*s %-5s %-14s %-7s %s${NC}\n" "$uw" USER EXP "USED/LIMIT" "IP-LIM" ST
    fi
    while read -r n id exp gb ipl; do
        [[ -z "$n" ]] && continue
        gb=${gb:-0}; ipl=${ipl:-0}
        used=$(xray_usage_of "$n")
        e=$exp; [[ "$e" == *T* ]] || e="${e}T23:59:59"
        ex_txt=${exp/T/ }; ex_txt=${ex_txt:0:16}
        st="${GREEN}OK${NC}"
        if [[ -e "$XR_DIS/${proto}_$n" ]]; then st="${RED}LOCKED (manual)${NC}"
        elif [[ ! "$e" > "$nowts" ]]; then st="${RED}EXPIRED${NC}"
        elif (( gb > 0 && used >= gb * XR_GIB )); then st="${RED}GB-LIMIT${NC}"
        elif [[ -r "$XR_LOCK/$n" ]] && read -r lu < "$XR_LOCK/$n" && (( 10#${lu:-0} > now )); then
            st="${RED}IP-LOCK (limit change karo)${NC}"
        fi
        if [[ "$st" == *"${RED}"* ]] && declare -F xray_dead_since >/dev/null; then
            ds=$(xray_dead_since "$proto" "$n" "$exp" "$gb")
            if [[ -n "$ds" ]]; then
                rem=$(( ds + XR_DEAD_GRACE - now )); (( rem < 0 )) && rem=0
                st+=" (auto-delete $(fmt_dur "$rem"))"
            fi
        fi
        lim="unlim"; (( gb > 0 )) && lim="${gb} GB"
        iplim="unlim"; (( ipl > 0 )) && iplim="$ipl"
        if (( W >= 80 )); then
            printf ' %-12s %-17s %-19s %-7s %b\n' "$n" "$ex_txt" "$(fmt_bytes "$used") / ${lim}" "$iplim" "$st"
        elif (( W >= 52 )); then
            printf ' %-*.*s %-11.11s %-14.14s %-7.7s %b\n' "$uw" "$uw" "$n" "${ex_txt:5}" "$(fmt_bytes "$used")/${lim// /}" "$iplim" "$(rt_status_short "$st")"
        else
            printf ' %-*.*s %-5.5s %-14.14s %-7.7s %b\n' "$uw" "$uw" "$n" "${ex_txt:5:5}" "$(fmt_bytes "$used")/${lim// /}" "$iplim" "$(rt_status_short "$st" 1)"
        fi
    done < "$db"
}

xray_render_connected() {   # $1 = proto — sirf us protocol ke users dikhta hain
    # FIX: narrow screen par har row EK line me. W>=80 poora | 46..79 USER IP LAST DATA | <46 USER IP DATA
    local proto="$1" pl db live u ip last cnt c total=0 row gb ipl n W uw nm
    declare -A ucnt=() isuser=()
    W=$(rt_width)
    pl=$(xray_proto_label "$proto"); db=$(xray_db_for "$proto")
    while read -r n _; do [[ -n "$n" ]] && isuser[$n]=1; done < "$db"
    if [[ -z "${RT_NOHEAD:-}" ]]; then
    echo -e "${CYAN}$(rt_line =)${NC}"
    if (( W >= 70 )); then echo -e "${YELLOW}   ${pl^^} CONNECTED IPs  (real client IP, active in last ${XR_IP_WINDOW}s)${NC}"
    else echo -e "${YELLOW} ${pl^^} CONNECTED IPs${NC}"; fi
    echo -e "${CYAN}$(rt_line =)${NC}"
    fi
    if [[ ! -r "$XR_LOG" ]]; then
        echo -e " ${RED}Access log nahi mila (${XR_LOG}). Menu 6 (Fix stack) chalayein.${NC}"; return
    fi
    if (( W >= 80 )); then
        printf " ${RT_TH:-$BOLD}%-12s %-16s %-14s %-9s %-5s %s${NC}\n" USER "REAL IP" COUNTRY LAST REQ "DATA (USER TOTAL)"
    elif (( W >= 46 )); then
        uw=$(rt_clamp $(( W - 36 )) 6 12)
        printf " ${RT_TH:-$BOLD}%-*s %-15s %-8s %s${NC}\n" "$uw" USER "REAL IP" LAST DATA
    else
        uw=$(rt_clamp $(( W - 27 )) 4 12)
        printf " ${RT_TH:-$BOLD}%-*s %-15s %s${NC}\n" "$uw" USER "REAL IP" DATA
    fi
    live=$(xray_live "$XR_IP_WINDOW" | sort)
    if [[ -n "$live" ]]; then
        while read -r u ip last cnt; do
            [[ -z "${isuser[$u]}" ]] && continue
            if (( W >= 80 )); then
                c=$(geo_country "$ip")
                printf ' %-12s %-16s %-14s %-9s %-5s %s / %s\n' "$u" "$ip" "${c:0:14}" "$last" "$cnt" \
                    "$(fmt_bytes "$(xray_usage_of "$u")")" \
                    "$( row=$(xray_row "$proto" "$u"); read -r _ _ _ gb _ <<< "$row"; gb=${gb:-0}; \
                       (( gb > 0 )) && echo "${gb} GB" || echo 'unlim' )"
            elif (( W >= 46 )); then
                printf ' %-*.*s %-15.15s %-8.8s %s\n' "$uw" "$uw" "$u" "$ip" "$last" "$(fmt_bytes "$(xray_usage_of "$u")")"
            else
                printf ' %-*.*s %-15.15s %s\n' "$uw" "$uw" "$u" "$ip" "$(fmt_bytes "$(xray_usage_of "$u")")"
            fi
            total=$(( total + 1 ))
            ucnt[$u]=$(( ${ucnt[$u]:-0} + 1 ))
        done <<< "$live"
    fi
    (( total == 0 )) && echo -e " ${YELLOW}Abhi koi ${pl} user connected nahi hai.${NC}"
    if [[ -n "${RT_NOHEAD:-}" ]]; then rt_sub_hr; else echo -e "${CYAN}$(rt_line -)${NC}"; fi
    for u in "${!ucnt[@]}"; do
        row=$(xray_row "$proto" "$u"); read -r _ _ _ gb ipl <<< "$row"; gb=${gb:-0}; ipl=${ipl:-0}
        if (( W >= 80 )); then
            printf ' %-12s IPs: %s/%s   data: %s / %s\n' "$u" "${ucnt[$u]}" \
                "$( (( ipl > 0 )) && echo "$ipl" || echo 'unlim')" \
                "$(fmt_bytes "$(xray_usage_of "$u")")" "$( (( gb > 0 )) && echo "${gb} GB" || echo 'unlim')"
        else
            nm=$(rt_clamp ${#u} 1 12)
            printf ' %-*.*s IP %s/%s  %s/%s\n' "$nm" "$nm" "$u" "${ucnt[$u]}" \
                "$( (( ipl > 0 )) && echo "$ipl" || echo 'unlim')" \
                "$(fmt_bytes "$(xray_usage_of "$u")")" "$( (( gb > 0 )) && echo "${gb}GB" || echo 'unlim')"
        fi
    done
}

xray_show_connected() {   # $1 = proto
    # Terminal me LIVE update nahi (sirf ek dafa ka snapshot). Live update sirf web panel me hota hai.
    local proto="$1"
    clear
    xray_collect_usage 2>/dev/null
    if rt_tty; then
        local pl; pl=$(xray_proto_label "$proto")
        rt_act_head "${pl^^} LIVE" "menu › 04 › 09 › ${pl} connected IPs (active in last ${XR_IP_WINDOW}s)"
        RT_NOHEAD=1 xray_render_connected "$proto"
        rt_sub_hr
        rt_info "Ye abhi ka snapshot hai (live update sirf web panel me). Dobara dekhne ke liye option phir chunein."
    else
        xray_render_connected "$proto"
        echo -e "\n${YELLOW}Ye abhi ka snapshot hai (live update sirf web panel me). Dobara dekhne ke liye option phir chunein.${NC}"
    fi
    press_any_key
}

# ------------------------------------------------------------------------------
# Xray menus — VLESS aur Trojan ke liye ALAG-ALAG menus, dono me saare options
# ------------------------------------------------------------------------------
xray_account_menu() {   # chooser menu
    local xc
    while true; do
        rt_sub_head "XRAY" "menu › 04 › 09 › VMess / VLESS / Trojan"
        if ! xray_ready; then
            printf '  %s✗ Xray (naya version) install/update nahi hai.%s %smain menu 06 (Fix stack) chalayein%s\n' "$U_E" "$U_R" "$U_M" "$U_R"
            press_any_key; return
        fi
        rt_acct_counts
        systemctl is-active --quiet xray; rt_dot $? running stopped; rt_sub_kv xray "$DOT"
        rt_sub_kv accounts "${U_M}VMess${U_R} ${U_W}${RC_VM}${U_R}   ${U_M}VLESS${U_R} ${U_W}${RC_VL}${U_R}   ${U_M}Trojan${U_R} ${U_W}${RC_TR}${U_R}"
        rt_sub_hr
        rt_sub_sec "PROTOCOLS"
        rt_sub_item 1 "VMess Management"
        rt_sub_item 2 "VLESS Management"
        rt_sub_item 3 "Trojan Management"
        rt_sub_item 4 "‹ Back" back
        rt_sub_hr
        rt_sub_prompt 4 4; xc=$SUB_OPT
        case $xc in
            1) vmess_account_menu ;;
            2) vless_account_menu ;;
            3) trojan_account_menu ;;
            4) return ;;
            *) rt_sub_bad ;;
        esac
    done
}

vmess_account_menu()  { xray_proto_menu "vmess";  }
vless_account_menu()  { xray_proto_menu "vless";  }
trojan_account_menu() { xray_proto_menu "trojan"; }

xray_proto_menu() {   # $1 = vmess|vless|trojan — us protocol ka poora menu
    local proto="$1" pl xc n
    pl=$(xray_proto_label "$proto")
    if [[ "$proto" == vmess ]] && xray_ready; then xray_ensure_vmess || press_any_key; fi
    while true; do
        rt_sub_head "${pl^^}" "menu › 04 › 09 › ${pl} accounts"
        if ! xray_ready; then
            printf '  %s✗ Xray (naya version) install/update nahi hai.%s %smain menu 06 (Fix stack) chalayein%s\n' "$U_E" "$U_R" "$U_M" "$U_R"
            press_any_key; return
        fi
        n=$(grep -c . "/var/lib/ddkvps/xray/${proto}.db" 2>/dev/null)
        rt_sub_kv users "${U_W}${n:-0}${U_R} ${U_M}${pl} account(s)${U_R}"
        rt_sub_hr
        rt_sub_sec "ACCOUNTS"
        rt_sub_item 1 "Create ${pl} User (GB / IP limit)"
        rt_sub_item 2 "Delete ${pl} User" danger
        rt_sub_item 3 "Renew ${pl} User"
        rt_sub_item 4 "List ${pl} Users (usage / limits / status)"
        rt_sub_sec "LIMITS & LINKS"
        rt_sub_item 5 "Connected IPs (${pl}, live, real IP)"
        rt_sub_item 6 "Edit Limits (GB / IP)"
        rt_sub_item 7 "Reset Data Usage"
        rt_sub_item 8 "Show Links (existing user)"
        rt_sub_item 9 "‹ Back" back
        rt_sub_hr
        rt_sub_prompt 9 9; xc=$SUB_OPT
        case $xc in
            1) clear; xray_create_proto "$proto" ;;
            2) xray_delete_proto "$proto" ;;
            3) xray_renew_proto "$proto" ;;
            4) clear; rt_act_head "${pl^^}" "menu › 04 › 09 › ${pl} accounts (usage / limits / status)"; xray_list_proto "$proto"; rt_tty && rt_sub_hr; press_any_key ;;
            5) xray_show_connected "$proto" ;;
            6) xray_edit_limits_proto "$proto" ;;
            7) xray_reset_proto "$proto" ;;
            8) xray_show_links_proto "$proto" ;;
            9) return ;;
            *) rt_sub_bad ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Ping stability (QoS): CAKE anti-bufferbloat + per-host fairness + per-user caps
#
#  Heavy downloading ping bigarta kyun hai: link 100% busy -> queue bhar jati hai ->
#  ping/DNS/ACK packets queue ke peeche phas jate hain. CAKE AQM queue ko control
#  karta hai (bufferbloat khatam) + har client IP ko barabar share deta hai, isliye
#  ek user sab kha jane par bhi baaki users ka ping stable rehta hai.
#  DSCP marks: ICMP + DNS = Voice class (top), chote ACKs = Video class.
# ------------------------------------------------------------------------------
detect_wan_iface() {
    ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' | head -n1
}

write_qos_scripts() {
    cat << 'QOS_EOF' > "$QOS_BIN"
#!/bin/bash
# rt-qos - DDK VPS Manager ping stability (CAKE AQM + per-host fairness)
CONF="/etc/ddkvps/qos.conf"
CAPS="/etc/ddkvps/qos-caps.conf"
IFACE=""; BW_MBIT=0

# wait for config + network (boot par interface late aata hai)
for _ in $(seq 1 60); do
    [[ -f "$CONF" ]] && break
    sleep 1
done
[[ -f "$CONF" ]] && . "$CONF"
[[ -z "$IFACE" ]] && IFACE=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' | head -n1)
[[ -z "$IFACE" ]] && { echo "rt-qos: no interface"; exit 1; }
[[ -z "$BW_MBIT" ]] && BW_MBIT=0
BW_UL=${BW_UL_MBIT:-$BW_MBIT}; BW_DL=${BW_DL_MBIT:-$BW_MBIT}

# TCP tweaks: BBR (agar kernel me hai) + fq — loss/congestion me throughput smooth
if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null
fi
sysctl -w net.core.default_qdisc=fq 2>/dev/null

modprobe sch_cake 2>/dev/null
modprobe ifb 2>/dev/null

# CAKE kernel me hai ya nahi (test add/del)
has_cake=0
if tc qdisc add dev "$IFACE" root cake 2>/dev/null; then
    tc qdisc del dev "$IFACE" root 2>/dev/null
    has_cake=1
fi

# ---- EGRESS (upload: server -> clients) ----
tc qdisc del dev "$IFACE" root 2>/dev/null
if [[ "$BW_UL" -gt 0 && "$has_cake" == "1" ]]; then
    tc qdisc add dev "$IFACE" root handle 1: cake bandwidth "${BW_UL}mbit" diffserv4 dual-dsthost wash ack-filter 2>/dev/null       || tc qdisc add dev "$IFACE" root handle 1: cake bandwidth "${BW_UL}mbit" diffserv4 dual-dsthost wash 2>/dev/null       || tc qdisc add dev "$IFACE" root handle 1: fq_codel
else
    tc qdisc add dev "$IFACE" root handle 1: fq_codel 2>/dev/null
fi

# ---- INGRESS (download: internet -> server) — ye heavy downloading ke liye sabse zaroori hai ----
tc qdisc del dev "$IFACE" handle ffff: ingress 2>/dev/null
ip link del ifb0 2>/dev/null
if ip link add ifb0 type ifb 2>/dev/null && ip link set ifb0 up 2>/dev/null; then
    tc qdisc add dev "$IFACE" handle ffff: ingress 2>/dev/null
    tc filter add dev "$IFACE" parent ffff: protocol all matchall         action mirred egress redirect dev ifb0 2>/dev/null
    tc qdisc del dev ifb0 root 2>/dev/null
    if [[ "$BW_DL" -gt 0 && "$has_cake" == "1" ]]; then
        tc qdisc add dev ifb0 root cake bandwidth "${BW_DL}mbit" diffserv4 dual-srchost wash 2>/dev/null           || tc qdisc add dev ifb0 root cake bandwidth "${BW_DL}mbit" besteffort wash 2>/dev/null           || tc qdisc add dev ifb0 root fq_codel
    else
        tc qdisc add dev ifb0 root fq_codel 2>/dev/null
    fi
fi

# ---- Priority marks: ping/DNS/small ACKs ko aage badhao (CAKE diffserv4 classes) ----
iptables -t mangle -C POSTROUTING -o "$IFACE" -p icmp -j DSCP --set-dscp 46 2>/dev/null   || iptables -t mangle -A POSTROUTING -o "$IFACE" -p icmp -j DSCP --set-dscp 46 2>/dev/null
iptables -t mangle -C POSTROUTING -o "$IFACE" -p udp --dport 53 -j DSCP --set-dscp 46 2>/dev/null   || iptables -t mangle -A POSTROUTING -o "$IFACE" -p udp --dport 53 -j DSCP --set-dscp 46 2>/dev/null
iptables -t mangle -C POSTROUTING -o "$IFACE" -p tcp --tcp-flags SYN,ACK,FIN,RST ACK -m length --length 0:128 -j DSCP --set-dscp 24 2>/dev/null   || iptables -t mangle -A POSTROUTING -o "$IFACE" -p tcp --tcp-flags SYN,ACK,FIN,RST ACK -m length --length 0:128 -j DSCP --set-dscp 24 2>/dev/null

# ---- Optional per-client caps (server -> client direction) ----
while read -r capip capmb; do
    [[ "$capip" =~ ^[0-9a-fA-F.:]+$ && "$capmb" =~ ^[0-9]+$ ]] || continue
    (( capmb > 0 )) || continue
    tc filter add dev "$IFACE" parent 1: protocol ip prio 1 u32 match ip dst "$capip"         police rate "${capmb}mbit" burst 1mbit drop 2>/dev/null
done < "$CAPS" 2>/dev/null

echo "rt-qos: iface=$IFACE dl=${BW_DL}mbit ul=${BW_UL}mbit cake=$has_cake"
QOS_EOF
    chmod +x "$QOS_BIN"

    cat << 'QOSSVC_EOF' > /etc/systemd/system/rt-qos.service
[Unit]
Description=DDK VPS Manager Ping Stability (CAKE QoS)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rt-qos
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
QOSSVC_EOF
}

install_ping_stability() {
    clear
    rt_act_head "QoS SETUP" "menu › 07 › 01 › CAKE anti-bufferbloat"
    mkdir -p /etc/ddkvps
    rt_info "Ping stability = CAKE anti-bufferbloat + per-host fairness."
    rt_info "Heavy downloading pe ping stable rakhta hai (upload aur download dono)."
    local def_if cur_bw=0
    def_if=$(detect_wan_iface)
    [[ -f "$QOS_CONF" ]] && { . "$QOS_CONF"; cur_bw=$BW_MBIT; }
    [[ -z "$def_if" ]] && { rt_err "Default interface nahi mila."; press_any_key; return; }
    read -rp "$(rt_q "WAN interface [${IFACE:-$def_if}]: ")" nif
    nif=${nif:-${IFACE:-$def_if}}
    if ! ip link show "$nif" &>/dev/null; then
        rt_err "Interface '$nif' nahi mila. 'ip a' se check karein."; press_any_key; return
    fi
    read -rp "$(rt_q "Total bandwidth Mbit/s — server ki REAL speed (e.g. 100) [${cur_bw}]: ")" nbw
    nbw=${nbw:-$cur_bw}
    if [[ ! "$nbw" =~ ^[0-9]+$ ]]; then
        rt_err "Number chahiye."; press_any_key; return
    fi
    printf 'IFACE=%s
BW_MBIT=%s
' "$nif" "$((10#$nbw))" > "$QOS_CONF"
    touch "$QOS_CAP_FILE"
    write_qos_scripts
    systemctl daemon-reload
    systemctl enable rt-qos >/dev/null 2>&1
    systemctl restart rt-qos
    sleep 2
    qos_status
    rt_ok "Tip: bandwidth apni REAL speed se ~90-95% rakhein (e.g. 100 Mbps line par 90-95)."
    press_any_key
}

auto_setup_qos() {
    local def_if
    def_if=$(detect_wan_iface)
    [[ -z "$def_if" ]] && return 0
    mkdir -p /etc/ddkvps
    printf 'IFACE=%s
BW_MBIT=0
' "$def_if" > "$QOS_CONF"
    touch "$QOS_CAP_FILE"
    write_qos_scripts
    systemctl daemon-reload
    systemctl enable rt-qos >/dev/null 2>&1
    systemctl restart rt-qos >/dev/null 2>&1
    echo -e "${GREEN}   ✔ Ping stability (QoS) enabled on ${def_if} (Menu 7 se bandwidth set karein).${NC}"
}

qos_status() {
    local ifc=""
    if [[ -f "$QOS_CONF" ]]; then . "$QOS_CONF"; ifc=$IFACE; fi
    if [[ -z "$ifc" ]]; then
        rt_warn "QoS configured nahi hai (Menu 7 -> Enable chalayein)."; return
    fi
    if rt_tty; then rt_sub_sec "EGRESS (upload) · $ifc"; else echo -e "${CYAN}=== egress (upload) : $ifc ===${NC}"; fi
    tc -s qdisc show dev "$ifc" 2>/dev/null | grep -E -A6 'cake|fq_codel' || tc qdisc show dev "$ifc"
    if ip link show ifb0 &>/dev/null; then
        if rt_tty; then echo; rt_sub_sec "INGRESS (download) · ifb0"; else echo -e "${CYAN}=== ingress (download) : ifb0 ===${NC}"; fi
        tc -s qdisc show dev ifb0 2>/dev/null
    fi
}

qos_caps_menu() {
    local c ip mbit n=0
    while true; do
        rt_sub_head "QoS CAPS" "menu › 07 › 02 › per-user bandwidth caps"
        if [[ -s "$QOS_CAP_FILE" ]]; then
            printf '  %s%-18s %s%s\n' "$U_T" "CLIENT IP" "MAX SPEED" "$U_R"
            while read -r ip mbit; do
                [[ -z "$ip" ]] && continue
                printf '  %s%-18s%s %s%s Mbit%s\n' "$U_W" "$ip" "$U_R" "$U_O" "$mbit" "$U_R"
            done < "$QOS_CAP_FILE"
        else
            printf '  %s○ koi cap set nahi%s %s(CAKE har client ko barabar share deta hai)%s\n' "$U_O" "$U_R" "$U_M" "$U_R"
        fi
        rt_sub_hr
        rt_sub_item 1 "Add / change cap"
        rt_sub_item 2 "Remove cap" danger
        rt_sub_item 3 "‹ Back" back
        rt_sub_hr
        rt_sub_prompt 3 3; c=$SUB_OPT
        case $c in
            1)
                read -rp "$(rt_q "Client IP (Connected IPs screen se lein): ")" ip
                read -rp "$(rt_q "Max Mbit/s (0 = cap hatao): ")" mbit
                grep -v "^${ip} " "$QOS_CAP_FILE" 2>/dev/null > "${QOS_CAP_FILE}.tmp"
                mv "${QOS_CAP_FILE}.tmp" "$QOS_CAP_FILE"
                if [[ "$ip" =~ ^[0-9a-fA-F.:]+$ && "$mbit" =~ ^[0-9]+$ && "$mbit" -gt 0 ]]; then
                    echo "$ip $mbit" >> "$QOS_CAP_FILE"
                    systemctl restart rt-qos && rt_ok "Cap applied."
                else
                    rt_err "Cap remove/cancel."
                fi
                press_any_key ;;
            2)
                read -rp "$(rt_q "Client IP to remove: ")" ip
                grep -v "^${ip} " "$QOS_CAP_FILE" 2>/dev/null > "${QOS_CAP_FILE}.tmp"
                mv "${QOS_CAP_FILE}.tmp" "$QOS_CAP_FILE"
                systemctl restart rt-qos && rt_ok "Removed."
                press_any_key ;;
            3) return ;;
            *) rt_sub_bad ;;
        esac
    done
}

remove_qos() {
    local ifc=""
    if [[ -f "$QOS_CONF" ]]; then . "$QOS_CONF"; ifc=$IFACE; fi
    systemctl stop rt-qos 2>/dev/null
    systemctl disable rt-qos 2>/dev/null
    rm -f "$QOS_CONF" "$QOS_CAP_FILE" "$QOS_BIN" /etc/systemd/system/rt-qos.service
    systemctl daemon-reload
    if [[ -n "$ifc" ]]; then
        tc qdisc del dev "$ifc" root 2>/dev/null
        tc qdisc del dev "$ifc" handle ffff: ingress 2>/dev/null
    fi
    tc qdisc del dev ifb0 root 2>/dev/null
    ip link del ifb0 2>/dev/null
    rt_ok "QoS removed."
}

ping_stability_menu() {
    local q ifc bw caps
    while true; do
        rt_sub_head "QoS" "menu › 07 › ping stability / anti-bufferbloat (CAKE)"
        ifc="-"; bw="-"
        if [[ -f "$QOS_CONF" ]]; then . "$QOS_CONF"; ifc=$IFACE; bw="${BW_MBIT} Mbit"; fi
        caps=$(grep -c . "$QOS_CAP_FILE" 2>/dev/null)
        systemctl is-active --quiet rt-qos; rt_dot $? ACTIVE INACTIVE; rt_sub_kv status "$DOT"
        rt_sub_kv iface "${U_W}${ifc}${U_R}   ${U_M}bandwidth${U_R} ${U_W}${bw}${U_R}"
        rt_sub_kv caps "${U_W}${caps:-0}${U_R} ${U_M}per-user cap(s)${U_R}"
        rt_sub_hr
        rt_sub_sec "SETUP"
        rt_sub_item 1 "Enable / Configure (recommended)"
        rt_sub_item 2 "Per-user bandwidth cap (add / remove)"
        rt_sub_sec "INFO"
        rt_sub_item 3 "Show status (tc / CAKE stats)"
        rt_sub_item 4 "Disable / remove QoS" danger
        rt_sub_item 5 "‹ Back" back
        rt_sub_hr
        rt_sub_prompt 5 5; q=$SUB_OPT
        case $q in
            1) install_ping_stability ;;
            2) qos_caps_menu ;;
            3) clear; rt_act_head "QoS STATUS" "menu › 07 › 03 › tc / CAKE stats"; qos_status; press_any_key ;;
            4) rt_act_head "QoS REMOVE" "menu › 07 › 04 › CAKE + caps hatao"
               read -rp "$(rt_q "QoS aur saare caps hata dein? [y/N]: ")" q
               if [[ "$q" =~ ^[Yy]$ ]]; then remove_qos; else rt_info "Cancelled."; fi
               press_any_key ;;
            5) return ;;
            *) rt_sub_bad ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Full install
# ------------------------------------------------------------------------------
# ==============================================================================
# DEPLOY SUITE UI - "Install All Components" ka live installer dashboard
#   Terminal par : brand header, host/node, progress bar, phases (Core / Tunnel / Xray /
#                  Boost / Secure / Panel), har step ka status + time, chalte step ki aakhri
#                  log line, CPU / RAM / DSK bars, elapsed / remaining.
#   Terminal na ho (Telegram bot / web panel / pipe) ya RT_PLAIN=1 : purana saada text output.
#   Poora log (dashboard mode): /var/log/ddkvps/install.log
# ==============================================================================
RT_SUITE_VER="7.0"
RT_INSTALL_LOG="/var/log/ddkvps/install.log"

rt_ui_colors() {   # 256-colour palette (teal / orange / green on dark)
    U_R=$'\033[0m'; U_B=$'\033[1m'
    U_T=$'\033[38;5;80m'                 # teal  (accent)
    U_TB=$'\033[1;38;5;234;48;5;80m'     # teal badge  (DDK VPS MANAGER)
    U_GB=$'\033[38;5;80;48;5;237m'       # gray badge  (DEPLOY SUITE)
    U_M=$'\033[38;5;245m'                # muted gray
    U_W=$'\033[38;5;255m'                # white
    U_O=$'\033[38;5;215m'                # orange (current phase)
    U_G=$'\033[38;5;114m'                # green  (done)
    U_E=$'\033[38;5;203m'                # red
    U_Y=$'\033[38;5;221m'                # yellow (warning)
    U_L=$'\033[38;5;239m'                # divider
    U_K=$'\033[38;5;237m'                # empty bar
    UI_EOL=$'\033[K\n'
}
rt_rep() { local s; printf -v s '%*s' "$2" ''; REP=${s// /$1}; }        # REP = $1 x $2
rt_mmss() { local t=$2; (( t < 0 )) && t=0
    if (( t >= 3600 )); then printf -v "$1" '%d:%02d:%02d' $((t/3600)) $((t%3600/60)) $((t%60))
    else printf -v "$1" '%02d:%02d' $((t/60)) $((t%60)); fi; }

rt_ui_size() {
    local s; s=$(stty size < /dev/tty 2>/dev/null)
    UI_ROWS=${s%% *}; UI_COLS=${s##* }
    [[ "$UI_ROWS" =~ ^[0-9]+$ ]] || UI_ROWS=24
    [[ "$UI_COLS" =~ ^[0-9]+$ ]] || UI_COLS=80
    UI_W=$(( UI_COLS - 4 )); (( UI_W > 64 )) && UI_W=64; (( UI_W < 40 )) && UI_W=40
    rt_rep '─' "$UI_W"; UI_LINE=$REP
}
rt_ui_node() {   # -> UI_IP UI_OS UI_NCPU UI_RAM
    UI_IP=$(public_ip)
    UI_OS=$( . /etc/os-release 2>/dev/null; echo "${NAME%% *} ${VERSION_ID:-}" )
    UI_NCPU=$(nproc 2>/dev/null || echo 1)
    UI_RAM=$(awk '/^MemTotal:/{printf "%.1f GB", $2/1048576}' /proc/meminfo 2>/dev/null)
}
rt_ui_host() { local d=${RT_UI_DOMAIN:-}; [[ -z "$d" ]] && d=$(get_domain); [[ "$d" == "No Domain Set" ]] && d="(domain nahi - self-signed)"; UI_HOST=$d; }
rt_ui_stats() {   # CPU (delta /proc/stat) / RAM / disk  -> UI_CPU_P UI_RAM_P UI_DSK_P
    local c u n s id io iq sq st rest tot mt=1 ma=0 k v
    read -r c u n s id io iq sq st rest < /proc/stat
    tot=$(( u + n + s + id + io + iq + sq + st )); id=$(( id + io ))
    if (( ${UI_PT:-0} > 0 && tot > UI_PT )); then
        UI_CPU_P=$(( 100 * ( (tot - UI_PT) - (id - UI_PI) ) / (tot - UI_PT) ))
    fi
    UI_PT=$tot; UI_PI=$id
    while read -r k v _; do
        case $k in MemTotal:) mt=$v ;; MemAvailable:) ma=$v ;; esac
    done < /proc/meminfo
    UI_RAM_P=$(( (mt - ma) * 100 / mt ))
    UI_DSK_P=$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5+0}')
}
rt_ui_lastlog() {   # chalte step ki aakhri saaf log line -> UI_LAST
    UI_LAST=$(tail -c 3000 "$RT_INSTALL_LOG" 2>/dev/null | tr '\r' '\n' \
        | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/[[:cntrl:]]//g; s/^[[:space:]✔✘!→•>-]+//; s/[[:space:]]+$//' \
        | grep -v -e '^$' -e '^=====' | tail -n 1)
}
rt_ui_mini() {   # $1 percent -> REP = 6-cell bar
    local p=${1:-0} f col=$U_T e
    (( p >= 75 )) && col=$U_O; (( p >= 90 )) && col=$U_E
    f=$(( (p * 6 + 50) / 100 )); (( f > 6 )) && f=6; (( f < 0 )) && f=0
    rt_rep '▰' "$f"; e=$REP; rt_rep '▱' $(( 6 - f ))
    REP="${col}${e}${U_K}${REP}${U_R}"
}

rt_ui_frame() {   # $1 = spinner frame -> poora dashboard (cursor home se) stdout par
    local SP=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) spin now i n=${#RT_ST_T[@]} r st a z
    local cur=-1 tot=0 dn=0 rem=0 el w part fin=0 warn=0 pct out="" l t tw tm
    local -a S A Z
    printf -v now '%(%s)T' -1
    spin=${SP[${1:-0} % 10]}
    [[ -f "$UI_DIR/state" ]] && mapfile -t _UI_ROWS < "$UI_DIR/state"
    for (( i = 0; i < n; i++ )); do
        r=( ${_UI_ROWS[i]:-wait 0 0} ); S[i]=${r[0]}; A[i]=${r[1]}; Z[i]=${r[2]}
        w=${RT_ST_E[i]}; tot=$(( tot + w ))
        case ${S[i]} in
            ok|skip) dn=$(( dn + w )); fin=$(( fin + 1 )) ;;
            warn)    dn=$(( dn + w )); fin=$(( fin + 1 )); warn=$(( warn + 1 )) ;;
            run)     cur=$i; el=$(( now - A[i] )); part=$el; (( part > w * 95 / 100 )) && part=$(( w * 95 / 100 ))
                     dn=$(( dn + part )); (( w - el > 3 )) && rem=$(( rem + w - el )) || rem=$(( rem + 3 )) ;;
            *)       rem=$(( rem + w )) ;;
        esac
    done
    pct=$(( dn * 100 / tot )); (( fin == n )) && { pct=100; rem=0; }

    # --- header ---
    out+="  ${U_TB} DDK VPS MANAGER ${U_R}${U_GB} ${RT_UI_BADGE:-DEPLOY SUITE} ${U_R} ${U_M}v${RT_SUITE_VER}${U_R}${UI_EOL}"
    out+="  ${U_M}${RT_UI_SUB:-SSH / WS / SSL / Xray / QoS setup}${U_R}${UI_EOL}${UI_EOL}"
    out+="  ${U_M}host${U_R}  ${U_W}${UI_HOST}${U_R}${UI_EOL}"
    out+="  ${U_M}node${U_R}  ${U_W}${UI_IP}  ${UI_OS}  ${UI_NCPU} vCPU  ${UI_RAM} RAM${U_R}${UI_EOL}"
    out+="  ${U_L}${UI_LINE}${U_R}${UI_EOL}"

    # --- progress bar ---
    local lab=${RT_UI_LAB:-DEPLOYING} bl f e
    (( fin == n )) && lab=${RT_UI_DONE:-DEPLOYED}
    bl=$(( UI_W - 17 )); f=$(( pct * bl / 100 ))
    rt_rep '━' "$f"; e=$REP; rt_rep '━' $(( bl - f ))
    printf -v l '  %s%-9s%s  %s%s%s%s%s  %s%3d%%%s' "$U_B$U_T" "$lab" "$U_R" "$U_T" "$e" "$U_K" "$REP" "$U_R" "$U_B$U_W" "$pct" "$U_R"
    out+="$l${UI_EOL}"

    # --- phases ---
    local p ph_done ph_any ph_run line="  "
    for p in "${!RT_PH[@]}"; do
        ph_done=1; ph_any=0; ph_run=0
        for (( i = 0; i < n; i++ )); do
            (( RT_ST_P[i] == p )) || continue
            case ${S[i]} in ok|warn|skip) ph_any=1 ;; run) ph_run=1; ph_done=0 ;; *) ph_done=0 ;; esac
        done
        if (( ph_done )); then line+="${U_G}✓ ${U_W}${RT_PH[p]}${U_R} "
        elif (( ph_run || ph_any )); then line+="${U_O}◉ ${U_B}${RT_PH[p]}${U_R} "
        else line+="${U_M}○ ${RT_PH[p]}${U_R} "; fi
    done
    out+="${line}${UI_EOL}${UI_EOL}"

    # --- steps (lambi list ho to chalte step ke aas-paas ka hissa) ---
    local maxv first=0 last
    maxv=$(( UI_ROWS - 16 )); (( maxv < 3 )) && maxv=3; (( maxv > n )) && maxv=$n
    local focus=$cur
    if (( focus < 0 )); then focus=$(( n - 1 )); for (( i = 0; i < n; i++ )); do [[ ${S[i]} == wait ]] && { focus=$i; break; }; done; fi
    if (( n > maxv )); then
        first=$(( focus - 2 )); (( first < 0 )) && first=0; (( first > n - maxv )) && first=$(( n - maxv ))
    fi
    last=$(( first + maxv - 1 ))
    tw=$(( UI_W - 13 ))
    for (( i = first; i <= last; i++ )); do
        t=${RT_ST_T[i]:0:tw}
        case ${S[i]} in
            ok)   rt_mmss tm $(( Z[i] - A[i] ))
                  printf -v l '  %s✓%s %s%02d%s  %s%-*s%s  %s%s%s' "$U_G" "$U_R" "$U_M" $((i+1)) "$U_R" "$U_W" "$tw" "$t" "$U_R" "$U_M" "$tm" "$U_R" ;;
            warn) rt_mmss tm $(( Z[i] - A[i] ))
                  printf -v l '  %s!%s %s%02d%s  %s%-*s%s  %s%s%s' "$U_Y" "$U_R" "$U_M" $((i+1)) "$U_R" "$U_W" "$tw" "$t" "$U_R" "$U_Y" "$tm" "$U_R" ;;
            skip) printf -v l '  %s-  %02d  %-*s  skip%s' "$U_M" $((i+1)) "$tw" "$t" "$U_R" ;;
            run)  rt_mmss tm $(( now - A[i] ))
                  printf -v l '  %s%s%s %s%02d%s  %s%s%-*s%s  %s%s%s' "$U_T" "$spin" "$U_R" "$U_T" $((i+1)) "$U_R" "$U_B" "$U_W" "$tw" "$t" "$U_R" "$U_T" "$tm" "$U_R" ;;
            *)    printf -v l '  %s·  %02d  %s%s' "$U_M" $((i+1)) "$t" "$U_R" ;;
        esac
        out+="$l${UI_EOL}"
        if [[ ${S[i]} == run ]]; then
            out+="     ${U_M}└ ${UI_LAST:0:$(( UI_W - 6 ))}${U_R}${UI_EOL}"
        fi
    done
    (( cur < 0 || cur < first || cur > last )) && out+="${UI_EOL}"
    out+="  ${U_L}${UI_LINE}${U_R}${UI_EOL}"

    # --- system + time ---
    local cb rb db te tr
    rt_ui_mini "${UI_CPU_P:-0}"; cb=$REP; rt_ui_mini "${UI_RAM_P:-0}"; rb=$REP; rt_ui_mini "${UI_DSK_P:-0}"; db=$REP
    printf -v l '  %sCPU%s %s %3d%%   %sRAM%s %s %3d%%   %sDSK%s %s %3d%%' \
        "$U_M" "$U_R" "$cb" "${UI_CPU_P:-0}" "$U_M" "$U_R" "$rb" "${UI_RAM_P:-0}" "$U_M" "$U_R" "$db" "${UI_DSK_P:-0}"
    out+="$l${UI_EOL}"
    rt_mmss te $(( ${Z[n-1]:-0} > 0 && fin == n ? Z[n-1] - UI_T0 : now - UI_T0 )); rt_mmss tr "$rem"
    if (( fin == n )); then
        if (( warn )); then out+="  ${U_M}elapsed${U_R} ${U_W}${te}${U_R}   ${U_Y}${warn} warning${U_R}${UI_EOL}"
        else out+="  ${U_M}elapsed${U_R} ${U_W}${te}${U_R}   ${U_G}sab steps OK${U_R}${UI_EOL}"; fi
    else
        out+="  ${U_M}elapsed${U_R} ${U_W}${te}${U_R}   ${U_M}remaining${U_R} ${U_W}~${tr}${U_R}${UI_EOL}"
    fi
    printf '\033[H%s\033[J' "$out"
}
rt_ui_loop() {   # background renderer
    trap 'exit 0' TERM INT
    local k=0
    while :; do
        if (( k % 3 == 0 )); then rt_ui_size; rt_ui_stats; rt_ui_lastlog; fi
        rt_ui_frame "$k"
        k=$(( k + 1 )); sleep 0.3
    done
}
rt_ui_save() {   # main shell -> state file (renderer padhta hai)
    local i out=""
    for i in "${!RT_ST_T[@]}"; do out+="${UI_S[i]:-wait} ${UI_A[i]:-0} ${UI_Z[i]:-0}"$'\n'; done
    printf '%s' "$out" > "$UI_DIR/state.tmp" && mv -f "$UI_DIR/state.tmp" "$UI_DIR/state"
}
rt_ui_start() {
    UI_DIR=$(mktemp -d /run/rt-ui.XXXXXX 2>/dev/null || mktemp -d)
    UI_S=(); UI_A=(); UI_Z=(); UI_B0=(); UI_B1=(); rt_ui_save
    printf -v UI_T0 '%(%s)T' -1
    rt_ui_host; rt_ui_size; rt_ui_stats
    stty -echo 2>/dev/null < /dev/tty          # beech me keys dabane se screen na bigde
    printf '\033[?25l\033[2J\033[H'
    rt_ui_loop & UI_PID=$!
    trap 'rt_ui_stop; printf "\n  %s✗ %s roka gaya%s  %slog:%s %s\n" "$U_E" "${RT_UI_WHAT:-install}" "$U_R" "$U_M" "$U_R" "$RT_INSTALL_LOG"; exit 130' INT TERM
}
rt_ui_stop() {
    if [[ -n "${UI_PID:-}" ]]; then kill "$UI_PID" 2>/dev/null; wait "$UI_PID" 2>/dev/null; UI_PID=""; fi
    stty echo 2>/dev/null < /dev/tty
    printf '\033[?25h'
}
rt_ui_ask_domain() {   # dashboard se pehle: domain screen -> RT_UI_DOMAIN
    local cur d
    cur=$(get_domain); [[ "$cur" == "No Domain Set" ]] && cur=""
    rt_ui_size
    printf '\033[2J\033[H'
    printf '  %s DDK VPS MANAGER %s%s DEPLOY SUITE %s %sv%s%s\n' "$U_TB" "$U_R" "$U_GB" "$U_R" "$U_M" "$RT_SUITE_VER" "$U_R"
    printf '  %sSSH / WS / SSL / Xray / QoS setup%s\n\n' "$U_M" "$U_R"
    printf '  %snode%s  %s%s  %s  %s vCPU  %s RAM%s\n' "$U_M" "$U_R" "$U_W" "$UI_IP" "$UI_OS" "$UI_NCPU" "$UI_RAM" "$U_R"
    printf '  %s%s%s\n' "$U_L" "$UI_LINE" "$U_R"
    printf '  %s%sDOMAIN%s  %sA record is VPS ke IP par: %s%s%s\n' "$U_B" "$U_T" "$U_R" "$U_M" "$U_W" "$UI_IP" "$U_R"
    printf '  %sIsi domain par SSL lagega; sab services + web panel isi cert ko use karenge.%s\n\n' "$U_M" "$U_R"
    while true; do
        printf '  %s›%s %s' "$U_T" "$U_R" "${cur:+${U_M}[Enter = $cur]${U_R} }"
        read -r d || d=""
        d=$(norm_domain "$d"); [[ -z "$d" ]] && d="$cur"
        valid_domain "$d" && break
        printf '  %s✗ domain galat hai%s %s(misal: vpn.example.com)%s\n' "$U_E" "$U_R" "$U_M" "$U_R"
    done
    RT_UI_DOMAIN=$d
}

# --- install steps (har ek: 0 = OK, 3 = skip, baaki = warning; install kabhi beech me nahi rukta) ---
_st_domain() {
    if ! ask_domain_first "${RT_UI_DOMAIN:-}"; then
        echo -e "${YELLOW}   ! Domain nahi mila - self-signed cert ke saath install ho raha hai (baad me Menu 2 + 3).${NC}"; return 1
    fi
    getent ahostsv4 "$(get_domain)" >/dev/null 2>&1 || return 1    # DNS abhi nahi mila -> SSL fail hoga (warning)
    return 0
}
_st_packages() {
    local pk miss=0 pkgs=(curl wget unzip tar net-tools iproute2 socat jq openssl nginx dropbear certbot rustc lsof haproxy psmisc)
    apt_wait_lock 900
    apt_run update
    if ! apt_run install "${pkgs[@]}"; then
        echo -e "${YELLOW}   ! Kuch packages ek saath nahi lage - ek-ek karke install...${NC}"
        for pk in "${pkgs[@]}"; do
            dpkg -s "$pk" >/dev/null 2>&1 || apt_run install "$pk" >/dev/null 2>&1 || { echo -e "${RED}   ✘ $pk install nahi hua${NC}"; miss=1; }
        done
    fi
    systemctl stop nginx 2>/dev/null; rm -f /etc/nginx/sites-enabled/default
    mkdir -p "$LIM_DIR" "$USE_DIR" "$LCK_DIR" "$GEO_DIR" "$EXPIRY_DIR" "$EXLCK_DIR" "$DEAD_DIR" "$RUN_DIR"
    return $miss
}
_st_dropbear() {
    if [[ ! -f "$BANNER_FILE" || ! -s "$BANNER_FILE" ]]; then write_default_banner; fi
    fix_dropbear_core; return 0
}
_st_wsproxy() { install_wsproxy_service; [[ -x /usr/local/bin/ws-proxy ]]; }
_st_nginx()   { apply_nginx_config; return 0; }
_st_haproxy() { install_haproxy; return 0; }
_st_monitor() { install_monitor_service; return 0; }
_st_xray() {
    install_xray && return 0
    echo -e "${YELLOW}   ! Xray pehli koshish me nahi laga - 20s baad dobara...${NC}"; sleep 20
    install_xray && return 0
    echo -e "${RED}   ✘ Xray abhi bhi nahi laga - final check dobara koshish karega${NC}"; return 1
}
_st_qos()    { auto_setup_qos; return 0; }
_st_harden() { harden_ssh_users; return 0; }
_st_ssl() {
    if has_domain; then issue_ssl_auto; return $?; fi
    write_cert_tools
    echo -e "${YELLOW}   ! Domain nahi - SSL skip (self-signed).${NC}"; return 1
}
_st_xtls() {   # Xray TCP/XHTTP inbounds ko asli (Let's Encrypt) cert
    [[ -f /usr/local/etc/xray/config.json ]] || return 3
    xray_add_transports
}
_st_web() {
    local rc; web_install_auto; rc=$?
    has_domain && [[ -s "/etc/letsencrypt/live/$(get_domain)/fullchain.pem" ]] && "$CERT_SYNC_BIN" >/dev/null 2>&1
    return $rc
}
_st_verify() { local rc; rt_verify_stack; rc=$?; ensure_menu_cmd; return $rc; }

rt_install_steps() {
    RT_PH=(Core Tunnel Xray Boost Secure Panel)
    RT_ST_T=("Domain + DNS check" "System packages" "Dropbear SSH core" "Rust ws-proxy (real-IP relay)"
             "Nginx internal router" "HAProxy 80/443 multiplexer" "GB / IP limit monitor" "Xray VMess/VLESS/Trojan"
             "Ping stability (CAKE QoS)" "SSH users: tunnel-only shell" "Let's Encrypt SSL certificate"
             "Xray TLS inbounds (TCP/XHTTP)" "Web panel (rt-web)" "Final health check")
    RT_ST_F=(_st_domain _st_packages _st_dropbear _st_wsproxy _st_nginx _st_haproxy _st_monitor _st_xray
             _st_qos _st_harden _st_ssl _st_xtls _st_web _st_verify)
    RT_ST_P=(0 0 0 1 1 1 1 2 3 4 4 4 5 5)
    RT_ST_E=(5 180 25 200 5 8 5 60 6 3 45 10 25 15)      # andaza (seconds) -> progress + remaining
}
# Web panel (rt-web) ke liye machine markers - sirf RT_WEB_UI=1 par (Telegram bot / pipe ka output wahi saada)
#   web panel inhe padh kar wahi Deploy Suite dashboard (progress / phases / steps / time) browser me banata hai
rt_web_mark() { [[ -n "${RT_WEB_UI:-}" ]] && printf '::rt:%s\n' "$1"; return 0; }
rt_web_plan() {   # $1 badge, $2 subtitle, $3 running label, $4 done label
    [[ -n "${RT_WEB_UI:-}" ]] || return 0
    local i t0; printf -v t0 '%(%s)T' -1
    rt_web_mark "plan:$1|$2|$3|$4|$t0|$RT_SUITE_VER"
    rt_web_mark "phases:$(IFS=,; echo "${RT_PH[*]}")"
    for i in "${!RT_ST_T[@]}"; do rt_web_mark "step:$i:${RT_ST_P[i]}:${RT_ST_E[i]}:${RT_ST_T[i]}"; done
}
rt_run_step() {   # $1 = step index
    local i=$1 rc t0 t1
    printf -v t0 '%(%s)T' -1
    if (( RT_UI )); then
        UI_S[i]=run; UI_A[i]=$t0; rt_ui_save
        printf '\n===== [%02d] %s  (%s) =====\n' $(( i + 1 )) "${RT_ST_T[i]}" "$(date '+%F %T')" >> "$RT_INSTALL_LOG"
        UI_B0[i]=$(stat -c %s "$RT_INSTALL_LOG" 2>/dev/null || echo 0)
        "${RT_ST_F[i]}" >> "$RT_INSTALL_LOG" 2>&1 < /dev/null; rc=$?
        UI_B1[i]=$(stat -c %s "$RT_INSTALL_LOG" 2>/dev/null || echo 0)
    else
        rt_web_mark "run:$i:$t0"
        echo -e "${BLUE}[$(( i + 1 ))/${#RT_ST_T[@]}] ${RT_ST_T[i]}...${NC}"
        "${RT_ST_F[i]}"; rc=$?
    fi
    printf -v t1 '%(%s)T' -1
    case $rc in 0) UI_S[i]=ok ;; 3) UI_S[i]=skip ;; *) UI_S[i]=warn; RT_WARN+=("$i") ;; esac
    UI_Z[i]=$t1
    if (( RT_UI )); then
        rt_ui_save
    else
        case ${UI_S[i]} in
            ok)   echo -e "${GREEN}   ✔ OK ($(( t1 - t0 ))s)${NC}" ;;
            skip) echo -e "   - skip" ;;
            *)    echo -e "${YELLOW}   ! warning ($(( t1 - t0 ))s)${NC}" ;;
        esac
        rt_web_mark "end:$i:${UI_S[i]}:$t1"
    fi
    return 0
}
rt_ui_summary() {   # dashboard ke neeche: links / SSL / web panel login / warnings
    local dom i u p kv
    dom=$(get_domain); cert_info
    kv() { printf '  %s%-11s%s %s%s%s\n' "$U_M" "$1" "$U_R" "${3:-$U_W}" "$2" "$U_R"; }
    echo
    if (( ${#RT_WARN[@]} )); then
        printf '  %s READY %s  %s%d/%d steps OK%s  %s! %d warning%s\n\n' "$U_TB" "$U_R" "$U_W" $(( ${#RT_ST_T[@]} - ${#RT_WARN[@]} )) "${#RT_ST_T[@]}" "$U_R" "$U_Y" "${#RT_WARN[@]}" "$U_R"
    else
        printf '  %s READY %s  %s✓ %d/%d steps OK%s\n\n' "$U_TB" "$U_R" "$U_G" "${#RT_ST_T[@]}" "${#RT_ST_T[@]}" "$U_R"
    fi
    kv "SSH Direct" "22 · 109 · 447 · 80 · 443  (banner auto-detect)"
    kv "SSH-WS"     "80  → ${CUSTOM_PATH}"
    kv "SSH-WS-SSL" "443 → ${CUSTOM_PATH}  (TLS)"
    kv "SSH-SSL"    "443 · SNI / Host = ${dom}"
    kv "Xray"       "VMess / VLESS / Trojan · WS / TCP / XHTTP"
    kv "Limits"     "GB + IP har protocol par · check har ${MONITOR_INTERVAL}s"
    if [[ "$CI_KIND" == letsencrypt ]]; then kv "SSL" "Let's Encrypt · expiry ${CI_END} · auto-renew ON" "$U_G"
    else kv "SSL" "self-signed - A record check karke Menu 3 chalayein" "$U_Y"; fi
    if web_installed; then
        echo
        printf '  %s WEB PANEL %s  %s%s%s\n' "$U_GB" "$U_R" "$U_T" "$(web_url)" "$U_R"
        u=$(web_login_user); p=$(web_login_pass)
        [[ -n "$u" ]] && kv "username" "$u  (Super Admin)"
        [[ -n "$p" ]] && kv "password" "$p" "$U_O"
        systemctl is-active --quiet rt-web || kv "status" "rt-web band hai - menu -> 10) Web Panel" "$U_E"
    fi
    if (( ${#RT_WARN[@]} )); then
        echo
        for i in "${RT_WARN[@]}"; do
            printf '  %s!%s %s%02d%s  %s%s%s\n' "$U_Y" "$U_R" "$U_M" $(( i + 1 )) "$U_R" "$U_W" "${RT_ST_T[i]}" "$U_R"
            tail -c +$(( ${UI_B0[i]:-0} + 1 )) "$RT_INSTALL_LOG" 2>/dev/null | head -c $(( ${UI_B1[i]:-0} - ${UI_B0[i]:-0} )) \
                | tr '\r' '\n' | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/^[[:space:]]+//' | grep -v '^$' | tail -n 2 \
                | while IFS= read -r l; do printf '       %s└ %s%s\n' "$U_M" "${l:0:$(( UI_W - 8 ))}" "$U_R"; done
        done
        printf '  %sMenu 6 (Fix) ya web panel se dobara chala sakte hain.%s\n' "$U_M" "$U_R"
    fi
    echo
    printf '  %s%s%s\n' "$U_L" "$UI_LINE" "$U_R"
    kv "log"    "$RT_INSTALL_LOG" "$U_M"
    kv "manage" "menu  (ya ddkvps)" "$U_T"
    unset -f kv
}

install_all_components() {   # $1 = domain (optional; na ho to pehle poochta hai)
    local i
    rt_install_steps; RT_WARN=(); UI_S=(); UI_A=(); UI_Z=(); RT_UI_DOMAIN=$(norm_domain "${1:-}")
    RT_UI=0
    [[ -t 1 && -z "${RT_PLAIN:-}" && "${TERM:-dumb}" != dumb ]] && RT_UI=1

    if (( ! RT_UI )); then   # ---- saada text mode (bot / web panel / pipe) ----
        echo -e "${CYAN}==============================================${NC}"
        echo -e "${YELLOW}   ${PANEL_NAME} - INSTALL (Deploy Suite v${RT_SUITE_VER})${NC}"
        echo -e "${CYAN}==============================================${NC}"
        rt_web_plan "DEPLOY SUITE" "SSH / WS / SSL / Xray / QoS setup" DEPLOYING DEPLOYED
        for i in "${!RT_ST_T[@]}"; do rt_run_step "$i"; done
        rt_web_mark "done:${#RT_WARN[@]}"
        echo -e "\n${GREEN}[SUCCESS] SSH Direct + SSH-WS + SSH-WS-SSL + SSH-SSL — all live on 80/443.${NC}"
        echo -e "${CYAN}SSH Direct   : 22, 109, 447, 80, 443 (auto-detected by banner)${NC}"
        echo -e "${CYAN}SSH-WS       : port 80  -> ${CUSTOM_PATH}${NC}"
        echo -e "${CYAN}SSH-WS-SSL   : port 443 (TLS) -> ${CUSTOM_PATH}${NC}"
        echo -e "${CYAN}SSH-SSL      : port 443 (TLS) -> SNI/Host = $(get_domain)${NC}"
        echo -e "${CYAN}Limits       : GB + IP limit har protocol par, rt-monitor har ${MONITOR_INTERVAL}s check karta hai${NC}"
        cert_info
        if [[ "$CI_KIND" == letsencrypt ]]; then
            echo -e "${GREEN}SSL          : Let's Encrypt (expiry ${CI_END}), auto-renew ON${NC}"
        else
            echo -e "${YELLOW}SSL          : self-signed - domain ka A record check karke Menu 3 chalayein.${NC}"
        fi
        (( ${#RT_WARN[@]} )) && echo -e "${YELLOW}   ! ${#RT_WARN[@]} step(s) me warning (upar dekhein) - Menu 6 (Fix) ya web panel se dobara.${NC}"
        if web_installed; then echo -e "\n${YELLOW}   WEB PANEL${NC}"; web_show_info; fi
        press_any_key
        return 0
    fi

    # ---- dashboard mode ----
    rt_ui_colors; rt_ui_node
    if ! valid_domain "$RT_UI_DOMAIN" && [[ -t 0 ]]; then rt_ui_ask_domain; fi
    mkdir -p "$(dirname "$RT_INSTALL_LOG")"
    ( umask 077; : > "$RT_INSTALL_LOG" ); chmod 600 "$RT_INSTALL_LOG"   # log me web panel password bhi hota hai
    printf 'DDK VPS Manager Deploy Suite v%s - install log (%s)\n' "$RT_SUITE_VER" "$(date '+%F %T')" >> "$RT_INSTALL_LOG"
    rt_ui_start
    for i in "${!RT_ST_T[@]}"; do
        rt_run_step "$i"
    done
    rt_ui_stop
    trap - INT TERM
    rt_ui_host; rt_ui_size; rt_ui_stats; rt_ui_lastlog
    rt_ui_frame 0                        # aakhri (100%) frame
    rt_ui_summary
    rm -rf "$UI_DIR"
    if [[ -t 0 ]]; then
        printf '\n  %sEnter%s %sdabayein - menu khulega%s ' "$U_T" "$U_R" "$U_M" "$U_R"; read -r _
    fi
    return 0
}

setup_ssl() {   # [--force]  (bot bhi isi ko chalata hai)
    clear
    local current_dom; current_dom=$(get_domain)
    rt_act_head "SSL" "menu › 03 › Let's Encrypt ${1:+(force) }issue / renew"
    if ! has_domain; then
        rt_err "[ERROR] Pehle domain set karein (Menu 2)!"; press_any_key; return
    fi
    rt_info "SSL for ${current_dom} (HAProxy + Xray + Web panel)..."
    dns_check "$current_dom"
    if issue_ssl_auto "${1:-}"; then
        rt_ok "[SUCCESS] Certificate ready: ${current_dom}"
        # haproxy config hi nahi / band hai to dobara bana do (pem ab Let's Encrypt wala)
        if [[ ! -f /etc/haproxy/haproxy.cfg ]] || ! systemctl is-active --quiet haproxy; then install_haproxy; fi
        if [[ -f /usr/local/etc/xray/config.json ]]; then
            echo -e "${BLUE}   → Xray TCP/XHTTP inbounds check...${NC}"
            xray_add_transports
        fi
        web_installed && rt_ok "   Web panel: $(web_url)"
    else
        rt_err "[ERROR] SSL fail (self-signed cert chalta rahega)."
    fi
    press_any_key
}

add_domain_option() {
    clear
    rt_act_head "DOMAIN" "menu › 02 › domain / subdomain set karo"
    read -rp "$(rt_q "Domain enter karein (e.g. sub.example.com): ")" new_dom
    if [[ -z "$new_dom" ]]; then
        rt_err "[ERROR] Khaali nahi ho sakta!"
    else
        new_dom=$(norm_domain "$new_dom")
        if ! valid_domain "$new_dom"; then
            rt_err "[ERROR] Domain galat hai (misal: vpn.example.com)"; press_any_key; return
        fi
        mkdir -p /etc/ddkvps
        echo "$new_dom" > "$DOMAIN_FILE"
        rt_ok "[SUCCESS] Domain: ${new_dom}"
        dns_check "$new_dom"
        apply_nginx_config
        [[ -f /etc/haproxy/haproxy.cfg ]] && install_haproxy
        if [[ -f /etc/haproxy/haproxy.cfg ]]; then
            echo -e "${BLUE}   → Naye domain ka SSL...${NC}"
            if issue_ssl_auto; then
                [[ -f /usr/local/etc/xray/config.json ]] && xray_add_transports
            fi
            web_installed && rt_ok "   Web panel: $(web_url)"
        fi
    fi
    press_any_key
}

# ------------------------------------------------------------------------------
# Small helpers used by the user menu
# ------------------------------------------------------------------------------
fmt_bytes() {   # bytes -> "1.25 GB" / "12.3 MB" / "800 KB"
    local b=${1:-0}
    if   (( b >= 1073741824 )); then printf '%d.%02d GB' $(( b / 1073741824 )) $(( (b % 1073741824) * 100 / 1073741824 ))
    elif (( b >= 1048576 ));    then printf '%d.%d MB'  $(( b / 1048576 )) $(( (b % 1048576) * 10 / 1048576 ))
    else printf '%d KB' $(( b / 1024 )); fi
}

fmt_dur() {     # seconds -> "2h05m" / "4m12s" / "30s"
    local s=${1:-0}; (( s < 0 )) && s=0
    if   (( s >= 3600 )); then printf '%dh%02dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
    elif (( s >= 60 ));   then printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
    else printf '%ds' "$s"; fi
}

valid_username() {   # a-z A-Z 0-9 _ -  (max 31); kam se kam 1 letter (sirf digits Linux user name nahi hota)
    [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]{0,30}$ && "$1" =~ [A-Za-z_] ]]
}

is_panel_user() {   # existing normal (non-system) account, safe to use in file paths
    local u="$1" uid
    [[ "$u" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$ ]] || return 1
    uid=$(id -u "$u" 2>/dev/null) || return 1
    (( uid >= 1000 && uid < 60000 ))
}

get_limits() {  # $1=user -> G_GB, G_IP  (0 = unlimited; users without a file are unlimited)
    local a=0 b=0
    [[ -r "${LIM_DIR}/$1" ]] && read -r a b < "${LIM_DIR}/$1"
    a=${a//[!0-9]/}; b=${b//[!0-9]/}
    G_GB=$(( 10#${a:-0} )); G_IP=$(( 10#${b:-0} ))
}

get_usage() {   # $1=user -> G_USED (bytes)
    local a=0
    [[ -r "${USE_DIR}/$1" ]] && read -r a < "${USE_DIR}/$1"
    a=${a//[!0-9]/}; G_USED=$(( 10#${a:-0} ))
}

# ---- manual lock / unlock (web panel ka power button) ----
# Lock  : login band (usermod -L) + sab connected sessions kaat do. Unlock tak band rehta hai, auto-delete NAHI hota.
# Unlock: manual lock hatao; agar GB/IP limit ya expiry ka lock bhi laga ho to wo waisa hi rehta hai.
ssh_set_disabled() {   # $1 = user, $2 = 1 (lock) | 0 (unlock)
    local u="$1"
    if ! is_panel_user "$u"; then echo -e "${RED}User nahi mila: $u${NC}"; return 1; fi
    mkdir -p "$DIS_DIR"
    if [[ "$2" == 1 ]]; then
        date +%s > "${DIS_DIR}/${u}"
        usermod -L "$u" 2>/dev/null
        kick_user "$u"; pkill -KILL -u "$u" 2>/dev/null
        echo -e "${GREEN}SSH account '$u' LOCK ho gaya: login band, connected sessions kaat diye.${NC}"
    else
        rm -f "${DIS_DIR}/${u}"
        if [[ -e "${LCK_DIR}/${u}" || -e "${STATE_DIR}/iplocked/${u}" || -e "${EXLCK_DIR}/${u}" ]]; then
            echo -e "${YELLOW}Manual lock hata diya, lekin account abhi bhi GB/IP limit ya expiry ki wajah se band hai (Renew / Reset / Limits se kholein).${NC}"
        else
            usermod -U "$u" 2>/dev/null
            echo -e "${GREEN}SSH account '$u' UNLOCK ho gaya.${NC}"
        fi
    fi
}
xray_set_disabled() {   # $1 = proto, $2 = user, $3 = 1 (lock) | 0 (unlock)
    local p="$1" n="$2" pl
    pl=$(xray_proto_label "$p")
    if [[ -z "$(xray_row "$p" "$n")" ]]; then echo -e "${RED}${pl} user nahi mila: $n${NC}"; return 1; fi
    xray_set_disabled_client "$p" "$n" "$3" || { echo -e "${RED}Xray config update fail.${NC}"; return 1; }
    if [[ "$3" == 1 ]]; then
        echo -e "${GREEN}${pl} account '$n' LOCK ho gaya (Xray se hata diya, connection kat gaya).${NC}"
    else
        echo -e "${GREEN}${pl} account '$n' UNLOCK ho gaya.${NC}"
        local row exp gb e nowts
        read -r _ _ exp gb _ <<< "$(xray_row "$p" "$n")"
        e=$exp; [[ "$e" == *T* ]] || e="${e}T23:59:59"; nowts=$(date +%Y-%m-%dT%H:%M:%S)
        gb=${gb//[!0-9]/}; gb=$(( 10#${gb:-0} ))
        if [[ ! "$e" > "$nowts" ]] || (( gb > 0 && $(xray_usage_of "$n") >= gb * XR_GIB )); then
            echo -e "${YELLOW}Note: account expiry / GB limit ki wajah se abhi bhi band hai (Renew / Reset / Limits se kholein).${NC}"
        fi
    fi
}

kick_user() {   # disconnect every live session of user $1 (pids come from rt-monitor's snapshot)
    [[ -r "$LIVE_FILE" ]] || return 0
    local u ip lbl since bytes pid
    while IFS='|' read -r u ip lbl since bytes pid; do
        [[ "$u" == "$1" && "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null
    done < "$LIVE_FILE"
    return 0
}

geo_country() { # real IP -> country name (cached in GEO_DIR; needs internet only for new IPs)
    local ip="$1" f c age
    local priv='^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)'
    local okre="^[A-Za-z][A-Za-z .,'()-]{1,50}\$"
    if [[ "$ip" =~ $priv || "$ip" == "::1" ]]; then echo "Local/Proxy"; return; fi
    f="${GEO_DIR}/${ip//:/_}"
    if [[ -s "$f" ]]; then
        c=$(<"$f")
        if [[ "$c" != "-" ]]; then echo "$c"; return; fi
        age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
        (( age < 600 )) && { echo "-"; return; }      # failed lookup: retry after 10 min
    fi
    mkdir -p "$GEO_DIR"
    c=$(curl -s -m 3 "https://ipapi.co/${ip}/country_name/" 2>/dev/null | head -c 60 | tr -d '\r\n')
    case "$c" in *rror*|*imit*|*many*|*equest*|*ndefined*) c="" ;; esac
    if [[ -n "$c" && "$c" =~ $okre ]]; then echo "$c" > "$f"; echo "$c"
    else echo "-" > "$f"; echo "-"; fi
}

# ------------------------------------------------------------------------------
# Custom banner = the "server message" every client sees while logging in.
# Dropbear has ONE banner for the whole server (not per user), and it refuses
# banner files bigger than 2000 bytes. HTML tags (<font>, <br>, <b>) work in
# HTTP Custom / injector style apps.
# ------------------------------------------------------------------------------
write_default_banner() {
    cat << 'BANNER_EOF' > "$BANNER_FILE"
<font color="green">==========================================</font><br>
<font color="yellow"><b>WELCOME TO DDK VPS MANAGER SSH</b></font><br>
<font color="green">==========================================</font><br>
BANNER_EOF
}

apply_banner() {   # Dropbear reads the banner file only at start -> restart needed
    local km a
    km=$(systemctl show dropbear -p KillMode --value 2>/dev/null)
    if [[ "$km" == "process" ]]; then
        rt_ok "Restart safe hai: connected users disconnect nahi honge."
    else
        rt_warn "! Dropbear restart par abhi connected users disconnect honge."
        rt_warn "  (Menu 6 'Fix SSH-WS / SSL stack' ek baar chala lein, uske baad restart safe hota hai.)"
    fi
    read -rp "$(rt_q "Banner abhi apply karein (dropbear restart)? [y/N]: ")" a
    if [[ "$a" =~ ^[Yy]$ ]]; then
        if systemctl restart dropbear; then rt_ok "Banner apply ho gaya."
        else rt_err "Dropbear restart fail: journalctl -u dropbear -n 20"; fi
    else
        rt_info "Banner agle dropbear restart par apply hoga."
    fi
}

banner_write_new() {
    local tmp line size
    rt_act_head "BANNER" "menu › 04 › 08 › naya banner"
    rt_info "Apna banner / server message likhein (HTML chalta hai, e.g. <font color=\"red\">text</font><br>)."
    rt_info "Khatam karne ke liye ALAG line par  END  likhein (max ${BANNER_MAX} bytes):"
    tmp=$(mktemp)
    while IFS= read -r line; do
        [[ "$line" == "END" ]] && break
        printf '%s\n' "$line" >> "$tmp"
    done
    size=$(wc -c < "$tmp")
    if (( size == 0 )); then
        rt_err "Banner khaali hai, cancel."; rm -f "$tmp"; return 1
    fi
    if (( size > BANNER_MAX )); then
        rt_err "Banner ${size} bytes ka hai; Dropbear max ${BANNER_MAX} bytes allow karta hai. Chota karein."
        rm -f "$tmp"; return 1
    fi
    cat "$tmp" > "$BANNER_FILE"; chmod 644 "$BANNER_FILE"; rm -f "$tmp"
    rt_ok "Banner saved (${size} bytes)."
    apply_banner
}

set_custom_banner() {
    local bc
    while true; do
        rt_sub_head "BANNER" "menu › 04 › 08 › SSH login par dikhne wala message"
        rt_sub_kv file "${U_W}${BANNER_FILE}${U_R}  ${U_M}$(wc -c < "$BANNER_FILE" 2>/dev/null || echo 0) / ${BANNER_MAX} bytes${U_R}"
        rt_sub_hr
        sed 's/^/  /' "$BANNER_FILE" 2>/dev/null | head -n 12
        rt_sub_hr
        rt_sub_item 1 "Naya banner likhein"
        rt_sub_item 2 "Default banner par reset" warn
        rt_sub_item 3 "‹ Back" back
        rt_sub_hr
        rt_sub_prompt 3 3; bc=$SUB_OPT
        case $bc in
            1) banner_write_new; press_any_key ;;
            2) write_default_banner; echo -e "${GREEN}Default banner set.${NC}"; apply_banner; press_any_key ;;
            3) return ;;
            *) rt_sub_bad ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Connected IPs (REAL client IP, per protocol) — terminal me ek dafa ka snapshot (live sirf web panel me)
# ------------------------------------------------------------------------------
# Live screen helpers
# live_redraw: cursor ko screen ke HOME (0,0) par le jata hai, har line ke aakhir me leftover erase karta hai
# aur sabse end me neeche ka purana content saaf karta hai.
# (Purana tareeka "N line upar jao" tha: phone jaisi narrow screen par lines wrap ho jati hain, to cursor
#  galat line par pahunchta tha aur text ke upar text chadhta tha => "DATAe update ..." wala kachra.)
live_redraw() {   # $1 = poora rendered text
    local l
    printf '\033[H'
    while IFS= read -r l; do printf '%s\033[K\n' "$l"; done <<< "$1"
    printf '\033[J'
}
# rt_line: terminal ki chaudai jitni (max 66) separator line. $1 = character (= ya -)
rt_width() {   # terminal ki asli chaudai (COLUMNS ya tput); na mile to 80
    local w=${COLUMNS:-$(tput cols 2>/dev/null)}
    [[ "$w" =~ ^[0-9]+$ ]] || w=80
    echo "$w"
}
rt_line() {
    local w; w=$(rt_width)
    if (( w > 66 )); then w=66; else w=$(( w - 1 )); fi
    (( w < 20 )) && w=20
    printf '%*s' "$w" '' | tr ' ' "$1"
}
rt_via() {   # narrow screen ke liye chhota protocol naam
    case "$1" in SSH-Direct) echo SSH;; SSH-SSL) echo SSL;; WS-SSL) echo WSS;; *) echo "${1:0:5}";; esac
}
rt_clamp() { local v=$1 lo=$2 hi=$3; (( v < lo )) && v=$lo; (( v > hi )) && v=$hi; echo "$v"; }
rt_status_short() {   # $1 = (rangeen) status text, $2 = 1 -> 3 akshar ka code
    local t c
    case "$1" in
        *EXPIRED*)             t=EXPIRED; c=$RED;;
        *GB-LIMIT*)            t=GB-LIM;  c=$RED;;
        *IP-LIMIT*|*IP-LOCK*)  t=IP-LIM;  c=$RED;;
        *LOCKED*)              t=LOCKED;  c=$RED;;
        *)                     t=OK;      c=$GREEN;;
    esac
    if [[ "$2" == 1 ]]; then case $t in EXPIRED) t=EXP;; GB-LIM) t=GB;; IP-LIM) t=IP;; LOCKED) t=LCK;; esac; fi
    printf '%b%s%b' "$c" "$t" "$NC"
}

render_connected() {
    # FIX: phone / narrow screen par har row EK hi line me (columns terminal ki chaudai ke hisaab se).
    #   W>=80 : poora table (COUNTRY ke saath) | 52..79 : COUNTRY hata | <52 : TIME bhi hata + chhota VIA
    local now mon u ip lbl since bytes pid c total=0 n W uw nm
    declare -A ucnt=() uips=() ubytes=()
    now=$(date +%s); W=$(rt_width)
    if systemctl is-active --quiet rt-monitor; then mon="${GREEN}running${NC}"
    elif (( W >= 56 )); then mon="${RED}STOPPED (Option 6 Fix chalayein)${NC}"; else mon="${RED}STOPPED${NC}"; fi
    if [[ -n "${RT_NOHEAD:-}" ]]; then
        systemctl is-active --quiet rt-monitor; rt_dot $? running "STOPPED (main menu 06 = Fix)"; rt_sub_kv monitor "$DOT"; echo
    else
    echo -e "${CYAN}$(rt_line =)${NC}"
    if (( W >= 56 )); then echo -e "${YELLOW}   CONNECTED IPs  (real client IP)${NC}   monitor: ${mon}"
    else echo -e "${YELLOW} CONNECTED IPs${NC}  mon: ${mon}"; fi
    echo -e "${CYAN}$(rt_line =)${NC}"
    fi
    if (( W >= 80 )); then
        printf " ${RT_TH:-$BOLD}%-12s %-16s %-14s %-11s %-8s %s${NC}\n" USER "REAL IP" COUNTRY VIA TIME DATA
    elif (( W >= 52 )); then
        uw=$(rt_clamp $(( W - 45 )) 6 12)
        printf " ${RT_TH:-$BOLD}%-*s %-15s %-10s %-6s %s${NC}\n" "$uw" USER "REAL IP" VIA TIME DATA
    else
        uw=$(rt_clamp $(( W - 33 )) 4 12)
        printf " ${RT_TH:-$BOLD}%-*s %-15s %-5s %s${NC}\n" "$uw" USER "REAL IP" VIA DATA
    fi
    if [[ -r "$LIVE_FILE" ]]; then
        while IFS='|' read -r u ip lbl since bytes pid; do
            [[ -z "$ip" || "$u" == \#* ]] && continue
            if (( W >= 80 )); then
                c=$(geo_country "$ip")
                printf ' %-12s %-16s %-14s %-11s %-8s %s\n' "$u" "$ip" "${c:0:14}" "$lbl" \
                    "$(fmt_dur $(( now - since )))" "$(fmt_bytes "$bytes")"
            elif (( W >= 52 )); then
                printf ' %-*.*s %-15.15s %-10.10s %-6.6s %s\n' "$uw" "$uw" "$u" "$ip" "$lbl" \
                    "$(fmt_dur $(( now - since )))" "$(fmt_bytes "$bytes")"
            else
                printf ' %-*.*s %-15.15s %-5.5s %s\n' "$uw" "$uw" "$u" "$ip" "$(rt_via "$lbl")" "$(fmt_bytes "$bytes")"
            fi
            total=$(( total + 1 ))
            ucnt[$u]=$(( ${ucnt[$u]:-0} + 1 ))
            [[ " ${uips[$u]} " == *" $ip "* ]] || uips[$u]+=" $ip"
        done < "$LIVE_FILE"
    fi
    (( total == 0 )) && echo -e " ${YELLOW}Abhi koi user connected nahi hai.${NC}"
    if [[ -n "${RT_NOHEAD:-}" ]]; then rt_sub_hr; else echo -e "${CYAN}$(rt_line -)${NC}"; fi
    for u in "${!ucnt[@]}"; do
        get_limits "$u"; get_usage "$u"
        set -- ${uips[$u]}; n=$#
        if (( W >= 80 )); then
            printf ' %-12s IPs: %s/%s   sessions: %s   data: %s / %s\n' "$u" "$n" \
                "$( (( G_IP > 0 )) && echo "$G_IP" || echo 'unlim')" "${ucnt[$u]}" \
                "$(fmt_bytes "$G_USED")" "$( (( G_GB > 0 )) && echo "${G_GB} GB" || echo 'unlim')"
        else
            nm=$(rt_clamp ${#u} 1 12)
            printf ' %-*.*s IP %s/%s  %s/%s\n' "$nm" "$nm" "$u" "$n" \
                "$( (( G_IP > 0 )) && echo "$G_IP" || echo 'unlim')" \
                "$(fmt_bytes "$G_USED")" "$( (( G_GB > 0 )) && echo "${G_GB}GB" || echo 'unlim')"
        fi
    done
}

show_connected_ips() {
    # Terminal me LIVE update nahi (sirf ek dafa ka snapshot). Live update sirf web panel me hota hai.
    clear
    if rt_tty; then
        rt_act_head "CONNECTED" "menu › 04 › 05 › live IPs (real client IP, snapshot)"
        RT_NOHEAD=1 render_connected
        rt_sub_hr
        rt_info "Ye abhi ka snapshot hai (live update sirf web panel me). Dobara dekhne ke liye option phir chunein."
    else
        render_connected
        echo -e "\n${YELLOW}Ye abhi ka snapshot hai (live update sirf web panel me). Dobara dekhne ke liye option phir chunein.${NC}"
    fi
    press_any_key
}

# ------------------------------------------------------------------------------
# User management
# ------------------------------------------------------------------------------
add_user() {
    local username password days gb ipl exp_date cur_dom exp_epoch sh_exp
    cur_dom=$(get_domain)
    rt_act_head "ADD USER" "menu › 04 › 01 › naya SSH account"
    read -rp "$(rt_q "Username: ")" username
    if ! valid_username "$username"; then
        rt_err "Username me sirf a-z, A-Z, 0-9, _ - chalega (max 31, kam se kam 1 letter)."; press_any_key; return
    fi
    if id "$username" &>/dev/null; then
        rt_err "User '${username}' pehle se maujood hai."; press_any_key; return
    fi
    read -rp "$(rt_q "Password: ")" password
    if [[ -z "$password" ]]; then rt_err "Password khaali nahi ho sakta."; press_any_key; return; fi
    read -rp "$(rt_q "Days: ")" days
    if [[ ! "$days" =~ ^[0-9]*[1-9][0-9]*$ ]]; then rt_err "Days number hona chahiye (kam se kam 1)."; press_any_key; return; fi
    read -rp "$(rt_q "GB limit (0 = unlimited): ")" gb;  gb=${gb:-0}
    read -rp "$(rt_q "IP limit (0 = unlimited): ")" ipl; ipl=${ipl:-0}
    if [[ ! "$gb" =~ ^[0-9]+$ || ! "$ipl" =~ ^[0-9]+$ ]]; then
        rt_err "GB / IP limit number hona chahiye."; press_any_key; return
    fi
    exp_epoch=$(( $(date +%s) + 10#$days * 86400 ))        # EXACT: abhi + days*24h
    exp_date=$(date -d "@$exp_epoch" '+%Y-%m-%d %H:%M')
    sh_exp=$(date -d "@$(( exp_epoch + 86400 ))" +%Y-%m-%d)  # shadow date sirf backup; asli expiry EXPIRY_DIR me hai
    # FIX: shell /bin/false (+ group rtvpn) => user sirf tunnel kar sakta hai, VPS par koi command nahi
    ensure_noshell
    local grp=(); getent group "$RT_SSH_GROUP" >/dev/null 2>&1 && grp=(-G "$RT_SSH_GROUP")
    if { useradd -M -s "$RT_NOSHELL" "${grp[@]}" -e "$sh_exp" "$username" 2>/dev/null || useradd --badname -M -s "$RT_NOSHELL" "${grp[@]}" -e "$sh_exp" "$username" 2>/dev/null; } && echo "$username:$password" | chpasswd; then
        mkdir -p "$LIM_DIR" "$USE_DIR" "$EXPIRY_DIR" "$EXLCK_DIR" "$DEAD_DIR"
        echo "$exp_epoch" > "${EXPIRY_DIR}/${username}"
        rm -f "${EXLCK_DIR}/${username}" "${DEAD_DIR}/${username}" "${DIS_DIR}/${username}"
        echo "$(( 10#$gb )) $(( 10#$ipl ))" > "${LIM_DIR}/${username}"
        echo 0 > "${USE_DIR}/${username}"
        rm -f "${LCK_DIR}/${username}"
        local L geo city region gbt ipt
        L="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        geo=$(curl -s -m 5 https://ipinfo.io/json 2>/dev/null)
        city=$(jq -r '.city // "-"' <<<"$geo" 2>/dev/null); city=${city:--}
        region=$(jq -r '.region // "-"' <<<"$geo" 2>/dev/null); region=${region:--}
        gbt=$(( 10#$gb )); [[ $gbt == 0 ]] && gbt=Unlimited || gbt="${gbt} GB"
        ipt=$(( 10#$ipl )); [[ $ipt == 0 ]] && ipt=Unlimited
        if rt_tty; then
            rt_ssh_card "$username" "$password" "$cur_dom" "$exp_date" "$gbt" "$ipt" "$city" "$region"
        else
            echo -e "${CYAN}${L}${NC}"
            echo -e "${GREEN}  🔐  SSH ACCOUNT CREATED${NC}"
            echo -e "${CYAN}${L}${NC}"
            echo -e " 👤 Username  : ${username}"
            echo -e " 🔑 Password  : ${password}"
            echo -e " 🌐 Host      : ${cur_dom}"
            echo -e " 🛡  SNI       : ${cur_dom}"
            echo -e " 📅 Expiry    : ${exp_date}"
            echo -e " 📊 Data      : ${gbt}"
            echo -e " 📱 IP Limit  : ${ipt}"
            echo -e "${CYAN}━━━━━━━━━━  PORTS  ━━━━━━━━━━${NC}"
            echo -e " 🖥  SSH Direct : 22, 109, 447"
            echo -e " 🔒 SSH SSL    : 443"
            echo -e " 🌍 SSH WS     : 80  -> ${CUSTOM_PATH}"
            echo -e " 🔐 SSH WS SSL : 443 -> ${CUSTOM_PATH}"
            echo -e "${CYAN}━━━━━━━━  LOCATION  ━━━━━━━━${NC}"
            echo -e " 🏙  City      : ${city}"
            echo -e " 🗺  Region    : ${region}"
            echo -e "${CYAN}━━━━━━━━  PAYLOAD  ━━━━━━━━━${NC}"
            echo -e "GET ${CUSTOM_PATH} HTTP/1.1[crlf]Host: ${cur_dom}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]"
            echo -e "${CYAN}${L}${NC}"
        fi
    else
        rt_err "User create nahi hua."
    fi
    press_any_key
}

delete_user() {
    local username
    rt_act_head "DELETE USER" "menu › 04 › 02 › SSH account hatao"
    read -rp "$(rt_q "Username to delete: ")" username
    if ! is_panel_user "$username"; then rt_err "User nahi mila."; press_any_key; return; fi
    kick_user "$username"
    userdel -f "$username" 2>/dev/null
    rm -f "${LIM_DIR}/${username}" "${USE_DIR}/${username}" "${LCK_DIR}/${username}" "${STATE_DIR}/iplocked/${username}" \
          "${EXPIRY_DIR}/${username}" "${EXLCK_DIR}/${username}" "${DEAD_DIR}/${username}" "${DIS_DIR}/${username}"
    rt_ok "Deleted."; press_any_key
}

renew_user() {
    local username r_days new_exp rs new_epoch
    rt_act_head "RENEW USER" "menu › 04 › 03 › expiry badhao"
    read -rp "$(rt_q "Username: ")" username
    read -rp "$(rt_q "Additional days: ")" r_days
    if is_panel_user "$username" && [[ "$r_days" =~ ^[0-9]*[1-9][0-9]*$ ]]; then
        new_epoch=$(( $(date +%s) + 10#$r_days * 86400 ))
        new_exp=$(date -d "@$new_epoch" '+%Y-%m-%d %H:%M')
        usermod -e "$(date -d "@$(( new_epoch + 86400 ))" +%Y-%m-%d)" "$username"
        mkdir -p "$EXPIRY_DIR" "$EXLCK_DIR" "$DEAD_DIR"
        echo "$new_epoch" > "${EXPIRY_DIR}/${username}"
        if [[ -e "${EXLCK_DIR}/${username}" ]]; then
            rm -f "${EXLCK_DIR}/${username}"
            [[ -e "${LCK_DIR}/${username}" || -e "${STATE_DIR}/iplocked/${username}" || -e "${DIS_DIR}/${username}" ]] || usermod -U "$username" 2>/dev/null
        fi
        [[ -e "${LCK_DIR}/${username}" || -e "${STATE_DIR}/iplocked/${username}" ]] || rm -f "${DEAD_DIR}/${username}"
        rt_ok "Renewed to ${new_exp}"
        read -rp "$(rt_q "Data usage bhi reset karein (0 GB se shuru)? [y/N]: ")" rs
        if [[ "$rs" =~ ^[Yy]$ ]]; then
            echo 0 > "${USE_DIR}/${username}"
            if [[ -e "${LCK_DIR}/${username}" ]]; then [[ -e "${DIS_DIR}/${username}" ]] || usermod -U "$username"; rm -f "${LCK_DIR}/${username}"; fi
            rt_ok "Usage reset."
        fi
    else
        rt_err "User not found / days galat."
    fi
    press_any_key
}

dead_note() {   # $1=user -> " (auto-delete 42m)" : expired/locked account kitni der me list se hat jayega
    local ds="" e="" now rem
    now=$(date +%s)
    [[ -r "${DEAD_DIR}/$1" ]] && read -r ds < "${DEAD_DIR}/$1"
    ds=${ds//[!0-9]/}
    if [[ -r "${EXPIRY_DIR}/$1" ]]; then
        read -r e < "${EXPIRY_DIR}/$1"; e=${e//[!0-9]/}
        if [[ -n "$e" ]] && (( e <= now )); then
            if [[ -z "$ds" ]] || (( e < ds )); then ds=$e; fi
        fi
    fi
    [[ -z "$ds" ]] && return 0
    rem=$(( ds + DEAD_GRACE_SECS - now )); (( rem < 0 )) && rem=0
    printf ' (auto-delete %s)' "$(fmt_dur "$rem")"
}

list_users() {
    local now u uid sh pw exp ex_txt status lim iplim used n ex_ep
    local lu lip llbl lsince lbytes lpid W uw
    declare -A ses=() ipn=()
    now=$(date +%s); W=$(rt_width)
    if [[ -r "$LIVE_FILE" ]]; then
        while IFS='|' read -r lu lip llbl lsince lbytes lpid; do
            [[ -z "$lip" || "$lu" == \#* ]] && continue
            ses[$lu]=$(( ${ses[$lu]:-0} + 1 ))
            [[ " ${ipn[$lu]} " == *" $lip "* ]] || ipn[$lu]+=" $lip"
        done < "$LIVE_FILE"
    fi
    rt_tty || echo -e "${CYAN}--- Users ---${NC}"
    # FIX: narrow screen par har user EK line me. W>=80 poora | 52..79 chhota date + status code | <52 aur chhota (CONN hata)
    if (( W >= 80 )); then
        printf " ${RT_TH:-$BOLD}%-12s %-17s %-19s %-7s %-6s %s${NC}\n" USER EXPIRY "USED / GB-LIMIT" "IPs" "CONN" STATUS
    elif (( W >= 52 )); then
        uw=$(rt_clamp $(( W - 49 )) 6 12)
        printf " ${RT_TH:-$BOLD}%-*s %-11s %-14s %-7s %-4s %s${NC}\n" "$uw" USER EXPIRY "USED/LIMIT" "IPs" CONN STATUS
    else
        uw=$(rt_clamp $(( W - 34 )) 4 12)
        printf " ${RT_TH:-$BOLD}%-*s %-5s %-14s %-7s %s${NC}\n" "$uw" USER EXP "USED/LIMIT" "IPs" ST
    fi
    while IFS=: read -r u _ uid _; do
        (( uid >= 1000 && uid < 60000 )) || continue
        sh=$(getent shadow "$u" 2>/dev/null)
        IFS=: read -r _ pw _ _ _ _ _ exp _ <<< "$sh"
        status="${GREEN}OK${NC}"; ex_txt="never"
        ex_ep=""
        [[ -r "${EXPIRY_DIR}/${u}" ]] && read -r ex_ep < "${EXPIRY_DIR}/${u}"
        ex_ep=${ex_ep//[!0-9]/}
        [[ -z "$ex_ep" && "$exp" =~ ^[0-9]+$ ]] && ex_ep=$(( exp * 86400 + 86399 ))   # purana account (monitor migrate karega)
        if [[ -n "$ex_ep" ]]; then
            ex_txt=$(date -d "@$ex_ep" '+%Y-%m-%d %H:%M')
            (( ex_ep <= now )) && status="${RED}EXPIRED${NC}"
        fi
        if [[ "$pw" == \!* ]]; then
            if [[ -e "${DIS_DIR}/${u}" ]]; then status="${RED}LOCKED (manual)${NC}"
            elif [[ -e "${LCK_DIR}/${u}" ]]; then status="${RED}GB-LIMIT (locked)${NC}"
            elif [[ -e "${STATE_DIR}/iplocked/${u}" ]]; then status="${RED}IP-LIMIT (locked)${NC}"
            elif [[ -e "${EXLCK_DIR}/${u}" ]]; then status="${RED}EXPIRED${NC}"
            else status="${RED}LOCKED${NC}"; fi
        fi
        [[ "$status" == *"${RED}"* ]] && status+="$(dead_note "$u")"
        get_limits "$u"; get_usage "$u"
        set -- ${ipn[$u]}; n=$#
        lim="unlim"; (( G_GB > 0 )) && lim="${G_GB} GB"
        iplim="unlim"; (( G_IP > 0 )) && iplim="$G_IP"
        if (( W >= 80 )); then
            printf ' %-12s %-17s %-19s %-7s %-6s %b\n' "$u" "$ex_txt" "$(fmt_bytes "$G_USED") / ${lim}" \
                "${n}/${iplim}" "${ses[$u]:-0}" "$status"
        elif (( W >= 52 )); then
            [[ "$ex_txt" == never ]] || ex_txt=${ex_txt:5}
            printf ' %-*.*s %-11.11s %-14.14s %-7.7s %-4.4s %b\n' "$uw" "$uw" "$u" "$ex_txt" "$(fmt_bytes "$G_USED")/${lim// /}" \
                "${n}/${iplim}" "${ses[$u]:-0}" "$(rt_status_short "$status")"
        else
            [[ "$ex_txt" == never ]] || ex_txt=${ex_txt:5:5}
            printf ' %-*.*s %-5.5s %-14.14s %-7.7s %b\n' "$uw" "$uw" "$u" "$ex_txt" "$(fmt_bytes "$G_USED")/${lim// /}" \
                "${n}/${iplim}" "$(rt_status_short "$status" 1)"
        fi
    done < /etc/passwd
}

edit_limits() {
    local u ngb nip
    rt_act_head "EDIT LIMITS" "menu › 04 › 06 › GB / IP limit"
    read -rp "$(rt_q "Username: ")" u
    if ! is_panel_user "$u"; then rt_err "User nahi mila."; press_any_key; return; fi
    get_limits "$u"; get_usage "$u"
    echo -e "${CYAN}Abhi: GB limit=${G_GB} (0=unlimited) | IP limit=${G_IP} (0=unlimited) | used=$(fmt_bytes "$G_USED")${NC}"
    read -rp "$(rt_q "Naya GB limit [Enter = same]: ")" ngb;  ngb=${ngb:-$G_GB}
    read -rp "$(rt_q "Naya IP limit [Enter = same]: ")" nip;  nip=${nip:-$G_IP}
    if [[ ! "$ngb" =~ ^[0-9]+$ || ! "$nip" =~ ^[0-9]+$ ]]; then
        rt_err "Number hona chahiye."; press_any_key; return
    fi
    mkdir -p "$LIM_DIR"
    echo "$(( 10#$ngb )) $(( 10#$nip ))" > "${LIM_DIR}/${u}"
    rt_ok "Saved: GB=$(( 10#$ngb )) IP=$(( 10#$nip )). Monitor ${MONITOR_INTERVAL}s ke andar apply kar dega."
    press_any_key
}

reset_usage() {
    local u
    rt_act_head "RESET USAGE" "menu › 04 › 07 › data usage 0 karo"
    read -rp "$(rt_q "Username (data usage 0 karne ke liye): ")" u
    if ! is_panel_user "$u"; then rt_err "User nahi mila."; press_any_key; return; fi
    echo 0 > "${USE_DIR}/${u}"
    if [[ -e "${LCK_DIR}/${u}" ]]; then [[ -e "${DIS_DIR}/${u}" ]] || usermod -U "$u"; rm -f "${LCK_DIR}/${u}"; fi
    rt_ok "Usage reset (agar GB-limit se lock tha to unlock bhi ho gaya)."
    press_any_key
}

user_menu() {
    local uc
    while true; do
        rt_sub_head "USERS" "menu › 04 › SSH accounts, limits, banner"
        rt_acct_counts
        rt_sub_kv accounts "${U_M}SSH${U_R} ${U_W}${RC_SSH}${U_R}   ${U_M}VMess${U_R} ${U_W}${RC_VM}${U_R}   ${U_M}VLESS${U_R} ${U_W}${RC_VL}${U_R}   ${U_M}Trojan${U_R} ${U_W}${RC_TR}${U_R}"
        systemctl is-active --quiet rt-monitor; rt_dot $? "on" "band"
        rt_sub_kv limits "${DOT}  ${U_M}GB / IP check har ${MONITOR_INTERVAL}s${U_R}   ${U_M}online${U_R} ${U_T}${RC_ON}${U_R}"
        rt_sub_hr
        rt_sub_sec "ACCOUNTS"
        rt_sub_item 1 "Add User (GB / IP limit)"
        rt_sub_item 2 "Delete User" danger
        rt_sub_item 3 "Renew User"
        rt_sub_item 4 "List Users (usage / limits / status)"
        rt_sub_sec "LIMITS & LIVE"
        rt_sub_item 5 "Connected IPs (live, real IP)"
        rt_sub_item 6 "Edit Limits (GB / IP)"
        rt_sub_item 7 "Reset Data Usage"
        rt_sub_sec "MORE"
        rt_sub_item 8 "Custom Banner (server message)"
        rt_sub_item 9 "Xray Management (VMess / VLESS / Trojan)"
        rt_sub_item 10 "‹ Back" back
        rt_sub_hr
        rt_sub_prompt 10 10; uc=$SUB_OPT
        case $uc in
            1) clear; add_user ;;
            2) delete_user ;;
            3) renew_user ;;
            4) clear; rt_act_head "USERS" "menu › 04 › 04 › SSH accounts (usage / limits / status)"; list_users; rt_tty && rt_sub_hr; press_any_key ;;
            5) show_connected_ips ;;
            6) edit_limits ;;
            7) reset_usage ;;
            8) set_custom_banner ;;
            9) xray_account_menu ;;
            10) return ;;
            *) rt_sub_bad ;;
        esac
    done
}

status_check() {   # Menu 5. Terminal: Deploy Suite screen; bot / web panel: purana saada report
    if rt_tty; then rt_status_screen; press_any_key; return 0; fi
    clear
    local current_dom; current_dom=$(get_domain)
    local svcs=(haproxy nginx dropbear ws-proxy rt-monitor rt-qos xray xray-monitor rt-web)
    echo -e "${CYAN}==============================================${NC}"
    echo -e "${YELLOW}   SYSTEM & PROTOCOL STATUS${NC}"
    echo -e "${CYAN}==============================================${NC}"
    echo -e " Domain      : ${BOLD}${current_dom}${NC}"
    echo -e " Path        : ${BOLD}${CUSTOM_PATH}${NC}"
    echo -e " SSH-SSL SNI : ${BOLD}${current_dom}${NC} (same as domain)\n"
    for s in "${svcs[@]}"; do
        st=$(systemctl is-active "$s" 2>/dev/null)
        [[ "$st" == "active" ]] && badge="${GREEN}[ ACTIVE ]${NC}" || badge="${RED}[ INACTIVE ]${NC}"
        printf "   %-14s : %b\n" "$s" "$badge"
    done
    echo -e "\n${CYAN} PORT MAP${NC}"
    echo "   SSH Direct       : 22, 109, 447, 80, 443 (auto)"
    echo "   SSH-SSL          : 443 (SNI=${current_dom})"
    echo "   SSH-WS           : 80  -> ${CUSTOM_PATH}"
    echo "   SSH-WS-SSL       : 443 -> ${CUSTOM_PATH}"
    echo "   VMess (WS)       : 80 / 443(TLS) -> /vmess"
    echo "   VLESS (WS)       : 80 / 443(TLS) -> /vless"
    echo "   Trojan (WS)      : 80 / 443(TLS) -> /trojan"
    echo -e "\n${CYAN} LIMITS${NC}"
    echo "   GB + IP limit    : har protocol par, rt-monitor har ${MONITOR_INTERVAL}s check karta hai"
    echo -e "${YELLOW}   [Reserved] V2Ray on UDP/QUIC 8443, DNSTT — not active yet${NC}"
    press_any_key
}

rt_status_screen() {   # Status & Ports - Deploy Suite style
    local dom s rc cell up=0 inst=0 k=0 line="" cw=27
    local svcs=(haproxy nginx dropbear ws-proxy rt-monitor rt-qos xray xray-monitor rt-web)
    local -a cells=()
    rt_sub_head "STATUS" "menu › 05 › services, ports, limits"
    dom=$(get_domain); cert_info
    for s in "${svcs[@]}"; do
        rt_svc_on "$s"; rc=$?
        case $rc in
            0) up=$(( up + 1 )); inst=$(( inst + 1 ))
               printf -v cell '%s●%s %s%-13s%s %s%-8s%s' "$U_G" "$U_R" "$U_W" "$s" "$U_R" "$U_G" running "$U_R" ;;
            1) inst=$(( inst + 1 ))
               printf -v cell '%s●%s %s%-13s%s %s%-8s%s' "$U_E" "$U_R" "$U_W" "$s" "$U_R" "$U_E" stopped "$U_R" ;;
            *) printf -v cell '%s○ %-13s %-8s%s' "$U_M" "$s" "n/a" "$U_R" ;;
        esac
        cells+=("$cell")
    done
    if [[ "$dom" == "No Domain Set" ]]; then rt_card_kv domain "domain set nahi → main menu 02" "$U_O"
    else rt_card_kv domain "$dom"; fi
    case "$CI_KIND" in
        letsencrypt) if (( ${CI_DAYS:-0} < 15 )); then rt_card_kv ssl "! Let's Encrypt · expiry ${CI_END} (${CI_DAYS} din)" "$U_Y"
                     else rt_card_kv ssl "✓ Let's Encrypt · expiry ${CI_END} (${CI_DAYS} din)" "$U_G"; fi ;;
        self) rt_card_kv ssl "! self-signed (main menu 03 se asli cert)" "$U_Y" ;;
        *)    rt_card_kv ssl "✗ koi cert nahi" "$U_E" ;;
    esac
    if (( up == inst && inst > 0 )); then rt_card_kv services "✓ ${up}/${inst} running" "$U_G"
    else rt_card_kv services "! ${up}/${inst} running (main menu 06 = Fix stack)" "$U_Y"; fi
    rt_sub_hr
    rt_sub_sec "SERVICES"
    for cell in "${cells[@]}"; do
        if (( SUB_W >= 60 )); then
            if (( k % 2 == 0 )); then line="  $cell"; else printf '%s   %s\n' "$line" "$cell"; line=""; fi
        else printf '  %s\n' "$cell"; fi
        k=$(( k + 1 ))
    done
    [[ -n "$line" ]] && printf '%s\n' "$line"
    echo
    rt_sub_sec "PORT MAP"
    rt_card_kv "ssh direct" "22 · 109 · 447 · 80 · 443  (banner auto-detect)"
    rt_card_kv "ssh ssl"    "443 · SNI / Host = ${dom}"
    rt_card_kv "ssh ws"     "80  → ${CUSTOM_PATH}"
    rt_card_kv "ssh ws ssl" "443 → ${CUSTOM_PATH}  (TLS)"
    rt_card_kv "vmess"      "80 / 443 → /vmess   ${U_M}tcp ${XRAY_MTCP_PORT:-8447} · xhttp 80/443"
    rt_card_kv "vless"      "80 / 443 → /vless   ${U_M}tcp ${XRAY_VTCP_PORT:-8442} · xhttp 80/443"
    rt_card_kv "trojan"     "80 / 443 → /trojan  ${U_M}tcp ${XRAY_TTCP_PORT:-8446} · xhttp 80/443"
    web_installed && rt_card_kv "web panel" "$(web_url)" "$U_T"
    echo
    rt_sub_sec "LIMITS"
    systemctl is-active --quiet rt-monitor; rt_dot $? "on" "band"
    rt_card_kv monitor "${DOT}  ${U_M}GB + IP limit har protocol par · check har ${MONITOR_INTERVAL}s"
    rt_card_kv reserved "V2Ray UDP/QUIC 8443, DNSTT - abhi active nahi" "$U_M"
    rt_sub_hr
}

# Fix stack (Menu 6 / bot / web panel) - install jaisa hi Deploy Suite dashboard, apne steps ke saath
_fx_dropbear() { fix_dropbear_core; return 0; }
_fx_wsproxy()  { install_wsproxy_service; [[ -x /usr/local/bin/ws-proxy ]]; }
_fx_nginx()    { apply_nginx_config; return 0; }
_fx_haproxy()  { install_haproxy; return 0; }
_fx_monitor()  { install_monitor_service; return 0; }
_fx_xray()     { install_xray; }
_fx_harden()   { harden_ssh_users; return 0; }
_fx_verify()   { local rc; rt_verify_stack; rc=$?; ensure_menu_cmd >/dev/null 2>&1; return $rc; }
rt_fix_steps() {
    RT_PH=(Core Tunnel Xray Secure)
    RT_ST_T=("Dropbear SSH core" "Rust ws-proxy (real-IP relay)" "Nginx internal router" "HAProxy 80/443 multiplexer"
             "GB / IP limit monitor" "Xray VMess/VLESS/Trojan" "SSH users: tunnel-only shell" "Final health check")
    RT_ST_F=(_fx_dropbear _fx_wsproxy _fx_nginx _fx_haproxy _fx_monitor _fx_xray _fx_harden _fx_verify)
    RT_ST_P=(0 1 1 1 1 2 3 3)
    RT_ST_E=(25 200 5 8 5 60 3 15)
}
rt_fix_summary() {
    local i n=${#RT_ST_T[@]} w=${#RT_WARN[@]}
    echo
    if (( w )); then
        printf '  %s READY %s  %s%d/%d steps OK%s  %s! %d warning%s\n\n' "$U_TB" "$U_R" "$U_W" $(( n - w )) "$n" "$U_R" "$U_Y" "$w" "$U_R"
    else
        printf '  %s READY %s  %s✓ %d/%d steps OK%s\n\n' "$U_TB" "$U_R" "$U_G" "$n" "$n" "$U_R"
    fi
    rt_card_kv identity "$SSH_IDENT"
    rt_card_kv domain "$(get_domain)"
    rt_card_kv "ssh ws"  "80 / 443 → ${CUSTOM_PATH}"
    if (( w )); then
        echo
        for i in "${RT_WARN[@]}"; do
            printf '  %s!%s %s%02d%s  %s%s%s\n' "$U_Y" "$U_R" "$U_M" $(( i + 1 )) "$U_R" "$U_W" "${RT_ST_T[i]}" "$U_R"
            tail -c +$(( ${UI_B0[i]:-0} + 1 )) "$RT_INSTALL_LOG" 2>/dev/null | head -c $(( ${UI_B1[i]:-0} - ${UI_B0[i]:-0} )) \
                | tr '\r' '\n' | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/^[[:space:]]+//' | grep -v '^$' | tail -n 2 \
                | while IFS= read -r l; do printf '       %s└ %s%s\n' "$U_M" "${l:0:$(( UI_W - 8 ))}" "$U_R"; done
        done
    fi
    echo
    printf '  %s%s%s\n' "$U_L" "$UI_LINE" "$U_R"
    rt_card_kv log "$RT_INSTALL_LOG" "$U_M"
}
fix_websocket() {   # Terminal: Deploy Suite dashboard. Bot / web panel / pipe: saada text (+ web markers)
    local i RT_UI=0 RT_INSTALL_LOG="/var/log/ddkvps/fix.log"
    local RT_UI_BADGE="FIX STACK" RT_UI_SUB="SSH-WS / SSH-SSL / Xray stack rebuild + limit monitor"
    local RT_UI_LAB="REPAIRING" RT_UI_DONE="REPAIRED" RT_UI_WHAT="fix"
    rt_fix_steps; RT_WARN=(); UI_S=(); UI_A=(); UI_Z=(); UI_B0=(); UI_B1=()
    [[ -t 1 && -z "${RT_PLAIN:-}" && "${TERM:-dumb}" != dumb ]] && RT_UI=1
    if (( ! RT_UI )); then
        clear
        echo -e "${CYAN}Rebuilding SSH-WS / SSH-WS-SSL / SSH-SSL stack + limit monitor...${NC}"
        rt_web_plan "$RT_UI_BADGE" "$RT_UI_SUB" "$RT_UI_LAB" "$RT_UI_DONE"
        for i in "${!RT_ST_T[@]}"; do rt_run_step "$i"; done
        rt_web_mark "done:${#RT_WARN[@]}"
        (( ${#RT_WARN[@]} )) && echo -e "${YELLOW}   ! ${#RT_WARN[@]} step(s) me warning (upar dekhein).${NC}"
        echo -e "${GREEN}[DONE] identity: ${SSH_IDENT}${NC}"
        press_any_key
        return 0
    fi
    rt_ui_colors; rt_ui_node
    mkdir -p "$(dirname "$RT_INSTALL_LOG")"
    ( umask 077; : > "$RT_INSTALL_LOG" ); chmod 600 "$RT_INSTALL_LOG"
    printf 'DDK VPS Manager Deploy Suite v%s - fix stack log (%s)\n' "$RT_SUITE_VER" "$(date '+%F %T')" >> "$RT_INSTALL_LOG"
    rt_ui_start
    for i in "${!RT_ST_T[@]}"; do rt_run_step "$i"; done
    rt_ui_stop
    trap - INT TERM
    rt_ui_host; rt_ui_size; rt_ui_stats; rt_ui_lastlog
    rt_ui_frame 0
    rt_fix_summary
    rm -rf "$UI_DIR"
    if [[ -t 0 ]]; then
        printf '\n  %sEnter%s %sdabayein - menu khulega%s ' "$U_T" "$U_R" "$U_M" "$U_R"; read -r _
    fi
    return 0
}

uninstall_panel() {
    clear
    rt_act_head "UNINSTALL" "menu › 11 › panel hatao"
    rt_err "${BOLD}This removes ws-proxy, rt-monitor, haproxy config + certs, nginx vpn conf, users."
    read -rp "$(rt_q "Confirm 'YES': ")" confirm
    [[ "$confirm" != "YES" ]] && { rt_info "Cancelled."; press_any_key; return; }

    systemctl stop ws-proxy rt-monitor haproxy dropbear xray-monitor xray rt-qos 2>/dev/null
    systemctl disable xray-monitor xray rt-qos 2>/dev/null
    rm -f "$QOS_BIN" /etc/systemd/system/rt-qos.service "$QOS_CONF" "$QOS_CAP_FILE"
    tc qdisc del dev ifb0 root 2>/dev/null; ip link del ifb0 2>/dev/null
    rm -f /etc/systemd/system/xray-monitor.service /usr/local/bin/xray-monitor "$XRAY_LIB"
    systemctl disable ws-proxy rt-monitor haproxy 2>/dev/null
    rm -f /etc/systemd/system/ws-proxy.service /etc/systemd/system/rt-monitor.service
    rm -f /etc/haproxy/haproxy.cfg /etc/nginx/conf.d/vpn.conf
    rm -rf /etc/haproxy/certs /etc/letsencrypt/renewal-hooks/deploy/haproxy-pem.sh
    systemctl disable --now rt-web 2>/dev/null; rm -f "$WEB_UNIT"
    rm -f /etc/letsencrypt/renewal-hooks/deploy/rt-cert-sync.sh /etc/letsencrypt/renewal-hooks/deploy/rt-xray-cert.sh \
          /etc/letsencrypt/renewal-hooks/pre/rt-port80.sh /etc/letsencrypt/renewal-hooks/post/rt-port80.sh \
          "$CERT_SYNC_BIN" "$ACME_PORT_BIN"
    rm -f /usr/local/bin/ws-proxy "$MONITOR_BIN"
    rm -rf /etc/ddkvps "$RUN_DIR"
    systemctl daemon-reload
    systemctl restart nginx 2>/dev/null
    rt_ok "Uninstalled. (Limit/usage data ${STATE_DIR} me rehne diya gaya hai.)"
    sleep 1
    exit 0
}

if [ -f /usr/local/lib/rt-extras.sh ]; then . /usr/local/lib/rt-extras.sh; fi
if ! declare -F ex_stats_menu >/dev/null; then
ex_stats_menu() {
    local s ip
    if rt_tty; then
        rt_sub_head "VPS STATS" "menu › 08 › uptime, load, CPU / RAM / disk, speedtest"
        rt_ui_stats; sleep 0.5; rt_ui_stats
        ip=$(curl -s -m 5 ifconfig.me)
        rt_card_kv uptime "$(uptime -p)"
        rt_card_kv load "$(cut -d' ' -f1-3 /proc/loadavg)   ${U_M}$(nproc 2>/dev/null || echo 1) vCPU"
        rt_ui_mini "${UI_CPU_P:-0}"; rt_card_kv cpu  "${REP}  ${U_W}${UI_CPU_P:-0}%"
        rt_ui_mini "${UI_RAM_P:-0}"; rt_card_kv ram  "${REP}  ${U_W}${UI_RAM_P:-0}%  ${U_M}$(free -h | awk '/Mem:/{print $3" / "$2}')"
        rt_ui_mini "${UI_DSK_P:-0}"; rt_card_kv disk "${REP}  ${U_W}${UI_DSK_P:-0}%  ${U_M}$(df -h / | awk 'NR==2{print $3" / "$2}')"
        rt_card_kv ip "${ip:-?}"
        rt_sub_hr
        read -rp "$(rt_q "Speedtest chalayein? [y/N]: ")" s
        if [[ "$s" =~ ^[Yy]$ ]]; then
            if ! command -v speedtest-cli >/dev/null; then rt_info "speedtest-cli install ho raha hai..."; apt install -y speedtest-cli >/dev/null 2>&1; fi
            rt_info "speedtest chal raha hai (30-60 second)..."
            echo
            rt_sub_sec "SPEEDTEST"
            speedtest-cli --simple 2>&1 | while IFS=: read -r k v; do
                [[ -n "$v" ]] && rt_card_kv "${k,,}" "${v# }" "$U_T" || printf '  %s%s%s\n' "$U_M" "$k" "$U_R"
            done
            rt_sub_hr
        fi
        press_any_key
        return 0
    fi
    clear
    echo -e "${CYAN}=========== VPS STATS ===========${NC}"
    echo -e " Uptime : $(uptime -p)"
    echo -e " Load   : $(cut -d' ' -f1-3 /proc/loadavg)"
    echo -e " RAM    : $(free -h | awk '/Mem:/{print $3" / "$2}')"
    echo -e " Disk   : $(df -h / | awk 'NR==2{print $3" / "$2" ("$5")"}')"
    echo -e " IP     : $(curl -s -m 5 ifconfig.me)"
    echo
    read -rp "$(rt_q "Speedtest chalayein? [y/N]: ")" s
    if [[ "$s" =~ ^[Yy]$ ]]; then
        if ! command -v speedtest-cli >/dev/null; then apt install -y speedtest-cli >/dev/null 2>&1; fi
        speedtest-cli --simple
    fi
    press_any_key
}
fi
# ------------------------------------------------------------------------------
# Telegram bot script (/usr/local/bin/rt-bot) — written from here so a fresh
# install / update never needs a separate file.
# ------------------------------------------------------------------------------
install_telegram_bot() {
    command -v jq >/dev/null 2>&1   || apt install -y jq >/dev/null 2>&1
    command -v curl >/dev/null 2>&1 || apt install -y curl >/dev/null 2>&1
    [[ -f /usr/local/bin/rt-bot ]] && cp -f /usr/local/bin/rt-bot /usr/local/bin/rt-bot.bak
    cat > /usr/local/bin/rt-bot << 'RTBOT_EOF'
#!/bin/bash
. /etc/ddkvps/bot.conf
export TERM=xterm
export COLUMNS=40   # phone par Telegram <pre> ~40 char: Connected IPs ek line me
. "$MENU_LIB" --lib >/dev/null 2>&1
press_any_key(){ :; }   # bot me ENTER wait/line nahi chahiye
API="https://api.telegram.org/bot${TOKEN}"
RTST=/run/rt-bot.st.0
RTMID=/run/rt-bot.mid.0
ADMF=/etc/ddkvps/bot.admins   # extra admins: ID|label|date  (sirf Super Admin badal sakta hai)
CUR=""

# ---- roles: ADMIN (bot.conf) = SUPER ADMIN (admin management + uninstall sirf isi ke paas) ----
setu(){ CUR="$1"; RTST="/run/rt-bot.st.$1"; RTMID="/run/rt-bot.mid.$1"; }
is_super(){ [[ -n "$ADMIN" && "$CUR" == "$ADMIN" ]]; }
bot_admin_has(){ [[ -f "$ADMF" ]] && grep -q "^$1|" "$ADMF"; }
is_admin(){ is_super || bot_admin_has "$CUR"; }
bot_admin_add(){ mkdir -p /etc/ddkvps; touch "$ADMF"; chmod 600 "$ADMF"; printf '%s|%s|%s\n' "$1" "$2" "$(date +%F)" >> "$ADMF"; }
bot_admin_del(){ local t; [[ -f "$ADMF" ]] || return 0; t=$(mktemp); grep -v "^$1|" "$ADMF" > "$t"; cat "$t" > "$ADMF"; rm -f "$t"; }

strip(){ sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\r//g'; }
esc(){ sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g'; }
h(){ printf '%s' "$1" | esc; }
kb(){ printf '%s\n' "$@" | jq -cRn '[inputs] | reduce .[] as $x ({rows:[],cur:[]};
  ($x|startswith("*")) as $f
  | ($x|ltrimstr("*")|split("|")|{text:.[0],callback_data:.[1]}) as $b
  | if $f then (if (.cur|length)>0 then .rows+=[.cur] else . end | .rows+=[[$b]] | .cur=[])
    else (.cur+=[$b] | if (.cur|length)==2 then (.rows+=[.cur] | .cur=[]) else . end) end)
  | (if (.cur|length)>0 then .rows+[.cur] else .rows end) | {inline_keyboard:.}'; }

panel(){ local t="$1" k="$2" r id
  id=$(cat "$RTMID" 2>/dev/null)
  if [[ -n "$id" ]]; then
    r=$(curl -s -m 20 "$API/editMessageText" --data-urlencode "chat_id=$CUR" --data-urlencode "message_id=$id" --data-urlencode "text=$t" --data-urlencode "parse_mode=HTML" --data-urlencode "reply_markup=$k")
    jq -e '.ok' <<<"$r" >/dev/null 2>&1 && return 0
    grep -q 'not modified' <<<"$r" && return 0
  fi
  r=$(curl -s -m 20 "$API/sendMessage" --data-urlencode "chat_id=$CUR" --data-urlencode "text=$t" --data-urlencode "parse_mode=HTML" --data-urlencode "reply_markup=$k")
  jq -r '.result.message_id // empty' <<<"$r" > "$RTMID"
}
delmsg(){ curl -s -m 10 "$API/deleteMessage" -d "chat_id=$CUR" -d "message_id=$1" >/dev/null; }
res(){ local t; t=$(strip | grep -vF 'Press [ENTER] to continue' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}' | tail -c 3300 | iconv -c -f UTF-8 -t UTF-8 | esc); panel "<pre>${t:-(khaali)}</pre>" "$(kb "*⬅ Back|$1" "*🏠 Main Menu|m:main")"; }
busy(){ panel "⏳ <b>$1</b>..." "$(kb "*🏠 Main Menu|m:main")"; }

# ---------------- menus ----------------
deny(){ panel "⛔ Ye option sirf <b>Super Admin</b> ke liye hai." "$(kb "*🏠 Main Menu|m:main")"; }
main_menu(){ local role="👤 Admin"; local -a b=("👤 SSH Users|m:ssh" "⚡ Xray|m:xray" "📊 Status & Ports|i:stat" "🌐 Domain|a:dom" "🖼 Banner|a:ban" "🚦 Ping QoS|m:qos" "🔌 Connected IPs|i:connm" "🛠 System|m:sys")
  if is_super; then role="👑 Super Admin"; b+=("*👮 Admin Management|m:adm"); fi
  panel "<b>DDK VPS Manager</b>"$'\n'"$role" "$(kb "${b[@]}")"; }
adm_menu(){ local t id lb dt n=0; local -a b=()
  t="<b>👮 Admin Management</b>"$'\n\n'"👑 Super Admin: <code>$(h "$ADMIN")</code> (aap)"$'\n\n'
  if [[ -s "$ADMF" ]]; then
    t+="Admins:"$'\n'
    while IFS='|' read -r id lb dt; do [[ "$id" =~ ^[0-9]+$ ]] || continue; n=$((n+1))
      t+="${n}. $(h "$lb") — <code>$id</code> · $dt"$'\n'; b+=("*🗑 Remove: $lb ($id)|d:adm:$id")
    done < "$ADMF"
  fi
  (( n )) || t+="Koi extra admin nahi hai."$'\n'
  t+=$'\n'"ℹ Naya admin pehle bot ko /start bheje, phir yaha add karein. Admin ko Admin Management aur Uninstall nahi milta."
  panel "$t" "$(kb "*➕ Add Admin|a:adm_add" "${b[@]}" "*⬅ Back|m:main")"; }
ssh_menu(){ panel "<b>👤 SSH Users</b>" "$(kb "➕ Create User|a:add" "🗑 Delete User|a:del" "🔁 Renew User|a:renew" "📋 List Users|i:list" "🔌 Connected IPs|i:conn" "✏️ Edit Limits|a:lim" "♻️ Reset Usage|a:reset" "🖼 Custom Banner|a:ban" "*⬅ Back|m:main")"; }
xray_menu(){ panel "<b>⚡ Xray</b>" "$(kb "VMess|m:vmess" "VLESS|m:vless" "Trojan|m:trojan" "*⬅ Back|m:main")"; }
xproto_menu(){ local p=$1; panel "<b>⚡ ${p^^} Users</b>" "$(kb "➕ Create|a:x_create:$p" "🗑 Delete|a:x_del:$p" "🔁 Renew|a:x_renew:$p" "📋 List|xi:list:$p" "🔌 Connected IPs|xi:conn:$p" "✏️ Edit Limits|a:x_lim:$p" "♻️ Reset Usage|a:x_reset:$p" "🔗 Show Links|a:x_links:$p" "*⬅ Back|m:xray")"; }
qos_menu(){ panel "<b>🚦 Ping QoS</b>" "$(kb "📈 Status|i:qs" "⚙ Set iface / bandwidth|a:qos" "🎯 Per-user cap|a:cap" "🚫 Disable QoS|i:qoff" "*⬅ Back|m:main")"; }
sys_menu(){ local -a b=("🔧 Fix SSH-WS/SSL stack|s:fix" "🔄 Restart services|s:restart" "🔒 Issue SSL|s:ssl" "📦 Install All|s:install")
  is_super && b+=("🗑 Uninstall|a:uninst")   # Uninstall sirf Super Admin ko dikhta hai
  panel "<b>🛠 System</b>" "$(kb "${b[@]}" "*⬅ Back|m:main")"; }

# ---------------- wizard ----------------
save_state(){ { printf 'S_ACT=%q\nS_P=%q\n' "$S_ACT" "$S_P"; declare -p S_A | sed 's/^declare -a/declare -ga/'; } > "$RTST"; }
load_state(){ S_ACT=""; S_P=""; S_A=(); [[ -f "$RTST" ]] && . "$RTST"; }

wz_spec(){ local a="$1" p="$S_P" pp="${S_P^^}"; BK="m:ssh"
 case "$a" in
  add)   TITLE="➕ Create SSH User"; PR=("Username" "Password" "Days" "GB limit" "IP limit"); KD=(nu pw n n0 n0);;
  del)   TITLE="🗑 Delete SSH User"; PR=("Username"); KD=(u);;
  renew) TITLE="🔁 Renew SSH User"; PR=("Username" "Additional days" "Data usage bhi reset karein?"); KD=(u n y);;
  lim)   TITLE="✏️ Edit SSH Limits"; PR=("Username" "New GB limit" "New IP limit"); KD=(u s s);;
  reset) TITLE="♻️ Reset SSH Usage"; PR=("Username"); KD=(u);;
  ban)   TITLE="🖼 Custom Banner"; PR=("Banner text (HTML chalta hai)"); KD=(ban);;
  dom)   BK="m:main"; TITLE="🌐 Domain"; PR=("Naya domain"); KD=(dom);;
  qos)   BK="m:qos"; TITLE="⚙ QoS Setup"; PR=("Interface" "Bandwidth Mbit/s (REAL speed)"); KD=(qi n);;
  cap)   BK="m:qos"; TITLE="🎯 Per-user Cap"; PR=("Client IP" "Max Mbit/s (0 = cap hatao)"); KD=(ip n);;
  adm_add) BK="m:adm"; TITLE="➕ Add Admin"; PR=("Naye admin ka Telegram User ID (numeric)" "Naam / label"); KD=(aid lbl);;
  uninst) BK="m:sys"; TITLE="🗑 Uninstall"; PR=("Sab kuch hat jayega (bot bhi). Confirm?"); KD=(y);;
  x_create) BK="m:$p"; TITLE="➕ Create $pp User"; PR=("Username" "Days" "GB limit" "IP limit"); KD=(nx n n0 n0);;
  x_del)    BK="m:$p"; TITLE="🗑 Delete $pp User"; PR=("Username"); KD=(xu);;
  x_renew)  BK="m:$p"; TITLE="🔁 Renew $pp User"; PR=("Username" "Additional days" "Data usage bhi reset karein?"); KD=(xu n y);;
  x_lim)    BK="m:$p"; TITLE="✏️ Edit $pp Limits"; PR=("Username" "New GB limit" "New IP limit"); KD=(xu s s);;
  x_reset)  BK="m:$p"; TITLE="♻️ Reset $pp Usage"; PR=("Username"); KD=(xu);;
  x_links)  BK="m:$p"; TITLE="🔗 $pp Links"; PR=("Username"); KD=(xu);;
  *) return 1;;
 esac; }

validate(){ local k="$1" v="$2"
 case "$k" in
  nu) valid_username "$v" || { ERR="Username me sirf a-z, A-Z, 0-9, _ - chalega (kam se kam 1 letter)"; return 1; }
      id "$v" &>/dev/null && { ERR="User pehle se maujood hai"; return 1; };;
  pw) [[ -n "$v" ]] || { ERR="Password khaali nahi ho sakta"; return 1; };;
  n|n0) [[ "$v" =~ ^[0-9]+$ ]] || { ERR="Number chahiye"; return 1; };;
  s) [[ "$v" == "=" || "$v" =~ ^[0-9]+$ ]] || { ERR="Number chahiye"; return 1; };;
  y) [[ "$v" == y || "$v" == n ]] || { ERR="Yes ya No dabayein"; return 1; };;
  u) is_panel_user "$v" || { ERR="User nahi mila"; return 1; };;
  nx) xray_valid_name "$v" || { ERR="Username me sirf a-z, A-Z, 0-9, _ - chalega (kam se kam 1 letter)"; return 1; }
      [[ -z "$(xray_row "$S_P" "$v")" ]] || { ERR="User pehle se maujood hai"; return 1; };;
  xu) [[ -n "$(xray_row "$S_P" "$v")" ]] || { ERR="User nahi mila"; return 1; };;
  ban) [[ -n "$v" ]] || { ERR="Khaali nahi ho sakta"; return 1; }
       [[ "$v" == default ]] || (( ${#v} <= BANNER_MAX )) || { ERR="Max ${BANNER_MAX} bytes"; return 1; };;
  dom) [[ "$v" =~ ^[A-Za-z0-9.-]+$ ]] || { ERR="Domain galat"; return 1; };;
  qi) [[ "$v" == auto ]] || ip link show "$v" &>/dev/null || { ERR="Interface nahi mila"; return 1; };;
  ip) [[ "$v" =~ ^[0-9a-fA-F.:]+$ ]] || { ERR="IP galat"; return 1; };;
  aid) [[ "$v" =~ ^[0-9]{5,15}$ ]] || { ERR="Sahi numeric Telegram ID chahiye (@userinfobot se mil jati hai)"; return 1; }
       [[ "$v" == "$ADMIN" ]] && { ERR="Ye to Super Admin hi hai"; return 1; }
       bot_admin_has "$v" && { ERR="Ye admin pehle se added hai"; return 1; };;
  lbl) [[ -n "$v" ]] && (( ${#v} <= 40 )) || { ERR="Naam khaali nahi / 40 akshar tak"; return 1; };;
 esac; return 0; }

wz_show(){ local n=${#S_A[@]} tot=${#PR[@]} i v t hint="" cg ci _a _b _c
 local -a btns=()
 t="<b>${TITLE}</b>  ·  step $((n+1))/${tot}"$'\n\n'
 for ((i=0;i<n;i++)); do v=${S_A[i]}
   [[ ${KD[i]} == pw ]] && v="••••••"; [[ ${KD[i]} == ban ]] && v="(set)"
   [[ "$v" == "=" ]] && v="same"
   t+="✔ ${PR[i]}: <code>$(h "$v")</code>"$'\n'
 done
 case "$S_ACT:$n" in
  lim:1|lim:2) get_limits "${S_A[0]}"; hint="Current: GB=$G_GB · IP=$G_IP (0 = unlimited)";;
  x_lim:1|x_lim:2) read -r _a _b _c cg ci <<<"$(xray_row "$S_P" "${S_A[0]}")"; hint="Current: GB=$cg · IP=$ci (0 = unlimited)";;
  ban:0) hint="Current banner:"$'\n'"<code>$(h "$(cat "$BANNER_FILE" 2>/dev/null)")</code>";;
  dom:0) hint="Current: $(h "$(get_domain)")";;
 esac
 [[ -n "$hint" ]] && t+=$'\n'"$hint"$'\n'
 [[ -n "$ERR" ]] && t+=$'\n'"⚠ $ERR"$'\n'
 t+=$'\n'"▶ <b>${PR[n]}</b>"
 case "${KD[n]}" in
  y) btns=("✅ Yes|w:y" "❌ No|w:n");;
  n0) btns=("♾ Unlimited (0)|w:0");;
  s) btns=("= Same|w:=" "♾ Unlimited (0)|w:0");;
  qi) btns=("Auto detect|w:auto");;
  ban) btns=("Default banner|w:default");;
  lbl) btns=("⏭ Skip|w:-");;
 esac
 panel "$t" "$(kb "${btns[@]}" "*✖ Cancel|$BK")"
}

wz_run(){ local a="$1" p="$2"; shift 2; local A=("$@") g i f lb
 case "$a" in uninst|adm_add) is_super || { deny; return; };; esac
 case "$a" in
  add)   busy "User ban raha hai"; printf '%s\n%s\n%s\n%s\n%s\n' "${A[@]}" | add_user 2>&1 | res m:ssh;;
  del)   printf '%s\n' "${A[0]}" | delete_user 2>&1 | res m:ssh;;
  renew) printf '%s\n%s\n%s\n' "${A[0]}" "${A[1]}" "${A[2]}" | renew_user 2>&1 | res m:ssh;;
  lim)   g=${A[1]}; i=${A[2]}; [[ $g == "=" ]] && g=""; [[ $i == "=" ]] && i=""
         printf '%s\n%s\n%s\n' "${A[0]}" "$g" "$i" | edit_limits 2>&1 | res m:ssh;;
  reset) printf '%s\n' "${A[0]}" | reset_usage 2>&1 | res m:ssh;;
  ban)   { if [[ "${A[0]}" == default ]]; then write_default_banner; else printf '%s\n' "${A[0]}" > "$BANNER_FILE"; fi
           chmod 644 "$BANNER_FILE"
           if [[ "$(systemctl show dropbear -p KillMode --value 2>/dev/null)" == process ]]; then systemctl restart dropbear && echo "Banner applied."
           else echo "Banner saved. Dropbear restart par apply hoga."; echo "(Abhi restart se connected users kat jayenge; pehle Fix stack chalao.)"; fi; } 2>&1 | res m:ssh;;
  dom)   { echo "${A[0]}" > "$DOMAIN_FILE"; echo "Domain: ${A[0]}"; apply_nginx_config; [[ -f /etc/haproxy/haproxy.cfg ]] && install_haproxy; } </dev/null 2>&1 | res m:main;;
  qos)   f=${A[0]}; [[ "$f" == auto ]] && f=$(detect_wan_iface)
         { mkdir -p /etc/ddkvps; printf 'IFACE=%s\nBW_MBIT=%s\n' "$f" "$((10#${A[1]}))" > "$QOS_CONF"; touch "$QOS_CAP_FILE"
           write_qos_scripts; systemctl daemon-reload; systemctl enable rt-qos >/dev/null 2>&1; systemctl restart rt-qos; sleep 2; qos_status; } 2>&1 | res m:qos;;
  cap)   { touch "$QOS_CAP_FILE"; grep -v "^${A[0]} " "$QOS_CAP_FILE" > "$QOS_CAP_FILE.tmp"; mv "$QOS_CAP_FILE.tmp" "$QOS_CAP_FILE"
           (( ${A[1]} > 0 )) && echo "${A[0]} ${A[1]}" >> "$QOS_CAP_FILE"; systemctl restart rt-qos; echo "Cap updated."; } 2>&1 | res m:qos;;
  adm_add) lb=${A[1]}; [[ "$lb" == "-" ]] && lb=Admin
         lb=$(printf '%s' "$lb" | tr -cd 'A-Za-z0-9 _.@-' | cut -c1-24); [[ -n "$lb" ]] || lb=Admin
         bot_admin_add "${A[0]}" "$lb"
         curl -s -m 10 "$API/sendMessage" --data-urlencode "chat_id=${A[0]}" --data-urlencode "text=✅ Aapko DDK VPS Manager bot ka Admin banaya gaya hai. /start bhejein." >/dev/null 2>&1
         { echo "✅ Admin added"; echo "ID   : ${A[0]}"; echo "Naam : $lb"; echo; echo "Unhe bot ko /start bhejna hoga."; } | res m:adm;;
  uninst) if [[ "${A[0]}" != y ]]; then panel "Cancelled." "$(kb "*🏠 Main Menu|m:main")"; return; fi
         busy "Uninstall ho raha hai"; ( echo YES | uninstall_panel ) >/dev/null 2>&1
         panel "✅ Uninstalled. Bot bhi band ho raha hai." ""
         rm -f /etc/systemd/system/rt-bot.service /usr/local/bin/rt-bot /etc/ddkvps/bot.admins /run/rt-bot.st.* /run/rt-bot.mid.*; systemctl disable --now rt-bot >/dev/null 2>&1;;
  x_create) busy "User ban raha hai"; printf '%s\n%s\n%s\n%s\n' "${A[@]}" | xray_create_proto "$p" 2>&1 | res "m:$p";;
  x_del)    printf '%s\n' "${A[0]}" | xray_delete_proto "$p" 2>&1 | res "m:$p";;
  x_renew)  printf '%s\n%s\n%s\n' "${A[0]}" "${A[1]}" "${A[2]}" | xray_renew_proto "$p" 2>&1 | res "m:$p";;
  x_lim)    g=${A[1]}; i=${A[2]}; [[ $g == "=" ]] && g=""; [[ $i == "=" ]] && i=""
            printf '%s\n%s\n%s\n' "${A[0]}" "$g" "$i" | xray_edit_limits_proto "$p" 2>&1 | res "m:$p";;
  x_reset)  printf '%s\n' "${A[0]}" | xray_reset_proto "$p" 2>&1 | res "m:$p";;
  x_links)  printf '%s\n' "${A[0]}" | xray_show_links_proto "$p" 2>&1 | res "m:$p";;
 esac; }

wz_step(){ wz_spec "$S_ACT" || return 1
 if (( ${#S_A[@]} >= ${#PR[@]} )); then
   local act=$S_ACT p=$S_P; local -a AA=("${S_A[@]}"); rm -f "$RTST"; S_ACT=""
   wz_run "$act" "$p" "${AA[@]}"
 else save_state; wz_show; fi; }
wz_start(){ case "$1" in uninst|adm_add) is_super || { deny; return; };; esac; S_ACT="$1"; S_P="$2"; S_A=(); ERR=""; wz_step; }
on_input(){ local v="$1" k n; load_state; [[ -n "$S_ACT" ]] || return 1
 wz_spec "$S_ACT" || return 1
 n=${#S_A[@]}; k=${KD[$n]}
 case "$k" in pw|ban) ;; *) v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"};; esac
 [[ "$k" == y ]] && v=${v,,}
 ERR=""
 if validate "$k" "$v"; then S_A+=("$v"); wz_step; else wz_show; fi; }

# ---------------- callbacks ----------------
on_cb(){ local a b c; IFS=: read -r a b c <<<"$1"
 case "$a" in
  m) case "$b" in main) main_menu;; ssh) ssh_menu;; xray) xray_menu;; vmess|vless|trojan) xproto_menu "$b";; qos) qos_menu;; sys) sys_menu;;
       adm) if is_super; then adm_menu; else deny; fi;; esac;;
  i) case "$b" in
      list)  list_users </dev/null 2>&1 | res m:ssh;;
      conn)  render_connected </dev/null 2>&1 | res m:ssh;;
      connm) render_connected </dev/null 2>&1 | res m:main;;
      stat)  status_check </dev/null 2>&1 | res m:main;;
      qs)    qos_status 2>&1 | res m:qos;;
      qoff)  remove_qos 2>&1 | res m:qos;;
     esac;;
  xi) case "$b" in
      list) xray_list_proto "$c" </dev/null 2>&1 | res "m:$c";;
      conn) xray_render_connected "$c" </dev/null 2>&1 | res "m:$c";;
     esac;;
  d) is_super || { deny; return; }; [[ "$c" =~ ^[0-9]+$ ]] || return
     case "$b" in
      adm)  panel "⚠ Admin <code>$c</code> hata dein?" "$(kb "✅ Haan, hatao|d:admy:$c" "❌ Cancel|m:adm")";;
      admy) bot_admin_del "$c"; rm -f "/run/rt-bot.st.$c" "/run/rt-bot.mid.$c"
            curl -s -m 10 "$API/sendMessage" --data-urlencode "chat_id=$c" --data-urlencode "text=⛔ Aapka DDK VPS Manager bot admin access hata diya gaya hai." >/dev/null 2>&1
            { echo "🗑 Admin removed: $c"; } | res m:adm;;
     esac;;
  a) wz_start "$b" "$c";;
  s) case "$b" in
      fix)     busy "Fix chal raha hai"; fix_websocket </dev/null 2>&1 | res m:sys;;
      restart) busy "Restart ho raha hai"; { systemctl restart ws-proxy rt-monitor xray xray-monitor haproxy nginx; echo "Restart done."; } 2>&1 | res m:sys;;
      ssl)     busy "SSL issue ho raha hai"; setup_ssl </dev/null 2>&1 | res m:sys;;
      install) busy "Install chal raha hai (kaafi time lagega)"; install_all_components </dev/null 2>&1 | res m:sys;;
     esac;;
 esac; }

on_cmd(){ local id; id=$(cat "$RTMID" 2>/dev/null); [[ -n "$id" ]] && delmsg "$id"; rm -f "$RTMID" "$RTST"; main_menu; }

handle(){ local u="$1" cb from txt mid
 cb=$(jq -r '.callback_query.data // empty' <<<"$u")
 if [[ -n "$cb" ]]; then
   from=$(jq -r '.callback_query.from.id' <<<"$u")
   curl -s -m 10 "$API/answerCallbackQuery" -d "callback_query_id=$(jq -r .callback_query.id <<<"$u")" >/dev/null
 else
   from=$(jq -r '.message.from.id // empty' <<<"$u"); txt=$(jq -r '.message.text // empty' <<<"$u"); mid=$(jq -r '.message.message_id // empty' <<<"$u")
 fi
 [[ "$from" =~ ^[0-9]+$ ]] || return
 setu "$from"; is_admin || return
 if [[ -n "$cb" ]]; then
   if [[ "$cb" == w:* ]]; then on_input "${cb#w:}" || main_menu
   else rm -f "$RTST"; on_cb "$cb"; fi
 else
   [[ -n "$mid" ]] && delmsg "$mid"
   if [[ "$txt" == /* ]]; then on_cmd
   elif [[ -n "$txt" ]]; then on_input "$txt" || [[ -s "$RTMID" ]] || main_menu; fi
 fi; }

off=0
while true; do
  r=$(curl -s -m 65 "$API/getUpdates?timeout=50&offset=$off")
  n=$(jq '.result|length' <<<"$r" 2>/dev/null)
  [[ "$n" =~ ^[0-9]+$ ]] || { sleep 3; continue; }
  for ((i=0;i<n;i++)); do
    u=$(jq -c ".result[$i]" <<<"$r"); off=$(( $(jq .update_id <<<"$u") + 1 ))
    handle "$u"
  done
done
RTBOT_EOF
    chmod +x /usr/local/bin/rt-bot
    if bash -n /usr/local/bin/rt-bot; then
        rt_ok "   ✔ rt-bot script written (syntax OK)."
    else
        rt_err "   ✘ rt-bot syntax error — purana version wapas rakha."
        [[ -f /usr/local/bin/rt-bot.bak ]] && cp -f /usr/local/bin/rt-bot.bak /usr/local/bin/rt-bot
        return 1
    fi
    rm -f /run/rt-bot.st* /run/rt-bot.mid* /run/rt-bot.state
    if systemctl is-active --quiet rt-bot; then systemctl restart rt-bot; fi
}

# Terminal se extra bot admins manage karna (root = server owner). Bot ye file har update par padhta hai, restart nahi chahiye.
bot_admins_terminal() {
    local f=/etc/ddkvps/bot.admins c id lb dt sa n t
    while true; do
        rt_sub_head "BOT ADMINS" "menu › 09 › 07 › extra Telegram admins"
        sa=$(grep -m1 '^ADMIN=' /etc/ddkvps/bot.conf 2>/dev/null | cut -d= -f2)
        rt_sub_kv super "${U_W}${U_B}${sa:-not set}${U_R}  ${U_M}Super Admin (admin management + uninstall sirf isko)${U_R}"
        rt_sub_hr
        rt_sub_sec "ADMINS"
        n=0
        if [[ -s "$f" ]]; then
            while IFS='|' read -r id lb dt; do
                [[ "$id" =~ ^[0-9]+$ ]] || continue; n=$((n+1))
                printf '  %s●%s %s%-16s%s %s%-15s%s %s%s%s\n' "$U_G" "$U_R" "$U_W" "$lb" "$U_R" "$U_T" "$id" "$U_R" "$U_M" "$dt" "$U_R"
            done < "$f"
        fi
        (( n )) || printf '  %sKoi extra admin nahi hai.%s\n' "$U_M" "$U_R"
        echo
        rt_sub_sec "ACTIONS"
        rt_sub_item 1 "Add admin"
        rt_sub_item 2 "Remove admin" danger
        rt_sub_item 3 "‹ Back" back
        rt_sub_hr
        rt_sub_prompt 3 3; c=$SUB_OPT
        case $c in
            1)
                rt_act_head "ADD ADMIN" "menu › 09 › 07 › 01 › naya bot admin"
                read -rp "$(rt_q "Naye admin ka Telegram User ID: ")" id
                if [[ ! "$id" =~ ^[0-9]{5,15}$ ]]; then rt_err "Sahi numeric ID chahiye."; press_any_key; continue; fi
                if [[ "$id" == "$sa" ]]; then rt_err "Ye to Super Admin hai."; press_any_key; continue; fi
                if [[ -f "$f" ]] && grep -q "^$id|" "$f"; then rt_err "Pehle se added hai."; press_any_key; continue; fi
                read -rp "$(rt_q "Naam / label: ")" lb
                lb=$(printf '%s' "$lb" | tr -cd 'A-Za-z0-9 _.@-' | cut -c1-24); [[ -n "$lb" ]] || lb=Admin
                mkdir -p /etc/ddkvps; touch "$f"; chmod 600 "$f"
                printf '%s|%s|%s\n' "$id" "$lb" "$(date +%F)" >> "$f"
                rt_ok "Admin added: $lb ($id). Unhe bot ko /start bhejna hoga."; press_any_key ;;
            2)
                rt_act_head "REMOVE ADMIN" "menu › 09 › 07 › 02 › bot admin hatao"
                read -rp "$(rt_q "Hatane wale admin ka ID: ")" id
                if [[ "$id" =~ ^[0-9]+$ ]] && [[ -f "$f" ]] && grep -q "^$id|" "$f"; then
                    t=$(mktemp); grep -v "^$id|" "$f" > "$t"; cat "$t" > "$f"; rm -f "$t"
                    rm -f "/run/rt-bot.st.$id" "/run/rt-bot.mid.$id"
                    rt_ok "Admin removed: $id"
                else
                    rt_err "Ye ID admin list me nahi hai."
                fi
                press_any_key ;;
            3) return ;;
            *) rt_sub_bad ;;
        esac
    done
}

telegram_bot_menu() {
    local c st T A cur_a ml r na
    while true; do
        rt_sub_head "TELEGRAM BOT" "menu › 09 › bot setup, service, admins"
        cur_a=$(grep -m1 '^ADMIN=' /etc/ddkvps/bot.conf 2>/dev/null | cut -d= -f2)
        na=$(grep -cE '^[0-9]+\|' /etc/ddkvps/bot.admins 2>/dev/null)
        if [[ ! -f /etc/systemd/system/rt-bot.service ]]; then
            DOT="${U_O}○ setup nahi hua${U_R} ${U_M}(01 se token lagayein)${U_R}"
        else
            systemctl is-active --quiet rt-bot; rt_dot $? running stopped
        fi
        rt_sub_kv status "$DOT"
        rt_sub_kv super "${U_W}${cur_a:-not set}${U_R}  ${U_M}Super Admin chat ID${U_R}"
        rt_sub_kv admins "${U_W}${na:-0}${U_R} ${U_M}extra admin(s)${U_R}"
        rt_sub_hr
        rt_sub_sec "SETUP"
        rt_sub_item 1 "Setup / Change token & chat ID"
        rt_sub_sec "SERVICE"
        rt_sub_item 2 "Restart bot"
        rt_sub_item 3 "Stop bot" warn
        rt_sub_item 4 "Logs (last 20 lines)"
        rt_sub_sec "MAINTENANCE"
        rt_sub_item 5 "Remove bot (service + config)" danger
        rt_sub_item 6 "Update / reinstall bot script"
        rt_sub_item 7 "Manage bot admins (add / remove)"
        rt_sub_item 8 "‹ Back" back
        rt_sub_hr
        rt_sub_prompt 8 8; c=$SUB_OPT
        case $c in
            1)
                rt_act_head "BOT SETUP" "menu › 09 › 01 › token + Super Admin chat ID"
                [[ -x /usr/local/bin/rt-bot ]] || install_telegram_bot || { press_any_key; continue; }
                read -rp "$(rt_q "Bot token: ")" T
                read -rp "$(rt_q "SUPER ADMIN chat ID (sirf isko admin management + uninstall milega): ")" A
                if [[ ! "$T" == *:* || ! "$A" =~ ^-?[0-9]+$ ]]; then
                    rt_err "Token ya chat ID ka format galat hai."; press_any_key; continue
                fi
                rt_info "Telegram se token check ho raha hai..."
                if ! curl -s -m 10 "https://api.telegram.org/bot${T}/getMe" | jq -e '.ok' >/dev/null 2>&1; then
                    rt_err "Token invalid hai (Telegram ne reject kiya)."; press_any_key; continue
                fi
                ml=$(grep -m1 '^MENU_LIB=' /etc/ddkvps/bot.conf 2>/dev/null | cut -d= -f2)
                ml=${ml:-/root/menu.new.sh}
                [[ -f "$ml" ]] || ml=$(readlink -f "$0")
                mkdir -p /etc/ddkvps
                printf 'TOKEN=%s\nADMIN=%s\nMENU_LIB=%s\n' "$T" "$A" "$ml" > /etc/ddkvps/bot.conf
                chmod 600 /etc/ddkvps/bot.conf
                cat > /etc/systemd/system/rt-bot.service << 'SVC_EOF'
[Unit]
Description=DDK VPS Manager Telegram Bot
After=network-online.target
[Service]
ExecStart=/usr/local/bin/rt-bot
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
SVC_EOF
                systemctl daemon-reload
                systemctl enable rt-bot >/dev/null 2>&1
                systemctl restart rt-bot
                sleep 1
                rt_ok "Bot configured. Telegram me bot ko /start bhejein."
                press_any_key ;;
            2) rt_act_head "BOT RESTART" "menu › 09 › 02 › rt-bot service"
               systemctl restart rt-bot && rt_ok "Restarted." || rt_err "Restart fail."; press_any_key ;;
            3) rt_act_head "BOT STOP" "menu › 09 › 03 › rt-bot service"
               systemctl stop rt-bot; rt_ok "Stopped."; press_any_key ;;
            4) rt_act_head "BOT LOGS" "menu › 09 › 04 › aakhri 20 lines"
               journalctl -u rt-bot -n 20 --no-pager; rt_tty && rt_sub_hr; press_any_key ;;
            5)
                rt_act_head "REMOVE BOT" "menu › 09 › 05 › service + config hatao"
                read -rp "$(rt_q "Bot service + config hata dein? [y/N]: ")" r
                if [[ "$r" =~ ^[Yy]$ ]]; then
                    systemctl disable --now rt-bot 2>/dev/null
                    rm -f /etc/systemd/system/rt-bot.service /etc/ddkvps/bot.conf /etc/ddkvps/bot.admins /run/rt-bot.st.* /run/rt-bot.mid.*
                    systemctl daemon-reload
                    rt_ok "Bot removed."
                else
                    rt_info "Cancelled."
                fi
                press_any_key ;;
            6) rt_act_head "BOT UPDATE" "menu › 09 › 06 › rt-bot script dobara likho"
               install_telegram_bot; press_any_key ;;
            7) bot_admins_terminal ;;
            8) return ;;
            *) rt_sub_bad ;;
        esac
    done
}
gradient_banner() {
    local txt="DDK VPS Manager"
    local -a cols=(ffbad2 fea5c4 fc91b6 fb7ca9 f9679b f8538d f63e7f f52972 f31564 f20056 ed1a62 e8346e e24e79 dd6885 d88191 d39b9d cdb5a8 c8cfb4)
    local i hex out=""
    for (( i=0; i<${#txt}; i++ )); do
        hex=${cols[i]}
        out+=$(printf '\e[1;38;2;%d;%d;%dm%s' $((16#${hex:0:2})) $((16#${hex:2:2})) $((16#${hex:4:2})) "${txt:i:1}")
    done
    printf '              %s\e[0m\n' "$out"
}
rainbow_banner() {
    local -A G=(
      [R]="████ |█   █|████ |█  █ |█   █"
      [A]=" ███ |█   █|█████|█   █|█   █"
      [E]="█████|█    |████ |█    |█████"
      [T]="█████|  █  |  █  |  █  |  █  "
      [I]="█████|  █  |  █  |  █  |█████"
      [C]=" ████|█    |█    |█    | ████"
      [K]="█   █|█  █ |███  |█  █ |█   █"
      [S]=" ████|█    | ███ |    █|████ "
    )
    local -a pal=(196 202 208 226 118 46 51 33 99 201)
    local -a rows
    local word r i k ch line out
    for word in RARE TRICCKS; do
        for r in 0 1 2 3 4; do
            line=""
            for (( i=0; i<${#word}; i++ )); do
                IFS='|' read -ra rows <<< "${G[${word:i:1}]}"
                line+="${rows[r]} "
            done
            out=""
            for (( k=0; k<${#line}; k++ )); do
                ch=${line:k:1}
                if [[ "$ch" == " " ]]; then out+=" "
                else out+=$'\e[38;5;'"${pal[$(( (k/3 + r) % ${#pal[@]} ))]}"'m'"$ch"; fi
            done
            printf '  %s%s\n' "$out" $'\e[0m'
        done
    done
    out=""; k=0
    for ch in P A N N E L; do
        out+=$'\e[1;38;5;'"${pal[$(( k*2 % ${#pal[@]} ))]}"'m'"$ch "; k=$((k+1))
    done
    printf '\n  %s%s\n' "$out" $'\e[0m'
}
# ==============================================================================
# SSL certificate tools — ek hi cert (Let's Encrypt) sab services par:
#   HAProxy (80/443) + Xray TCP/XHTTP (844x) + Web panel (rt-web)
#
# Port-80 conflict ka hal:
#   * Issue / renew pehle WEBROOT se: HAProxy :80 -> nginx -> /.well-known/acme-challenge/
#     (koi service band nahi hoti, users disconnect nahi hote)
#   * Webroot na chale to STANDALONE: rt-acme-port80 kuch second ke liye :80 khaali karta hai
#     (HAProxy / nginx / apache jo bhi :80 par ho), cert ke baad sab wapas chalu.
#   * Renewal (certbot.timer) ke pre/post/deploy hooks yahi kaam khud karte hain.
#   * rt-cert-sync naya cert HAProxy pem + Xray cert folder + rt-web tak pahunchata hai
#     aur sirf wahi service reload/restart karta hai jiska cert sach me badla.
# ==============================================================================
ACME_ROOT="/var/www/rt-acme"
CERT_SYNC_BIN="/usr/local/bin/rt-cert-sync"
ACME_PORT_BIN="/usr/local/bin/rt-acme-port80"

valid_domain() {   # $1 -> 0 = sahi domain naam
    [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$ ]]
}
norm_domain() {    # "https://Sub.Example.com/ " -> "sub.example.com"
    local d="${1,,}"
    d="${d#http://}"; d="${d#https://}"; d="${d%%/*}"; d="${d%%:*}"; d="${d//[[:space:]]/}"
    echo "$d"
}
has_domain() { local d; d=$(get_domain); [[ "$d" != "No Domain Set" ]] && valid_domain "$d"; }

public_ip() {
    local ip
    ip=$(curl -4 -s -m 5 https://api.ipify.org 2>/dev/null)
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "$ip"
}

dns_check() {   # $1 = domain -> sirf warning (Cloudflare proxy me IP alag hota hai, isliye rokta nahi)
    local d="$1" ip res
    ip=$(public_ip)
    res=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
    if [[ -z "$res" ]]; then
        echo -e "${YELLOW}   ! ${d} ka DNS (A record) abhi nahi mila. SSL tabhi milega jab A record ${ip} par point kare.${NC}"
        return 1
    fi
    if [[ " $res " == *" $ip "* ]]; then
        echo -e "${GREEN}   ✔ DNS: ${d} -> ${ip} (sahi)${NC}"
    else
        echo -e "${YELLOW}   ! DNS: ${d} -> ${res}(VPS IP: ${ip}). Cloudflare proxy (orange cloud) ho to theek hai;${NC}"
        echo -e "${YELLOW}     warna A record ${ip} par set karein, nahi to SSL fail hoga.${NC}"
    fi
    return 0
}

ask_domain_first() {   # $1 = domain (optional). Interactive ho to poochta hai. 0 = valid domain save hua
    local cur new; cur=$(get_domain); [[ "$cur" == "No Domain Set" ]] && cur=""
    new=$(norm_domain "${1:-}")
    if [[ -z "$new" && -t 0 ]]; then
        rt_info "Pehle apna domain / subdomain likhein (A record isi VPS ke IP par: $(public_ip))."
        rt_info "Isi domain par SSL lagega aur sab services + web panel isi cert ko use karenge."
    fi
    while true; do
        if [[ -z "$new" && -t 0 ]]; then
            read -rp "$(rt_q " Domain${cur:+ [Enter = $cur]}: ")" new
            new=$(norm_domain "$new"); [[ -z "$new" ]] && new="$cur"
        fi
        [[ -z "$new" ]] && new="$cur"
        if valid_domain "$new"; then break; fi
        if [[ -t 0 ]]; then
            rt_err "   ✘ Domain galat hai (misal: vpn.example.com)"; new=""; continue
        fi
        return 1
    done
    mkdir -p "$(dirname "$DOMAIN_FILE")"
    echo "$new" > "$DOMAIN_FILE"
    rt_ok "   ✔ Domain: ${new}"
    dns_check "$new"
    return 0
}

write_cert_tools() {
    mkdir -p "$ACME_ROOT/.well-known/acme-challenge" /etc/letsencrypt/renewal-hooks/{pre,post,deploy}

    cat > "$ACME_PORT_BIN" << 'ACME_EOF'
#!/bin/bash
# rt-acme-port80 stop|start|pre  — certbot standalone ke liye public :80 thodi der khaali karna
#   stop  : jo bhi service :80 par hai (haproxy / nginx / apache2 / lighttpd / caddy) band
#   pre   : renewal hook — sirf tab stop jab koi cert standalone method wala ho (webroot me kuch band nahi)
#   start : jo band kiye the wapas chalu (+ haproxy enabled ho to hamesha chalu)
ST=/run/rt-acme-stopped
busy80() { ss -Htln 'sport = :80' 2>/dev/null | grep -q .; }
do_stop() {
    local s
    for s in haproxy nginx apache2 lighttpd caddy; do
        systemctl is-active --quiet "$s" 2>/dev/null || continue
        if [[ "$s" == haproxy ]] || ss -Htlnp 'sport = :80' 2>/dev/null | grep -q "\"$s\""; then
            systemctl stop "$s" && echo "$s" >> "$ST"
        fi
    done
    for _ in 1 2 3 4 5 6; do busy80 || return 0; sleep 1; done
    echo "port 80 abhi bhi busy: $(ss -Htlnp 'sport = :80' 2>/dev/null | head -2)" >&2
    return 1
}
case "$1" in
    stop) do_stop ;;
    pre)  grep -qsE '^authenticator *= *standalone' /etc/letsencrypt/renewal/*.conf && do_stop; exit 0 ;;
    start)
        if [[ -f "$ST" ]]; then sort -u "$ST" | while read -r s; do [[ -n "$s" ]] && systemctl start "$s"; done; rm -f "$ST"; fi
        if systemctl is-enabled --quiet haproxy 2>/dev/null && ! systemctl is-active --quiet haproxy; then systemctl start haproxy; fi
        exit 0 ;;
    *) echo "usage: $0 stop|start|pre"; exit 2 ;;
esac
ACME_EOF
    chmod 755 "$ACME_PORT_BIN"

    cat > "$CERT_SYNC_BIN" << 'SYNC_EOF'
#!/bin/bash
# rt-cert-sync [--force] — Let's Encrypt cert ko HAProxy + Xray + Web panel tak pahunchao.
# Sirf wahi service reload/restart hoti hai jiska cert sach me badla (--force = sab dobara).
D=$(tr -d '\r\n' < /etc/ddkvps/domain.conf 2>/dev/null)
L="/etc/letsencrypt/live/$D"
FORCE=0; [[ "$1" == "--force" ]] && FORCE=1
[[ -n "$D" && -s "$L/fullchain.pem" && -s "$L/privkey.pem" ]] || { echo "rt-cert-sync: $D ka Let's Encrypt cert nahi mila"; exit 1; }
openssl x509 -noout -in "$L/fullchain.pem" >/dev/null 2>&1 || { echo "rt-cert-sync: cert kharab hai"; exit 1; }

# 1) HAProxy pem (rt-web bhi yahi file use karta hai)
HP=/etc/haproxy/certs/domain.pem; hp_changed=0
mkdir -p /etc/haproxy/certs; chmod 700 /etc/haproxy/certs
tmp=$(mktemp); cat "$L/fullchain.pem" "$L/privkey.pem" > "$tmp"
if (( FORCE )) || ! cmp -s "$tmp" "$HP"; then
    chmod 600 "$tmp"; mv -f "$tmp" "$HP"; hp_changed=1; echo "✔ HAProxy cert updated"
else rm -f "$tmp"; fi
if (( hp_changed )) && systemctl is-active --quiet haproxy; then
    if haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1; then systemctl reload haproxy && echo "✔ HAProxy reload"
    else echo "! haproxy.cfg test fail - reload nahi kiya"; fi
fi

# 2) Xray TCP/XHTTP TLS inbounds
XD=/usr/local/etc/xray/cert
if [[ -d "$XD" ]]; then
    if (( FORCE )) || ! cmp -s "$L/fullchain.pem" "$XD/fullchain.pem" || ! cmp -s "$L/privkey.pem" "$XD/privkey.pem"; then
        cp -L "$L/fullchain.pem" "$XD/fullchain.pem"; cp -L "$L/privkey.pem" "$XD/privkey.pem"
        u=$(systemctl show xray -p User --value 2>/dev/null); [[ -n "$u" ]] && chown -R "$u" "$XD"
        chmod 755 "$XD"; chmod 644 "$XD/fullchain.pem"; chmod 600 "$XD/privkey.pem"
        echo "✔ Xray cert updated"
        [[ -f /usr/local/etc/xray/config.json ]] && systemctl restart xray && echo "✔ Xray restart"
    fi
fi

# 3) Web panel (rt-web): HTTP se HTTPS par aane / naya cert lene ke liye restart
if [[ -f /etc/systemd/system/rt-web.service ]] && (( hp_changed )) && systemctl is-active --quiet rt-web; then
    systemctl restart rt-web && echo "✔ Web panel restart (naya cert)"
fi
exit 0
SYNC_EOF
    chmod 755 "$CERT_SYNC_BIN"

    printf '#!/bin/bash\nexec %s pre\n'   "$ACME_PORT_BIN" > /etc/letsencrypt/renewal-hooks/pre/rt-port80.sh
    printf '#!/bin/bash\nexec %s start\n' "$ACME_PORT_BIN" > /etc/letsencrypt/renewal-hooks/post/rt-port80.sh
    printf '#!/bin/bash\nexec %s\n'       "$CERT_SYNC_BIN" > /etc/letsencrypt/renewal-hooks/deploy/rt-cert-sync.sh
    chmod 755 /etc/letsencrypt/renewal-hooks/pre/rt-port80.sh /etc/letsencrypt/renewal-hooks/post/rt-port80.sh \
              /etc/letsencrypt/renewal-hooks/deploy/rt-cert-sync.sh
    # purane alag-alag hooks (har renewal par xray do baar restart / haproxy band hone par reload fail) hatao
    rm -f /etc/letsencrypt/renewal-hooks/deploy/haproxy-pem.sh /etc/letsencrypt/renewal-hooks/deploy/rt-xray-cert.sh
    # auto-renew timer
    if systemctl list-unit-files certbot.timer >/dev/null 2>&1 && systemctl list-unit-files certbot.timer | grep -q certbot.timer; then
        systemctl enable --now certbot.timer >/dev/null 2>&1
    fi
}

webroot_ok() {   # $1 = domain -> 0 agar HAProxy:80 -> nginx -> webroot raasta chal raha hai
    local d="$1" tok got
    systemctl is-active --quiet haproxy && systemctl is-active --quiet nginx || return 1
    grep -q 'acme-challenge' /etc/nginx/conf.d/vpn.conf 2>/dev/null || return 1
    tok="rt-test-$RANDOM$RANDOM"
    echo "$tok" > "$ACME_ROOT/.well-known/acme-challenge/$tok"
    got=$(curl -s -m 6 -H "Host: $d" "http://127.0.0.1/.well-known/acme-challenge/$tok" 2>/dev/null)
    rm -f "$ACME_ROOT/.well-known/acme-challenge/$tok"
    [[ "$got" == "$tok" ]]
}

cert_info() {   # -> CI_KIND (letsencrypt|self|none), CI_END (date), CI_DAYS
    local d f end; d=$(get_domain); CI_KIND=none; CI_END=""; CI_DAYS=""
    f="/etc/letsencrypt/live/$d/fullchain.pem"
    if [[ -s "$f" ]]; then CI_KIND=letsencrypt
    elif [[ -s "$HAPROXY_CERT" ]]; then CI_KIND=self; f="$HAPROXY_CERT"
    else return; fi
    end=$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2)
    [[ -n "$end" ]] || return
    CI_END=$(date -d "$end" '+%Y-%m-%d' 2>/dev/null)
    CI_DAYS=$(( ( $(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
}

issue_ssl_auto() {   # [--force] -> domain ka Let's Encrypt cert lo / renew karo, phir sab services par lagao. 0 = ready
    local force="${1:-}" d le ok=0
    d=$(get_domain)
    has_domain || { echo -e "${RED}   ✘ Domain set nahi hai (Menu 2).${NC}"; return 1; }
    command -v certbot >/dev/null 2>&1 || apt install -y certbot >/dev/null 2>&1
    command -v certbot >/dev/null 2>&1 || { echo -e "${RED}   ✘ certbot install nahi hua${NC}"; return 1; }
    write_cert_tools
    le="/etc/letsencrypt/live/$d/fullchain.pem"
    if [[ "$force" != "--force" && -s "$le" ]] && openssl x509 -checkend $(( 30*86400 )) -noout -in "$le" >/dev/null 2>&1; then
        cert_info
        echo -e "${GREEN}   ✔ ${d} ka cert pehle se valid hai (expiry ${CI_END}, ${CI_DAYS} din). Auto-renew on.${NC}"
        "$CERT_SYNC_BIN" | sed 's/^/     /'
        return 0
    fi
    # purane install par nginx me acme location nahi hogi -> config dobara (reload, users nahi katte)
    if [[ -f /etc/nginx/conf.d/vpn.conf ]] && ! grep -q 'acme-challenge' /etc/nginx/conf.d/vpn.conf; then
        apply_nginx_config >/dev/null 2>&1
    fi
    local args=(--non-interactive --agree-tos --register-unsafely-without-email --preferred-challenges http
                --cert-name "$d" -d "$d")
    [[ "$force" == "--force" ]] && args+=(--force-renewal) || args+=(--keep-until-expiring)
    if webroot_ok "$d"; then
        echo -e "${BLUE}   → SSL (webroot): koi service band nahi hogi...${NC}"
        certbot certonly --webroot -w "$ACME_ROOT" "${args[@]}" && ok=1
        (( ok )) || echo -e "${YELLOW}   ! webroot fail, standalone try kar raha hoon...${NC}"
    fi
    if (( ! ok )); then
        echo -e "${BLUE}   → SSL (standalone): port 80 kuch second ke liye khaali...${NC}"
        "$ACME_PORT_BIN" stop || echo -e "${YELLOW}   ! port 80 khaali nahi hua (upar dekhein)${NC}"
        certbot certonly --standalone "${args[@]}" && ok=1
        "$ACME_PORT_BIN" start
    fi
    if (( ok )) && [[ -s "$le" ]]; then
        cert_info
        echo -e "${GREEN}   ✔ SSL ready: ${d} (expiry ${CI_END}). Auto-renew: certbot.timer${NC}"
        "$CERT_SYNC_BIN" | sed 's/^/     /'
        return 0
    fi
    echo -e "${RED}   ✘ SSL nahi mila. Check: A record -> $(public_ip), port 80 cloud firewall me open, Cloudflare ho to SSL mode 'Full'.${NC}"
    echo -e "${RED}     Log: /var/log/letsencrypt/letsencrypt.log  (tab tak self-signed cert chalta rahega)${NC}"
    return 1
}

ssl_menu() {
    local c auth dom pct
    while true; do
        rt_sub_head "SSL" "menu › 03 › Let's Encrypt certificate"
        cert_info; dom=$(get_domain)
        auth=$(grep -hsE '^authenticator' "/etc/letsencrypt/renewal/${dom}.conf" | awk -F'= *' '{print $2}')
        if [[ "$dom" == "No Domain Set" ]]; then
            rt_sub_kv domain "${U_O}domain set nahi${U_R} ${U_M}→ main menu 02${U_R}"
        else
            rt_sub_kv domain "${U_W}${dom}${U_R}"
        fi
        case "$CI_KIND" in
            letsencrypt)
                pct=$(( (${CI_DAYS:-0} * 6 + 45) / 90 )); (( pct > 6 )) && pct=6; (( pct < 0 )) && pct=0
                rt_rep '▰' "$pct"; c=$REP; rt_rep '▱' $(( 6 - pct ))
                if (( ${CI_DAYS:-0} < 15 )); then REP="${U_Y}${c}${U_K}${REP}${U_R}"; else REP="${U_G}${c}${U_K}${REP}${U_R}"; fi
                if (( ${CI_DAYS:-0} < 15 )); then
                    rt_sub_kv cert "${U_Y}! Let's Encrypt${U_R}  ${U_M}expiry${U_R} ${U_W}${CI_END}${U_R}"
                    rt_sub_kv baqi "${U_Y}${CI_DAYS} din${U_R}  ${REP}"
                else
                    rt_sub_kv cert "${U_G}✓ Let's Encrypt${U_R}  ${U_M}expiry${U_R} ${U_W}${CI_END}${U_R}"
                    rt_sub_kv baqi "${U_G}${CI_DAYS} din${U_R}  ${REP}"
                fi ;;
            self) rt_sub_kv cert "${U_Y}! self-signed${U_R} ${U_M}(01 se asli cert lein)${U_R}" ;;
            *)    rt_sub_kv cert "${U_E}✗ koi nahi${U_R}" ;;
        esac
        if systemctl is-active --quiet certbot.timer 2>/dev/null || systemctl is-active --quiet snap.certbot.renew.timer 2>/dev/null; then
            rt_sub_kv renew "${U_G}● auto-renew ON${U_R}${auth:+  ${U_M}method ${auth}${U_R}}"
        else
            rt_sub_kv renew "${U_E}● auto-renew OFF${U_R} ${U_M}(01 chalayein)${U_R}"
        fi
        rt_sub_kv "used by" "${U_M}HAProxy 80/443 · Xray TCP/XHTTP · Web panel${U_R}"
        rt_sub_hr
        rt_sub_sec "ACTIONS"
        rt_sub_item 1 "Issue / Renew SSL (sirf zaroorat ho to)"
        rt_sub_item 2 "Force renew abhi" warn
        rt_sub_item 3 "Auto-renew test (dry-run)"
        rt_sub_item 4 "Cert sab services par dobara lagao"
        rt_sub_item 0 "‹ Back" back
        rt_sub_hr
        rt_sub_prompt 4 0; c=$SUB_OPT
        case "$c" in
            1) setup_ssl ;;
            2) setup_ssl --force ;;
            3) rt_act_head "SSL" "menu › 03 › 03 › auto-renew dry-run"; write_cert_tools; certbot renew --dry-run --cert-name "$(get_domain)"; rt_sub_hr; press_any_key ;;
            4) rt_act_head "SSL" "menu › 03 › 04 › cert sab services par"; write_cert_tools; "$CERT_SYNC_BIN" --force; rt_sub_hr; press_any_key ;;
            0) return ;;
            *) rt_sub_bad ;;
        esac
    done
}

# ==============================================================================
# Web Panel (rt-web) — terminal se manage: link, login, port, restart
# ==============================================================================
WEB_CONF="/etc/ddkvps/web.conf"
WEB_USERS="/etc/ddkvps/web.users"
WEB_LOGIN="/etc/ddkvps/web.login"     # line1 = Super Admin user, line2 = password (chmod 600, sirf root)
WEB_UNIT="/etc/systemd/system/rt-web.service"
RT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# panel ke liye mana ports (VPN stack ke apne ports)
WEB_RESERVED_PORTS="22 80 443 109 447 2082 2083 2084 2085 8080 8081 8442 8443 8444 8445 8446 8447 8448 10085 20001 20002 20003 20011 20012 20013 20014 20015 20016"

web_py() {   # rt-web.py ka path
    local f
    f=$(grep -oE 'python3 +[^ ]+rt-web\.py' "$WEB_UNIT" 2>/dev/null | awk '{print $2}')
    for f in "$f" "$RT_SELF_DIR/rt-web.py" /opt/ddkvps/rt-web.py; do
        [[ -n "$f" && -f "$f" ]] && { echo "$f"; return 0; }
    done
    return 1
}
web_installer() {
    local f
    for f in "$RT_SELF_DIR/install-web.sh" /opt/ddkvps/install-web.sh; do [[ -f "$f" ]] && { echo "$f"; return 0; }; done
    return 1
}
web_installed() { [[ -f "$WEB_UNIT" ]]; }
web_getkey() { grep -m1 "^$1=" "$WEB_CONF" 2>/dev/null | cut -d= -f2-; }
web_setkey() {
    mkdir -p "$(dirname "$WEB_CONF")"; touch "$WEB_CONF"; chmod 600 "$WEB_CONF"
    if grep -q "^$1=" "$WEB_CONF"; then sed -i "s|^$1=.*|$1=$2|" "$WEB_CONF"; else echo "$1=$2" >> "$WEB_CONF"; fi
}
web_port() { local p; p=$(web_getkey PORT); echo "${p:-9090}"; }
web_tls_on() {   # panel HTTPS par hai? (chal raha ho to asli check, warna config se)
    local t c; t=$(web_getkey TLS); c=$(web_getkey CERT); c="${c:-$HAPROXY_CERT}"
    if systemctl is-active --quiet rt-web; then
        curl -sk -m 3 -o /dev/null "https://127.0.0.1:$(web_port)/" 2>/dev/null && return 0
        curl -s  -m 3 -o /dev/null "http://127.0.0.1:$(web_port)/" 2>/dev/null && return 1
    fi
    [[ "$t" != "off" && -s "$c" ]]
}
web_url() {
    local host proto=http
    web_tls_on && proto=https
    if has_domain; then host=$(get_domain); else host=$(public_ip); fi
    echo "${proto}://${host}:$(web_port)"
}
web_port_reserved() { [[ " $WEB_RESERVED_PORTS " == *" $1 "* ]]; }
web_port_busy() {   # $1 = port -> 0 agar koi AUR program (rt-web nahi) use kar raha hai
    local l pid; l=$(ss -Htlnp "sport = :$1" 2>/dev/null)
    [[ -n "$l" ]] || return 1
    pid=$(systemctl show rt-web -p MainPID --value 2>/dev/null)
    [[ -n "$pid" && "$pid" != 0 ]] && grep -q "pid=$pid," <<< "$l" && return 1
    return 0
}
web_login_user() { [[ -s "$WEB_LOGIN" ]] && sed -n 1p "$WEB_LOGIN"; }
web_login_pass() { [[ -s "$WEB_LOGIN" ]] && sed -n 2p "$WEB_LOGIN"; }
web_login_save() {   # user pass
    mkdir -p "$(dirname "$WEB_LOGIN")"
    ( umask 077; printf '%s\n%s\n' "$1" "$2" > "$WEB_LOGIN" ); chmod 600 "$WEB_LOGIN"
}
web_supers() {   # super admin usernames
    local py; py=$(web_py) || return
    python3 "$py" --list-users 2>/dev/null | awk '$2=="super" && $3=="active"{print $1}'
}

web_show_info() {
    local st py u p users
    py=$(web_py)
    if systemctl is-active --quiet rt-web; then st="${GREEN}running${NC}"; else st="${RED}stopped${NC}"; fi
    echo -e "${CYAN}----------------------------------------------${NC}"
    echo -e " Status    : ${st}"
    echo -e " Link      : ${CYAN}$(web_url)${NC}"
    has_domain || echo -e "             ${YELLOW}(domain set nahi - IP wala link; Menu 2 se domain lagayein)${NC}"
    web_tls_on || echo -e "             ${YELLOW}(SSL nahi - HTTP; Menu 3 se SSL lein)${NC}"
    echo -e " Port      : $(web_port)"
    u=$(web_login_user); p=$(web_login_pass)
    users=$(web_supers | tr '\n' ' ')
    if [[ -n "$u" && -n "$py" ]] && printf '%s\n' "$p" | python3 "$py" --check-user "$u" >/dev/null 2>&1; then
        echo -e " Username  : ${BOLD}${u}${NC}  (Super Admin)"
        echo -e " Password  : ${BOLD}${p}${NC}"
    else
        echo -e " Username  : ${BOLD}${users:-?}${NC} (Super Admin)"
        echo -e " Password  : ${YELLOW}saved nahi / badal diya gaya - option 3 se naya set karein${NC}"
    fi
    echo -e "${CYAN}----------------------------------------------${NC}"
}

web_install_auto() {   # install / update bina sawal ke (port auto, user admin, random password)
    local inst; inst=$(web_installer) || { echo -e "${YELLOW}   ! install-web.sh nahi mila ($RT_SELF_DIR) - web panel skip${NC}"; return 1; }
    [[ -f "$(dirname "$inst")/rt-web.py" ]] || { echo -e "${YELLOW}   ! rt-web.py nahi mila - web panel skip${NC}"; return 1; }
    RT_WEB_AUTO=1 bash "$inst"
}

web_change_port() {
    local np
    rt_info "Abhi port: $(web_port)"
    read -rp "$(rt_q " Naya port (1024-65535): ")" np
    [[ "$np" =~ ^[0-9]+$ ]] && (( np >= 1024 && np <= 65535 )) || { rt_err "   ✘ port galat"; return 1; }
    [[ "$np" == "$(web_port)" ]] && { rt_info "Port wahi hai."; return 0; }
    web_port_reserved "$np" && { rt_err "   ✘ Port $np VPN stack (HAProxy/Nginx/Xray/ws-proxy) ka hai - doosra chunein"; return 1; }
    web_port_busy "$np" && { rt_err "   ✘ Port $np pehle se use me hai: $(ss -Htlnp "sport = :$np" | head -1)"; return 1; }
    local old; old=$(web_port)
    web_setkey PORT "$np"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$np/tcp" >/dev/null 2>&1; ufw delete allow "$old/tcp" >/dev/null 2>&1
    fi
    systemctl restart rt-web; sleep 2
    if systemctl is-active --quiet rt-web; then
        rt_ok "   ✔ Port badal gaya: $np"
        rt_info "Cloud firewall (AWS/GCP/Oracle) me bhi ${np}/tcp kholna ho sakta hai."
    else
        rt_err "   ✘ rt-web start nahi hua - purana port $old wapas"
        web_setkey PORT "$old"; systemctl restart rt-web
    fi
}

web_change_login() {
    local py cur nu np np2 gen=0
    py=$(web_py) || { rt_err "   ✘ rt-web.py nahi mila"; return 1; }
    cur=$(web_login_user); [[ -n "$cur" ]] || cur=$(web_supers | head -1)
    read -rp "$(rt_q " Naya username${cur:+ [Enter = $cur]}: ")" nu; nu="${nu:-$cur}"; nu="${nu:-admin}"
    [[ "$nu" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]{0,30}$ ]] || { rt_err "   ✘ username galat (a-z 0-9 _ -)"; return 1; }
    read -rsp "$(rt_q " Naya password (khaali = random): ")" np; echo
    if [[ -n "$np" ]]; then
        read -rsp "$(rt_q " Password dobara: ")" np2; echo
        [[ "$np" == "$np2" ]] || { rt_err "   ✘ dono password match nahi hue"; return 1; }
        (( ${#np} >= 6 )) || { rt_err "   ✘ password kam se kam 6 akshar"; return 1; }
    else
        np=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 14); gen=1
    fi
    printf '%s\n' "$np" | python3 "$py" --set-user "$nu" --role super >/dev/null || { rt_err "   ✘ login save nahi hua"; return 1; }
    if [[ -n "$cur" && "$cur" != "$nu" ]]; then
        python3 "$py" --del-user "$cur" >/dev/null 2>&1 && rt_info "purana login '${cur}' hata diya"
    fi
    web_login_save "$nu" "$np"
    rt_ok "   ✔ Login update ho gaya (purane sessions logout)."
    if rt_tty; then
        rt_sub_kv username "${U_W}${U_B}${nu}${U_R}  ${U_M}Super Admin${U_R}"
        rt_sub_kv password "${U_O}${np}${U_R}$( (( gen )) && echo "  ${U_M}(random)${U_R}")"
    else
        echo -e "   Username: ${BOLD}${nu}${NC}   Password: ${BOLD}${np}${NC}$( (( gen )) && echo '  (random)')"
    fi
}

web_panel_menu() {
    local c inst
    while true; do
        rt_sub_head "WEB PANEL" "menu › 10 › browser control panel"
        if ! web_installed; then
            rt_sub_kv status "${U_O}○ install nahi hai${U_R}"
            rt_sub_hr
            rt_sub_item 1 "Install Web Panel"
            rt_sub_item 0 "‹ Back" back
            rt_sub_hr
            rt_sub_prompt 1 0; c=$SUB_OPT
            case "$c" in
                1) rt_act_head "WEB PANEL" "menu › 10 › 01 › install"; inst=$(web_installer) && bash "$inst" || rt_err "install-web.sh nahi mila (${RT_SELF_DIR}) - install.sh dobara chalayein"; press_any_key ;;
                *) return ;;
            esac
            continue
        fi
        rt_web_rows
        rt_sub_hr
        rt_sub_sec "ACCESS"
        rt_sub_item 1 "Link + login details"
        rt_sub_item 2 "Port change"
        rt_sub_item 3 "Username / Password change"
        rt_sub_sec "SERVICE"
        rt_sub_item 4 "Restart web panel"
        rt_sub_item 5 "Logs (aakhri 40 lines)"
        rt_sub_item 6 "Update / Reinstall (login wahi rahega)"
        rt_sub_item 7 "Uninstall web panel" danger
        rt_sub_item 0 "‹ Back" back
        rt_sub_hr
        rt_sub_prompt 7 0; c=$SUB_OPT
        case "$c" in
            1) rt_sub_head "WEB PANEL" "menu › 10 › 01 › link + login"; rt_web_rows; rt_sub_hr; press_any_key ;;
            2) rt_act_head "WEB PANEL" "menu › 10 › 02 › port change"; web_change_port; press_any_key ;;
            3) rt_act_head "WEB PANEL" "menu › 10 › 03 › username / password"; web_change_login; press_any_key ;;
            4) rt_act_head "WEB PANEL" "menu › 10 › 04 › restart"; systemctl restart rt-web; sleep 2
               systemctl is-active --quiet rt-web && rt_ok "   ✔ Web panel restart ho gaya: $(web_url)" \
                   || { rt_err "   ✘ start nahi hua:"; journalctl -u rt-web -n 15 --no-pager; }
               press_any_key ;;
            5) rt_act_head "WEB PANEL" "menu › 10 › 05 › logs (aakhri 40 lines)"; journalctl -u rt-web -n 40 --no-pager; rt_sub_hr; press_any_key ;;
            6) rt_act_head "WEB PANEL" "menu › 10 › 06 › update / reinstall"; inst=$(web_installer) && RT_WEB_AUTO=1 bash "$inst" || rt_err "install-web.sh nahi mila"; press_any_key ;;
            7) rt_act_head "WEB PANEL" "menu › 10 › 07 › uninstall"; read -rp "$(rt_q " Web panel hatana hai? VPN par asar nahi hoga. (y/N): ")" c
               if [[ "$c" =~ ^[Yy]$ ]]; then
                   inst=$(web_installer) && bash "$inst" --uninstall || { systemctl disable --now rt-web; rm -f "$WEB_UNIT"; systemctl daemon-reload; }
                   rm -f "$WEB_LOGIN"
               fi
               press_any_key ;;
            0) return ;;
            *) rt_sub_bad ;;
        esac
    done
}

# ==============================================================================
# INPUT / ACTION SCREENS - Deploy Suite style (sirf asli terminal par; bot / web panel ka output wahi purana)
# ==============================================================================
rt_tty() { [[ -t 0 && -t 1 && "${TERM:-dumb}" != dumb && -z "${RT_PLAIN:-}" ]]; }
rt_q() {   # read -p ka prompt:  "GB limit (0 = unlimited): "  ->  "  › GB limit (0 = unlimited) : "
    local s=$1 h=""
    [[ -n "${U_T:-}" ]] || rt_ui_colors
    s="${s#"${s%%[! ]*}"}"; s="${s%"${s##*[! ]}"}"; s=${s%:}; s="${s%"${s##*[! ]}"}"
    if [[ "$s" =~ ^(.*[^ ])\ +(\[[^]]*\]|\([^\)]*\))$ ]]; then s=${BASH_REMATCH[1]}; h=${BASH_REMATCH[2]}; fi
    printf '  %s›%s %s%s%s%s %s:%s ' "$U_T" "$U_R" "$U_W" "$s" "$U_R" "${h:+ ${U_M}${h}${U_R}}" "$U_L" "$U_R"
}
rt_act_head() { rt_tty && rt_sub_head "$1" "$2"; return 0; }   # $1 badge, $2 breadcrumb
rt_msg() {   # $1 = err|ok|warn|info, $2 = text. Terminal: rangeen icon line. Warna: purana "${COLOR}text${NC}"
    local k=$1 t=$2 c i
    case $k in err) c=$RED ;; ok) c=$GREEN ;; warn) c=$YELLOW ;; *) c=$CYAN ;; esac
    if ! rt_tty; then echo -e "${c}${t}${NC}"; return 0; fi
    [[ -n "${U_T:-}" ]] || rt_ui_colors
    t="${t#"${t%%[! ]*}"}"
    for i in '✔ ' '✘ ' '! ' '[ERROR] ' '[SUCCESS] ' '[DONE] '; do t=${t#"$i"}; done
    case $k in
        err)  echo -e "  ${U_E}✗${U_R} ${U_E}${t}${U_R}" ;;
        ok)   echo -e "  ${U_G}✓${U_R} ${U_W}${t}${U_R}" ;;
        warn) echo -e "  ${U_Y}!${U_R} ${U_Y}${t}${U_R}" ;;
        *)    echo -e "  ${U_T}·${U_R} ${U_M}${t}${U_R}" ;;
    esac
}
rt_err()  { rt_msg err  "$1"; }
rt_ok()   { rt_msg ok   "$1"; }
rt_warn() { rt_msg warn "$1"; }
rt_info() { rt_msg info "$1"; }
rt_card_kv()  { printf '  %s%-11s%s %s%s%s\n' "$U_M" "$1" "$U_R" "${3:-$U_W}" "$2" "$U_R"; }   # key value [colour]
rt_card_sec() { printf '\n  %s%s%s%s\n' "$U_B" "$U_T" "$1" "$U_R"; }
rt_card_top() {   # $1 = title  (✓ TITLE + line)
    [[ -n "${SUB_HR:-}" ]] || { rt_rep '─' 52; SUB_HR="  ${U_L}${REP}${U_R}"; }
    printf '\n  %s✓%s %s%s%s%s\n%s\n' "$U_G" "$U_R" "$U_B" "$U_W" "$1" "$U_R" "$SUB_HR"
}
rt_ssh_card() {   # user pass host exp data iplimit city region
    rt_card_top "SSH ACCOUNT CREATED"
    rt_card_kv username "$1"; rt_card_kv password "$2" "$U_O"; rt_card_kv host "$3"; rt_card_kv sni "$3"
    rt_card_kv expiry "$4"; rt_card_kv data "$5"; rt_card_kv "ip limit" "$6"
    rt_card_sec "PORTS"
    rt_card_kv "ssh direct" "22, 109, 447"; rt_card_kv "ssh ssl" "443"
    rt_card_kv "ssh ws" "80  → ${CUSTOM_PATH}"; rt_card_kv "ssh ws ssl" "443 → ${CUSTOM_PATH}"
    rt_card_sec "LOCATION"
    rt_card_kv city "$7"; rt_card_kv region "$8"
    rt_card_sec "PAYLOAD"
    printf '%s%s%s\n' "$U_T" "GET ${CUSTOM_PATH} HTTP/1.1[crlf]Host: ${3}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]" "$U_R"
    printf '%s\n' "$SUB_HR"
}
# ==============================================================================
# SUBMENU UI - Deploy Suite style helpers (Users / Xray / SSL / QoS / Web Panel)
# ==============================================================================
rt_sub_head() {   # $1 = section badge, $2 = breadcrumb / subtitle
    local s cols
    rt_ui_colors
    s=$(stty size </dev/tty 2>/dev/null || stty size 2>/dev/null); cols=${s##* }; [[ "$cols" =~ ^[0-9]+$ ]] || cols=${COLUMNS:-80}; [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    SUB_W=$(( cols - 4 )); (( SUB_W > 64 )) && SUB_W=64; (( SUB_W < 40 )) && SUB_W=40
    rt_rep '─' "$SUB_W"; SUB_HR="  ${U_L}${REP}${U_R}"
    RT_TH=$'\033[1;38;5;80m'   # list / connected tables ke column headers: teal (Deploy Suite)
    clear
    printf '  %s DDK VPS MANAGER %s%s %s %s %sv%s%s\n' "$U_TB" "$U_R" "$U_GB" "$1" "$U_R" "$U_M" "$RT_SUITE_VER" "$U_R"
    printf '  %s%s%s\n\n' "$U_M" "$2" "$U_R"
}
rt_sub_kv()   { printf '  %s%-9s%s %s\n' "$U_M" "$1" "$U_R" "$2"; }     # $1 key, $2 value (rangeen)
rt_sub_note() { printf '  %-9s %s%s%s\n' "" "$U_Y" "$1" "$U_R"; }        # value ke neeche peela note
rt_sub_hr()   { printf '%s\n' "$SUB_HR"; }
rt_sub_sec()  { printf '  %s%s%s%s\n' "$U_B" "$U_T" "$1" "$U_R"; }
rt_sub_item() {   # $1 number, $2 label, $3 = ""|danger|warn|back
    local col=$U_W
    case ${3:-} in danger) col=$U_E ;; warn) col=$U_O ;; back) col=$U_M ;; esac
    printf '  %s%02d%s  %s%s%s\n' "$U_T" "$1" "$U_R" "$col" "$2" "$U_R"
}
rt_sub_prompt() {   # $1 = max option, $2 = back number -> SUB_OPT  (0 / 00 / q / Enter = back, 01 = 1)
    printf '  %s›%s %soption%s %s[1-%s]  0 = back%s ' "$U_T" "$U_R" "$U_W" "$U_R" "$U_M" "$1" "$U_R"
    read -r SUB_OPT || SUB_OPT=$2
    SUB_OPT=${SUB_OPT//[[:space:]]/}
    case ${SUB_OPT,,} in ""|0|00|q|b) SUB_OPT=$2 ;; esac
    [[ "$SUB_OPT" =~ ^0+[1-9][0-9]*$ ]] && SUB_OPT=$(( 10#$SUB_OPT ))
    return 0
}
rt_sub_bad()  { printf '  %s✗ galat option%s\n' "$U_E" "$U_R"; sleep 1; }
rt_dot() {   # $1 = 0 on / else off, $2 on-text, $3 off-text
    if [[ "$1" == 0 ]]; then printf -v DOT '%s● %s%s' "$U_G" "$2" "$U_R"; else printf -v DOT '%s● %s%s' "$U_E" "$3" "$U_R"; fi
}
rt_acct_counts() {   # -> RC_SSH RC_VM RC_VL RC_TR RC_ON
    RC_SSH=$(awk -F: '$3>=1000 && $3<60000 && $1!="nobody"' /etc/passwd 2>/dev/null | wc -l)
    RC_VM=$(grep -c . /var/lib/ddkvps/xray/vmess.db 2>/dev/null); RC_VL=$(grep -c . /var/lib/ddkvps/xray/vless.db 2>/dev/null)
    RC_TR=$(grep -c . /var/lib/ddkvps/xray/trojan.db 2>/dev/null)
    RC_ON=$(grep -vc -e '^#' -e '^$' "$LIVE_FILE" 2>/dev/null)
    RC_SSH=${RC_SSH:-0}; RC_VM=${RC_VM:-0}; RC_VL=${RC_VL:-0}; RC_TR=${RC_TR:-0}; RC_ON=${RC_ON:-0}
}
rt_web_rows() {   # web panel info - Deploy Suite style (web_show_info plain text wala bot/install ke liye wahi hai)
    local py u p users
    py=$(web_py)
    systemctl is-active --quiet rt-web; rt_dot $? running stopped; rt_sub_kv status "$DOT"
    rt_sub_kv link "${U_T}$(web_url)${U_R}"
    has_domain || rt_sub_note "domain set nahi - IP wala link (main menu 02 se domain)"
    web_tls_on || rt_sub_note "SSL nahi - HTTP (main menu 03 se SSL)"
    rt_sub_kv port "${U_W}$(web_port)${U_R}"
    u=$(web_login_user); p=$(web_login_pass)
    if [[ -n "$u" && -n "$py" ]] && printf '%s\n' "$p" | python3 "$py" --check-user "$u" >/dev/null 2>&1; then
        rt_sub_kv username "${U_W}${U_B}${u}${U_R}  ${U_M}Super Admin${U_R}"
        rt_sub_kv password "${U_O}${p}${U_R}"
    else
        users=$(web_supers | tr '\n' ' ')
        rt_sub_kv username "${U_W}${users:-?}${U_R} ${U_M}Super Admin${U_R}"
        rt_sub_kv password "${U_Y}saved nahi / badal diya gaya - 03 se naya set karein${U_R}"
    fi
}
# ==============================================================================
# MAIN MENU - Deploy Suite style (teal / orange / green), live status ke saath
# ==============================================================================
RT_MM_ITEMS=("Install All Components" "Add / Change Domain" "SSL Certificate (issue / renew)"
             "Manage Users / Limits / Banner" "Status & Ports" "Fix SSH-WS / SSL stack"
             "Ping Stability (QoS)" "VPS Stats / Speedtest" "Telegram Bot"
             "Web Panel (link / login / port)" "Uninstall" "Exit")
rt_svc_on() {   # $1.. = units -> 0 agar installed + active, 1 band, 2 installed hi nahi
    local s inst=0
    for s in "$@"; do
        [[ -f "/etc/systemd/system/$s.service" || -f "/lib/systemd/system/$s.service" || -f "/usr/lib/systemd/system/$s.service" ]] || continue
        inst=1; systemctl is-active --quiet "$s" || return 1
    done
    (( inst )) && return 0 || return 2
}
rt_main_menu_draw() {
    local s cols W two dom ssl up upd uph nssh nvm nvl ntr onl web l i n colw tw lab num c out="" pc pr pd
    rt_ui_colors
    if [[ -z "${MM_IP:-}" ]]; then rt_ui_node; MM_IP=$UI_IP; rt_ui_stats; sleep 0.2; fi
    s=$(stty size </dev/tty 2>/dev/null || stty size 2>/dev/null); cols=${s##* }; [[ "$cols" =~ ^[0-9]+$ ]] || cols=${COLUMNS:-80}; [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    W=$(( cols - 4 )); (( W > 76 )) && W=76; (( W < 40 )) && W=40
    two=0; (( W >= 70 )) && two=1
    rt_rep '─' "$W"; local HR="  ${U_L}${REP}${U_R}"

    # --- header ---
    out+="  ${U_TB} DDK VPS MANAGER ${U_R}${U_GB} PANEL ${U_R} ${U_M}v${RT_SUITE_VER}${U_R}\n"
    out+="  ${U_M}SSH / WS / SSL / Xray / QoS control${U_R}\n\n"
    dom=$(get_domain)
    if [[ "$dom" == "No Domain Set" ]]; then
        out+="  ${U_M}host${U_R}  ${U_O}domain set nahi${U_R} ${U_M}→ 02 se lagayein${U_R}\n"
    else
        cert_info
        case $CI_KIND in
            letsencrypt) if (( ${CI_DAYS:-0} < 15 )); then ssl="${U_Y}! SSL ${CI_DAYS}d${U_R}"; else ssl="${U_G}✓ SSL ${CI_DAYS}d${U_R}"; fi ;;
            self)        ssl="${U_Y}! self-signed${U_R}" ;;
            *)           ssl="${U_E}✗ no SSL${U_R}" ;;
        esac
        if (( two )); then out+="  ${U_M}host${U_R}  ${U_W}${dom}${U_R}  ${ssl}   ${U_M}path${U_R} ${U_W}${CUSTOM_PATH}${U_R}\n"
        else out+="  ${U_M}host${U_R}  ${U_W}${dom}${U_R}  ${ssl}\n"; fi
    fi
    read -r up _ < /proc/uptime 2>/dev/null; up=${up%%.*}; upd=$(( ${up:-0} / 86400 )); uph=$(( ${up:-0} % 86400 / 3600 ))
    if (( two )); then
        out+="  ${U_M}node${U_R}  ${U_W}${MM_IP}  ${UI_OS}  ${UI_NCPU} vCPU  ${UI_RAM} RAM${U_R}  ${U_M}up ${upd}d ${uph}h${U_R}\n"
    else
        out+="  ${U_M}node${U_R}  ${U_W}${MM_IP}  ${UI_NCPU} vCPU  ${UI_RAM} RAM${U_R}\n"
        out+="  ${U_M}os${U_R}    ${U_W}${UI_OS}${U_R}  ${U_M}up ${upd}d ${uph}h   path${U_R} ${U_W}${CUSTOM_PATH}${U_R}\n"
    fi
    if web_installed; then
        if systemctl is-active --quiet rt-web; then web="${U_T}$(web_url)${U_R}"; else web="${U_E}rt-web band hai${U_R} ${U_M}→ 10${U_R}"; fi
        out+="  ${U_M}web${U_R}   ${web}\n"
    fi
    out+="${HR}\n"

    # --- services ---
    l="  "; local any=0 pair lbl units vis=0
    for pair in "haproxy:haproxy" "nginx:nginx" "dropbear:dropbear" "ws:ws-proxy" "xray:xray" "limits:rt-monitor xray-monitor" "qos:rt-qos" "web:rt-web"; do
        lbl=${pair%%:*}; units=${pair#*:}
        rt_svc_on $units; c=$?
        (( c > 1 )) && continue
        if (( vis > 0 && vis + ${#lbl} + 2 > W )); then out+="${l}\n"; l="  "; vis=0; fi
        case $c in 0) l+="${U_G}●${U_R} ${U_W}${lbl}${U_R}  " ;; 1) l+="${U_E}●${U_R} ${U_E}${lbl}${U_R}  " ;; esac
        any=1; vis=$(( vis + ${#lbl} + 4 ))
    done
    (( any )) || l="  ${U_O}○ abhi kuch install nahi${U_R} ${U_M}→ 01 Install All Components${U_R}"
    out+="${l}\n"

    # --- accounts + system ---
    nssh=$(awk -F: '$3>=1000 && $3<60000 && $1!="nobody"' /etc/passwd 2>/dev/null | wc -l)
    nvm=$(grep -c . /var/lib/ddkvps/xray/vmess.db 2>/dev/null); nvl=$(grep -c . /var/lib/ddkvps/xray/vless.db 2>/dev/null)
    ntr=$(grep -c . /var/lib/ddkvps/xray/trojan.db 2>/dev/null)
    onl=$(grep -vc -e '^#' -e '^$' "$LIVE_FILE" 2>/dev/null)
    out+="  ${U_M}SSH${U_R} ${U_W}${nssh:-0}${U_R}   ${U_M}VMess${U_R} ${U_W}${nvm:-0}${U_R}   ${U_M}VLESS${U_R} ${U_W}${nvl:-0}${U_R}   ${U_M}Trojan${U_R} ${U_W}${ntr:-0}${U_R}   ${U_M}online${U_R} ${U_T}${onl:-0}${U_R}\n"
    rt_ui_stats
    rt_ui_mini "${UI_CPU_P:-0}"; pc=$REP; rt_ui_mini "${UI_RAM_P:-0}"; pr=$REP; rt_ui_mini "${UI_DSK_P:-0}"; pd=$REP
    printf -v l '  %sCPU%s %s %3d%%   %sRAM%s %s %3d%%   %sDSK%s %s %3d%%' "$U_M" "$U_R" "$pc" "${UI_CPU_P:-0}" "$U_M" "$U_R" "$pr" "${UI_RAM_P:-0}" "$U_M" "$U_R" "$pd" "${UI_DSK_P:-0}"
    out+="${l}\n${HR}\n"

    # --- options ---
    n=${#RT_MM_ITEMS[@]}
    item() {   # $1 index -> ITEM (rangeen) ; $2 = max label width (0 = poora)
        local k=$1 t=${RT_MM_ITEMS[$1]} col=$U_W
        (( ${2:-0} > 0 )) && t=${t:0:$2}
        (( k == 10 )) && col=$U_E; (( k == 11 )) && col=$U_M
        printf -v ITEM '%s%02d%s  %s%s%s' "$U_T" $(( k + 1 )) "$U_R" "$col" "$t" "$U_R"
        ITEM_LEN=$(( 4 + ${#t} ))
    }
    if (( two )); then
        colw=$(( W / 2 ))
        printf -v l '  %s%s%-*s%s%s%s' "$U_B$U_T" "SETUP & USERS" $(( colw - 13 )) "" "TOOLS & SYSTEM" "$U_R" ""
        out+="${l}\n"
        for (( i = 0; i < 6; i++ )); do
            item "$i" $(( colw - 6 )); l="  ${ITEM}"; printf -v s '%*s' $(( colw - ITEM_LEN )) ''; l+="$s"
            item $(( i + 6 )) $(( W - colw - 4 )); l+="${ITEM}"
            out+="${l}\n"
        done
    else
        for (( i = 0; i < n; i++ )); do
            (( i == 0 )) && out+="  ${U_B}${U_T}SETUP & USERS${U_R}\n"
            (( i == 6 )) && out+="  ${U_B}${U_T}TOOLS & SYSTEM${U_R}\n"
            item "$i" $(( W - 4 )); out+="  ${ITEM}\n"
        done
    fi
    unset -f item
    out+="${HR}\n"
    clear
    printf '%b' "$out"
}
rt_main_menu_prompt() {   # -> opt
    printf '  %s›%s %soption%s %s[1-12]%s ' "$U_T" "$U_R" "$U_W" "$U_R" "$U_M" "$U_R"
    read -r opt || opt=12
    opt=${opt//[[:space:]]/}; [[ "$opt" == 0 ]] && opt=12
    opt=${opt#0}; [[ -z "$opt" ]] && opt=x
    [[ "${opt,,}" == q ]] && opt=12
}

if [[ "${1:-}" == "--lib" ]]; then
    return 0 2>/dev/null || exit 0
fi
# Non-interactive entry points (install.sh inhe use karta hai)
#   menu.sh --install-all <domain>   : poora install (domain -> packages -> stack -> SSL -> web panel)
#   menu.sh --cert-setup             : renewal hooks + port-80 logic + cert sab services par (upgrade ke liye)
#   menu.sh --install-xray           : sirf Xray install / repair (SSH stack pehle se ho)
#   menu.sh --repair                 : SSH + Xray services check + jo band ho theek karo
#   menu.sh --harden                 : SSH users ka shell band (sirf tunnel)
#   menu.sh --install-cmd            : "menu" command dobara banao
case "${1:-}" in
    --install-all) install_all_components "${2:-}"; exit 0 ;;
    --install-xray) install_xray; rc=$?; (( rc == 0 )) && [[ -f /etc/systemd/system/rt-monitor.service ]] && harden_ssh_users >/dev/null; exit $rc ;;
    --repair)       harden_ssh_users; rt_verify_stack; exit $? ;;
    --harden)       harden_ssh_users; exit 0 ;;
    --install-cmd)  ensure_menu_cmd; echo "menu command ready"; exit 0 ;;
    --cert-setup)
        write_cert_tools
        [[ -f /etc/nginx/conf.d/vpn.conf ]] && ! grep -q acme-challenge /etc/nginx/conf.d/vpn.conf && apply_nginx_config >/dev/null 2>&1
        has_domain && [[ -s "/etc/letsencrypt/live/$(get_domain)/fullchain.pem" ]] && "$CERT_SYNC_BIN"
        echo "cert tools ready (auto-renew + port 80 conflict fix)"; exit 0 ;;
esac

ensure_menu_cmd >/dev/null 2>&1   # "menu" command hamesha isi file ko khole

while true; do
    rt_main_menu_draw
    rt_main_menu_prompt
    case $opt in
        1) install_all_components ;;
        2) add_domain_option ;;
        3) ssl_menu ;;
        4) user_menu ;;
        5) status_check ;;
        6) fix_websocket ;;
        7) ping_stability_menu ;;
        8) ex_stats_menu ;;
        9) telegram_bot_menu ;;
        10) web_panel_menu ;;
        11) uninstall_panel ;;
        12) exit 0 ;;
        *) printf '  %s✗ galat option%s %s(1-12 likhein)%s\n' "$U_E" "$U_R" "$U_M" "$U_R"; sleep 1 ;;
    esac
done

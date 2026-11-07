#!/bin/bash
# ==============================================================================
# DDK VPS Manager Web Panel (rt-web) - installer
#
#   bash install-web.sh                 # install / update (pehli baar login poochega)
#   bash install-web.sh --reset-password  # Super Admin login dobara set (password bhool gaye to)
#   bash install-web.sh --list-users      # panel logins ki list
#   bash install-web.sh --port 9443     # port badlo
#   bash install-web.sh --uninstall     # web panel hatao (VPN / users ko kuch nahi hota)
#
# rt-web.py isi folder me (ya /opt/ddkvps me) hona chahiye. Sirf python3 chahiye.
# HTTPS: agar /etc/haproxy/certs/domain.pem hai (menu "Issue SSL" ke baad) to panel
#        khud HTTPS par chalega:  https://<domain>:<port>
# Mazeed logins (Admin / Viewer): panel me Super Admin -> "Panel Admins" page.
# ==============================================================================
DIR="${RT_DIR:-/opt/ddkvps}"
SRC="$(cd "$(dirname "$0")" && pwd)"
CONF=/etc/ddkvps/web.conf
UNIT=/etc/systemd/system/rt-web.service
CERT=/etc/haproxy/certs/domain.pem
# Deploy Suite palette (teal / orange / green on dark) - terminal na ho to bina rang
if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then
    T=$'\033[38;5;80m'; TB=$'\033[1;38;5;234;48;5;80m'; GB=$'\033[38;5;80;48;5;237m'; M=$'\033[38;5;245m'
    W=$'\033[38;5;255m'; G=$'\033[38;5;114m'; Y=$'\033[38;5;221m'; E=$'\033[38;5;203m'; L=$'\033[38;5;239m'
    O=$'\033[38;5;215m'; B=$'\033[1m'; NC=$'\033[0m'
else
    T=; TB=; GB=; M=; W=; G=; Y=; E=; L=; O=; B=; NC=
fi
RED=$E; GREEN=$G; YELLOW=$Y; CYAN=$T
ok()   { echo -e "  ${G}✓${NC} $*"; }
warn() { echo -e "  ${Y}!${NC} $*"; }
die()  { echo -e "  ${E}✗ $*${NC}"; exit 1; }
hr()   { echo -e "  ${L}────────────────────────────────────────────────────────────────${NC}"; }
rt_badge() {   # $1 = doosra label
    echo -e "  ${TB} DDK VPS MANAGER ${NC}${GB} $1 ${NC} ${M}v7.0${NC}"
    echo -e "  ${M}SSH / WS / SSL / Xray / QoS setup${NC}"
    echo
}

RESET=0; NEWPORT=""; UNINST=0; LISTU=0
USERS=/etc/ddkvps/web.users
while (( $# )); do
    case "$1" in
        --reset-password) RESET=1 ;;
        --port) shift; NEWPORT="$1" ;;
        --uninstall) UNINST=1 ;;
        --list-users) LISTU=1 ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac; shift
done
[[ $EUID -eq 0 ]] || die "root chahiye (sudo -i)"

if (( UNINST )); then
    systemctl disable --now rt-web >/dev/null 2>&1
    rm -f "$UNIT" "$CONF" "$USERS" /etc/ddkvps/web.login /var/lib/ddkvps/web-owners.json; systemctl daemon-reload
    ok "Web panel hata diya (rt-web.py $DIR me pada hai, VPN par koi asar nahi)"; exit 0
fi

if (( LISTU )); then
    python3 "$DIR/rt-web.py" --list-users; exit $?
fi

rt_badge "WEB PANEL"
if ! command -v python3 >/dev/null 2>&1; then
    echo -e "  ${T}→${NC} python3 install ho raha hai"
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3 >/dev/null 2>&1 || die "python3 install fail"
fi
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,7) else 1)' || die "python3 3.7+ chahiye"
ok "python3 $(python3 -c 'import platform;print(platform.python_version())')"

# ---- rt-web.py ------------------------------------------------------------
mkdir -p "$DIR" /etc/ddkvps
if [[ -f "$SRC/rt-web.py" && "$SRC" != "$DIR" ]]; then
    python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$SRC/rt-web.py" || die "rt-web.py me syntax error (adhoori upload?)"
    cp -f "$SRC/rt-web.py" "$DIR/rt-web.py"
fi
[[ -f "$DIR/rt-web.py" ]] || die "rt-web.py nahi mila ($SRC ya $DIR me rakhein)"
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$DIR/rt-web.py" || die "rt-web.py me syntax error"
chmod 700 "$DIR/rt-web.py"
ok "rt-web.py -> $DIR/rt-web.py"
[[ -f "$DIR/menu.sh" ]] || warn "$DIR/menu.sh nahi mila - pehle install.sh chalayein (panel ko menu.sh chahiye)"

# ---- config ---------------------------------------------------------------
TTY=/dev/tty; [[ -r /dev/tty ]] || TTY=""
# RT_WEB_AUTO=1 (menu "Install All" / install.sh): koi sawal nahi -> port auto, user admin, random password
[[ -n "${RT_WEB_AUTO:-}" ]] && TTY=""
LOGIN=/etc/ddkvps/web.login   # terminal menu (Web Panel) ke liye: line1 user, line2 password (root-only)
# VPN stack ke apne ports - panel inpar kabhi nahi chalega (port conflict se bachao)
RESERVED=" 22 80 443 109 447 2082 2083 2084 2085 8080 8081 8442 8443 8444 8445 8446 8447 8448 10085 20001 20002 20003 20011 20012 20013 20014 20015 20016 "
ask() {   # $1 prompt, $2 default -> REPLY
    REPLY=""
    if [[ -n "$TTY" ]]; then read -rp "$1" REPLY < "$TTY"; fi
    REPLY="${REPLY:-$2}"
}
port_used() { ss -Htln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; }
port_reserved() { [[ "$RESERVED" == *" $1 "* ]]; }
port_other() {   # port kisi AUR program ke paas hai (rt-web khud nahi)
    local l pid; l=$(ss -Htlnp "sport = :$1" 2>/dev/null); [[ -n "$l" ]] || return 1
    pid=$(systemctl show rt-web -p MainPID --value 2>/dev/null)
    [[ -n "$pid" && "$pid" != 0 ]] && grep -q "pid=$pid," <<< "$l" && return 1
    return 0
}
setkey() {   # key value
    touch "$CONF"; chmod 600 "$CONF"
    if grep -q "^$1=" "$CONF"; then sed -i "s|^$1=.*|$1=$2|" "$CONF"; else echo "$1=$2" >> "$CONF"; fi
}
getkey() { grep -m1 "^$1=" "$CONF" 2>/dev/null | cut -d= -f2-; }

FRESH=1   # na web.users, na purana WEB_PASS = pehli install
[[ -s "$USERS" ]] && FRESH=0
grep -q '^WEB_PASS=' "$CONF" 2>/dev/null && FRESH=0
if (( FRESH )); then
    port=9090
    while port_used "$port" || port_reserved "$port"; do port=$((port+1)); done
    ask "  Panel port [$port]: " "$port"; port="$REPLY"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port < 65536 )) || die "port galat"
    port_reserved "$port" && die "port $port VPN stack (HAProxy/Nginx/Xray/ws-proxy) ka hai - doosra chunein"
    port_other "$port" && die "port $port pehle se use me hai - doosra port chunein"
    setkey PORT "$port"
    setkey BIND 0.0.0.0
    setkey MENU_LIB "$DIR/menu.sh"
    setkey CERT "$CERT"
    setkey TLS auto
    setkey SESSION_HOURS 168
    RESET=1
fi
if [[ -n "$NEWPORT" ]]; then
    [[ "$NEWPORT" =~ ^[0-9]+$ ]] && (( NEWPORT > 0 && NEWPORT < 65536 )) || die "port galat"
    port_reserved "$NEWPORT" && die "port $NEWPORT VPN stack ka hai - doosra chunein"
    port_other "$NEWPORT" && die "port $NEWPORT pehle se use me hai"
    setkey PORT "$NEWPORT"
fi
if (( RESET )); then
    ask "  Panel username [admin]: " "admin"; wu="$REPLY"
    [[ "$wu" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]{0,30}$ ]] || die "username galat (a-z 0-9 _ -)"
    wp=""
    if [[ -n "$TTY" ]]; then
        read -rsp "  Panel password (khaali = random): " wp < "$TTY"; echo
        if [[ -n "$wp" ]]; then
            read -rsp "  Password dobara: " wp2 < "$TTY"; echo
            [[ "$wp" == "$wp2" ]] || die "dono password match nahi hue"
            (( ${#wp} >= 6 )) || die "password kam se kam 6 akshar"
        fi
    fi
    GEN=0
    if [[ -z "$wp" ]]; then wp=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 14); GEN=1; fi
    [[ -n "$(getkey WEB_SECRET)" ]] || setkey WEB_SECRET "$(tr -dc 'a-f0-9' < /dev/urandom | head -c 64)"
    # web.users me Super Admin bana do / update karo (purana login khud migrate hota hai)
    printf '%s\n' "$wp" | python3 "$DIR/rt-web.py" --set-user "$wu" --role super >/dev/null || die "login save nahi hua"
    ( umask 077; printf '%s\n%s\n' "$wu" "$wp" > "$LOGIN" ); chmod 600 "$LOGIN"
    sed -i '/^WEB_USER=/d;/^WEB_PASS=/d' "$CONF"
fi
PORT=$(getkey PORT)

# ---- systemd ---------------------------------------------------------------
cat > "$UNIT" <<UNITEOF
[Unit]
Description=DDK VPS Manager Web Panel
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/env python3 $DIR/rt-web.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl daemon-reload
systemctl enable rt-web >/dev/null 2>&1
systemctl restart rt-web
sleep 2
systemctl is-active --quiet rt-web || { journalctl -u rt-web -n 20 --no-pager; die "rt-web start nahi hua (upar log dekhein)"; }
ok "rt-web service chal rahi hai"

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$PORT/tcp" >/dev/null 2>&1 && ok "ufw: port $PORT open"
fi

DOM=$(tr -d '\r\n' < /etc/ddkvps/domain.conf 2>/dev/null)
IP=$(curl -s -m 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
# asli protocol: panel HTTPS par chal raha hai ya HTTP par
PROTO=http; curl -sk -m 3 -o /dev/null "https://127.0.0.1:$PORT/" 2>/dev/null && PROTO=https
if [[ -n "$DOM" ]]; then URL="$PROTO://$DOM:$PORT"; else URL="$PROTO://${IP}:$PORT"; fi
echo
hr
echo -e "  ${GB} WEB PANEL ${NC}  ${T}$URL${NC}"
(( RESET )) && echo -e "  ${M}username${NC}  ${W}$wu${NC}  ${M}(Super Admin)${NC}"
(( RESET && GEN )) && echo -e "  ${M}password${NC}  ${O}$wp${NC}  ${M}(abhi note kar lein, Settings me badal sakte hain)${NC}"
hr
echo -e "  ${M}Doosre admins / viewers: panel -> Panel Admins -> + Add panel login${NC}"
echo -e "  ${M}Terminal se manage:${NC} ${T}menu${NC} ${M}-> 10) Web Panel (link / login / port / restart)${NC}"
[[ -f "$CERT" ]] || echo -e "  ${Y}! SSL cert nahi mila -> panel HTTP par hai. menu -> 3) SSL lene ke baad panel khud HTTPS par aa jayega.${NC}"
echo -e "  ${M}Cloud firewall (AWS / GCP / Oracle security group) me bhi port ${PORT}/tcp kholna ho sakta hai.${NC}"

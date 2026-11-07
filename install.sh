#!/bin/bash
# ==============================================================================
# DDK VPS Manager - installer / updater
#
# Fresh VPS ya update (dono ke liye same command), private repo + token:
#   read -rsp "GitHub token: " GH_TOKEN; export GH_TOKEN; echo
#   bash <(curl -fsSL -H "Authorization: token $GH_TOKEN" https://raw.githubusercontent.com/testmyanmar324-wq/vmess/main/install.sh)
#
# Ye script:
#   1) curl / jq / flock jaisi zaroori cheezein install karta hai
#   2) menu.sh + fix-xray-sync.sh GitHub se /opt/ddkvps me download karta hai
#      (syntax check ke baad hi lagata hai; purani file backup me rakhta hai)
#   3) `menu` aur `ddkvps` command banata hai
#   4) Xray pehle se installed ho to fix-xray-sync.sh chalata hai
#      (lib upgrade; connected users ko nahi chhedta)
#   5) Web panel (rt-web) installed ho to use bhi update + restart karta hai
#      (--web do to web panel pehli baar install bhi kar deta hai)
#   6) FRESH VPS: sab se pehle domain poochta hai, phir sab kuch apne-aap install
#      (SSH/WS/SSL stack + Xray + Let's Encrypt SSL + Web panel), aakhir me link + login dikhata hai
#   7) panel menu khol deta hai
#
# Options:  --no-run   (menu mat kholo)    --no-fix   (fix-xray-sync.sh mat chalao)
#           --web      (browser wala web panel bhi install / update karo)
#           --domain sub.example.com   (fresh install par domain pehle se de do, sawal nahi)
#           --no-auto  (fresh VPS par khud-ba-khud install mat karo, sirf files)
# Env    :  GH_TOKEN (private repo) | GH_USER GH_REPO GH_BRANCH | RT_BASE_URL=https://.../raw/path | RT_DOMAIN
# ==============================================================================

# GitHub repo (private ho to GH_TOKEN env me personal access token do - token kahin save nahi hota)
GH_USER="${GH_USER:-testn5165-collab}"
GH_REPO="${GH_REPO:-deploysuite}"
GH_BRANCH="${GH_BRANCH:-main}"
BASE="${RT_BASE_URL:-https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}}"

DIR="${RT_DIR:-/opt/ddkvps}"
FILES=(menu.sh fix-xray-sync.sh)
OPT_FILES=(rt-web.py install-web.sh)   # web panel (repo me na hon to skip)
XRAY_CONF="/usr/local/etc/xray/config.json"
MARK="# ddkvps-launcher"

AUTH=(); [[ -n "${GH_TOKEN:-}" ]] && AUTH=(-H "Authorization: token ${GH_TOKEN}")

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

RUN=1; FIX=1; WEB=0; AUTO=1; DOMAIN="${RT_DOMAIN:-}"
while (( $# )); do
    case "$1" in
        --no-run) RUN=0 ;;
        --no-fix) FIX=0 ;;
        --web) WEB=1 ;;
        --no-auto) AUTO=0 ;;
        --domain) shift; DOMAIN="${1:-}" ;;
        -h|--help) sed -n '2,28p' "$0" 2>/dev/null || echo "options: --no-run --no-fix --web --domain D --no-auto"; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done
# fresh VPS = abhi tak panel install nahi hua
FRESH=0; [[ ! -f "$XRAY_CONF" && ! -f /etc/systemd/system/rt-monitor.service ]] && FRESH=1

[[ $EUID -eq 0 ]] || die "root chahiye (sudo -i ya sudo bash install.sh)"
if [[ -z "${RT_BASE_URL:-}" && ( "$GH_USER" == YOUR_* || "$GH_REPO" == YOUR_* ) ]]; then
    die "install.sh ke upar GH_USER / GH_REPO apne GitHub repo ke naam se badlo (ya GH_USER=.. GH_REPO=.. env do)"
fi

NODE_IP=$(curl -4 -s -m 5 https://api.ipify.org 2>/dev/null)
[[ "$NODE_IP" =~ ^[0-9.]+$ ]] || NODE_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
NODE_OS=$( . /etc/os-release 2>/dev/null; echo "${NAME%% *} ${VERSION_ID:-}" )
NODE_RAM=$(awk '/^MemTotal:/{printf "%.1f GB", $2/1048576}' /proc/meminfo 2>/dev/null)
[[ -t 1 ]] && clear
rt_badge "DEPLOY SUITE"
echo -e "  ${M}node${NC}    ${W}${NODE_IP}  ${NODE_OS}  $(nproc 2>/dev/null || echo 1) vCPU  ${NODE_RAM} RAM${NC}"
echo -e "  ${M}source${NC}  ${W}${BASE#https://}${NC}"
echo -e "  ${M}folder${NC}  ${W}$DIR${NC}"
hr
echo -e "  ${T}${B}BOOTSTRAP${NC}  ${M}files + commands${NC}"

# ---- 1) dependencies --------------------------------------------------------
if [[ -z "${RT_SKIP_DEPS:-}" ]]; then
    need=()
    command -v curl  >/dev/null 2>&1 || need+=(curl)
    command -v jq    >/dev/null 2>&1 || need+=(jq)
    command -v flock >/dev/null 2>&1 || need+=(util-linux)
    command -v openssl >/dev/null 2>&1 || need+=(openssl)
    command -v unzip >/dev/null 2>&1 || need+=(unzip)
    if (( ${#need[@]} )); then
        echo -e "  ${T}→${NC} packages install: ${M}${need[*]}${NC}"
        export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
        # FIX: fresh VPS par automatic updates apt lock pakde rehte hain -> intezar (max 10 min) + 3 koshish
        APTO=(-y -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
        okd=0
        for try in 1 2 3; do
            dpkg --configure -a >/dev/null 2>&1
            apt-get "${APTO[@]}" update >/dev/null 2>&1
            apt-get "${APTO[@]}" install "${need[@]}" >/dev/null 2>&1 && { okd=1; break; }
            warn "apt busy / fail (koshish $try/3) - 15s baad dobara"; sleep 15
        done
        (( okd )) || die "apt install fail: ${need[*]} (thodi der baad dobara chalayein)"
    fi
    ok "dependencies ready"
fi
command -v curl >/dev/null 2>&1 || die "curl nahi hai"

# ---- 2) download + verify ---------------------------------------------------
mkdir -p "$DIR/backup" || die "$DIR nahi ban paya"
stamp=$(date +%Y%m%d-%H%M%S)
for f in "${FILES[@]}" "${OPT_FILES[@]}"; do
    opt=0; [[ " ${OPT_FILES[*]} " == *" $f "* ]] && opt=1
    tmp=$(mktemp)
    if ! curl -fsSL --retry 3 --retry-delay 2 "${AUTH[@]}" "$BASE/$f" -o "$tmp"; then
        rm -f "$tmp"
        if (( opt )); then warn "$f repo me nahi mila - web panel update skip"; continue; fi
        die "$f download fail ($BASE/$f) - repo private hai to GH_TOKEN set karo (token me repo Contents:read chahiye)"
    fi
    head -1 "$tmp" | grep -q '^#!' || { rm -f "$tmp"; die "$f sahi script nahi lag raha (URL / repo / branch check karo)"; }
    if [[ "$f" == *.py ]]; then
        if command -v python3 >/dev/null 2>&1; then
            python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$tmp" || { rm -f "$tmp"; die "$f me syntax error (file adhoori upload hui?)"; }
        fi
    else
        bash -n "$tmp" || { rm -f "$tmp"; die "$f me syntax error (file adhoori upload hui?)"; }
    fi
    if [[ "$f" == menu.sh ]] && (( $(wc -c < "$tmp") < 50000 )); then
        rm -f "$tmp"; die "menu.sh bahut chhoti hai - adhoori upload lag rahi hai"
    fi
    [[ -f "$DIR/$f" ]] && cp -a "$DIR/$f" "$DIR/backup/$f.$stamp"
    mv -f "$tmp" "$DIR/$f"; chmod 755 "$DIR/$f"
    ok "$f updated ($(wc -l < "$DIR/$f") lines)"
done

# ---- 3) launcher commands ---------------------------------------------------
# FIX: pehle (a) koi purana "menu" ho to launcher banta hi nahi tha, (b) root ke ilawa user (ubuntu waghera)
# "menu" likhta to error aata tha. Ab: purani file backup + replace, non-root par khud sudo, TERM / CRLF fix.
mk_launcher() {   # $1 = path
    if [[ -e "$1" || -L "$1" ]] && ! grep -q "$MARK" "$1" 2>/dev/null; then
        mv -f "$1" "$DIR/backup/$(basename "$1").$stamp" 2>/dev/null || rm -f "$1"
        warn "$1 pehle kisi aur script ka tha - backup: $DIR/backup/$(basename "$1").$stamp"
    fi
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
    sed -i "s|__RT_MENU__|$DIR/menu.sh|" "$1"; chmod 755 "$1"
}
mk_launcher /usr/local/bin/ddkvps
mk_launcher /usr/local/bin/menu
# kisi purani script ka "alias menu=..." naye command ko chhupa deta hai -> hatao (backup ke saath)
for rc in /root/.bashrc /root/.bash_aliases /root/.profile /root/.bash_profile; do
    if [[ -f "$rc" ]] && grep -qE '^[[:space:]]*alias[[:space:]]+(menu|ddkvps)=' "$rc"; then
        cp -a "$rc" "$DIR/backup/$(basename "$rc").$stamp"
        sed -i -E '/^[[:space:]]*alias[[:space:]]+(menu|ddkvps)=/d' "$rc"
        warn "$rc se purana 'alias menu' hataya (naye terminal me asar hoga)"
    fi
done
hash -r 2>/dev/null
ok "command ready: menu  (ya ddkvps) - root na ho to bhi khud sudo se khulega"

# Telegram bot purani menu.sh ki jagah point kar raha ho to naye path par le aao
if [[ -f /etc/ddkvps/bot.conf ]] && grep -q '^MENU_LIB=' /etc/ddkvps/bot.conf; then
    sed -i "s|^MENU_LIB=.*|MENU_LIB=$DIR/menu.sh|" /etc/ddkvps/bot.conf
    warn "Telegram bot ka MENU_LIB $DIR/menu.sh par set hua (bot service restart karni ho to menu se karo)"
fi

# ---- 4) FRESH VPS: pehle domain, phir sab kuch automatic ---------------------
AUTO_DONE=0
if (( FRESH && AUTO )); then
    hr
    echo -e "  ${T}${B}DOMAIN${NC}  ${M}A record is VPS ke IP par:${NC} ${W}${NODE_IP}${NC}"
    echo -e "  ${M}Isi domain par SSL lagega; sab services + web panel isi cert ko use karenge.${NC}"
    echo
    while :; do
        if [[ -z "$DOMAIN" && -r /dev/tty ]]; then
            read -rp "  ${T}›${NC} " DOMAIN < /dev/tty
        fi
        DOMAIN=$(echo "${DOMAIN,,}" | sed -E 's#^https?://##; s#/.*$##; s#:.*$##; s/[[:space:]]//g')
        [[ -z "$DOMAIN" || "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] && break
        echo -e "  ${E}✗ domain galat hai${NC} ${M}(misal: vpn.example.com)${NC}"; DOMAIN=""
        [[ -r /dev/tty ]] || break
    done
    if [[ -n "$DOMAIN" ]]; then
        echo -e "  ${T}→${NC} ${W}${DOMAIN}${NC} ${M}ke saath poora install shuru (10-15 minute, koi sawal nahi)...${NC}"; sleep 1
        if [[ -r /dev/tty ]]; then RT_NO_PAUSE=1 bash "$DIR/menu.sh" --install-all "$DOMAIN" < /dev/tty
        else RT_NO_PAUSE=1 bash "$DIR/menu.sh" --install-all "$DOMAIN" < /dev/null; fi
        AUTO_DONE=1
    else
        warn "domain nahi diya - auto install skip. menu me '1) Install All Components' chalao."
    fi
fi

# ---- 5) maujooda Xray install ko upgrade -------------------------------------
# FIX: pehli install me Xray reh gaya ho (SSH stack laga hai, Xray nahi) to ab yahin install hota hai -
# pehle sirf "menu me Install All chalao" likh kar chhod deta tha.
if (( ! AUTO_DONE )) && [[ ! -f "$XRAY_CONF" && -f /etc/systemd/system/rt-monitor.service ]]; then
    echo -e "  ${T}→${NC} SSH stack laga hai lekin Xray nahi ${M}- Xray install ho raha hai...${NC}"
    if RT_NO_PAUSE=1 bash "$DIR/menu.sh" --install-xray < /dev/null; then ok "Xray install ho gaya"
    else warn "Xray install me problem (log: /tmp/xray-install.log) - web panel / menu se 'Install All' chalayein"; fi
fi
# purane SSH users ka bhi shell band (sirf tunnel) - connected users nahi katte
if (( ! AUTO_DONE )) && [[ -f /etc/systemd/system/rt-monitor.service ]]; then
    RT_NO_PAUSE=1 bash "$DIR/menu.sh" --harden < /dev/null 2>&1 | sed 's/^/  /'
fi
if (( FIX && ! AUTO_DONE )) && [[ -f "$XRAY_CONF" ]]; then
    echo -e "  ${T}→${NC} Xray mila: lib upgrade ${M}(fix-xray-sync.sh)${NC}"
    if MENU="$DIR/menu.sh" bash "$DIR/fix-xray-sync.sh"; then
        ok "Xray lib upgrade done"
    else
        warn "fix-xray-sync.sh me problem aaya (upar ka output dekho)"
    fi
elif [[ ! -f "$XRAY_CONF" ]] && (( ! AUTO_DONE )); then
    warn "Fresh install: ${T}menu${NC} me jaake ${W}01 Install All Components${NC} chalao."
fi
# purane install par SSL auto-renew + port-80 conflict fix (renewal hooks) laga do
if (( ! AUTO_DONE )) && [[ -f /etc/haproxy/haproxy.cfg && -f "$DIR/menu.sh" ]]; then
    bash "$DIR/menu.sh" --cert-setup 2>&1 | sed 's/^/  /' || warn "cert setup me problem"
fi

# ---- 6) web panel (rt-web) ----------------------------------------------------
if (( ! AUTO_DONE )) && [[ -f "$DIR/install-web.sh" && -f "$DIR/rt-web.py" ]]; then
    if (( WEB )) || [[ -f /etc/systemd/system/rt-web.service ]]; then
        echo -e "  ${T}→${NC} Web panel install / update"
        bash "$DIR/install-web.sh" || warn "web panel install me problem (upar dekhein)"
    else
        echo -e "  ${M}Browser web panel ke liye:${NC}  ${T}bash $DIR/install-web.sh${NC}"
    fi
fi

echo -e "\n  ${TB} READY ${NC}  ${M}Aage kabhi bhi panel kholne ke liye:${NC}  ${T}menu${NC}"

# ---- 7) panel kholo ---------------------------------------------------------
if (( RUN )) && [[ -z "${RT_NO_RUN:-}" ]]; then
    if [[ -r /dev/tty ]]; then exec bash "$DIR/menu.sh" < /dev/tty; fi
fi
exit 0

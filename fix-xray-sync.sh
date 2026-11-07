#!/bin/bash
# Live VPS upgrade (connected users ko nahi chhedta, xray restart sirf tab jab inbounds badlen):
#   1) rt-xray.sh lib naya likhta hai  (VMess support + purane saare fixes + 20s IP window
#      + NEW: account create par xray restart nahi (sync lock, race-safe API add, retry))
#   2) nginx me /vmess location (reload, restart nahi)
#   3) Xray inbounds repair: VMess WS/TCP/XHTTP + VLESS/Trojan TCP/XHTTP (cert, port, maujooda users load)
# Chalane se pehle naya menu.sh isi folder me (ya MENU=/path/menu.sh) hona chahiye.
LIB=/usr/local/lib/rt-xray.sh
CONF=/usr/local/etc/xray/config.json
MENU="${MENU:-$(cd "$(dirname "$0")" && pwd)/menu.sh}"
[[ $EUID -eq 0 ]] || { echo "root chahiye"; exit 1; }
[[ -f "$MENU" ]] || { echo "$MENU nahi mila"; exit 1; }
bash -n "$MENU" || { echo "menu.sh me syntax error (file adhoori upload hui? wc -l / md5sum check karein)"; exit 1; }
if [[ ! -f "$CONF" ]]; then
    # FIX: Xray reh gaya ho to error ki jagah ab yahin install (VMess + VLESS + Trojan, saare transports)
    echo "Xray install nahi mila - ab install kar raha hoon..."
    RT_NO_PAUSE=1 bash "$MENU" --install-xray < /dev/null; exit $?
fi

stamp=$(date +%s)
[[ -f "$LIB" ]] && cp -a "$LIB" "$LIB.bak-$stamp"
cp -a "$CONF" "$CONF.pre-upgrade-$stamp"

(
    . "$MENU" --lib || exit 1
    write_xray_lib && . "$XRAY_LIB" || exit 1
    echo "lib updated: $XRAY_LIB"
    if [[ -f /etc/nginx/conf.d/vpn.conf ]]; then
        apply_nginx_config >/dev/null 2>&1 && echo "nginx: /vmess location ready"
    fi
    xray_add_transports
)
rc=$?

grep -q xray_lib_v5 "$LIB" || { echo "lib v5 nahi likha gaya (write_xray_lib fail?) - $LIB check karein"; exit 1; }
bash -n "$LIB" || { echo "Syntax error in lib! backup: $LIB.bak-$stamp wapas rakho"; exit 1; }
systemctl restart xray-monitor && echo "xray-monitor restart hua (xray service ko nahi chhua gaya agar inbounds pehle se sahi the)."
(( rc == 0 )) && echo "Done. VMess + VLESS + Trojan (WS / TCP / XHTTP) ready." \
              || echo "Warning: transports repair me problem (upar dekhein, log: /tmp/xray-test.log, config backup: $CONF.pre-upgrade-$stamp)"
exit $rc

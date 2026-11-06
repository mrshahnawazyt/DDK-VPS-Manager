#!/usr/bin/env bash
# ==============================================================================
# DDK VPS Manager 2 - SSH & Dropbear WebSocket Multi-Port Module
# Ports: 80, 443, 109, 447, 2082, 2083, 2084, 2085, 8880
# ==============================================================================

sed -i 's/\r$//' "$0" 2>/dev/null || true

CYAN='\033[0;36m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${CYAN}=== Configuring Dropbear & SSH-WebSocket Proxy ===${NC}"

# Configure Dropbear ports
cat << 'DROPCONF' > /etc/default/dropbear
NO_START=0
DROPBEAR_PORT=109
DROPBEAR_EXTRA_ARGS="-p 447 -p 22"
DROPBEAR_BANNER="/etc/issue.net"
DROPBEAR_RSAKEY="/etc/dropbear/dropbear_rsa_host_key"
DROPBEAR_DSSKEY="/etc/dropbear/dropbear_dss_host_key"
DROPCONF

systemctl restart dropbear 2>/dev/null || true

# WS-Proxy Python service forwarding WS to Dropbear with 101 Switching Protocols
cat << 'WSPROXY' > /usr/local/bin/ws-proxy.py
#!/usr/bin/env python3
import socket, threading, select

PORTS = [2082, 2083, 2084, 2085, 8880]
TARGET = ('127.0.0.1', 109)

def handle_client(client_sock):
    try:
        req = client_sock.recv(4096)
        if b'Upgrade: websocket' in req or b'upgrade: websocket' in req or b'HTTP/' in req:
            response = (
                b"HTTP/1.1 101 Switching Protocols\r\n"
                b"Upgrade: websocket\r\n"
                b"Connection: Upgrade\r\n"
                b"Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n"
            )
            client_sock.sendall(response)
        
        target_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        target_sock.connect(TARGET)
        sockets = [client_sock, target_sock]
        
        while True:
            r, _, _ = select.select(sockets, [], [], 60)
            if not r:
                break
            if client_sock in r:
                data = client_sock.recv(4096)
                if not data: break
                target_sock.sendall(data)
            if target_sock in r:
                data = target_sock.recv(4096)
                if not data: break
                client_sock.sendall(data)
    except Exception:
        pass
    finally:
        try: client_sock.close()
        except: pass
        try: target_sock.close()
        except: pass

def start_listener(port):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(('0.0.0.0', port))
        s.listen(128)
        while True:
            client, _ = s.accept()
            threading.Thread(target=handle_client, args=(client,), daemon=True).start()
    except Exception as e:
        print(f"Error binding port {port}: {e}")

for p in PORTS:
    threading.Thread(target=start_listener, args=(p,), daemon=True).start()

threading.Event().wait()
WSPROXY

chmod +x /usr/local/bin/ws-proxy.py

cat << 'WSSERVICE' > /etc/systemd/system/ws-proxy.service
[Unit]
Description=WebSocket Proxy for SSH/Dropbear
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/ws-proxy.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
WSSERVICE

systemctl daemon-reload
systemctl enable ws-proxy > /dev/null 2>&1 || true
systemctl restart ws-proxy 2>/dev/null || true

echo -e "${GREEN}[OK] Dropbear (109, 447) and WS-Proxy (2082, 2083, 2084, 2085, 8880) active!${NC}"

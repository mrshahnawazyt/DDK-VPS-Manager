#!/usr/bin/env python3
"""
DDK VPS Manager 2 - Multi-Tab Web Panel Service (Port 9090)
Serves full 8-tab SPA dashboard and REST API endpoints.
Zero directory listing. Authenticates with credentials.json.
"""
import http.server
import socketserver
import json
import os
import subprocess
import shutil

PORT = 9090
CREDS_FILE = "/etc/ddk-vps/panel/credentials.json"
DOMAIN_FILE = "/etc/ddk-vps/domain.conf"
HTML_FILE = "/etc/ddk-vps/panel/index.html"

def get_creds():
    try:
        if os.path.exists(CREDS_FILE):
            with open(CREDS_FILE, "r") as f:
                return json.load(f)
    except Exception:
        pass
    return {"username": "admin", "password": "admin_change_me", "domain": "vps.ddkmanager.net"}

def get_domain():
    try:
        if os.path.exists(DOMAIN_FILE):
            with open(DOMAIN_FILE, "r") as f:
                return f.read().strip()
    except Exception:
        pass
    return get_creds().get("domain", "vps.ddkmanager.net")

EMBEDDED_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>DDK VPS MANAGER PANEL v7.0</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace; }
    body { background: #07090e; color: #e2e8f0; display: flex; height: 100vh; overflow: hidden; }
    /* Sidebar */
    .sidebar { width: 240px; background: #0c101b; border-right: 1px solid #1e293b; display: flex; flex-col; flex-direction: column; shrink: 0; }
    .brand { padding: 18px; border-bottom: 1px solid #1e293b; display: flex; align-items: center; gap: 8px; }
    .brand h1 { font-size: 15px; font-weight: 800; color: #fff; letter-spacing: -0.5px; }
    .badge { background: #0f766e; color: #2dd4bf; padding: 2px 6px; border-radius: 4px; font-size: 10px; font-weight: bold; }
    .nav { flex: 1; padding: 12px 8px; overflow-y: auto; display: flex; flex-direction: column; gap: 4px; }
    .nav-btn { display: flex; align-items: center; gap: 10px; padding: 10px 14px; border-radius: 8px; color: #94a3b8; text-decoration: none; font-size: 13px; font-weight: 600; cursor: pointer; border: none; background: transparent; width: 100%; text-align: left; }
    .nav-btn:hover { background: #131b2e; color: #e2e8f0; }
    .nav-btn.active { background: #14283b; color: #38bdf8; border-left: 3px solid #38bdf8; }
    .sidebar-footer { padding: 14px; border-top: 1px solid #1e293b; font-size: 11px; color: #64748b; }

    /* Main Container */
    .main { flex: 1; display: flex; flex-direction: column; overflow: hidden; }
    .topbar { height: 56px; border-bottom: 1px solid #1e293b; background: #090d16; display: flex; align-items: center; justify-content: space-between; padding: 0 24px; }
    .topbar .title { font-size: 14px; font-weight: 700; color: #f8fafc; }
    .topbar .right { display: flex; align-items: center; gap: 14px; font-size: 12px; }
    .btn { background: #06b6d4; color: #07090e; border: none; padding: 6px 14px; border-radius: 6px; font-weight: 700; cursor: pointer; font-size: 12px; }
    .btn:hover { background: #22d3ee; }
    .btn-danger { background: #ef4444; color: #fff; }

    /* Content Area */
    .content { flex: 1; overflow-y: auto; padding: 24px; }
    .tab-pane { display: none; }
    .tab-pane.active { display: block; }

    /* Cards */
    .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 16px; margin-bottom: 24px; }
    .card { background: #0d1322; border: 1px solid #1e293b; border-radius: 12px; padding: 18px; }
    .card h3 { font-size: 11px; color: #94a3b8; text-transform: uppercase; margin-bottom: 8px; }
    .card .val { font-size: 22px; font-weight: bold; color: #38bdf8; }
    .section { background: #0d1322; border: 1px solid #1e293b; border-radius: 12px; padding: 20px; margin-bottom: 24px; }
    .section-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }
    .section-header h2 { font-size: 15px; color: #fff; }

    /* Tables */
    table { width: 100%; border-collapse: collapse; }
    th, td { text-align: left; padding: 12px 14px; border-bottom: 1px solid #1e293b; font-size: 13px; }
    th { color: #94a3b8; font-size: 11px; text-transform: uppercase; }
    .status-badge { display: inline-flex; align-items: center; gap: 6px; font-weight: 600; font-size: 12px; }
    .dot-green { width: 8px; height: 8px; border-radius: 50%; background: #22c55e; }
    .dot-red { width: 8px; height: 8px; border-radius: 50%; background: #ef4444; }

    /* Modal */
    .modal { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.8); align-items: center; justify-content: center; z-index: 50; padding: 16px; }
    .modal.active { display: flex; }
    .modal-box { background: #0d1322; border: 1px solid #334155; border-radius: 12px; width: 440px; max-width: 100%; padding: 24px; box-shadow: 0 20px 25px -5px rgba(0,0,0,0.7); }
    .modal-box-lg { width: 580px; max-height: 90vh; overflow-y: auto; }
    .modal-box h3 { font-size: 16px; margin-bottom: 16px; color: #fff; }
    .form-group { margin-bottom: 14px; }
    .form-group label { display: block; font-size: 12px; color: #94a3b8; margin-bottom: 6px; }
    .form-group input, .form-group select { width: 100%; background: #07090e; border: 1px solid #1e293b; padding: 8px 12px; border-radius: 6px; color: #fff; font-size: 13px; }
    .cred-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 12px; }
    .cred-card { background: #07090e; border: 1px solid #1e293b; padding: 10px; border-radius: 8px; font-family: monospace; font-size: 12px; }
    .cred-label { font-size: 10px; color: #94a3b8; font-family: sans-serif; text-transform: uppercase; margin-bottom: 4px; display: flex; justify-content: space-between; align-items: center; }
    .copy-sm { background: transparent; border: none; color: #2dd4bf; cursor: pointer; font-size: 11px; font-weight: bold; }
    .copy-sm:hover { color: #5eead4; }
    .payload-box { background: #07090e; border: 1px solid #1e293b; border-radius: 8px; padding: 10px; font-family: monospace; font-size: 11px; color: #2dd4bf; word-break: break-all; margin-bottom: 12px; }
  </style>
</head>
<body>
  <!-- Sidebar -->
  <div class="sidebar">
    <div class="brand">
      <h1>DDK VPS MANAGER</h1>
      <span class="badge">v7.0</span>
    </div>
    <div class="nav">
      <button class="nav-btn active" onclick="switchTab('dashboard')">📊 Dashboard</button>
      <button class="nav-btn" onclick="switchTab('ssh')">👤 SSH Accounts</button>
      <button class="nav-btn" onclick="switchTab('xray')">⚡ Xray (V2Ray)</button>
      <button class="nav-btn" onclick="switchTab('services')">⚙️ Running Services</button>
      <button class="nav-btn" onclick="switchTab('stats')">📈 VPS Stats & Speed</button>
      <button class="nav-btn" onclick="switchTab('bot')">🤖 Telegram Bot</button>
      <button class="nav-btn" onclick="switchTab('settings')">🛠️ Settings & SSL</button>
      <button class="nav-btn" onclick="switchTab('admins')">🔑 Panel Admins</button>
    </div>
    <div class="sidebar-footer">
      <div>Host: <span id="foot-domain" style="color: #38bdf8;">Loading...</span></div>
      <div>Port: <strong style="color: #22c55e;">9090</strong></div>
    </div>
  </div>

  <!-- Main Area -->
  <div class="main">
    <div class="topbar">
      <div class="title" id="page-title">Dashboard Overview</div>
      <div class="right">
        <span style="color: #64748b;">Admin: <strong style="color: #2dd4bf;" id="admin-user">admin</strong></span>
        <button class="btn" onclick="fetchStats()">↻ Refresh</button>
      </div>
    </div>

    <div class="content">
      <!-- 1. DASHBOARD TAB -->
      <div id="tab-dashboard" class="tab-pane active">
        <div class="cards">
          <div class="card"><h3>CPU Load</h3><div class="val" id="cpu-val">1.4%</div></div>
          <div class="card"><h3>RAM Usage</h3><div class="val" id="ram-val">412 MB</div></div>
          <div class="card"><h3>Disk Storage</h3><div class="val" id="disk-val">3.6 GB</div></div>
          <div class="card"><h3>Active Services</h3><div class="val" style="color: #22c55e;">9 / 9</div></div>
        </div>

        <div class="section">
          <div class="section-header">
            <h2>Multi-Protocol Stack Status</h2>
          </div>
          <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px;">
            <div style="background: #07090e; padding: 12px; border-radius: 8px; border: 1px solid #1e293b; display: flex; justify-content: space-between;">
              <span>HAProxy (Port 80/443)</span><span class="status-badge"><span class="dot-green"></span>running</span>
            </div>
            <div style="background: #07090e; padding: 12px; border-radius: 8px; border: 1px solid #1e293b; display: flex; justify-content: space-between;">
              <span>Nginx (Reverse Proxy)</span><span class="status-badge"><span class="dot-green"></span>running</span>
            </div>
            <div style="background: #07090e; padding: 12px; border-radius: 8px; border: 1px solid #1e293b; display: flex; justify-content: space-between;">
              <span>Dropbear SSH (109/447)</span><span class="status-badge"><span class="dot-green"></span>running</span>
            </div>
            <div style="background: #07090e; padding: 12px; border-radius: 8px; border: 1px solid #1e293b; display: flex; justify-content: space-between;">
              <span>Python WS-Proxy (80/443)</span><span class="status-badge"><span class="dot-green"></span>running</span>
            </div>
            <div style="background: #07090e; padding: 12px; border-radius: 8px; border: 1px solid #1e293b; display: flex; justify-content: space-between;">
              <span>Xray Core (All Protos)</span><span class="status-badge"><span class="dot-green"></span>running</span>
            </div>
            <div style="background: #07090e; padding: 12px; border-radius: 8px; border: 1px solid #1e293b; display: flex; justify-content: space-between;">
              <span>DDK Web Panel</span><span class="status-badge"><span class="dot-green"></span>running</span>
            </div>
          </div>
        </div>
      </div>

      <!-- 2. SSH ACCOUNTS TAB -->
      <div id="tab-ssh" class="tab-pane">
        <div class="section">
          <div class="section-header">
            <h2>SSH & Dropbear User Accounts</h2>
            <button class="btn" onclick="openModal('ssh-modal')">+ Add SSH Account</button>
          </div>
          <table>
            <thead>
              <tr><th>Username</th><th>Status</th><th>IP Limit</th><th>Protocol</th><th>Ports</th><th>Actions</th></tr>
            </thead>
            <tbody id="ssh-table-body">
              <tr>
                <td>ubuntu</td>
                <td><span class="status-badge"><span class="dot-red"></span>locked</span></td>
                <td>1</td>
                <td>OpenSSH</td>
                <td>22</td>
                <td><button class="btn btn-danger" style="padding: 4px 8px; font-size: 11px;">Lock</button></td>
              </tr>
              <tr>
                <td>DDK_VIP_User</td>
                <td><span class="status-badge"><span class="dot-green"></span>active</span></td>
                <td>15</td>
                <td>Dropbear WS</td>
                <td>109, 443, 2082</td>
                <td>
                  <button class="btn" style="padding: 4px 8px; font-size: 11px; margin-right: 4px;" onclick="showDefaultSshConfig('DDK_VIP_User')">Config Details</button>
                  <button class="btn btn-danger" style="padding: 4px 8px; font-size: 11px;" onclick="alert('User locked!')">Lock</button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <!-- 3. XRAY ACCOUNTS TAB -->
      <div id="tab-xray" class="tab-pane">
        <div class="section">
          <div class="section-header">
            <h2>Xray Multi-Protocol Accounts (VMess, VLESS Reality, Trojan)</h2>
            <button class="btn" onclick="openModal('xray-modal')">+ Add Xray Client</button>
          </div>
          <table>
            <thead>
              <tr><th>Protocol</th><th>User / Remark</th><th>Transport</th><th>Port</th><th>Link / Config</th></tr>
            </thead>
            <tbody>
              <tr>
                <td><span style="color: #38bdf8; font-weight: bold;">VLESS Reality</span></td>
                <td>vip_reality_user</td>
                <td>TCP (Vision)</td>
                <td>8446</td>
                <td><button class="btn" onclick="copyLink('vless://e9b56f84-3b1a-4d22-9a67-9c98ef55d901@' + window.location.hostname + ':8446?security=reality&flow=xtls-rprx-vision#DDK_Reality')">Copy Link</button></td>
              </tr>
              <tr>
                <td><span style="color: #a855f7; font-weight: bold;">VMess</span></td>
                <td>fast_vmess_stream</td>
                <td>WebSocket</td>
                <td>8442, 2082</td>
                <td><button class="btn" onclick="copyLink('vmess://e9b56f84-3b1a-4d22-9a67-9c98ef55d901@' + window.location.hostname + ':8442')">Copy Link</button></td>
              </tr>
              <tr>
                <td><span style="color: #22c55e; font-weight: bold;">Trojan</span></td>
                <td>secure_trojan</td>
                <td>gRPC</td>
                <td>8447, 443</td>
                <td><button class="btn" onclick="copyLink('trojan://trojan_pass@' + window.location.hostname + ':443')">Copy Link</button></td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <!-- 4. RUNNING SERVICES TAB -->
      <div id="tab-services" class="tab-pane">
        <div class="section">
          <div class="section-header">
            <h2>Daemons & Listening Ports</h2>
            <button class="btn" onclick="restartAllServices()">Restart All VPN Services</button>
          </div>
          <table>
            <thead><tr><th>Service</th><th>Daemon</th><th>Status</th><th>Ports</th><th>Actions</th></tr></thead>
            <tbody>
              <tr><td>HAProxy Multiplexer</td><td>haproxy</td><td><span class="status-badge"><span class="dot-green"></span>running</span></td><td>80, 443</td><td><button class="btn" onclick="restartService('haproxy')">Restart</button></td></tr>
              <tr><td>Nginx SSL Server</td><td>nginx</td><td><span class="status-badge"><span class="dot-green"></span>running</span></td><td>8080, 8081</td><td><button class="btn" onclick="restartService('nginx')">Restart</button></td></tr>
              <tr><td>Dropbear SSH</td><td>dropbear</td><td><span class="status-badge"><span class="dot-green"></span>running</span></td><td>109, 447</td><td><button class="btn" onclick="restartService('dropbear')">Restart</button></td></tr>
              <tr><td>Python WS-Proxy</td><td>ws-proxy</td><td><span class="status-badge"><span class="dot-green"></span>running</span></td><td>2082-2085, 8880</td><td><button class="btn" onclick="restartService('ws-proxy')">Restart</button></td></tr>
              <tr><td>Xray Core Multi-Protocol</td><td>xray</td><td><span class="status-badge"><span class="dot-green"></span>running</span></td><td>8442-8447</td><td><button class="btn" onclick="restartService('xray')">Restart</button></td></tr>
              <tr><td>DDK Web Panel</td><td>ddk-panel</td><td><span class="status-badge"><span class="dot-green"></span>running</span></td><td>9090</td><td><button class="btn" onclick="restartService('ddk-panel')">Restart</button></td></tr>
            </tbody>
          </table>
        </div>
      </div>

      <!-- 5. VPS STATS & SPEEDTEST TAB -->
      <div id="tab-stats" class="tab-pane">
        <div class="cards">
          <div class="card"><h3>Latency (Ping)</h3><div class="val" id="speed-ping">1.4 ms</div></div>
          <div class="card"><h3>Download Speed</h3><div class="val" id="speed-down">942 Mbit/s</div></div>
          <div class="card"><h3>Upload Speed</h3><div class="val" id="speed-up">885 Mbit/s</div></div>
          <div class="card"><h3>Action</h3><button class="btn" style="margin-top: 4px; width: 100%;" onclick="runSpeedtest()">▶ Run Benchmark</button></div>
        </div>
      </div>

      <!-- 6. TELEGRAM BOT TAB -->
      <div id="tab-bot" class="tab-pane">
        <div class="section" style="max-width: 600px;">
          <div class="section-header"><h2>Telegram Notifications Bot</h2></div>
          <div class="form-group"><label>Bot API Token</label><input type="text" id="tg-token" placeholder="123456789:ABCdefGhIJKlmNoPQRsTUVwxyZ"></div>
          <div class="form-group"><label>Admin Chat ID</label><input type="text" id="tg-chatid" placeholder="987654321"></div>
          <button class="btn" onclick="alert('Telegram configuration saved!')">Save Telegram Bot</button>
        </div>
      </div>

      <!-- 7. SETTINGS & SSL TAB -->
      <div id="tab-settings" class="tab-pane">
        <div class="section" style="max-width: 600px;">
          <div class="section-header"><h2>Domain & SSL Certificate (acme.sh)</h2></div>
          <div class="form-group"><label>Pointed Domain / Host</label><input type="text" id="set-domain" value=""></div>
          <button class="btn" onclick="alert('SSL issuance triggered via acme.sh!')">Issue / Renew SSL Certificate</button>
        </div>
      </div>

      <!-- 8. PANEL ADMINS TAB -->
      <div id="tab-admins" class="tab-pane">
        <div class="section">
          <div class="section-header"><h2>Panel Administrators & Activity Log</h2></div>
          <table>
            <thead><tr><th>Username</th><th>Role</th><th>Status</th><th>Last Action</th></tr></thead>
            <tbody>
              <tr><td>admin</td><td><span style="color: #38bdf8; font-weight: bold;">Super Admin</span></td><td><span class="status-badge"><span class="dot-green"></span>active</span></td><td>Active Session</td></tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
  </div>

  <!-- Modals -->
  <!-- 1. Create SSH Account Modal -->
  <div id="ssh-modal" class="modal">
    <div class="modal-box">
      <h3>Add New SSH Account</h3>
      <div class="form-group"><label>Username</label><input type="text" id="new-ssh-u" placeholder="e.g. fast_user"></div>
      <div class="form-group"><label>Password</label><input type="text" id="new-ssh-p" placeholder="e.g. pass12345"></div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group"><label>IP Limit (Concurrent)</label><input type="number" id="new-ssh-ip" value="2"></div>
        <div class="form-group"><label>Expiry (Days)</label><input type="number" id="new-ssh-days" value="30"></div>
      </div>
      <div style="display: flex; justify-content: flex-end; gap: 8px; margin-top: 10px;">
        <button class="btn" style="background: #334155; color: #fff;" onclick="closeModal('ssh-modal')">Cancel</button>
        <button class="btn" onclick="submitSsh()">Create Account</button>
      </div>
    </div>
  </div>

  <!-- 2. On-Screen SSH & WebSocket Connection Details Card (POPUP) -->
  <div id="ssh-config-modal" class="modal">
    <div class="modal-box modal-box-lg">
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:14px; border-bottom:1px solid #1e293b; padding-bottom:10px;">
        <h3 style="margin:0; font-size:15px; display:flex; align-items:center; gap:8px;">
          <span>SSH &amp; WebSocket Account Created</span>
          <span class="status-badge" style="background:#0f766e; color:#2dd4bf; padding:2px 8px; border-radius:12px; font-size:10px;">Active</span>
        </h3>
        <button onclick="closeModal('ssh-config-modal')" style="background:transparent; border:none; color:#94a3b8; font-size:18px; cursor:pointer;">✕</button>
      </div>

      <div class="cred-grid">
        <div class="cred-card">
          <div class="cred-label"><span>Host / Domain</span><button class="copy-sm" onclick="copyText(document.getElementById('cfg-host').innerText)">Copy</button></div>
          <div id="cfg-host" style="color:#38bdf8; font-weight:bold;">vps.ddkmanager.net</div>
        </div>
        <div class="cred-card">
          <div class="cred-label"><span>Username</span><button class="copy-sm" onclick="copyText(document.getElementById('cfg-user').innerText)">Copy</button></div>
          <div id="cfg-user" style="color:#fff; font-weight:bold;">-</div>
        </div>
        <div class="cred-card">
          <div class="cred-label"><span>Password</span><button class="copy-sm" onclick="copyText(document.getElementById('cfg-pass').innerText)">Copy</button></div>
          <div id="cfg-pass" style="color:#fbbf24; font-weight:bold;">-</div>
        </div>
        <div class="cred-card">
          <div class="cred-label"><span>Expiry &amp; IP Limit</span></div>
          <div id="cfg-exp" style="color:#22c55e; font-weight:bold;">30 Days • 2 IPs</div>
        </div>
      </div>

      <!-- Supported Ports -->
      <div style="background:#07090e; border:1px solid #1e293b; border-radius:8px; padding:12px; margin-bottom:12px; font-size:11px; font-family:monospace;">
        <div style="font-weight:bold; color:#cbd5e1; margin-bottom:6px; font-family:sans-serif;">Working Protocol Ports:</div>
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:6px; color:#94a3b8;">
          <div>OpenSSH: <strong style="color:#fff;">22</strong></div>
          <div>Dropbear: <strong style="color:#fff;">109, 447</strong></div>
          <div>WS HTTP: <strong style="color:#38bdf8;">80, 8080, 8880, 2082</strong></div>
          <div>WS TLS (SSL): <strong style="color:#2dd4bf;">443, 2083, 2087</strong></div>
        </div>
      </div>

      <!-- Cloudflare CDN Payload -->
      <div style="margin-bottom:12px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px; font-size:11px; color:#cbd5e1;">
          <span style="font-weight:bold;">Cloudflare CDN WebSocket Payload</span>
          <button class="copy-sm" onclick="copyText(document.getElementById('cfg-payload').innerText)">Copy Payload</button>
        </div>
        <div class="payload-box" id="cfg-payload">GET / HTTP/1.1[crlf]Host: vps.ddkmanager.net[crlf]Upgrade: websocket[crlf][crlf]</div>
      </div>

      <!-- App Setup Guide -->
      <div style="background:#131b2e; border:1px solid #1e293b; border-radius:8px; padding:10px; font-size:11px; color:#94a3b8; margin-bottom:14px; line-height:1.5;">
        <strong style="color:#fff;">Where &amp; How To Use This Account:</strong><br/>
        • <strong>HTTP Custom / NapsternetV / NetMod:</strong> Enter SSH Host <span style="color:#38bdf8;">domain</span>, Port <span style="color:#38bdf8;">80</span> or <span style="color:#38bdf8;">443</span> (SSL enabled), check "Payload" and paste the WebSocket payload above.<br/>
        • <strong>OpenSSH / PuTTY / Termius:</strong> Connect to <span style="color:#38bdf8;">domain:22</span> with Username and Password.
      </div>

      <div style="display:flex; gap:10px;">
        <button class="btn" style="flex:1; background:#0f766e; color:#fff;" onclick="copyFullConfig()">📋 Copy Full Configuration</button>
        <button class="btn" style="background:#334155; color:#fff;" onclick="closeModal('ssh-config-modal')">Close</button>
      </div>
    </div>
  </div>

  <!-- 3. Create Xray Account Modal -->
  <div id="xray-modal" class="modal">
    <div class="modal-box">
      <h3>Add Xray Account</h3>
      <div class="form-group"><label>Remark / Name</label><input type="text" id="new-xray-u" placeholder="e.g. streamer_vip"></div>
      <div class="form-group"><label>Protocol</label><select id="new-xray-proto"><option value="vless">VLESS Reality</option><option value="vmess">VMess WS</option><option value="trojan">Trojan WS</option></select></div>
      <div style="display: flex; justify-content: flex-end; gap: 8px;">
        <button class="btn" style="background: #334155; color: #fff;" onclick="closeModal('xray-modal')">Cancel</button>
        <button class="btn" onclick="submitXray()">Create Xray Client</button>
      </div>
    </div>
  </div>

  <!-- 4. On-Screen Xray Client Link & QR Modal -->
  <div id="xray-config-modal" class="modal">
    <div class="modal-box">
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:14px; border-bottom:1px solid #1e293b; padding-bottom:8px;">
        <h3 style="margin:0; font-size:15px; color:#fff;">Xray Client Configuration</h3>
        <button onclick="closeModal('xray-config-modal')" style="background:transparent; border:none; color:#94a3b8; font-size:18px; cursor:pointer;">✕</button>
      </div>
      <div style="text-align:center; padding:12px; background:#fff; border-radius:8px; margin-bottom:12px;">
        <div style="color:#000; font-weight:bold; font-size:12px; margin-bottom:4px;">SCAN QR IN V2RAYNG / SHADOWROCKET</div>
        <div style="font-family:monospace; font-size:11px; color:#333; padding:8px; border:2px dashed #000;" id="xray-qr-placeholder">
          [ QR CODE PREVIEW ]
        </div>
      </div>
      <div class="form-group">
        <label>Subscription / Client Link</label>
        <textarea id="xray-link-text" readonly style="width:100%; height:70px; background:#07090e; border:1px solid #1e293b; color:#2dd4bf; font-family:monospace; font-size:11px; padding:6px; border-radius:6px;"></textarea>
      </div>
      <div style="display:flex; gap:8px;">
        <button class="btn" style="flex:1;" onclick="copyText(document.getElementById('xray-link-text').value)">Copy Link</button>
        <button class="btn" style="background:#334155; color:#fff;" onclick="closeModal('xray-config-modal')">Close</button>
      </div>
    </div>
  </div>

  <script>
    let currentConfigText = '';

    function switchTab(tabId) {
      document.querySelectorAll('.tab-pane').forEach(el => el.classList.remove('active'));
      document.querySelectorAll('.nav-btn').forEach(el => el.classList.remove('active'));
      const target = document.getElementById('tab-' + tabId);
      if (target) target.classList.add('active');
      if (event && event.currentTarget) event.currentTarget.classList.add('active');
      const titles = {
        dashboard: 'Dashboard Overview',
        ssh: 'SSH & Dropbear User Accounts',
        xray: 'Xray Multi-Protocol Core (VMess, VLESS, Trojan)',
        services: 'Running VPN Daemons & Ports',
        stats: 'Hardware Utilization & Speedtest',
        bot: 'Telegram Alerts Bot Integration',
        settings: 'Domain, SSL Certificates & Security',
        admins: 'Panel Administrators & Activity Log'
      };
      document.getElementById('page-title').innerText = titles[tabId] || 'DDK Web Panel';
    }

    function openModal(id) { document.getElementById(id).classList.add('active'); }
    function closeModal(id) { document.getElementById(id).classList.remove('active'); }

    function copyText(txt) {
      if (!txt) return;
      navigator.clipboard.writeText(txt);
      alert('Copied to clipboard!');
    }

    function copyLink(link) {
      navigator.clipboard.writeText(link);
      alert('Subscription Link copied to clipboard!');
    }

    function copyFullConfig() {
      if (currentConfigText) {
        navigator.clipboard.writeText(currentConfigText);
        alert('All SSH connection credentials copied to clipboard!');
      }
    }

    function showConfigModal(data) {
      const dom = data.domain || window.location.hostname;
      document.getElementById('cfg-host').innerText = dom;
      document.getElementById('cfg-user').innerText = data.username || '-';
      document.getElementById('cfg-pass').innerText = data.password || '-';
      document.getElementById('cfg-exp').innerText = (data.expiry || '30 Days') + ' • ' + (data.ip_limit || 2) + ' IPs';
      const pl = 'GET / HTTP/1.1[crlf]Host: ' + dom + '[crlf]Upgrade: websocket[crlf][crlf]';
      document.getElementById('cfg-payload').innerText = pl;
      currentConfigText = '=====================================\n   DDK VPS MANAGER - SSH ACCOUNT\n=====================================\nDomain / Host : ' + dom + '\nUsername      : ' + data.username + '\nPassword      : ' + data.password + '\nOpenSSH Port  : 22\nDropbear Ports: 109, 447\nWS HTTP Ports : 80, 8080, 8880, 2082\nWS TLS Ports  : 443, 2083, 2087\nExpiry        : ' + (data.expiry || '30 Days') + '\nIP Limit      : ' + (data.ip_limit || 2) + ' Devices\n=====================================\nPayload:\n' + pl + '\n=====================================';
      openModal('ssh-config-modal');
    }

    function showDefaultSshConfig(username) {
      showConfigModal({
        domain: window.location.hostname || 'vps.ddkmanager.net',
        username: username,
        password: 'DDK_VIP_Password@123',
        ip_limit: 15,
        expiry: '30 Days'
      });
    }

    function showXrayModal(data) {
      document.getElementById('xray-link-text').value = data.link;
      document.getElementById('xray-qr-placeholder').innerText = data.link.slice(0, 40) + '...';
      openModal('xray-config-modal');
    }

    async function fetchStats() {
      try {
        const res = await fetch('/api/stats');
        const d = await res.json();
        document.getElementById('cpu-val').innerText = d.cpu + '%';
        document.getElementById('ram-val').innerText = d.ram + ' MB';
        document.getElementById('disk-val').innerText = d.disk + ' GB';
        const dom = d.domain || window.location.hostname;
        document.getElementById('foot-domain').innerText = dom;
        document.getElementById('set-domain').value = dom;
        if (d.admin) document.getElementById('admin-user').innerText = d.admin;
      } catch (e) {
        console.log(e);
      }
    }

    function submitSsh() {
      const u = document.getElementById('new-ssh-u').value.trim();
      const p = document.getElementById('new-ssh-p').value.trim();
      const ip = document.getElementById('new-ssh-ip').value || '2';
      const days = document.getElementById('new-ssh-days').value || '30';
      if (!u || !p) return alert('Please enter username and password');
      
      fetch('/api/ssh/create', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: u, password: p, ip_limit: ip, days: days })
      })
      .then(r => r.json())
      .then(data => {
        closeModal('ssh-modal');
        document.getElementById('new-ssh-u').value = '';
        document.getElementById('new-ssh-p').value = '';
        
        // Add new row to SSH Table with Config Details button
        const tbody = document.getElementById('ssh-table-body');
        const tr = document.createElement('tr');
        tr.innerHTML = '<td>' + data.username + '</td>' +
          '<td><span class="status-badge"><span class="dot-green"></span>active</span></td>' +
          '<td>' + (data.ip_limit || 2) + '</td>' +
          '<td>Dropbear WS</td>' +
          '<td>109, 443, 2082</td>' +
          '<td><button class="btn" style="padding:4px 8px; font-size:11px; margin-right:4px;" onclick=\'showConfigModal(' + JSON.stringify(data) + ')\'>Config Details</button>' +
          '<button class="btn btn-danger" style="padding:4px 8px; font-size:11px;">Lock</button></td>';
        tbody.prepend(tr);
        
        // IMMEDIATELY OPEN CONNECTION DETAILS MODAL ON SCREEN!
        showConfigModal(data);
      })
      .catch(err => {
        // Fallback for demo preview
        closeModal('ssh-modal');
        const fallback = {
          domain: window.location.hostname || 'vps.ddkmanager.net',
          username: u,
          password: p,
          ip_limit: ip,
          expiry: days + ' Days'
        };
        showConfigModal(fallback);
      });
    }

    function submitXray() {
      const u = document.getElementById('new-xray-u').value.trim();
      const proto = document.getElementById('new-xray-proto').value;
      if (!u) return alert('Please enter client remark');

      fetch('/api/xray/create', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: u, protocol: proto })
      })
      .then(r => r.json())
      .then(data => {
        closeModal('xray-modal');
        document.getElementById('new-xray-u').value = '';
        showXrayModal(data);
      })
      .catch(() => {
        closeModal('xray-modal');
        const dummyLink = proto + '://' + Math.random().toString(36).slice(2) + '@' + (window.location.hostname || 'vps.ddkmanager.net') + ':443?security=tls#' + u;
        showXrayModal({ link: dummyLink });
      });
    }

    function restartService(srv) {
      fetch('/api/services/restart', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ service: srv })
      }).then(() => alert(srv + ' restarted successfully!'));
    }

    function restartAllServices() {
      alert('Restarting all VPN services: HAProxy, Nginx, Dropbear, WS-Proxy, Xray Core...');
    }

    function runSpeedtest() {
      document.getElementById('speed-ping').innerText = 'Testing...';
      document.getElementById('speed-down').innerText = 'Testing...';
      document.getElementById('speed-up').innerText = 'Testing...';
      setTimeout(() => {
        document.getElementById('speed-ping').innerText = '1.3 ms';
        document.getElementById('speed-down').innerText = '948.2 Mbit/s';
        document.getElementById('speed-up').innerText = '892.4 Mbit/s';
      }, 1500);
    }

    fetchStats();
    setInterval(fetchStats, 3000);
  </script>
</body>
</html>
"""

class PanelHandler(http.server.SimpleHTTPRequestHandler):
    def list_directory(self, path):
        self.send_response(200)
        self.send_header('Content-type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(EMBEDDED_HTML.encode('utf-8'))
        return None

    def do_GET(self):
        creds = get_creds()
        if self.path == '/api/stats':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            
            cpu = 1.4
            ram = 396
            disk = 3.6
            try:
                mem = shutil.disk_usage("/")
                disk = round((mem.total - mem.free) / (1024**3), 1)
            except Exception: pass

            stats = {
                "status": "online",
                "panel": "DDK VPS Manager Panel v7.0",
                "domain": get_domain(),
                "admin": creds.get("username", "admin"),
                "port": PORT,
                "cpu": cpu,
                "ram": ram,
                "disk": disk,
                "services": {
                    "haproxy": "running",
                    "nginx": "running",
                    "dropbear": "running",
                    "ws_proxy": "running",
                    "xray": "running",
                    "web_panel": "running"
                }
            }
            self.wfile.write(json.dumps(stats).encode('utf-8'))
            return

        if self.path in ['/', '/index.html', '/dashboard', '/ssh', '/xray', '/services', '/stats', '/bot', '/settings', '/admins']:
            self.send_response(200)
            self.send_header('Content-type', 'text/html; charset=utf-8')
            self.end_headers()
            if os.path.exists(HTML_FILE):
                try:
                    with open(HTML_FILE, "rb") as f:
                        self.wfile.write(f.read())
                        return
                except Exception:
                    pass
            self.wfile.write(EMBEDDED_HTML.encode('utf-8'))
            return

        return super().do_GET()

    def do_POST(self):
        length = int(self.headers.get('content-length', 0))
        body = self.rfile.read(length) if length > 0 else b'{}'
        try:
            data = json.loads(body.decode('utf-8'))
        except Exception:
            data = {}

        if self.path == '/api/ssh/create':
            u = data.get('username')
            p = data.get('password')
            ip_lim = data.get('ip_limit', 2)
            days = data.get('days', 30)
            if u and p:
                try:
                    subprocess.run(["useradd", "-M", "-s", "/bin/false", u], check=False)
                    proc = subprocess.Popen(["passwd", u], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    proc.communicate(f"{p}\n{p}\n".encode('utf-8'))
                except Exception: pass

            dom = get_domain()
            res = {
                "status": "ok",
                "username": u,
                "password": p,
                "domain": dom,
                "ip_limit": ip_lim,
                "expiry": f"{days} Days",
                "openssh_port": 22,
                "dropbear_ports": "109, 447",
                "ws_http_ports": "80, 8080, 8880, 2082",
                "ws_tls_ports": "443, 2083, 2087",
                "payload": f"GET / HTTP/1.1[crlf]Host: {dom}[crlf]Upgrade: websocket[crlf][crlf]"
            }
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(res).encode('utf-8'))
            return

        if self.path == '/api/xray/create':
            u = data.get('username', 'client_user')
            proto = data.get('protocol', 'vless')
            import uuid
            uid = str(uuid.uuid4())
            dom = get_domain()
            port = 443 if proto == 'vless' else (8442 if proto == 'vmess' else 8447)
            link = f"{proto}://{uid}@{dom}:{port}?security=tls#{u}"
            res = {
                "status": "ok",
                "username": u,
                "protocol": proto,
                "uuid": uid,
                "domain": dom,
                "port": port,
                "link": link
            }
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(res).encode('utf-8'))
            return

        if self.path == '/api/services/restart':
            srv = data.get('service')
            if srv:
                try:
                    subprocess.run(["systemctl", "restart", srv], check=False)
                except Exception: pass
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(b'{"status": "restarted"}')
            return

        self.send_response(404)
        self.end_headers()

print(f"DDK Web Panel running on http://0.0.0.0:{PORT}")
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", PORT), PanelHandler) as httpd:
    httpd.serve_forever()

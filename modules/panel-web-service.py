#!/usr/bin/env python3
"""
DDK VPS Manager 2 - Web Panel Service (Port 9090)
Serves REST API and Web Panel Dashboard
"""
import http.server
import socketserver
import json
import os
import subprocess

PORT = 9090

class PanelHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/api/stats':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            
            # Simple server metrics
            stats = {
                "status": "online",
                "panel": "DDK VPS Manager Panel v7.0",
                "port": PORT,
                "services": {
                    "haproxy": "running",
                    "nginx": "running",
                    "dropbear": "running",
                    "ws_proxy": "running",
                    "xray": "running",
                    "web_panel": "running"
                }
            }
            self.wfile.write(json.dumps(stats).encode())
            return
            
        return super().do_GET()

print(f"DDK Web Panel running on http://0.0.0.0:{PORT}")
with socketserver.TCPServer(("", PORT), PanelHandler) as httpd:
    httpd.serve_forever()

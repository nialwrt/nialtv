#!/bin/bash
set -e

echo "=== INSTALLING OTT TV M3U PROVIDER ==="

# Dependency
apt update
apt install -y python3 jq wget curl

# Directory
mkdir -p /opt/ott/{data,seed,public/playlist}
[ ! -f /opt/ott/data/clients.json ] && echo '{}' > /opt/ott/data/clients.json
[ ! -f /opt/ott/data/sessions.json ] && echo '{}' > /opt/ott/data/sessions.json

# ================= ENGINE =================
cat << 'EOF' > /opt/ott/engine.py
from http.server import BaseHTTPRequestHandler, HTTPServer
import json, time, os

BASE = "/opt/ott"
CLIENTS = f"{BASE}/data/clients.json"
SESSIONS = f"{BASE}/data/sessions.json"
SEED = f"{BASE}/seed/seed.m3u"

def load(p):
    if not os.path.exists(p):
        return {}
    with open(p) as f:
        return json.load(f)

def save(p,d):
    with open(p,'w') as f:
        json.dump(d,f,indent=2)

class OTT(BaseHTTPRequestHandler):

    def deny(self, code=403):
        self.send_response(code)
        self.end_headers()

    def do_GET(self):
        if not self.path.startswith("/playlist/"):
            self.deny(404); return

        user = self.path.split("/")[-1].replace(".m3u","")
        now = int(time.time())

        clients = load(CLIENTS)
        sessions = load(SESSIONS)

        if user not in clients:
            self.deny(); return

        c = clients[user]
        if c["status"] != "active" or now > c["exp"]:
            c["status"] = "expired"
            save(CLIENTS, clients)
            self.deny(); return

        ip = self.client_address[0]

        # STRICT 1 DEVICE
        sessions[user] = {
            "ip": ip,
            "time": now
        }
        save(SESSIONS, sessions)

        self.send_response(200)
        self.send_header("Content-Type","audio/x-mpegurl")
        self.end_headers()

        with open(SEED, encoding="utf-8", errors="ignore") as f:
            for line in f:
                self.wfile.write(line.encode())

HTTPServer(("",8080),OTT).serve_forever()
EOF

# ================= SERVICE =================
cat << EOF > /etc/systemd/system/ott.service
[Unit]
Description=OTT Dummy M3U Provider
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/ott/engine.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ott

# ================= PANEL =================
cat << 'EOF' > /opt/ott/panel.sh
#!/bin/bash
BASE=/opt/ott
CLIENTS=$BASE/data/clients.json
IP=$(hostname -I | awk '{print $1}')

clear
echo "=== OTT TV M3U PROVIDER PANEL ==="
echo "Service Status : $(systemctl is-active ott)"
echo "Server IP     : $IP"
echo

TOTAL=$(jq length $CLIENTS)
ACTIVE=$(jq '[.[]|select(.status=="active")]|length' $CLIENTS)
EXPIRED=$(jq '[.[]|select(.status=="expired")]|length' $CLIENTS)
SUSP=$(jq '[.[]|select(.status=="suspend")]|length' $CLIENTS)

echo "Total Client  : $TOTAL"
echo "Active        : $ACTIVE"
echo "Expired       : $EXPIRED"
echo "Suspended     : $SUSP"
echo
echo "1) Add Client"
echo "2) Renew Client"
echo "3) Suspend Client"
echo "4) Delete Client"
echo "5) Update Seed M3U"
echo "0) Exit"
echo
read -p "Select: " x

case $x in
1)
 read -p "Username : " u
 read -p "Valid days : " d
 exp=$(date -d "+$d days" +%s)
 jq ". + {\"$u\":{\"exp\":$exp,\"status\":\"active\"}}" $CLIENTS > /tmp/c && mv /tmp/c $CLIENTS
 echo
 echo "Client Created"
 echo "Username : $u"
 echo "Expiry   : $(date -d @$exp)"
 echo "M3U URL  : http://$IP:8080/playlist/$u.m3u"
 ;;
2)
 read -p "Username : " u
 read -p "Extend days : " d
 exp=$(date -d "+$d days" +%s)
 jq ".\"$u\".exp=$exp | .\"$u\".status=\"active\"" $CLIENTS > /tmp/c && mv /tmp/c $CLIENTS
 echo "Renewed until $(date -d @$exp)"
 ;;
3)
 read -p "Username : " u
 jq ".\"$u\".status=\"suspend\"" $CLIENTS > /tmp/c && mv /tmp/c $CLIENTS
 echo "Client suspended"
 ;;
4)
 read -p "Username : " u
 jq "del(.\"$u\")" $CLIENTS > /tmp/c && mv /tmp/c $CLIENTS
 echo "Client deleted"
 ;;
5)
 read -p "Seed M3U URL : " s
 wget -O $BASE/seed/seed.m3u "$s"
 echo "Seed updated"
 ;;
esac
EOF

chmod +x /opt/ott/panel.sh

# Auto load panel
grep -q ott/panel.sh /root/.bashrc || echo "/opt/ott/panel.sh" >> /root/.bashrc

echo "=== INSTALLATION COMPLETE ==="
echo "Logout & login semula SSH untuk buka panel"

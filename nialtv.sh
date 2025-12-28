#!/bin/bash
set -Eeuo pipefail

# =========================
# NIALTV PREMIUM – FULL
# Ubuntu 24.04
# =========================

GREEN="\e[1;32m"; NC="\e[0m"
BASE="/opt/nialtv"

clear
echo -e "${GREEN}"
cat <<EOF
╭════════════════════════════════════════════════════════╮
│                  📺 NIALTV PREMIUM                     │
╰════════════════════════════════════════════════════════╯
EOF
echo -e "${NC}"

# ===== OS CHECK =====
if ! lsb_release -d | grep -q "Ubuntu 24"; then
  echo "❌ Ubuntu 24.04 only"
  exit 1
fi

# ===== INPUT DOMAIN =====
read -p "DOMAIN NAME : " DOMAIN
EMAIL="admin@$DOMAIN"

# ===== DEPENDENCIES =====
apt update
apt install -y python3 python3-venv python3-pip curl jq certbot ufw

# ===== FIREWALL =====
ufw allow 22/tcp
ufw allow 8080/tcp
ufw --force enable

# ===== DIRECTORIES =====
mkdir -p "$BASE"
cd "$BASE"

echo "DOMAIN=$DOMAIN" > .env
echo "{}" > users.json
echo "#EXTM3U" > playlist.m3u

# ===== PYTHON ENV =====
python3 -m venv venv
source venv/bin/activate
pip install flask

# ===== FLASK AUTH SERVER =====
cat > app.py <<EOF
from flask import Flask, request, Response, jsonify
import json, datetime, os

BASE="$BASE"
USERS=f"{BASE}/users.json"
PLAYLIST=f"{BASE}/playlist.m3u"

app=Flask(__name__)

def load():
    return json.load(open(USERS))

def save(d):
    json.dump(d, open(USERS,"w"), indent=2)

def expired(d):
    return datetime.date.today() > datetime.datetime.strptime(d,"%Y-%m-%d").date()

@app.route("/player_api.php")
def api():
    u=request.args.get("username")
    p=request.args.get("password")
    ip=request.remote_addr
    ua=request.headers.get("User-Agent","")
    d=load()

    if u not in d or d[u]["password"]!=p or expired(d[u]["expiry"]):
        return jsonify({"user_info":{"auth":0}})

    # ===== ONE DEVICE ONLY =====
    if d[u].get("ip") and d[u]["ip"]!=ip:
        # auto kick old device
        d[u]["ip"]=ip
        d[u]["ua"]=ua
    else:
        d[u]["ip"]=ip
        d[u]["ua"]=ua

    save(d)
    return jsonify({"user_info":{"auth":1,"username":u,"exp_date":d[u]["expiry"]}})

@app.route("/get.php")
def m3u():
    u=request.args.get("username")
    p=request.args.get("password")
    ip=request.remote_addr
    d=load()

    if u not in d or d[u]["password"]!=p or expired(d[u]["expiry"]):
        return "Unauthorized",401

    if d[u].get("ip") and d[u]["ip"]!=ip:
        return "Device limit",403

    return Response(open(PLAYLIST).read(),mimetype="audio/x-mpegurl")

app.run(
    host="0.0.0.0",
    port=8080,
    ssl_context=(
        f"/etc/letsencrypt/live/{os.environ['DOMAIN']}/fullchain.pem",
        f"/etc/letsencrypt/live/{os.environ['DOMAIN']}/privkey.pem"
    )
)
EOF

# ===== SELLER PANEL =====
cat > seller.sh <<'EOF'
#!/bin/bash
source /opt/nialtv/.env
U="/opt/nialtv/users.json"
G="\e[1;32m";N="\e[0m"

while true; do
clear
echo -e "$G"
cat <<MENU
╭════════════════════════════════════════════════════════╮
│                📺 NIALTV PREMIUM PANEL                 │
╰════════════════════════════════════════════════════════╯
══════════════════════════════════════════════
 USERS   : $(jq length $U)
 DATE    : $(date)
 SERVICE : $(systemctl is-active nialtv)
══════════════════════════════════════════════
 [01] Create User
 [02] Remove User
 [03] Extend User
 [04] List Users
 [05] Update M3U
 [06] Kick Device
 [07] Restart Service
 [X]  Exit
MENU
echo -e "$N"
read -p "Select: " c

case $c in
1)
 read -p "Username   : " u
 read -p "Password   : " p
 read -p "Valid days : " d
 e=$(date -d "+$d days" +%Y-%m-%d)
 jq ".+{\"$u\":{\"password\":\"$p\",\"expiry\":\"$e\",\"ip\":\"\",\"ua\":\"\"}}" $U > /tmp/u && mv /tmp/u $U
 clear
 cat <<INFO
━━━━━━━━━━━━━━━━━━━━━━
📺 NIALTV PREMIUM
━━━━━━━━━━━━━━━━━━━━━━
URL      : https://$DOMAIN:8080
USERNAME : $u
PASSWORD : $p
EXP      : $e
━━━━━━━━━━━━━━━━━━━━━━
INFO
 read;;
2)
 read -p "Username: " u
 jq "del(.\"$u\")" $U > /tmp/u && mv /tmp/u $U;;
3)
 read -p "Username: " u
 read -p "Extend days: " d
 e=$(date -d "+$d days" +%Y-%m-%d)
 jq ".\"$u\".expiry=\"$e\"" $U > /tmp/u && mv /tmp/u $U;;
4)
 jq . $U | less;;
5)
 read -p "M3U URL: " url
 curl -fsSL "$url" -o /opt/nialtv/playlist.m3u;;
6)
 read -p "Username: " u
 jq ".\"$u\".ip=\"\"" $U > /tmp/u && mv /tmp/u $U;;
7)
 systemctl restart nialtv;;
x|X) exit;;
esac
done
EOF

chmod +x seller.sh

# ===== SSL =====
certbot certonly --standalone -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive

# ===== SYSTEMD =====
cat > /etc/systemd/system/nialtv.service <<EOF
[Unit]
Description=NIALTV PREMIUM IPTV AUTH
After=network.target

[Service]
WorkingDirectory=$BASE
EnvironmentFile=$BASE/.env
ExecStart=$BASE/venv/bin/python $BASE/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nialtv
systemctl restart nialtv

echo -e "${GREEN}✅ INSTALL COMPLETE${NC}"
echo "Seller Panel : /opt/nialtv/seller.sh"
echo "Xtream URL   : https://$DOMAIN:8080"

#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================
# NIALTV PREMIUM – FULL AUTOSCRIPT
# Ubuntu 24.04 ONLY
# =========================================

GREEN="\e[1;32m"; NC="\e[0m"
BASE="/opt/nialtv"
SERVICE="nialtv"

clear
echo -e "${GREEN}"
cat <<'EOF'
╭════════════════════════════════════════════════════════╮
│                  📺 NIALTV PREMIUM                     │
╰════════════════════════════════════════════════════════╯
EOF
echo -e "${NC}"

# ===== OS CHECK =====
if ! lsb_release -rs | grep -q "^24"; then
  echo "❌ This script supports Ubuntu 24.04 only"
  exit 1
fi

# ===== DOMAIN INPUT =====
read -rp "DOMAIN NAME : " DOMAIN
EMAIL="admin@$DOMAIN"

# ===== BASIC DEPENDENCIES =====
apt update -y
apt install -y python3 python3-venv python3-pip \
               curl jq certbot ufw ca-certificates

# ===== FIREWALL (LETSENCRYPT NEEDS 80) =====
ufw allow 22/tcp
ufw allow 80/tcp
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
pip install --upgrade pip
pip install flask

# ===== FLASK AUTH SERVER =====
cat > app.py <<EOF
from flask import Flask, request, Response, jsonify
import json, datetime, os

BASE = "$BASE"
USERS = f"{BASE}/users.json"
PLAYLIST = f"{BASE}/playlist.m3u"
DOMAIN = os.environ.get("DOMAIN")

app = Flask(__name__)

def load_users():
    with open(USERS) as f:
        return json.load(f)

def save_users(d):
    with open(USERS, "w") as f:
        json.dump(d, f, indent=2)

def expired(date):
    return datetime.date.today() > datetime.datetime.strptime(date,"%Y-%m-%d").date()

@app.route("/player_api.php")
def player_api():
    u = request.args.get("username")
    p = request.args.get("password")
    ip = request.remote_addr
    ua = request.headers.get("User-Agent","")

    users = load_users()

    if u not in users:
        return jsonify({"user_info":{"auth":0}})

    user = users[u]

    if user["password"] != p or expired(user["expiry"]):
        return jsonify({"user_info":{"auth":0}})

    # ===== ONE DEVICE ONLY (AUTO KICK) =====
    if user.get("ip") and user["ip"] != ip:
        user["ip"] = ip
        user["ua"] = ua
    else:
        user["ip"] = ip
        user["ua"] = ua

    save_users(users)

    return jsonify({
        "user_info":{
            "auth":1,
            "username":u,
            "exp_date":user["expiry"]
        }
    })

@app.route("/get.php")
def get_m3u():
    u = request.args.get("username")
    p = request.args.get("password")
    ip = request.remote_addr

    users = load_users()

    if u not in users:
        return "Unauthorized",401

    user = users[u]

    if user["password"] != p or expired(user["expiry"]):
        return "Unauthorized",401

    if user.get("ip") and user["ip"] != ip:
        return "Device limit",403

    return Response(open(PLAYLIST).read(), mimetype="audio/x-mpegurl")

if __name__ == "__main__":
    app.run(
        host="0.0.0.0",
        port=8080,
        ssl_context=(
            f"/etc/letsencrypt/live/{DOMAIN}/fullchain.pem",
            f"/etc/letsencrypt/live/{DOMAIN}/privkey.pem"
        )
    )
EOF

# ===== SELLER PANEL =====
cat > seller.sh <<'EOF'
#!/usr/bin/env bash
set -e

BASE="/opt/nialtv"
USERS="$BASE/users.json"
source "$BASE/.env"

GREEN="\e[1;32m"; NC="\e[0m"

while true; do
clear
echo -e "$GREEN"
cat <<MENU
╭════════════════════════════════════════════════════════╮
│               📺 NIALTV PREMIUM PANEL                  │
╰════════════════════════════════════════════════════════╯
══════════════════════════════════════════════
 USERS   : $(jq length "$USERS")
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
echo -e "$NC"
read -rp "Select: " opt

case "$opt" in
1)
 read -rp "Username   : " u
 read -rp "Password   : " p
 read -rp "Valid days : " d
 exp=\$(date -d "+\$d days" +%Y-%m-%d)

 jq ". + {\"\$u\":{
   \"password\":\"\$p\",
   \"expiry\":\"\$exp\",
   \"ip\":\"\",
   \"ua\":\"\"
 }}" "\$USERS" > /tmp/u && mv /tmp/u "\$USERS"

 clear
 cat <<INFO
━━━━━━━━━━━━━━━━━━━━━━
📺 NIALTV PREMIUM
━━━━━━━━━━━━━━━━━━━━━━
URL      : https://$DOMAIN:8080
USERNAME : \$u
PASSWORD : \$p
EXP      : \$exp
━━━━━━━━━━━━━━━━━━━━━━
INFO
 read;;
2)
 read -rp "Username: " u
 jq "del(.\"\$u\")" "\$USERS" > /tmp/u && mv /tmp/u "\$USERS";;
3)
 read -rp "Username: " u
 read -rp "Extend days: " d
 exp=\$(date -d "+\$d days" +%Y-%m-%d)
 jq ".\"\$u\".expiry=\"\$exp\"" "\$USERS" > /tmp/u && mv /tmp/u "\$USERS";;
4)
 jq . "\$USERS" | less;;
5)
 read -rp "M3U URL: " url
 curl -fsSL "\$url" -o "$BASE/playlist.m3u";;
6)
 read -rp "Username: " u
 jq ".\"\$u\".ip=\"\"" "\$USERS" > /tmp/u && mv /tmp/u "\$USERS";;
7)
 systemctl restart nialtv;;
x|X) exit;;
esac
done
EOF

chmod +x seller.sh

# ===== SSL (AFTER PORT 80 OPEN) =====
certbot certonly --standalone \
  -d "$DOMAIN" \
  -m "$EMAIL" \
  --agree-tos \
  --non-interactive

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
echo "Seller Panel : $BASE/seller.sh"
echo "Xtream URL   : https://$DOMAIN:8080"

#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================
# NIALTV PREMIUM – FULL AUTOSCRIPT + PANEL
# Ubuntu 24.04 ONLY
# =========================================

# ===== COLORS =====
GREEN="\e[1;32m"
RED="\e[1;31m"
YELLOW="\e[1;33m"
NC="\e[0m"

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
  echo -e "${RED}❌ This script supports Ubuntu 24.04 only${NC}"
  exit 1
fi

# ===== DOMAIN INPUT =====
read -rp "DOMAIN NAME : " DOMAIN
EMAIL="admin@$DOMAIN"

# ===== BASIC DEPENDENCIES =====
apt update -y
apt install -y python3 python3-venv python3-pip curl jq certbot ufw ca-certificates

# ===== FIREWALL =====
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
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
    if user.get("ip") and user["ip"] != ip:
        user["ip"] = ip
        user["ua"] = ua
    else:
        user["ip"] = ip
        user["ua"] = ua
    save_users(users)
    return jsonify({"user_info":{"auth":1,"username":u,"exp_date":user["expiry"]}})

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
        ssl_context=(f"/etc/letsencrypt/live/{DOMAIN}/fullchain.pem",
                     f"/etc/letsencrypt/live/{DOMAIN}/privkey.pem")
    )
EOF

# ===== SELLER PANEL =====
cat > seller.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/opt/nialtv"
USERS="$BASE/users.json"
source "$BASE/.env"

GREEN="\e[1;32m"
RED="\e[1;31m"
YELLOW="\e[1;33m"
NC="\e[0m"
SERVICE="nialtv"

while true; do
    clear
    OS=$(lsb_release -ds)
    RAM=$(free -m | awk '/Mem:/ {print $2 " MB"}')
    CPU="$(nproc --all) Core"
    IP=$(curl -s ipinfo.io/ip)
    DOMAIN=${DOMAIN:-N/A}
    URL="https://$DOMAIN:8080"
    SERVICE_STATUS=$(systemctl is-active $SERVICE || echo "inactive")
    CLIENTS=$(jq length "$USERS" 2>/dev/null || echo 0)
    EXP=$(jq -r '.[].expiry' "$USERS" 2>/dev/null | sort | tail -n1 || echo "N/A")

    echo -e "${GREEN}================= NIALTV PANEL =================${NC}"
    echo -e "${GREEN}OS           :${NC} $OS"
    echo -e "${GREEN}RAM          :${NC} $RAM"
    echo -e "${GREEN}CPU          :${NC} $CPU"
    echo -e "${GREEN}IP           :${NC} $IP"
    echo -e "${GREEN}DOMAIN       :${NC} $DOMAIN"
    echo -e "${GREEN}URL          :${NC} $URL"
    if [[ "$SERVICE_STATUS" == "active" ]]; then
        echo -e "${GREEN}SERVICE      :✅ active${NC}"
    else
        echo -e "${RED}SERVICE      :❌ inactive${NC}"
    fi
    echo -e "${GREEN}Clients      :${NC} $CLIENTS"
    echo -e "${GREEN}Next Expiry  :${NC} $EXP"
    echo -e "${GREEN}==============================================${NC}"

    echo -e "[1] Create User"
    echo -e "[2] Remove User"
    echo -e "[3] Extend User"
    echo -e "[4] List Users"
    echo -e "[5] Update M3U"
    echo -e "[6] Kick Device"
    echo -e "[7] Restart Service"
    echo -e "[X] Exit"
    echo
    read -rp "Select option [1-7 or x]: " opt

    case $opt in
        1)
            read -rp "Username   : " u
            read -rp "Password   : " p
            read -rp "Valid days : " d
            exp=$(date -d "+$d days" +%Y-%m-%d)
            jq ". + {\"$u\":{\"password\":\"$p\",\"expiry\":\"$exp\",\"ip\":\"\",\"ua\":\"\"}}" "$USERS" > /tmp/u && mv /tmp/u "$USERS"
            echo -e "${GREEN}✅ USER CREATED: $u | EXP: $exp${NC}"
            read -n1 -r -p "Press any key to continue..."
            ;;
        2)
            read -rp "Username to remove: " u
            jq "del(.\"$u\")" "$USERS" > /tmp/u && mv /tmp/u "$USERS"
            echo -e "${RED}❌ USER REMOVED: $u${NC}"
            read -n1 -r -p "Press any key to continue..."
            ;;
        3)
            read -rp "Username to extend: " u
            read -rp "Extra days: " d
            new_exp=$(date -d "+$d days" +%Y-%m-%d)
            jq ".\"$u\".expiry=\"$new_exp\"" "$USERS" > /tmp/u && mv /tmp/u "$USERS"
            echo -e "${GREEN}✅ USER $u EXTENDED TO $new_exp${NC}"
            read -n1 -r -p "Press any key to continue..."
            ;;
        4)
            jq . "$USERS" | less
            ;;
        5)
            read -rp "M3U URL: " url
            curl -fsSL "$url" -o "$BASE/playlist.m3u"
            echo -e "${GREEN}✅ M3U UPDATED${NC}"
            read -n1 -r -p "Press any key to continue..."
            ;;
        6)
            read -rp "Username to kick: " u
            jq ".\"$u\".ip=\"\"" "$USERS" > /tmp/u && mv /tmp/u "$USERS"
            echo -e "${GREEN}✅ DEVICE KICKED: $u${NC}"
            read -n1 -r -p "Press any key to continue..."
            ;;
        7)
            systemctl restart $SERVICE
            echo -e "${GREEN}✅ SERVICE RESTARTED${NC}"
            read -n1 -r -p "Press any key to continue..."
            ;;
        x|X) exit;;
        *) echo -e "${YELLOW}❌ Invalid option${NC}"; read -n1 -r -p "Press any key to continue...";;
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

# ===== AUTO OPEN PANEL ON SSH LOGIN =====
grep -qxF "$BASE/seller.sh" /etc/profile || echo "$BASE/seller.sh" >> /etc/profile

# ===== AUTOREBOOT AFTER INSTALL (10s) =====
echo -e "${YELLOW}⚠️  System will reboot in 10 seconds to apply changes...${NC}"
sleep 10
reboot now

#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================
# NIALTV XTREAM API – FULL AUTOSCRIPT + PANEL
# Ubuntu 24.04 ONLY
# Stable version (Gunicorn)
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
echo "================= NIALTV INSTALLER ================="
echo -e "${NC}"

# ===== OS CHECK =====
if ! lsb_release -rs | grep -q "^24"; then
  echo -e "${RED}❌ This script supports Ubuntu 24.04 only${NC}"
  exit 1
fi

# ===== DOMAIN INPUT =====
read -rp "DOMAIN NAME : " DOMAIN
EMAIL="admin@$DOMAIN"

# ===== DEPENDENCIES =====
apt update -y
apt install -y python3 python3-venv python3-pip curl jq ufw ca-certificates

# ===== FIREWALL =====
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# ===== DIRECTORIES =====
mkdir -p "$BASE"
cd "$BASE"
echo "DOMAIN=$DOMAIN" > .env
echo "{}" > users.json
echo "#EXTM3U" > playlist.m3u
LOG="$BASE/nialtv.log"

# ===== PYTHON ENV =====
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install flask gunicorn

# ===== FLASK APP (Xtream API) =====
cat > app.py <<EOF
from flask import Flask, request, Response, jsonify
import json, datetime, os

BASE = "$BASE"
USERS = f"{BASE}/users.json"
PLAYLIST = f"{BASE}/playlist.m3u"

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
    users = load_users()
    if u not in users:
        return jsonify({"user_info":{"auth":0}})
    user = users[u]
    if user["password"] != p or expired(user["expiry"]):
        return jsonify({"user_info":{"auth":0}})
    return jsonify({"user_info":{"auth":1,"username":u,"exp_date":user["expiry"]}})

@app.route("/get.php")
def get_m3u():
    u = request.args.get("username")
    p = request.args.get("password")
    users = load_users()
    if u not in users:
        return "Unauthorized",401
    user = users[u]
    if user["password"] != p or expired(user["expiry"]):
        return "Unauthorized",401
    return Response(open(PLAYLIST).read(), mimetype="audio/x-mpegurl")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)  # Gunicorn will handle production
EOF

# ===== SELLER PANEL (SSH) =====
cat > seller.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/opt/nialtv"
USERS="$BASE/users.json"
LOG="$BASE/nialtv.log"
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
    SERVICE_STATUS=$(systemctl is-active $SERVICE || echo "inactive")
    CLIENTS=$(jq length "$USERS" 2>/dev/null || echo 0)

    echo -e "${GREEN}=========== NIALTV PANEL ===========${NC}"
    echo -e "${GREEN}OS     :${NC} $OS"
    echo -e "${GREEN}IP     :${NC} $IP"
    echo -e "${GREEN}DOMAIN :${NC} $DOMAIN"
    if [[ "$SERVICE_STATUS" == "active" ]]; then
        echo -e "${GREEN}SERVICE: ✅ active${NC}"
    else
        echo -e "${RED}SERVICE: ❌ inactive${NC}"
    fi
    echo -e "${GREEN}USERS  :${NC} $CLIENTS"
    echo -e "${GREEN}===================================${NC}"

    echo -e "1) Create User"
    echo -e "2) Remove User"
    echo -e "3) Extend User"
    echo -e "4) List Users"
    echo -e "5) Restart Service"
    echo -e "X) Exit"
    echo
    read -rp "Select: " opt

    case $opt in
        1)
            read -rp "Username: " u
            read -rp "Password: " p
            read -rp "Valid days: " d
            exp=$(date -d "+$d days" +%Y-%m-%d)
            m3u_link="http://$DOMAIN/get.php?username=$u&password=$p"
            jq ". + {\"$u\":{\"password\":\"$p\",\"expiry\":\"$exp\",\"m3u\":\"$m3u_link\"}}" "$USERS" > /tmp/u && mv /tmp/u "$USERS"
            echo -e "$(date '+%Y-%m-%d %H:%M:%S') - ✅ USER CREATED: $u | EXP: $exp | M3U: $m3u_link" >> "$LOG"
            echo -e "${GREEN}✅ USER CREATED: $u | EXP: $exp${NC}"
            echo -e "${GREEN}M3U Link: $m3u_link${NC}"
            read -n1 -r -p "Press any key to continue..."
            ;;
        2)
            read -rp "Username to remove: " u
            jq "del(.\"$u\")" "$USERS" > /tmp/u && mv /tmp/u "$USERS"
            echo -e "$(date '+%Y-%m-%d %H:%M:%S') - ❌ USER REMOVED: $u" >> "$LOG"
            echo -e "${RED}❌ USER REMOVED: $u${NC}"
            read -n1 -r -p "Press any key to continue..."
            ;;
        3)
            read -rp "Username to extend: " u
            read -rp "Extra days: " d
            new_exp=$(date -d "+$d days" +%Y-%m-%d)
            jq ".\"$u\".expiry=\"$new_exp\"" "$USERS" > /tmp/u && mv /tmp/u "$USERS"
            echo -e "$(date '+%Y-%m-%d %H:%M:%S') - ✅ USER $u EXTENDED TO $new_exp" >> "$LOG"
            echo -e "${GREEN}✅ USER $u EXTENDED TO $new_exp${NC}"
            read -n1 -r -p "Press any key to continue..."
            ;;
        4)
            echo -e "${GREEN}=== LIST OF USERS ===${NC}"
            jq -r 'to_entries[] | "\(.key) | Exp: \(.value.expiry) | Status: \((if (.value.expiry | strptime("%Y-%m-%d") | mktime) < (now) then "Expired" else "Active" end)) | M3U: \(.value.m3u)"' "$USERS"
            read -n1 -r -p "Press any key to continue..."
            ;;
        5)
            systemctl restart $SERVICE
            echo -e "$(date '+%Y-%m-%d %H:%M:%S') - ✅ SERVICE RESTARTED" >> "$LOG"
            echo -e "${GREEN}✅ SERVICE RESTARTED${NC}"
            read -n1 -r -p "Press any key to continue..."
            ;;
        x|X) exit;;
        *) echo -e "${YELLOW}❌ Invalid option${NC}"; read -n1 -r -p "Press any key to continue...";;
    esac
done
EOF

chmod +x seller.sh

# ===== SYSTEMD SERVICE (Gunicorn) =====
cat > /etc/systemd/system/nialtv.service <<EOF
[Unit]
Description=NIALTV Xtream API
After=network.target

[Service]
WorkingDirectory=$BASE
EnvironmentFile=$BASE/.env
ExecStart=$BASE/venv/bin/gunicorn -b 0.0.0.0:80 app:app
Restart=always
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nialtv
systemctl restart nialtv

# ===== AUTO OPEN PANEL ON SSH LOGIN =====
grep -qxF "$BASE/seller.sh" /etc/profile || echo "$BASE/seller.sh" >> /etc/profile

echo -e "${GREEN}✅ NIALTV INSTALL COMPLETE! SSH panel ready.${NC}"

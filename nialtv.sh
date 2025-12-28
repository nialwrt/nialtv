#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================
# NIALTV M3U PANEL – FULL SSH MANAGEMENT
# Ubuntu 24.04 ONLY
# =========================================

# ===== COLORS =====
GREEN="\e[1;32m"
RED="\e[1;31m"
YELLOW="\e[1;33m"
NC="\e[0m"

BASE="/opt/nialtv"
SERVICE="nialtv"
LOG="$BASE/nialtv.log"

clear
echo -e "${GREEN}================= NIALTV INSTALLER =================${NC}"

# ===== OS CHECK =====
if ! lsb_release -rs | grep -q "^24"; then
  echo -e "${RED}❌ This script supports Ubuntu 24.04 only${NC}"
  exit 1
fi

# ===== DEPENDENCIES =====
apt update -y
apt install -y python3 python3-venv python3-pip curl jq ufw ca-certificates

# ===== FIREWALL =====
ufw allow 22/tcp
ufw allow 8080/tcp
ufw --force enable

# ===== DIRECTORIES =====
mkdir -p "$BASE"
cd "$BASE"
echo "{}" > users.json
echo "{}" > m3u.json

# ===== PYTHON ENV =====
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install flask requests

# ===== FLASK SERVER (PROXY + USER AUTH) =====
cat > app.py <<'EOF'
from flask import Flask, request, Response, jsonify
import json, datetime, os, requests

BASE = "/opt/nialtv"
USERS_FILE = f"{BASE}/users.json"
M3U_FILE = f"{BASE}/m3u.json"

app = Flask(__name__)

def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except:
        return {}

def save_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2)

def expired(date):
    return datetime.date.today() > datetime.datetime.strptime(date,"%Y-%m-%d").date()

@app.route("/player_api.php")
def player_api():
    u = request.args.get("username")
    p = request.args.get("password")
    ip = request.remote_addr
    users = load_json(USERS_FILE)
    if u not in users:
        return jsonify({"user_info":{"auth":0}})
    user = users[u]
    if user["password"] != p or expired(user["expiry"]):
        return jsonify({"user_info":{"auth":0}})
    # 1 active device policy
    if user.get("active_ip") and user["active_ip"] != ip:
        prev_ip = user["active_ip"]
        user["active_ip"] = ip
    else:
        user["active_ip"] = ip
    save_json(USERS_FILE, users)
    return jsonify({"user_info":{"auth":1,"username":u,"exp_date":user["expiry"]}})

@app.route("/live/<username>/<password>/<channel_id>.m3u8")
def proxy_stream(username, password, channel_id):
    users = load_json(USERS_FILE)
    m3u = load_json(M3U_FILE)
    ip = request.remote_addr
    if username not in users:
        return "Unauthorized",401
    user = users[username]
    if user["password"] != password or expired(user["expiry"]):
        return "Unauthorized",401
    # 1 device enforcement
    if user.get("active_ip") != ip:
        return "Device limit active",403
    if channel_id not in m3u:
        return "Channel not found",404
    stream_url = m3u[channel_id]["url"]
    # Fake OTT headers
    headers = {
        "User-Agent": "Smarters/2.0.2",
        "Accept": "*/*",
        "Referer": "http://example.com"
    }
    r = requests.get(stream_url, headers=headers, stream=True)
    return Response(r.iter_content(chunk_size=1024), content_type="application/vnd.apple.mpegurl")

@app.route("/get_user_m3u/<username>/<password>")
def user_m3u(username,password):
    users = load_json(USERS_FILE)
    m3u = load_json(M3U_FILE)
    ip = request.remote_addr
    if username not in users:
        return "Unauthorized",401
    user = users[username]
    if user["password"] != password or expired(user["expiry"]):
        return "Unauthorized",401
    if user.get("active_ip") != ip:
        return "Device limit active",403
    # Build user M3U
    lines = ["#EXTM3U"]
    for cid,data in m3u.items():
        url = f"http://{request.host}/live/{username}/{password}/{cid}.m3u8"
        lines.append(f'#EXTINF:-1,{data.get("name","Channel")}')
        lines.append(url)
    return Response("\n".join(lines), mimetype="audio/x-mpegurl")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
EOF

# ===== PANEL SSH MANAGEMENT =====
cat > panel.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/opt/nialtv"
USERS="$BASE/users.json"
M3U="$BASE/m3u.json"
LOG="$BASE/nialtv.log"
SERVICE="nialtv"

GREEN="\e[1;32m"
RED="\e[1;31m"
YELLOW="\e[1;33m"
NC="\e[0m"

while true; do
    clear
    OS=$(lsb_release -ds)
    IP=$(curl -s ipinfo.io/ip)
    STATUS=$(systemctl is-active $SERVICE || echo "inactive")
    USERS_COUNT=$(jq length "$USERS" 2>/dev/null || echo 0)
    M3U_COUNT=$(jq length "$M3U" 2>/dev/null || echo 0)

    echo -e "${GREEN}=========== NIALTV PANEL ===========${NC}"
    echo -e "${GREEN}OS     :${NC} $OS"
    echo -e "${GREEN}IP     :${NC} $IP"
    echo -e "${GREEN}SERVICE:${NC} $STATUS"
    echo -e "${GREEN}USERS  :${NC} $USERS_COUNT"
    echo -e "${GREEN}CHANNELS:${NC} $M3U_COUNT"
    echo -e "${GREEN}==================================${NC}"

    echo -e "[1] Create User"
    echo -e "[2] Remove User"
    echo -e "[3] Extend User"
    echo -e "[4] List Users"
    echo -e "[5] Update M3U Source"
    echo -e "[6] Restart Service"
    echo -e "[X] Exit"
    read -rp "Select: " opt

    case $opt in
        1)
            read -rp "Username: " u
            read -rp "Password: " p
            read -rp "Valid days: " d
            exp=$(date -d "+$d days" +%Y-%m-%d)
            jq ". + {\"$u\":{\"password\":\"$p\",\"expiry\":\"$exp\",\"active_ip\":\"\"}}" "$USERS" > /tmp/u && mv /tmp/u "$USERS"
            echo -e "$(date '+%Y-%m-%d %H:%M:%S') - USER CREATED: $u | EXP: $exp" >> "$LOG"
            read -n1 -r -p "Press any key..."
            ;;
        2)
            read -rp "Username to remove: " u
            jq "del(.\"$u\")" "$USERS" > /tmp/u && mv /tmp/u "$USERS"
            echo -e "$(date '+%Y-%m-%d %H:%M:%S') - USER REMOVED: $u" >> "$LOG"
            read -n1 -r -p "Press any key..."
            ;;
        3)
            read -rp "Username to extend: " u
            read -rp "Extra days: " d
            new_exp=$(date -d "+$d days" +%Y-%m-%d)
            jq ".\"$u\".expiry=\"$new_exp\"" "$USERS" > /tmp/u && mv /tmp/u "$USERS"
            echo -e "$(date '+%Y-%m-%d %H:%M:%S') - USER EXTENDED: $u | EXP: $new_exp" >> "$LOG"
            read -n1 -r -p "Press any key..."
            ;;
        4)
            jq . "$USERS" | less
            ;;
        5)
            read -rp "M3U Source URL: " url
            # Download & parse M3U
            curl -fsSL "$url" -o "$BASE/m3u_raw.m3u8"
            # Convert to JSON
            jq -n '{}'> "$M3U"
            awk '/^#EXTINF/{name=$0; getline; print name "|" $0}' "$BASE/m3u_raw.m3u8" | while IFS="|" read -r title url; do
                cid=$(echo "$title" | md5sum | cut -d' ' -f1)
                jq ". + {\"$cid\":{\"name\":\"$title\",\"url\":\"$url\"}}" "$M3U" > /tmp/m && mv /tmp/m "$M3U"
            done
            echo -e "$(date '+%Y-%m-%d %H:%M:%S') - M3U UPDATED" >> "$LOG"
            read -n1 -r -p "Press any key..."
            ;;
        6)
            systemctl restart $SERVICE
            echo -e "$(date '+%Y-%m-%d %H:%M:%S') - SERVICE RESTARTED" >> "$LOG"
            read -n1 -r -p "Press any key..."
            ;;
        x|X) exit;;
        *) read -n1 -r -p "Invalid option. Press any key...";;
    esac
done
EOF

chmod +x panel.sh

# ===== SYSTEMD SERVICE =====
cat > /etc/systemd/system/nialtv.service <<EOF
[Unit]
Description=NIALTV M3U PANEL
After=network.target

[Service]
WorkingDirectory=$BASE
ExecStart=$BASE/venv/bin/python $BASE/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nialtv
systemctl restart nialtv

echo -e "${GREEN}✅ Installation complete. Run: ./panel.sh to manage${NC}"

#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================
# NIALTV M3U PANEL – FIXED SCRIPT (AUTO CLEAN M3U)
# Ubuntu 24.04 ONLY
# =========================================

GREEN="\e[1;32m"
RED="\e[1;31m"
YELLOW="\e[1;33m"
NC="\e[0m"

BASE="/opt/nialtv"
SERVICE="nialtv"
LOG="$BASE/nialtv.log"

clear
echo -e "${GREEN}================= NIALTV INSTALLER =================${NC}"

if ! lsb_release -rs | grep -q "^24"; then
  echo -e "${RED}❌ This script supports Ubuntu 24.04 only${NC}"
  exit 1
fi

apt update -y
apt install -y python3 python3-venv python3-pip curl jq ufw ca-certificates

ufw allow 22/tcp
ufw allow 8080/tcp
ufw --force enable

mkdir -p "$BASE"
cd "$BASE"
echo "{}" > users.json
echo "{}" > m3u.json

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install flask requests

cat > app.py <<'EOF'
from flask import Flask, request, Response, jsonify
import json, datetime, requests

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
    user["active_ip"] = ip
    with open(USERS_FILE,"w") as f:
        json.dump(users,f,indent=2)
    return jsonify({"user_info":{"auth":1,"username":u,"exp_date":user["expiry"]}})

@app.route("/live/<username>/<password>/<channel_id>.m3u8")
def proxy_stream(username,password,channel_id):
    users = load_json(USERS_FILE)
    m3u = load_json(M3U_FILE)
    ip = request.remote_addr
    if username not in users:
        return "Unauthorized",401
    user = users[username]
    if user["password"] != password:
        return "Unauthorized",401
    if user.get("active_ip") != ip:
        return "Device limit active",403
    if channel_id not in m3u:
        return "Channel not found",404
    stream_url = m3u[channel_id]["url"]
    headers = {
        "User-Agent":"Smarters/2.0.2",
        "Accept":"*/*",
        "Referer":"http://example.com"
    }
    r = requests.get(stream_url, headers=headers, stream=True, timeout=15)
    return Response(r.iter_content(chunk_size=1024), content_type="application/vnd.apple.mpegurl")

@app.route("/get_user_m3u/<username>/<password>")
def user_m3u(username,password):
    users = load_json(USERS_FILE)
    m3u = load_json(M3U_FILE)
    ip = request.remote_addr
    if username not in users:
        return "Unauthorized",401
    user = users[username]
    if user["password"] != password:
        return "Unauthorized",401
    if user.get("active_ip") != ip:
        return "Device limit active",403
    lines = ["#EXTM3U"]
    for cid,data in m3u.items():
        url = f"http://{request.host}/live/{username}/{password}/{cid}.m3u8"
        lines.append(f"#EXTINF:-1,{data.get('name','Channel')}")
        lines.append(url)
    return Response("\n".join(lines),mimetype="audio/x-mpegurl")

if __name__ == "__main__":
    app.run(host="0.0.0.0",port=8080)
EOF

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
    IP=$(curl -s ipinfo.io/ip||echo "N/A")
    STATUS=$(systemctl is-active "$SERVICE"||echo "inactive")
    UCOUNT=$(jq length "$USERS" 2>/dev/null||echo 0)
    CCOUNT=$(jq length "$M3U" 2>/dev/null||echo 0)

    echo -e "${GREEN}=========== NIALTV PANEL ===========${NC}"
    echo -e "OS      : $OS"
    echo -e "IP      : $IP"
    echo -e "SERVICE : $STATUS"
    echo -e "USERS   : $UCOUNT"
    echo -e "CHANNELS: $CCOUNT"
    echo -e "${GREEN}==================================${NC}"

    echo "[1] Create User"
    echo "[2] Remove User"
    echo "[3] Extend User"
    echo "[4] List Users"
    echo "[5] Update M3U Source"
    echo "[6] Restart Service"
    echo "[X] Exit"
    read -rp "Select: " opt

    case $opt in
        1)
            read -rp "Username   : " u
            read -rp "Password   : " p
            read -rp "Valid days : " d
            exp=$(date -d "+$d days" +%Y-%m-%d)
            jq ". + {\"$u\":{\"password\":\"$p\",\"expiry\":\"$exp\",\"active_ip\":\"\"}}" "$USERS" > /tmp/u && mv /tmp/u "$USERS"
            echo "$(date) - USER CREATED: $u | EXP: $exp" >> "$LOG"
            ;;
        2)
            read -rp "Username to remove: " u
            jq "del(.\"$u\")" "$USERS" > /tmp/u && mv /tmp/u "$USERS"
            echo "$(date) - USER REMOVED: $u" >> "$LOG"
            ;;
        3)
            read -rp "Username to extend: " u
            read -rp "Extra days: " d
            current=$(jq -r --arg u "$u" '.[$u].expiry' "$USERS")
            newexp=$(date -d "$current +$d days" +%Y-%m-%d)
            jq ".\"$u\".expiry=\"$newexp\"" "$USERS" > /tmp/u && mv /tmp/u "$USERS"
            echo "$(date) - EXTENDED: $u to $newexp" >> "$LOG"
            ;;
        4)
            jq -r 'to_entries[] | "\(.key) | Exp: \(.value.expiry)"' "$USERS"
            read -n1 -r -p "Press any key..."
            ;;
        5)
            read -rp "M3U Source URL: " url
            # clean internal quote issues
            curl -fsSL "$url" | sed -E 's/group-title="([^"]*)"/group-title=\1/g; s/tvg-logo="([^"]*)"/tvg-logo=\1/g' > "$BASE/m3u_raw.m3u8"
            jq -n '{}' > "$M3U"
            awk '/^#EXTINF/{n=$0; getline; print n "|" $0}' "$BASE/m3u_raw.m3u8" | while IFS="|" read -r title link; do
                id=$(echo "$title" | md5sum | cut -d' ' -f1)
                jq ". + {\"$id\":{\"name\":\"$title\",\"url\":\"$link\"}}" "$M3U" > /tmp/m && mv /tmp/m "$M3U"
            done
            echo "$(date) - M3U UPDATED" >> "$LOG"
            ;;
        6)
            systemctl restart "$SERVICE"
            echo "$(date) - SERVICE RESTARTED" >> "$LOG"
            ;;
        x|X) exit;;
    esac
done
EOF

chmod +x panel.sh

cat > /etc/systemd/system/nialtv.service <<EOF
[Unit]
Description=NIALTV M3U Panel Service
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

echo -e "${GREEN}✅ Installation complete — run: ./panel.sh${NC}"

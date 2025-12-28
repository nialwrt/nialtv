#!/usr/bin/env bash
set -Eeuo pipefail

#############################################
# NIALTV STABLE XTREAM + M3U8 CONVERTER
# Ubuntu 24.04 ONLY
#############################################

GREEN="\e[1;32m"; RED="\e[1;31m"; YELLOW="\e[1;33m"; NC="\e[0m"

BASE="/opt/nialtv"
SERVICE="nialtv"

clear
echo -e "${GREEN}============= NIALTV INSTALLER =============${NC}"

# ===== OS CHECK =====
if ! lsb_release -rs | grep -q "^24"; then
  echo -e "${RED}Ubuntu 24.04 ONLY${NC}"
  exit 1
fi

# ===== INPUT =====
read -rp "DOMAIN (eg: tv.example.com): " DOMAIN
read -rp "M3U SOURCE URL: " SOURCE_M3U

EMAIL="admin@$DOMAIN"

# ===== DEPENDENCIES =====
apt update -y
apt install -y python3 python3-venv python3-pip curl jq ufw ca-certificates

# ===== FIREWALL =====
ufw allow 22
ufw allow 80
ufw --force enable

# ===== DIRECTORIES =====
mkdir -p "$BASE"
cd "$BASE"

echo "DOMAIN=$DOMAIN" > .env
echo "SOURCE_M3U=$SOURCE_M3U" >> .env
echo "{}" > users.json
touch panel.log

# ===== PYTHON ENV =====
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip flask requests

# ===== FLASK XTREAM SERVER =====
cat > app.py <<EOF
from flask import Flask, request, Response, jsonify
import json, datetime, os, requests

BASE="$BASE"
USERS=f"{BASE}/users.json"
SOURCE=os.environ.get("SOURCE_M3U")
DOMAIN=os.environ.get("DOMAIN")

app = Flask(__name__)

def load_users():
    return json.load(open(USERS))

def expired(d):
    return datetime.date.today() > datetime.datetime.strptime(d,"%Y-%m-%d").date()

@app.route("/player_api.php")
def player_api():
    u=request.args.get("username")
    p=request.args.get("password")
    users=load_users()

    if u not in users or users[u]["password"]!=p or expired(users[u]["expiry"]):
        return jsonify({"user_info":{"auth":0}})

    return jsonify({
        "user_info":{
            "auth":1,
            "username":u,
            "password":p,
            "status":"Active",
            "exp_date":users[u]["expiry"],
            "active_cons":0,
            "max_connections":1
        },
        "server_info":{
            "url":DOMAIN,
            "port":"80",
            "https_port":"",
            "server_protocol":"http"
        }
    })

@app.route("/get.php")
def get_m3u():
    u=request.args.get("username")
    p=request.args.get("password")
    users=load_users()

    if u not in users or users[u]["password"]!=p or expired(users[u]["expiry"]):
        return "Unauthorized",401

    r=requests.get(SOURCE,timeout=15)
    return Response(r.text, mimetype="application/vnd.apple.mpegurl")

@app.route("/")
def root():
    return "NIALTV XTREAM API OK"
EOF

# ===== SYSTEMD =====
cat > /etc/systemd/system/nialtv.service <<EOF
[Unit]
Description=NIALTV Xtream API
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

# ===== SELLER PANEL (SSH ONLY) =====
cat > /usr/bin/nialtv <<'EOF'
#!/usr/bin/env bash
BASE="/opt/nialtv"
USERS="$BASE/users.json"
source "$BASE/.env"

while true; do
clear
echo "=========== NIALTV PANEL ==========="
echo "OS     : $(lsb_release -ds)"
echo "IP     : $(curl -s ifconfig.me)"
echo "DOMAIN : $DOMAIN"
echo "SERVICE: $(systemctl is-active nialtv)"
echo "USERS  : $(jq length $USERS)"
echo "==================================="
echo "1) Create User"
echo "2) Remove User"
echo "3) Extend User"
echo "4) List Users"
echo "5) Restart Service"
echo "X) Exit"
read -rp "Select: " o

case $o in
1)
 read -rp "Username: " u
 read -rp "Password: " p
 read -rp "Days: " d
 exp=$(date -d "+$d days" +%Y-%m-%d)
 jq ". + {\"$u\":{\"password\":\"$p\",\"expiry\":\"$exp\"}}" $USERS > /tmp/u && mv /tmp/u $USERS
 echo "USER CREATED"
 echo "XTREAM URL : http://$DOMAIN"
 echo "USERNAME   : $u"
 echo "PASSWORD   : $p"
 read
;;
2)
 read -rp "Username: " u
 jq "del(.\"$u\")" $USERS > /tmp/u && mv /tmp/u $USERS
 echo "REMOVED"; read;;
3)
 read -rp "Username: " u
 read -rp "Extra days: " d
 exp=$(date -d "+$d days" +%Y-%m-%d)
 jq ".\"$u\".expiry=\"$exp\"" $USERS > /tmp/u && mv /tmp/u $USERS
 echo "EXTENDED"; read;;
4)
 jq . $USERS | less;;
5)
 systemctl restart nialtv; echo "RESTARTED"; read;;
x|X) exit;;
esac
done
EOF

chmod +x /usr/bin/nialtv

echo -e "${GREEN}INSTALL DONE${NC}"
echo -e "Run panel with: nialtv"

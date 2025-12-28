#!/usr/bin/env bash
set -e

BASE="/opt/nialtv"
SERVICE="nialtv"

clear
echo "=========== NIALTV XTREAM INSTALLER ==========="

# DEPENDENCIES
apt update -y
apt install -y python3 python3-pip python3-venv jq curl

# DIRECTORIES
mkdir -p $BASE
cd $BASE
echo "{}" > users.json
echo "#EXTM3U" > source.m3u

# PYTHON ENV
python3 -m venv venv
source venv/bin/activate
pip install flask

# ================= FLASK XTREAM API =================
cat > app.py <<'PY'
from flask import Flask, request, Response, jsonify
import json, os, time

BASE="/opt/nialtv"
USERS=f"{BASE}/users.json"
M3U=f"{BASE}/source.m3u"

app=Flask(__name__)

def load():
    with open(USERS) as f: return json.load(f)

def save(d):
    with open(USERS,"w") as f: json.dump(d,f,indent=2)

def device_id():
    return request.headers.get("X-Device-ID","") + request.headers.get("User-Agent","")

@app.route("/player_api.php")
def api():
    u=request.args.get("username")
    p=request.args.get("password")
    users=load()

    if u not in users or users[u]["password"]!=p:
        return jsonify({"user_info":{"auth":0}})

    did=device_id()
    users[u]["device"]=did
    users[u]["last"]=int(time.time())
    save(users)

    return jsonify({
        "user_info":{
            "auth":1,
            "username":u,
            "status":"Active"
        }
    })

@app.route("/get.php")
def get():
    u=request.args.get("username")
    p=request.args.get("password")
    users=load()

    if u not in users or users[u]["password"]!=p:
        return "Unauthorized",401

    if users[u].get("device")!=device_id():
        users[u]["device"]=device_id()
        save(users)

    return Response(open(M3U).read(),mimetype="application/x-mpegURL")

if __name__=="__main__":
    app.run(host="0.0.0.0",port=80)
PY

# ================= SYSTEMD =================
cat > /etc/systemd/system/nialtv.service <<EOF
[Unit]
Description=NIALTV Xtream IPTV
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

# ================= PANEL =================
cat > /usr/bin/nialtv <<'SH'
#!/usr/bin/env bash
BASE="/opt/nialtv"
USERS="$BASE/users.json"
SERVICE="nialtv"

while true; do
clear
echo "=========== NIALTV PANEL ==========="
echo "OS     : $(lsb_release -ds)"
echo "IP     : $(curl -s ipinfo.io/ip)"
echo "SERVICE: $(systemctl is-active $SERVICE)"
echo "USERS  : $(jq length $USERS)"
echo "==================================="
echo "1) Create User"
echo "2) Remove User"
echo "3) Extend User"
echo "4) List Users"
echo "5) Update M3U"
echo "6) Restart Service"
echo "X) Exit"
read -rp "Select: " x

case $x in
1)
 read -rp "Username: " u
 read -rp "Password: " p
 jq ".+{\"$u\":{\"password\":\"$p\",\"device\":\"\"}}" $USERS > /tmp/u && mv /tmp/u $USERS
 ;;
2)
 read -rp "Username: " u
 jq "del(.\"$u\")" $USERS > /tmp/u && mv /tmp/u $USERS
 ;;
3)
 echo "Auto extend not needed (no expiry)"
 ;;
4)
 jq .
 read -n1
 ;;
5)
 read -rp "M3U URL: " url
 curl -fsSL "$url" -o $BASE/source.m3u
 ;;
6)
 systemctl restart $SERVICE
 ;;
x|X) exit ;;
esac
done
SH

chmod +x /usr/bin/nialtv

echo "DONE. Login SSH and type: nialtv"

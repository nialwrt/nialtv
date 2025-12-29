#!/bin/bash
# ott.sh - Full SSH management menu
set -euo pipefail

BASE="/opt/ott"
DATA="$BASE/data"
LOG="$BASE/logs"

mkdir -p $DATA $LOG

# ------------------------
# Function: Show summary
# ------------------------
info_summary() {
clients=$(jq 'keys | length' $DATA/clients.json)
active=$(jq '[.[] | select(.status=="active")] | length' $DATA/clients.json)
suspended=$(jq '[.[] | select(.status=="suspended")] | length' $DATA/clients.json)
expired=$(jq '[.[] | select(.expire < "'$(date +%F)'")] | length' $DATA/clients.json)
sessions=$(jq 'keys | length' $DATA/sessions.json 2>/dev/null || echo 0)
echo -e "\e[1;33m[INFO]\e[0m Total Clients: $clients | Active: $active | Suspended: $suspended | Expired: $expired | Online: $sessions"
}

# ------------------------
# Function: List clients with details
# ------------------------
list_clients() {
jq -r 'to_entries[] | "\(.key) | Status: \(.value.status) | Expire: \(.value.expire) | Pass: \(.value.pass) | Online: \(.value.device // "None")"' $DATA/clients.json
}

# ------------------------
# Menu Functions
# ------------------------
create_id() {
read -p "Username: " u
read -p "Days valid: " d
exp=$(date -d "+$d days" +%F)
pass=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
jq ". + {\"$u\": {\"pass\":\"$pass\",\"expire\":\"$exp\",\"status\":\"active\"}}" \
$DATA/clients.json > /tmp/c && mv /tmp/c $DATA/clients.json
echo -e "\e[1;32m[OK]\e[0m CREATED: $u | $pass | $exp"
}

renew_id() {
read -p "Username: " u
read -p "Extend days: " d
new=$(date -d "+$d days" +%F)
jq ".\"$u\".expire=\"$new\"" $DATA/clients.json > /tmp/c && mv /tmp/c $DATA/clients.json
echo -e "\e[1;32m[OK]\e[0m RENEWED: $u -> $new"
}

delete_id() {
read -p "Username: " u
jq "del(.\"$u\")" $DATA/clients.json > /tmp/c && mv /tmp/c $DATA/clients.json
echo -e "\e[1;31m[DEL]\e[0m Deleted: $u"
}

suspend_id() {
read -p "Username: " u
jq ".\"$u\".status=\"suspended\"" $DATA/clients.json > /tmp/c && mv /tmp/c $DATA/clients.json
echo -e "\e[1;33m[SUSP]\e[0m Suspended: $u"
}

unsuspend_id() {
read -p "Username: " u
jq ".\"$u\".status=\"active\"" $DATA/clients.json > /tmp/c && mv /tmp/c $DATA/clients.json
echo -e "\e[1;32m[ACTIVE]\e[0m Activated: $u"
}

seed_m3u() {
read -p "M3U URL: " url
wget -qO /tmp/src.m3u "$url"
awk '
/^#EXTINF/ {
  gsub(/tvg-id="[^"]*"/,"tvg-id=\"ott-dummy\"")
  print
  getline
  print "http://server/live/${CLIENT}/${CHANNEL}.m3u8"
}' /tmp/src.m3u > $BASE/master.m3u
echo -e "\e[1;32m[OK]\e[0m M3U seeded -> $BASE/master.m3u"
}

menu() {
clear
echo -e "\e[1;34m=== OTT TV M3U Provider Panel ===\e[0m"
info_summary
echo "
1) Create ID
2) Renew ID
3) Delete ID
4) Suspend ID
5) Unsuspend ID
6) List Clients
7) Seed M3U
0) Exit
"
read -p "Select: " opt
case $opt in
1) create_id ;;
2) renew_id ;;
3) delete_id ;;
4) suspend_id ;;
5) unsuspend_id ;;
6) list_clients ;;
7) seed_m3u ;;
0) exit ;;
*) echo "Invalid";;
esac
read -p "Press Enter to continue..." key
menu
}

# ------------------------
# Auto menu on SSH login
# ------------------------
if [[ $SSH_CONNECTION ]]; then
  menu
fi

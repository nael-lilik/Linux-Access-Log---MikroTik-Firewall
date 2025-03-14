#!/bin/bash

# MikroTik API settings
BASE_URL="http://MikroTik-HOST/rest/ip/firewall/address-list"
USERNAME="security-bot"
PASSWORD="secret-password"

# File log NGINX
LOG_FILE="/var/log/nginx/access.log"

# Daftar IP atau subnet untuk dikecualikan
EXCLUDED_IPS=("127.0.0.1" "10.0.0.0/8")

# Fungsi untuk memeriksa apakah IP termasuk dalam subnet atau dikecualikan
is_excluded() {
  local ip=$1
  for excluded in "${EXCLUDED_IPS[@]}"; do
    if [[ $excluded == *"/"* ]]; then
      cidr=$(echo "$excluded" | cut -d '/' -f 2)
      base=$(echo "$excluded" | cut -d '/' -f 1)
      if [[ $ip =~ ^${base%.*}\.* ]]; then
        return 0
      fi
    elif [[ $ip == "$excluded" ]]; then
      return 0
    fi
  done
  return 1
}

# Fungsi untuk mengkonversi format timeout MikroTik ke total detik
convert_to_seconds() {
  local time=$1
  local seconds=0
  local d h m s

  # Ekstrak hari, jam, menit, dan detik dari string waktu
  d=$(echo "$time" | grep -o '[0-9]\+d' | sed 's/d//')
  h=$(echo "$time" | grep -o '[0-9]\+h' | sed 's/h//')
  m=$(echo "$time" | grep -o '[0-9]\+m' | sed 's/m//')
  s=$(echo "$time" | grep -o '[0-9]\+s' | sed 's/s//')

  # Default ke 0 jika tidak ditemukan
  d=${d:-0}
  h=${h:-0}
  m=${m:-0}
  s=${s:-0}

  # Validasi bahwa semua nilai adalah angka
  if ! [[ "$d" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ && "$m" =~ ^[0-9]+$ && "$s" =~ ^[0-9]+$ ]]; then
    echo "DEBUG: Invalid time format: $time"
    echo "0"
    return
  fi

  # Konversi ke total detik
  seconds=$((d * 86400 + h * 3600 + m * 60 + s))
  echo "$seconds"
}

# Fungsi untuk mengkonversi total detik ke format waktu MikroTik (d hh:mm:ss)
convert_to_mikrotik_time() {
  local seconds=$1
  local d h m s

  d=$((seconds / 86400))
  h=$(( (seconds % 86400) / 3600 ))
  m=$(( (seconds % 3600) / 60 ))
  s=$((seconds % 60))

  if (( d > 0 )); then
    printf "%dd %02d:%02d:%02d\n" $d $h $m $s
  else
    printf "%02d:%02d:%02d\n" $h $m $s
  fi
}

# Fungsi untuk memeriksa apakah IP sudah ada di address-list
is_existing() {
  local ip=$1
  echo "DEBUG: Checking if IP exists: $ip"
  CURL_RESPONSE=$(curl -s -X POST "$BASE_URL/print" \
    -u "$USERNAME:$PASSWORD" \
    -H "Content-Type: application/json" \
    -d '{
          ".query": ["address='"$ip"'", "list=intruder"]
        }')
  echo "DEBUG: API Response for IP check: $CURL_RESPONSE"
  echo "$CURL_RESPONSE" | jq -r ".[0].timeout"
}

# Fungsi untuk menghapus IP dari address-list
delete_ip() {
  local ip=$1
  echo "DEBUG: Checking if IP exists before deletion: $ip"

  CURL_RESPONSE=$(curl -s -X POST "$BASE_URL/print" \
    -u "$USERNAME:$PASSWORD" \
    -H "Content-Type: application/json" \
    -d '{
          ".query": ["address='"$ip"'", "list=intruder"]
        }')

  local id=$(echo "$CURL_RESPONSE" | jq -r ".[0].\".id\"")

  echo "DEBUG: API Response for ID check: $CURL_RESPONSE"
  if [[ -n "$id" && "$id" != "null" ]]; then
    echo "DEBUG: Found ID $id for IP $ip. Proceeding to delete."
    DELETE_RESPONSE=$(curl -s -X DELETE "$BASE_URL/$id" -u "$USERNAME:$PASSWORD")
    echo "DEBUG: Deletion Response: $DELETE_RESPONSE"
    echo "Deleted IP: $ip from address-list"
  else
    echo "DEBUG: No valid ID found for $ip. Skipping deletion."
  fi
}

# Fungsi untuk membuat entri baru
create_entry() {
  local ip=$1
  local timeout=$2
  echo "DEBUG: Creating entry for IP: $ip with timeout: $timeout"
  PAYLOAD='{
    "address": "'"$ip"'",
    "list": "intruder",
    "disabled": "false",
    "comment": "Automatically added by Nael Security Check",
    "dynamic": "false",
    "timeout": "'"$timeout"'"
  }'
  CURL_RESPONSE=$(curl -s -X POST "$BASE_URL/add" \
    -u "$USERNAME:$PASSWORD" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")
  if echo "$CURL_RESPONSE" | grep -q "failure: already have such entry"; then
    echo "DEBUG: Entry for IP $ip already exists. Skipping creation."
  else
    echo "DEBUG: Create Response: $CURL_RESPONSE"
  fi
}

# Ambil waktu satu jam yang lalu dalam format log NGINX - disesuaikan
START_TIME=$(date --date="0 hour ago" "+%d/%b/%Y:%H")

# Ambil 5000 baris terakhir dan filter log dari satu jam terakhir
#TOP_IPS=$(tail -n 5000 "$LOG_FILE" | grep "$START_TIME" | awk '{print $1}' | sort | uniq -c | sort -nr | awk '$1 >= 50 {print $2}' | head -n 3)
TOP_IPS=$(tail -n 10000 "$LOG_FILE" | awk '{print $1}' | sort | uniq -c | sort -nr | awk '$1 >= 50 {print $2}')


# Loop untuk setiap IP top
for IP in $TOP_IPS; do
  if is_excluded "$IP"; then
    echo "Excluded IP: $IP"
    continue
  fi

  if [[ -n "$EXISTING_TIMEOUT" ]]; then
    EXISTING_SECONDS=$(convert_to_seconds "$EXISTING_TIMEOUT")
    if [[ -z "$EXISTING_SECONDS" || "$EXISTING_SECONDS" -eq 0 ]]; then
      echo "DEBUG: Failed to convert timeout for IP $IP. Setting default."
      EXISTING_SECONDS=0
    fi
    NEW_SECONDS=$((EXISTING_SECONDS + 3600)) # Tambahkan 1 jam
    NEW_TIMEOUT=$(convert_to_mikrotik_time "$NEW_SECONDS")
    echo "DEBUG: IP $IP is a repeat offender. Re-adding with timeout: $NEW_TIMEOUT"
  else
    NEW_TIMEOUT="1h"
    echo "DEBUG: Adding new IP $IP with timeout: $NEW_TIMEOUT"
  fi

  create_entry "$IP" "$NEW_TIMEOUT"
done

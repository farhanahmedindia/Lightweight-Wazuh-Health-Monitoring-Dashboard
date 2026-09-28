#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG=/etc/wazuh-health-dashboard.conf
OUTPUT_DIR=/var/www/wazuh-health
[[ -r "$CONFIG" ]] || { echo "Missing $CONFIG" >&2; exit 1; }
source "$CONFIG"

: "${WAZUH_INDEXER_URL:?Set WAZUH_INDEXER_URL in $CONFIG}"
: "${WAZUH_INDEXER_USER:?Set WAZUH_INDEXER_USER in $CONFIG}"
: "${WAZUH_INDEXER_PASSWORD:?Set WAZUH_INDEXER_PASSWORD in $CONFIG}"
mkdir -p "$OUTPUT_DIR"

curl_args=(--silent --show-error --fail --connect-timeout 5 --max-time 15
  --user "$WAZUH_INDEXER_USER:$WAZUH_INDEXER_PASSWORD")
if [[ "${WAZUH_INDEXER_INSECURE_TLS:-false}" == "true" ]]; then
  curl_args+=(--insecure)
elif [[ -n "${WAZUH_INDEXER_CA:-}" ]]; then
  curl_args+=(--cacert "$WAZUH_INDEXER_CA")
fi

service_state() { systemctl is-active --quiet "$1" && printf 'running' || printf 'stopped'; }

cpu_sample() {
  local -a first second
  read -r -a first < /proc/stat
  sleep 1
  read -r -a second < /proc/stat
  local total1=0 total2=0 i
  for ((i=1;i<${#first[@]};i++)); do total1=$((total1+first[i])); done
  for ((i=1;i<${#second[@]};i++)); do total2=$((total2+second[i])); done
  local idle1=$((first[4]+first[5])) idle2=$((second[4]+second[5]))
  local delta_total=$((total2-total1)) delta_idle=$((idle2-idle1))
  awk -v t="$delta_total" -v i="$delta_idle" 'BEGIN{if(t>0)printf "%.1f",(t-i)*100/t;else print "0.0"}'
}

cluster=$(curl "${curl_args[@]}" "$WAZUH_INDEXER_URL/_cluster/health?filter_path=status,number_of_nodes,active_shards,unassigned_shards" 2>/dev/null || printf '{"status":"red","number_of_nodes":0,"active_shards":0,"unassigned_shards":0}')
indices=$(curl "${curl_args[@]}" "$WAZUH_INDEXER_URL/_cat/indices/wazuh-alerts-*?format=json&bytes=b&h=health,index,docs.count,store.size" 2>/dev/null || printf '[]')

daily=$(printf '%s' "$indices" | jq -c '
  map(select(.index | startswith("wazuh-alerts-")) |
      {date: (.index | split("-") | last | gsub("\\."; "-")),
       sizeBytes: (."store.size" | tonumber? // 0),
       documents: (."docs.count" | tonumber? // 0),
       health: (.health // "unknown")}) |
  sort_by(.date) | .[-14:]')
manager=$(service_state wazuh-manager)
indexer_service=$(service_state wazuh-indexer)
dashboard=$(service_state wazuh-dashboard)
cpu_percent=$(cpu_sample)
read -r memory_total memory_used memory_available < <(free -b | awk '/^Mem:/ {print $2,$3,$7}')
read -r disk_total disk_used disk_available disk_percent < <(df -B1 / | awk 'NR==2 {gsub("%","",$5);print $2,$3,$4,$5}')

overall=healthy
[[ "$manager" == running && "$indexer_service" == running && "$(printf '%s' "$cluster"|jq -r '.status // "red"')" == green ]] || overall=warning

tmp=$(mktemp "$OUTPUT_DIR/.health.json.XXXXXX")
jq -n   --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)"   --arg overall "$overall"   --arg manager "$manager" --arg indexerService "$indexer_service" --arg dashboard "$dashboard"   --argjson cpuPercent "$cpu_percent"   --argjson memory "{\"totalBytes\":$memory_total,\"usedBytes\":$memory_used,\"availableBytes\":$memory_available,\"usedPercent\":$((memory_used*100/memory_total))}" \
  --argjson disk "{\"totalBytes\":$disk_total,\"usedBytes\":$disk_used,\"availableBytes\":$disk_available,\"usedPercent\":$disk_percent}"   --argjson cluster "$cluster" --argjson ingestion "$daily"   '{generatedAt:$generatedAt,overall:$overall,services:{"wazuh-manager":$manager,"wazuh-indexer":$indexerService,"wazuh-dashboard":$dashboard},system:{cpuPercent:$cpuPercent,memory:$memory,disk:$disk},indexer:$cluster,ingestion:$ingestion}' > "$tmp"
install -m 0644 "$tmp" "$OUTPUT_DIR/health.json"
rm -f "$tmp"

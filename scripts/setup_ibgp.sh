#!/bin/bash

set -euo pipefail

# ===== 必填：当前节点 ID =====
SELF_ID="${SELF_ID:-}"

if [ -z "$SELF_ID" ]; then
  echo "ERROR: SELF_ID is required (e.g. SELF_ID=2 ./script.sh)"
  exit 1
fi

IDX_START=1
IDX_END=11

IP_TEMPLATE="2406:840:e300:ffee:3397::{{IDX}}"
OUTPUT_DIR="/etc/bird/ibgp"
mkdir -p "$OUTPUT_DIR"

ASN=150184
NEIGHBOR_COUNT=5

# ===== 工具函数 =====

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

pad_idx() {
  printf "%03d" "$1"
}

gen_ip() {
  echo "$IP_TEMPLATE" | sed "s/{{IDX}}/$1/g"
}

get_latency() {
  local ip=$1
  local result

  result=$(ping -c 3 -W 1 "$ip" 2>/dev/null || true)
  echo "$result" | awk -F'/' '/avg/ {print $5}'
}

# ===== 当前节点信息 =====

SELF_IDX=$(pad_idx "$SELF_ID")
SELF_IP=$(gen_ip "$SELF_ID")
INTERFACE="kawaiinet${SELF_IDX}"

log "=============================="
log "Current Node: $SELF_IDX ($SELF_IP)"
log "Interface: $INTERFACE"

TMP_FILE=$(mktemp)

# ===== 探测其他节点 =====

for ((j=IDX_START; j<=IDX_END; j++)); do
  if [ "$j" -eq "$SELF_ID" ]; then
    log "Skip self node $j"
    continue
  fi

  REMOTE_IP=$(gen_ip $j)

  log "Probing node $(pad_idx $j) ($REMOTE_IP)..."

  LATENCY=$(get_latency "$REMOTE_IP")

  if [ -z "$LATENCY" ]; then
    LATENCY=9999
    log "  -> unreachable (set latency=9999)"
  else
    log "  -> latency=${LATENCY} ms"
  fi

  echo "$LATENCY $j" >> "$TMP_FILE"
done

# ===== 选邻居 =====

NEIGHBORS=$(sort -n "$TMP_FILE" | head -n "$NEIGHBOR_COUNT" | awk '{print $2}')
rm -f "$TMP_FILE"

log "Selected neighbors: $(echo $NEIGHBORS)"

# ===== 生成配置 =====

CONF_FILE="${OUTPUT_DIR}/I_AUTO_${SELF_IDX}.conf"
> "$CONF_FILE"

for n in $NEIGHBORS; do
  REMOTE_IDX=$(pad_idx $n)
  REMOTE_IP=$(gen_ip $n)

  PROTO_NAME="I_${SELF_IDX}_${REMOTE_IDX}"

  log "Generating BGP session: $PROTO_NAME -> $REMOTE_IP"

  cat >> "$CONF_FILE" <<EOF
protocol bgp ${PROTO_NAME} from template_ibgp {
  neighbor ${REMOTE_IP} as ${ASN};
  source address ${SELF_IP};
  direct;
}
EOF

  echo "" >> "$CONF_FILE"
done

log "Config written: $CONF_FILE"
log "======== DONE ========"
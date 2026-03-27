#!/bin/bash

set -euo pipefail

# ===== 配置区域 =====
SELF_ID="${SELF_ID:-}"
IDX_START=1
IDX_END=11
IP_TEMPLATE="2406:840:e300:ffee:3397::{{IDX}}"
OUTPUT_DIR="/etc/bird/ibgp"
ASN=150184
NEIGHBOR_COUNT=5

# ===== 过滤阈值 (可调整) =====
MAX_LATENCY_MS=120       # 最大允许延迟 (ms)
MAX_LOSS_PERCENT=20       # 最大允许丢包率 (%)
PING_COUNT=10            # Ping 包数量
PING_TIMEOUT=1           # 单个包超时时间 (s)

# ===== 必填检查 =====
if [ -z "$SELF_ID" ]; then
  echo "ERROR: SELF_ID is required (e.g. SELF_ID=2 ./script.sh)"
  exit 1
fi

# ===== 初始化 =====
mkdir -p "$OUTPUT_DIR"
TMP_FILE=$(mktemp)

trap 'rm -f "$TMP_FILE"' EXIT

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

# 获取延迟和丢包率
# 返回格式："loss latency" (例如："0 12.5")
get_ping_stats() {
  local ip=$1
  local ping_output
  local loss="100"
  local latency="9999"

  ping_output=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ip" 2>&1 || true)

  # 解析丢包率 (寻找 % packet loss)
  loss=$(echo "$ping_output" | grep -oP '\d+(?=% packet loss)' || echo "100")
  if [ -z "$loss" ]; then loss="100"; fi

  # 解析平均延迟 (保留原来的逻辑，使用 / 分隔取第 5 个字段)
  latency=$(echo "$ping_output" | awk -F'/' '/avg/ {print $5}')
  if [ -z "$latency" ]; then latency="9999"; fi

  echo "$loss $latency"
}

# ===== 当前节点信息 =====
SELF_IDX=$(pad_idx "$SELF_ID")
SELF_IP=$(gen_ip "$SELF_ID")
INTERFACE="kawaiinet${SELF_IDX}"

log "=============================="
log "Current Node: $SELF_IDX ($SELF_IP)"
log "Interface: $INTERFACE"
log "Filter: Latency <= ${MAX_LATENCY_MS}ms, Loss <= ${MAX_LOSS_PERCENT}%"
log "=============================="

# ===== 探测其他节点 =====
valid_count=0

for ((j=IDX_START; j<=IDX_END; j++)); do
  if [ "$j" -eq "$SELF_ID" ]; then
    continue
  fi

  REMOTE_IP=$(gen_ip "$j")
  REMOTE_IDX_PAD=$(pad_idx "$j")

  log "Probing node $REMOTE_IDX_PAD ($REMOTE_IP)..."

  read -r LOSS LATENCY <<< "$(get_ping_stats "$REMOTE_IP")"

  # 格式化显示
  LOSS_DISPLAY="${LOSS}%"
  if [ "$LATENCY" == "9999" ] || [ -z "$LATENCY" ]; then
    LATENCY_DISPLAY="unreachable"
  else
    LATENCY_DISPLAY="${LATENCY} ms"
  fi

  # ===== 过滤逻辑 =====
  is_valid=true

  # 1. 检查是否不可达
  if [ "$LOSS" -ge 100 ] || [ "$LATENCY" == "9999" ] || [ -z "$LATENCY" ]; then
    log "  -> SKIP: Unreachable (Loss: $LOSS_DISPLAY, Lat: $LATENCY_DISPLAY)"
    is_valid=false
  fi

  # 2. 检查丢包率阈值
  if [ "$is_valid" == true ] && [ "$LOSS" -gt "$MAX_LOSS_PERCENT" ]; then
    log "  -> SKIP: High Packet Loss (Loss: $LOSS_DISPLAY > ${MAX_LOSS_PERCENT}%)"
    is_valid=false
  fi

  # 3. 检查延迟阈值 (浮点数比较)
  if [ "$is_valid" == true ]; then
    exceed_latency=$(awk -v lat="$LATENCY" -v max="$MAX_LATENCY_MS" 'BEGIN {print (lat > max) ? 1 : 0}')
    if [ "$exceed_latency" -eq 1 ]; then
      log "  -> SKIP: High Latency (Lat: $LATENCY_DISPLAY > ${MAX_LATENCY_MS}ms)"
      is_valid=false
    fi
  fi

  # 如果通过过滤，写入临时文件
  if [ "$is_valid" == true ]; then
    log "  -> PASS (Loss: $LOSS_DISPLAY, Lat: $LATENCY_DISPLAY)"
    echo "$LOSS $LATENCY $j" >> "$TMP_FILE"
    ((valid_count++)) || true
  fi
done

# ===== 选邻居 =====
if [ "$valid_count" -eq 0 ]; then
  log "WARNING: No valid neighbors found matching criteria!"
  log "Please check network connectivity or adjust thresholds."
  CONF_FILE="${OUTPUT_DIR}/I_AUTO_${SELF_IDX}.conf"
  > "$CONF_FILE"
  exit 0
fi

# 排序：优先丢包率低，其次延迟低
NEIGHBORS=$(sort -g -k1,1 -k2,2 "$TMP_FILE" | head -n "$NEIGHBOR_COUNT" | awk '{print $3}')

log "Selected ${NEIGHBOR_COUNT} neighbors from $valid_count valid candidates."
log "Neighbors ID: $(echo $NEIGHBORS | tr '\n' ' ')"

# ===== 生成配置 =====
CONF_FILE="${OUTPUT_DIR}/I_AUTO_${SELF_IDX}.conf"
> "$CONF_FILE"

for n in $NEIGHBORS; do
  REMOTE_IDX=$(pad_idx "$n")
  REMOTE_IP=$(gen_ip "$n")
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
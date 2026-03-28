#!/bin/bash

set -euo pipefail

# ===== 配置区域 =====
SELF_ID="${SELF_ID:-}"
IDX_START=1
IDX_END=13
IP_TEMPLATE="2406:840:e300:ffee:3397::{{IDX}}"
OUTPUT_DIR="/etc/bird/ibgp"
ASN=150184
NEIGHBOR_COUNT=5

# ===== 过滤阈值 (可调整) =====
MAX_LATENCY_MS=120       # 最大允许延迟 (ms)
MAX_LOSS_PERCENT=20      # 最大允许丢包率 (%)
PING_COUNT=10            # Ping 包数量
PING_TIMEOUT=1           # 单个包超时时间 (s)

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

# 自动检测 SELF_ID
auto_detect_self_id() {
  local interface_pattern="kawaiinet"
  local found_id=""
  local found_count=0

  # 方法 1: 通过 ip 命令查找匹配的接口
  while IFS= read -r iface; do
    if [[ "$iface" =~ ^${interface_pattern}([0-9]+)$ ]]; then
      local id="${BASH_REMATCH[1]}"
      # 去掉前导零
      id=$(echo "$id" | sed 's/^0*//')
      [ -z "$id" ] && id="0"
      
      if [ -n "$found_id" ]; then
        found_count=$((found_count + 1))
      else
        found_id="$id"
      fi
    fi
  done < <(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1)

  # 方法 2: 如果方法 1 没找到，尝试通过 /sys/class/net
  if [ -z "$found_id" ] && [ -d "/sys/class/net" ]; then
    for iface in /sys/class/net/*; do
      local name=$(basename "$iface")
      if [[ "$name" =~ ^${interface_pattern}([0-9]+)$ ]]; then
        local id="${BASH_REMATCH[1]}"
        id=$(echo "$id" | sed 's/^0*//')
        [ -z "$id" ] && id="0"
        
        if [ -n "$found_id" ]; then
          found_count=$((found_count + 1))
        else
          found_id="$id"
        fi
      fi
    done
  fi

  # 返回结果
  if [ -z "$found_id" ]; then
    echo ""
  elif [ "$found_count" -gt 0 ]; then
    # 找到多个接口，返回第一个并警告
    echo "$found_id"
    return 1
  else
    echo "$found_id"
    return 0
  fi
}

# 获取延迟和丢包率
get_ping_stats() {
  local ip=$1
  local ping_output
  local loss="100"
  local latency="9999"

  ping_output=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ip" 2>&1 || true)

  # 解析丢包率
  loss=$(echo "$ping_output" | awk '/packet loss/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+%$/) {gsub(/%/,"",$i); print $i; exit}}')
  if [ -z "$loss" ]; then loss="100"; fi

  # 解析平均延迟 (使用 / 分隔取第 5 个字段)
  latency=$(echo "$ping_output" | awk -F'/' '/avg/ {print $5}')
  if [ -z "$latency" ]; then latency="9999"; fi

  echo "$loss $latency"
}

# ===== 自动识别或手动指定 SELF_ID =====
if [ -z "$SELF_ID" ]; then
  log "SELF_ID not specified, auto-detecting..."
  
  detected_id=$(auto_detect_self_id)
  detect_status=$?

  if [ -z "$detected_id" ]; then
    log "ERROR: No kawaiinet interface found!"
    log "Please specify SELF_ID manually (e.g. SELF_ID=2 ./script.sh)"
    log "Or create interface with name pattern: kawaiinet001, kawaiinet002, etc."
    exit 1
  fi

  SELF_ID="$detected_id"
  
  if [ "$detect_status" -ne 0 ]; then
    log "WARNING: Multiple kawaiinet interfaces found, using first one: $SELF_ID"
  else
    log "Auto-detected SELF_ID: $SELF_ID"
  fi
else
  log "Using specified SELF_ID: $SELF_ID"
fi

# ===== 初始化 =====
mkdir -p "$OUTPUT_DIR"
TMP_FILE=$(mktemp)

trap 'rm -f "$TMP_FILE"' EXIT

# ===== 当前节点信息 =====
SELF_IDX=$(pad_idx "$SELF_ID")
SELF_IP=$(gen_ip "$SELF_ID")
INTERFACE="kawaiinet${SELF_IDX}"

# 验证接口是否存在
if ! ip link show "$INTERFACE" &>/dev/null; then
  log "WARNING: Interface $INTERFACE does not exist!"
  log "Proceeding anyway (interface may be created later)..."
fi

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

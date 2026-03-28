#!/bin/bash

set -euo pipefail

# ===== 配置区域 =====
SELF_ID="${SELF_ID:-}"
IP_TEMPLATE="2406:840:e300:ffee:3397::{{IDX}}"
OUTPUT_DIR="/etc/bird/ibgp"
LIST_FILE="/etc/bird/config/ibgp.list"
ASN=150184

# ===== 工具函数 =====

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

# 用于生成带前导零的十进制编号 (用于协议命名, 如 001, 013)
pad_idx() {
  printf "%03d" "$1"
}

# 将十进制 ID 转换为十六进制并生成 IPv6 地址
gen_ip_hex() {
  local dec_id="$1"
  local hex_id=$(printf "%x" "$dec_id")
  echo "$IP_TEMPLATE" | sed "s/{{IDX}}/$hex_id/g"
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

# ===== 初始化与验证 =====
mkdir -p "$OUTPUT_DIR"
SELF_IDX=$(pad_idx "$SELF_ID")
SELF_IP=$(gen_ip_hex "$SELF_ID")
INTERFACE="kawaiinet${SELF_IDX}"

log "=============================="
log "Current Node: ID $SELF_ID (Padded: $SELF_IDX)"
log "Local IPv6  : $SELF_IP"
log "Interface   : $INTERFACE"
log "=============================="

if [ ! -f "$LIST_FILE" ]; then
  log "ERROR: Topology file $LIST_FILE not found!"
  exit 1
fi

# ===== 读取并解析拓扑文件 =====
# 声明一个关联数组用于去重
declare -A NEIGHBORS_MAP

log "Parsing topology file: $LIST_FILE"
while IFS= read -r line || [ -n "$line" ]; do
  # 去除行内的注释 (即 # 及之后的所有内容)
  line="${line%%#*}"
  # 去除所有的空白字符
  line="${line//[[:space:]]/}"
  
  # 忽略空行
  if [[ -z "$line" ]]; then
    continue
  fi

  # 匹配 A,B 格式
  if [[ "$line" =~ ^([0-9]+),([0-9]+)$ ]]; then
    NODE_A="${BASH_REMATCH[1]}"
    NODE_B="${BASH_REMATCH[2]}"

    # 双向匹配：只要自己是其中一端，就把另一端加入邻居列表
    if [ "$NODE_A" -eq "$SELF_ID" ]; then
      NEIGHBORS_MAP["$NODE_B"]=1
    elif [ "$NODE_B" -eq "$SELF_ID" ]; then
      NEIGHBORS_MAP["$NODE_A"]=1
    fi
  else
    log "WARNING: Unrecognized line format, ignoring: $line"
  fi
done < "$LIST_FILE"

# 提取所有的邻居节点 ID
NEIGHBORS="${!NEIGHBORS_MAP[@]}"

if [ ${#NEIGHBORS_MAP[@]} -eq 0 ]; then
  log "WARNING: No neighbors found for SELF_ID $SELF_ID in $LIST_FILE."
  CONF_FILE="${OUTPUT_DIR}/I_AUTO_${SELF_IDX}.conf"
  > "$CONF_FILE" # 生成空文件
  exit 0
fi

log "Found unique neighbors ID: $(echo $NEIGHBORS | tr '\n' ' ')"

# ===== 生成配置 =====
CONF_FILE="${OUTPUT_DIR}/I_AUTO_${SELF_IDX}.conf"
> "$CONF_FILE"

# 为了输出美观，对邻居 ID 进行排序后处理
for n in $(echo "$NEIGHBORS" | tr ' ' '\n' | sort -n); do
  REMOTE_IDX=$(pad_idx "$n")
  REMOTE_IP=$(gen_ip_hex "$n")
  PROTO_NAME="I_${SELF_IDX}_${REMOTE_IDX}"

  log "Generating BGP session: $PROTO_NAME -> $REMOTE_IP (Hex ID: $(printf "%x" "$n"))"

  cat >> "$CONF_FILE" <<EOF
protocol bgp ${PROTO_NAME} from template_ibgp {
  neighbor ${REMOTE_IP} as ${ASN};
  source address ${SELF_IP};
  direct;
}

EOF
done

log "Config successfully written to: $CONF_FILE"
log "======== DONE ========"
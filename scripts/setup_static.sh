#!/bin/bash

set -euo pipefail

INPUT_FILE="/etc/bird/data/prefixes_v6.list"
OUTPUT_FILE="/etc/bird/static.conf"

# 必填：ASN
SELF_ASN="${SELF_ASN:-150184}"

if [ ! -f "$INPUT_FILE" ]; then
  echo "ERROR: input file not found: $INPUT_FILE"
  exit 1
fi

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

log "Reading prefixes from: $INPUT_FILE"
log "Output file: $OUTPUT_FILE"
log "ASN: $SELF_ASN"

TMP_FILE=$(mktemp)

# ===== 写头 =====
cat > "$TMP_FILE" <<EOF
protocol static {
  ipv6 {
    import all;
    export none;
  };

EOF

COUNT=0

# ===== 逐行处理 =====
while IFS= read -r line || [ -n "$line" ]; do
  # 去掉空格
  prefix=$(echo "$line" | xargs)

  # 跳过空行和注释
  if [[ -z "$prefix" || "$prefix" =~ ^# ]]; then
    continue
  fi

  # 简单校验 IPv6 CIDR 格式
  if ! [[ "$prefix" =~ : && "$prefix" =~ / ]]; then
    log "Skip invalid line: $prefix"
    continue
  fi

  log "Adding prefix: $prefix"

  cat >> "$TMP_FILE" <<EOF
  route $prefix reject {
    bgp_large_community.add((${SELF_ASN}, 114514, 1));
  };

EOF

  COUNT=$((COUNT+1))

done < "$INPUT_FILE"

# ===== 写尾 =====
cat >> "$TMP_FILE" <<EOF
}
EOF

# 原子替换
mv "$TMP_FILE" "$OUTPUT_FILE"

log "Generated $COUNT routes"
log "Done."
#!/usr/bin/env bash
set -euo pipefail

########################################
# Interactive prompts
########################################

read -rp "Elasticsearch URL [http://localhost:9200]: " ES
ES="${ES:-http://localhost:9200}"

read -rp "Use Basic Auth? (y/n) [y]: " USE_BASIC
USE_BASIC="${USE_BASIC:-y}"

AUTH=""
if [[ "$USE_BASIC" =~ ^[Yy]$ ]]; then
    read -rp "Username: " ES_USER
    read -rsp "Password: " ES_PASS
    echo ""
    AUTH="Authorization: Basic $(echo -n "$ES_USER:$ES_PASS" | base64)"
fi

read -rp "Number of newest indices to keep [5]: " KEEP
KEEP="${KEEP:-5}"

read -rp "Dry run? (true/false) [true]: " DRY_RUN
DRY_RUN="${DRY_RUN:-true}"

read -rp "Index patterns (comma-separated, e.g., logs-*,metrics-*) [logs-*,metrics-*]: " INCLUDE_PATTERNS
INCLUDE_PATTERNS="${INCLUDE_PATTERNS:-logs-*,metrics-*}"
IFS=',' read -r -a PATTERNS <<< "$INCLUDE_PATTERNS"

read -rp "Low disk warning threshold % [85]: " LOW_WARNING
LOW_WARNING="${LOW_WARNING:-85}"

read -rp "High disk warning threshold % [90]: " HIGH_WARNING
HIGH_WARNING="${HIGH_WARNING:-90}"

read -rp "Flood stage threshold % [95]: " FLOOD_STAGE
FLOOD_STAGE="${FLOOD_STAGE:-95}"

# System indices prefixes to always skip
SYSTEM_PREFIXES=(
  "."
  ".kibana"
  ".security"
  ".monitoring"
  ".fleet"
  ".tasks"
  ".ml"
  ".transform"
  ".ds-"
)

########################################
# Disk usage check
########################################
echo ""
echo "Checking disk usage per node..."
NODE_DISKS=$(curl -s -H "$AUTH" "$ES/_cat/allocation?h=node,disk.percent" | sort -k2 -nr)

HIGHEST_DISK=$(echo "$NODE_DISKS" | head -n1 | awk '{print $2}')
HIGHEST_NODE=$(echo "$NODE_DISKS" | head -n1 | awk '{print $1}')

echo "Highest disk usage: $HIGHEST_DISK% on node $HIGHEST_NODE"

if [ "$HIGHEST_DISK" -ge "$FLOOD_STAGE" ]; then
  echo "⚠️ WARNING: Disk usage at or above flood stage ($FLOOD_STAGE%) on $HIGHEST_NODE."
elif [ "$HIGHEST_DISK" -ge "$HIGH_WARNING" ]; then
  echo "⚠️ High disk usage warning ($HIGH_WARNING%) on $HIGHEST_NODE."
elif [ "$HIGHEST_DISK" -ge "$LOW_WARNING" ]; then
  echo "⚠️ Disk usage approaching threshold ($LOW_WARNING%) on $HIGHEST_NODE."
fi

########################################
# Fetch indices and sizes
########################################
INDICES_RAW=$(curl -s -H "$AUTH" "$ES/_cat/indices?h=index,store.size&format=json" \
  | jq -r '.[] | "\(.index)\t\(.store.size)"')

declare -A INDEX_CREATION
for line in $(curl -s -H "$AUTH" "$ES/_settings?filter_path=*.settings.index.creation_date" \
    | jq -r 'to_entries[] | "\(.key)\t\(.value.settings.index.creation_date)"'); do
  idx=$(echo "$line" | cut -f1)
  ts=$(echo "$line" | cut -f2)
  INDEX_CREATION["$idx"]=$ts
done

########################################
# Filter eligible indices
########################################
ELIGIBLE=()
declare -A INDEX_SIZE

while IFS=$'\t' read -r index size; do
  # Skip system indices
  skip=false
  for prefix in "${SYSTEM_PREFIXES[@]}"; do
    [[ "$index" == $prefix* ]] && skip=true && break
  done
  [ "$skip" = true ] && continue

  # Apply include patterns
  match=false
  for pattern in "${PATTERNS[@]}"; do
    [[ "$index" == $pattern ]] && match=true
  done
  [ "$match" = false ] && continue

  created=${INDEX_CREATION[$index]:-0}
  ELIGIBLE+=("$created|$index")
  INDEX_SIZE["$index"]=$size
done <<< "$INDICES_RAW"

TOTAL=${#ELIGIBLE[@]}

if [ "$TOTAL" -le "$KEEP" ]; then
  echo "Only $TOTAL eligible indices found. Nothing to delete."
  exit 0
fi

# Sort oldest → newest
IFS=$'\n' SORTED=($(sort -n <<<"${ELIGIBLE[*]}"))
unset IFS
DELETE_COUNT=$((TOTAL - KEEP))

########################################
# Generate report
########################################
echo ""
printf "%-30s %-20s %-12s %-15s\n" "INDEX" "CREATED DATE" "SIZE" "ACTION"
echo "-------------------------------------------------------------------------------"

TOTAL_SIZE_TO_FREE=0
for ((i=0; i<TOTAL; i++)); do
  index=$(echo "${SORTED[$i]}" | cut -d'|' -f2)
  created_ts=$(echo "${SORTED[$i]}" | cut -d'|' -f1)
  created_human=$(date -d @"$((created_ts/1000))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$((created_ts/1000))" '+%Y-%m-%d %H:%M:%S')
  size=${INDEX_SIZE[$index]:-0}

  if [ "$i" -lt "$DELETE_COUNT" ]; then
    action="[DRY RUN] Would delete"
    size_bytes=$(echo $size | awk '
      /kb$/ {print $1*1024; next}
      /mb$/ {print $1*1024*1024; next}
      /gb$/ {print $1*1024*1024*1024; next}
      /tb$/ {print $1*1024*1024*1024*1024; next}
      {print $1}
    ')
    TOTAL_SIZE_TO_FREE=$((TOTAL_SIZE_TO_FREE + size_bytes))
  else
    action="Keep"
  fi

  printf "%-30s %-20s %-12s %-15s\n" "$index" "$created_human" "$size" "$action"
done

echo ""
echo "Total eligible indices: $TOTAL"
echo "Keeping newest: $KEEP"
echo "Will remove: $DELETE_COUNT"
echo "Estimated space to be freed: $(numfmt --to=iec --suffix=B $TOTAL_SIZE_TO_FREE)"
echo ""

########################################
# Interactive confirmation for live deletion
########################################
if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry run complete. No indices were deleted."
else
    read -rp "Proceed with deletion of $DELETE_COUNT indices? (yes/no) [no]: " CONFIRM
    CONFIRM="${CONFIRM:-no}"
    if [[ "$CONFIRM" == "yes" ]]; then
        echo "Deleting indices..."
        for ((i=0; i<DELETE_COUNT; i++)); do
            index=$(echo "${SORTED[$i]}" | cut -d'|' -f2)
            echo "Deleting index: $index"
            curl -s -X DELETE "$ES/$index" -H "$AUTH"
        done
        echo "Deletion complete."
    else
        echo "Deletion aborted by user."
    fi
fi

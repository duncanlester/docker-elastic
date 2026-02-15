#!/usr/bin/env bash
set -euo pipefail
set -o noglob

########################################
# Interactive prompts
########################################

read -rp "Elasticsearch URL [http://localhost:9200]: " ES
ES="${ES:-http://localhost:9200}"

read -rp "Use Basic Auth? (y/n) [y]: " USE_BASIC
USE_BASIC="${USE_BASIC:-y}"

AUTH_HEADER=()
if [[ "$USE_BASIC" =~ ^[Yy]$ ]]; then
    read -rp "Username: " ES_USER
    read -rsp "Password: " ES_PASS
    echo ""
    AUTH_HEADER=(-u "$ES_USER:$ES_PASS")
fi

read -rp "Number of newest indices to keep [5]: " KEEP
KEEP="${KEEP:-5}"

read -rp "Dry run? (true/false) [true]: " DRY_RUN
DRY_RUN="${DRY_RUN:-true}"

read -rp "Index patterns (comma-separated) [logs-*,metrics-*]: " INCLUDE_PATTERNS
INCLUDE_PATTERNS="${INCLUDE_PATTERNS:-logs-*,metrics-*}"

read -rp "Flood stage threshold % [95]: " FLOOD_STAGE
FLOOD_STAGE="${FLOOD_STAGE:-95}"

########################################
# System indices to skip
########################################
SYSTEM_REGEX='^(\.|\.kibana|\.security|\.monitoring|\.fleet|\.tasks|\.ml|\.transform|\.ds-)'

########################################
# Disk usage check
########################################
echo ""
echo "Checking disk usage per node..."

NODE_DISKS=$(curl -s "${AUTH_HEADER[@]}" "$ES/_cat/allocation?h=node,disk.percent" | sort -k2 -nr)
HIGHEST_DISK=$(echo "$NODE_DISKS" | head -n1 | awk '{print $2}')
HIGHEST_NODE=$(echo "$NODE_DISKS" | head -n1 | awk '{print $1}')

echo "Highest disk usage: ${HIGHEST_DISK}% on node ${HIGHEST_NODE}"

if [ "$HIGHEST_DISK" -lt "$FLOOD_STAGE" ]; then
    echo "Disk usage below flood stage ($FLOOD_STAGE%). No cleanup needed."
fi

########################################
# Fetch indices and real sizes (in bytes)
########################################

# Using bytes=b to get exact byte sizes
INDICES=$(curl -s "${AUTH_HEADER[@]}" "$ES/_cat/indices?format=json&h=index,creation.date,store.size&bytes=b" \
          | jq -r '.[] | "\(.index)|\(.["creation.date"])|\(.["store.size"])"')

########################################
# Filter eligible indices
########################################
ELIGIBLE=$(echo "$INDICES" \
  | grep -Ev "$SYSTEM_REGEX" \
  | while IFS='|' read -r idx created size; do
        for pattern in ${INCLUDE_PATTERNS//,/ }; do
            case "$idx" in
                $pattern)
                    echo "$created|$idx|$size"
                    break
                    ;;
            esac
        done
    done)

TOTAL=$(echo "$ELIGIBLE" | wc -l | tr -d ' ')
if [ "$TOTAL" -le "$KEEP" ]; then
    echo "Only $TOTAL eligible indices found. Nothing to delete."
    exit 0
fi

########################################
# Sort oldest → newest
########################################
SORTED=$(echo "$ELIGIBLE" | sort -n)
DELETE_COUNT=$((TOTAL - KEEP))

########################################
# Helper functions
########################################
human_date() {
  ts=$(( $1 / 1000 ))
  date -r "$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$ts" '+%Y-%m-%d %H:%M:%S'
}

human_size() {
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B "$1"
  else
    echo "$1 bytes"
  fi
}

########################################
# Report
########################################
echo ""
printf "%-30s %-20s %-12s %-15s\n" "INDEX" "CREATED" "SIZE" "ACTION"
echo "---------------------------------------------------------------------"

TOTAL_BYTES=0
i=0

# Read SORTED in while loop
echo "$SORTED" | while IFS='|' read -r created idx size; do
  created_human=$(human_date "$created")
  if [ "$i" -lt "$DELETE_COUNT" ]; then
    action="[DRY RUN] Delete"
    TOTAL_BYTES=$((TOTAL_BYTES + size))
  else
    action="Keep"
  fi

  printf "%-30s %-20s %-12s %-15s\n" "$idx" "$created_human" "$(human_size "$size")" "$action"
  i=$((i+1))
done

echo ""
echo "Total eligible indices: $TOTAL"
echo "Keeping newest: $KEEP"
echo "Will remove: $DELETE_COUNT"
echo "Estimated space to free: $(human_size "$TOTAL_BYTES")"
echo ""

########################################
# Deletion
########################################
if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry run complete. No indices deleted."
    exit 0
fi

read -rp "Proceed with deletion of $DELETE_COUNT indices? (yes/no) [no]: " CONFIRM
CONFIRM="${CONFIRM:-no}"

if [[ "$CONFIRM" != "yes" ]]; then
    echo "Deletion aborted."
    exit 0
fi

echo "Deleting indices..."
echo "$SORTED" | head -n "$DELETE_COUNT" | while IFS='|' read -r created idx size; do
    echo "Deleting $idx"
    curl -s -X DELETE "${AUTH_HEADER[@]}" "$ES/$idx" >/dev/null
done

echo "Deletion complete."

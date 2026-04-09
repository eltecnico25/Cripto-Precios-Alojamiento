#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

OUTFILE="data/snapshots.json"
COINS_FILE="coins_list.txt"
mkdir -p data

TODAY=$(date -u +"%Y-%m-%d")
CUTOFF=$(date -u -d "2 days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-2d +"%Y-%m-%d")

echo "=== Fetch & Prune — $TODAY ==="

# --- Step 1: Read coins_list.txt, prune entries older than 2 days ---
declare -A COIN_DATES
PRUNED_LIST=""
if [ -f "$COINS_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$line" ] && continue
    coin=$(echo "$line" | cut -d',' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    cdate=$(echo "$line" | cut -d',' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$coin" ] && continue
    if [ -z "$cdate" ] || [[ "$cdate" < "$CUTOFF" ]]; then
      echo "  PRUNED: $coin (date: ${cdate:-none}, older than 2 days)"
      PRUNED_LIST="$PRUNED_LIST $coin"
    else
      COIN_DATES["$coin"]="$cdate"
    fi
  done < "$COINS_FILE"
else
  echo "  No coins_list.txt found, using defaults"
fi

# Ensure defaults exist
for dc in bitcoin ethereum solana dogecoin cardano; do
  if [ -z "${COIN_DATES[$dc]+x}" ]; then
    COIN_DATES["$dc"]="$TODAY"
  fi
done

# Write cleaned coins_list.txt
> "$COINS_FILE"
for coin in "${!COIN_DATES[@]}"; do
  echo "$coin,${COIN_DATES[$coin]}" >> "$COINS_FILE"
done
sort -o "$COINS_FILE" "$COINS_FILE"
echo "  Active coins: $(wc -l < "$COINS_FILE")"

# --- Step 2: Load existing JSON, check date ---
EXISTING_DATE=""
if [ -f "$OUTFILE" ] && jq empty "$OUTFILE" 2>/dev/null; then
  EXISTING_DATE=$(jq -r '.date // ""' "$OUTFILE")
fi
echo "  Existing JSON date: ${EXISTING_DATE:-none}"
echo "  Today: $TODAY"

SAME_DAY=0
if [ "$EXISTING_DATE" = "$TODAY" ]; then
  SAME_DAY=1
  echo "  Mode: SAME DAY — only fetch new coins"
else
  echo "  Mode: NEW DAY — fetch all coins"
fi

# --- Step 3: Determine which coins need fetching ---
FETCH_ALL=()    # coins needing d1, d7, d30
FETCH_NEW=()    # coins needing d1, d2, d7, d8, d30, d31

for coin in "${!COIN_DATES[@]}"; do
  IN_JSON=0
  if [ "$SAME_DAY" -eq 1 ] && [ -f "$OUTFILE" ]; then
    IN_JSON=$(jq --arg c "$coin" '.coins[$c] // null | if . then 1 else 0 end' "$OUTFILE")
  fi

  if [ "$SAME_DAY" -eq 1 ] && [ "$IN_JSON" -eq 1 ]; then
    echo "  SKIP: $coin (already in today's JSON)"
  elif [ "$SAME_DAY" -eq 1 ] && [ "$IN_JSON" -eq 0 ]; then
    echo "  NEW: $coin (not in JSON, full fetch)"
    FETCH_NEW+=("$coin")
  else
    # New day: existing coins get d1,d7,d30; truly new ones get full
    if [ -f "$OUTFILE" ] && jq -e --arg c "$coin" '.coins[$c]' "$OUTFILE" >/dev/null 2>&1; then
      FETCH_ALL+=("$coin")
    else
      FETCH_NEW+=("$coin")
    fi
  fi
done

echo "  Coins to update (d1,d7,d30): ${FETCH_ALL[*]:-none}"
echo "  Coins to add (full): ${FETCH_NEW[*]:-none}"

# --- Helper: round price ---
round_price() {
  local p="$1"
  echo "$p" | awk '{if($1>=1) printf "%.2f\n",$1; else printf "%.8f\n",$1}'
}

# --- Helper: get price at 23:59 UTC for a target date from market_chart data ---
# Uses jq to find the price point closest to 23:59 UTC of target date
get_price_at_2359() {
  local json_data="$1"
  local target_date="$2"  # YYYY-MM-DD

  # Target timestamp: target_date at 23:59:00 UTC
  local target_ts
  target_ts=$(date -u -d "${target_date} 23:59:00" +%s 2>/dev/null || date -u -j -f "%Y-%m-%d %H:%M:%S" "${target_date} 23:59:00" +%s)
  local target_ms=$((target_ts * 1000))

  local price
  price=$(echo "$json_data" | jq --argjson tms "$target_ms" '
    .prices | map({ts: .[0], p: .[1]})
    | min_by((.ts - $tms) | fabs)
    | .p // null
  ')

  if [ "$price" = "null" ] || [ -z "$price" ]; then
    echo "null"
  else
    round_price "$price"
  fi
}

# --- Step 4: Fetch and build coin entries ---
# Start with existing JSON coins (if same day)
if [ "$SAME_DAY" -eq 1 ] && [ -f "$OUTFILE" ]; then
  COINS_JSON=$(jq '.coins' "$OUTFILE")
else
  COINS_JSON='{}'
fi

fetch_coin_data() {
  local coin="$1"
  local is_new="$2"  # 1=new coin, 0=existing

  echo "  Fetching $coin (new=$is_new) ..."

  local RESP
  RESP=$(curl -sS --retry 2 --retry-delay 5 \
    "https://api.coingecko.com/api/v3/coins/${coin}/market_chart?vs_currency=usd&days=35")

  if [ -z "$RESP" ] || echo "$RESP" | jq -e '.error' >/dev/null 2>&1; then
    echo "  ERROR: $coin — API error, skipping"
    return 1
  fi

  # Calculate target dates
  local d1 d2 d7 d8 d30 d31
  d1=$(date -u -d "1 day ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-1d +"%Y-%m-%d")
  d7=$(date -u -d "7 days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-7d +"%Y-%m-%d")
  d30=$(date -u -d "30 days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-30d +"%Y-%m-%d")

  local p1 p7 p30
  p1=$(get_price_at_2359 "$RESP" "$d1")
  p7=$(get_price_at_2359 "$RESP" "$d7")
  p30=$(get_price_at_2359 "$RESP" "$d30")

  local entry
  if [ "$is_new" -eq 1 ]; then
    d2=$(date -u -d "2 days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-2d +"%Y-%m-%d")
    d8=$(date -u -d "8 days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-8d +"%Y-%m-%d")
    d31=$(date -u -d "31 days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-31d +"%Y-%m-%d")

    local p2 p8 p31
    p2=$(get_price_at_2359 "$RESP" "$d2")
    p8=$(get_price_at_2359 "$RESP" "$d8")
    p31=$(get_price_at_2359 "$RESP" "$d31")

    entry=$(jq -n \
      --argjson d1 "$p1" --argjson d2 "$p2" \
      --argjson d7 "$p7" --argjson d8 "$p8" \
      --argjson d30 "$p30" --argjson d31 "$p31" \
      '{d1:$d1, d2:$d2, d7:$d7, d8:$d8, d30:$d30, d31:$d31}')
  else
    entry=$(jq -n \
      --argjson d1 "$p1" --argjson d7 "$p7" --argjson d30 "$p30" \
      '{d1:$d1, d7:$d7, d30:$d30}')
  fi

  # Merge into COINS_JSON
  COINS_JSON=$(echo "$COINS_JSON" | jq --arg c "$coin" --argjson e "$entry" '.[$c] = $e')
  echo "  OK: $coin"
}

# Fetch existing coins (d1, d7, d30)
for coin in "${FETCH_ALL[@]}"; do
  fetch_coin_data "$coin" 0
  sleep 7  # Rate limit
done

# Fetch new coins (d1, d2, d7, d8, d30, d31)
for coin in "${FETCH_NEW[@]}"; do
  fetch_coin_data "$coin" 1
  sleep 7
done

# --- Step 5: Cleanup old keys (d3, d9, d32) ---
COINS_JSON=$(echo "$COINS_JSON" | jq '
  to_entries | map(
    .value |= (del(.d3) | del(.d9) | del(.d32))
  ) | from_entries
')

# Also remove pruned coins from JSON
for pruned in $PRUNED_LIST; do
  COINS_JSON=$(echo "$COINS_JSON" | jq --arg c "$pruned" 'del(.[$c])')
done

# --- Build final JSON ---
jq -n --arg date "$TODAY" --argjson coins "$COINS_JSON" \
  '{date: $date, coins: $coins}' > "$OUTFILE"

echo "=== Generated $OUTFILE ==="
echo "  Date: $TODAY"
echo "  Coins: $(jq '.coins | length' "$OUTFILE")"
jq '.' "$OUTFILE" | head -40

# --- Commit & push ---
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

git add data/ "$COINS_FILE"
if git diff --cached --quiet; then
  echo "No changes to commit"
else
  git commit -m "data: snapshot $TODAY $(date -u +%H:%M)"
  git push
fi

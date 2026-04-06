#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

DATA_DIR="data"
mkdir -p "$DATA_DIR"
DEFAULT_COINS=("bitcoin" "ethereum")
COINS_FILE="coins_list.txt"

NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
THRESHOLD_ISO=$(date -u -d '48 hours ago' +"%Y-%m-%dT%H:%M:%SZ")

if ! command -v jq >/dev/null 2>&1; then
  echo "jq required"
  exit 1
fi

# Build coin list
COINS=("${DEFAULT_COINS[@]}")
if [ -f "$COINS_FILE" ]; then
  while IFS= read -r line; do
    coin=$(echo "$line" | tr -d '[:space:]')
    [ -z "$coin" ] && continue
    if [[ ! " ${COINS[*]} " =~ " ${coin} " ]]; then
      COINS+=("$coin")
    fi
  done < "$COINS_FILE"
fi

# helper: nearest sample from prices array
nearest_sample() {
  prices_json="$1"
  target_ms="$2"
  echo "$prices_json" | jq --argjson target "$target_ms" '
    ( . | map({ts: (.[0]|tonumber), price: .[1]})
      | min_by((.ts - $target)|abs) ) as $n
    | {timestamp_ms: $n.ts, timestamp_iso: ($n.ts/1000 | todate), price: $n.price}
  '
}

fetch_coin_to_csv() {
  coin="$1"
  outdir="$DATA_DIR/$coin"
  mkdir -p "$outdir"
  csvfile="$outdir/data.csv"
  # ensure header exists
  if [ ! -f "$csvfile" ]; then
    echo "coin,fetched_at,price_24h,date_24h,price_48h,date_48h,price_7d,date_7d,price_8d,date_8d,price_30d,date_30d,price_31d,date_31d" > "$csvfile"
  fi

  resp=$(curl -sS "https://api.coingecko.com/api/v3/coins/${coin}/market_chart?vs_currency=usd&days=35")
  if [ -z "$resp" ]; then
    echo "Empty response for $coin"
    return 1
  fi
  prices=$(echo "$resp" | jq '.prices')

  now_ms=$(date -u +"%s000")
  t24_ms=$(date -u -d '24 hours ago' +"%s000")
  t48_ms=$(date -u -d '48 hours ago' +"%s000")
  t7d_ms=$(date -u -d '7 days ago' +"%s000")
  t8d_ms=$(date -u -d '8 days ago' +"%s000")
  t30d_ms=$(date -u -d '30 days ago' +"%s000")
  t31d_ms=$(date -u -d '31 days ago' +"%s000")

  s_now=$(nearest_sample "$prices" "$now_ms")
  s_24=$(nearest_sample "$prices" "$t24_ms")
  s_48=$(nearest_sample "$prices" "$t48_ms")
  s_7=$(nearest_sample "$prices" "$t7d_ms")
  s_8=$(nearest_sample "$prices" "$t8d_ms")
  s_30=$(nearest_sample "$prices" "$t30d_ms")
  s_31=$(nearest_sample "$prices" "$t31d_ms")

  # Extract fields
  price_24=$(echo "$s_24" | jq -r '.price // empty')
  date_24=$(echo "$s_24" | jq -r '.timestamp_iso // empty')
  price_48=$(echo "$s_48" | jq -r '.price // empty')
  date_48=$(echo "$s_48" | jq -r '.timestamp_iso // empty')
  price_7=$(echo "$s_7" | jq -r '.price // empty')
  date_7=$(echo "$s_7" | jq -r '.timestamp_iso // empty')
  price_8=$(echo "$s_8" | jq -r '.price // empty')
  date_8=$(echo "$s_8" | jq -r '.timestamp_iso // empty')
  price_30=$(echo "$s_30" | jq -r '.price // empty')
  date_30=$(echo "$s_30" | jq -r '.timestamp_iso // empty')
  price_31=$(echo "$s_31" | jq -r '.price // empty')
  date_31=$(echo "$s_31" | jq -r '.timestamp_iso // empty')

  # append CSV row
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$coin" "$NOW_ISO" \
    "$price_24" "$date_24" \
    "$price_48" "$date_48" \
    "$price_7" "$date_7" \
    "$price_8" "$date_8" \
    "$price_30" "$date_30" \
    "$price_31" "$date_31" >> "$csvfile"

  echo "Wrote $csvfile row for $coin"
  return 0
}

CHANGED=0
for coin in "${COINS[@]}"; do
  if fetch_coin_to_csv "$coin"; then
    CHANGED=1
  else
    echo "Failed $coin"
  fi
done

# Prune CSV rows older than 48 hours (based on fetched_at field) and remove coin dirs if empty and not default/requested
for coin_dir in "$DATA_DIR"/*; do
  [ -d "$coin_dir" ] || continue
  csv="$coin_dir/data.csv"
  [ -f "$csv" ] || continue
  tmp="${csv}.tmp"
  header=$(head -n1 "$csv")
  echo "$header" > "$tmp"
  # keep rows with fetched_at >= THRESHOLD_ISO
  awk -F',' -v thresh="$THRESHOLD_ISO" 'NR>1{ if ($2 >= thresh) print }' "$csv" >> "$tmp"
  mv "$tmp" "$csv"
  # remove dir if only header and not default/coins_file
  if [ "$(wc -l < "$csv")" -le 1 ]; then
    coin_name=$(basename "$coin_dir")
    keep=0
    for d in "${DEFAULT_COINS[@]}"; do [ "$d" = "$coin_name" ] && keep=1 && break; done
    if [ "$keep" -eq 0 ] && [ -f "$COINS_FILE" ]; then
      if grep -Fxq "$coin_name" "$COINS_FILE"; then keep=1; fi
    fi
    if [ "$keep" -eq 0 ]; then
      rm -f "$csv"
      rmdir "$coin_dir" || true
      CHANGED=1
    fi
  fi
done

# Commit if changed
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

if [ "$CHANGED" -eq 1 ]; then
  git add "$DATA_DIR" || true
  if git diff --cached --quiet; then
    echo "No staged changes"
  else
    git commit -m "ci: snapshots CSV $NOW_ISO"
    if [ -z "${GH_TOKEN:-}" ]; then
      echo "GH_TOKEN not set; cannot push"
      exit 1
    fi
    git push "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" HEAD:"${GITHUB_REF#refs/heads/}"
  fi
else
  echo "No changes"
fi

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

OUTFILE="data/snapshots.json"
mkdir -p data

# Coin list: read from coins_list.txt or use defaults
DEFAULT_COINS="bitcoin ethereum solana dogecoin cardano"
COINS_FILE="coins_list.txt"

if [ -f "$COINS_FILE" ]; then
  COINS=$(cat "$COINS_FILE" | tr '\n' ' ' | tr ',' ' ')
  # merge defaults
  for dc in $DEFAULT_COINS; do
    echo "$COINS" | grep -qw "$dc" || COINS="$COINS $dc"
  done
else
  COINS="$DEFAULT_COINS"
fi

# Trim
COINS=$(echo "$COINS" | xargs)
echo "Fetching coins: $COINS"

NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Build JSON array
echo '{"updated":"'"$NOW_ISO"'","coins":[' > "$OUTFILE"

FIRST=1
for coin in $COINS; do
  echo "  Processing $coin ..."

  # Fetch 35 days of hourly data
  RESP=$(curl -sS --retry 2 --retry-delay 5 \
    "https://api.coingecko.com/api/v3/coins/${coin}/market_chart?vs_currency=usd&days=35")

  if [ -z "$RESP" ] || echo "$RESP" | jq -e '.error' >/dev/null 2>&1; then
    echo "  SKIP $coin (API error)"
    continue
  fi

  # Use jq to extract nearest prices for each period
  ENTRY=$(echo "$RESP" | jq --arg coin "$coin" --arg now "$NOW_ISO" '
    def nearest(target_ms):
      .prices | map({ts: .[0], p: .[1]})
      | min_by((.ts - target_ms) | fabs)
      | {price: .p, date: (.ts / 1000 | todate)};

    (.prices[-1][0]) as $now_ms |
    ($now_ms - 86400000) as $t24 |
    ($now_ms - 172800000) as $t48 |
    ($now_ms - 604800000) as $t7d |
    ($now_ms - 691200000) as $t8d |
    ($now_ms - 2505600000) as $t30d |
    ($now_ms - 2592000000) as $t31d |

    {
      coin: $coin,
      current: {price: .prices[-1][1], date: (.prices[-1][0] / 1000 | todate)},
      h24: nearest($t24),
      h48: nearest($t48),
      d7: nearest($t7d),
      d8: nearest($t8d),
      d29: nearest($t30d),
      d30: nearest($t31d)
    }
  ' 2>/dev/null)

  if [ -z "$ENTRY" ]; then
    echo "  SKIP $coin (jq parse error)"
    continue
  fi

  if [ "$FIRST" -eq 1 ]; then
    FIRST=0
  else
    echo "," >> "$OUTFILE"
  fi
  echo "$ENTRY" >> "$OUTFILE"

  # Rate limit: CoinGecko free = 10-30 req/min
  sleep 7
done

echo ']}'  >> "$OUTFILE"

# Validate JSON
if ! jq empty "$OUTFILE" 2>/dev/null; then
  echo "ERROR: invalid JSON generated"
  cat "$OUTFILE"
  exit 1
fi

echo "Generated $OUTFILE with $(jq '.coins | length' "$OUTFILE") coins"

# Commit and push
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

git add data/
if git diff --cached --quiet; then
  echo "No changes to commit"
else
  git commit -m "data: snapshot $NOW_ISO"
  git push
fi

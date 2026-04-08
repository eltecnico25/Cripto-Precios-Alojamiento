#!/usr/bin/env bash
# Mantenemos solo -u y pipefail; manejamos errores manualmente para evitar exit 2
set -uo pipefail
cd "$(dirname "$0")/.."

OUTFILE="data/snapshots.json"
COINS_FILE="coins_list.txt"
mkdir -p data

# 🪙 Leer monedas
DEFAULT_COINS="bitcoin ethereum solana dogecoin cardano"
if [ -f "$COINS_FILE" ]; then
  COINS=$(tr ',\n' ' ' < "$COINS_FILE" | xargs)
  for dc in $DEFAULT_COINS; do
    echo "$COINS" | grep -qw "$dc" || COINS="$COINS $dc"
  done
else
  COINS="$DEFAULT_COINS"
fi
COINS=$(echo "$COINS" | xargs)
echo "📥 Monedas: $COINS"

# 📅 Fechas UTC exactas (YYYY-MM-DD) para coincidencia de cierre
TODAY=$(date -u +%Y-%m-%d)
YESTERDAY=$(date -u -d "yesterday" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)
DAY2=$(date -u -d "2 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-2d +%Y-%m-%d)
D7=$(date -u -d "7 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-7d +%Y-%m-%d)
D8=$(date -u -d "8 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-8d +%Y-%m-%d)
D30=$(date -u -d "30 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-30d +%Y-%m-%d)
D31=$(date -u -d "31 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-31d +%Y-%m-%d)
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# 📦 Cargar snapshot existente
EXISTING='{"updated":"0000-00-00","coins":[]}'
[ -f "$OUTFILE" ] && EXISTING=$(cat "$OUTFILE")

# 🔄 Decidir qué consultar
LAST_DATE=$(echo "$EXISTING" | jq -r '.updated // "0000-00-00"')
FETCH_LIST=""

if [ "$TODAY" != "$LAST_DATE" ]; then
  echo "🌅 Nuevo día ($TODAY)"
  SKIP_COINS=$(echo "$EXISTING" | jq -r --arg now "$(date -u +%s)000" '
    .coins[] | select(.last_fetched != null)
    | select(($now | tonumber) - .last_fetched < 172800000)
    | .id' 2>/dev/null | tr '\n' ' ')
  
  for coin in $COINS; do
    echo " $SKIP_COINS " | grep -qw " $coin " && echo "  ⏭ SKIP $coin (<48h)" || FETCH_LIST="$FETCH_LIST $coin"
  done
else
  echo "📅 Mismo día"
  EXISTING_IDS=$(echo "$EXISTING" | jq -r '.coins[].id' 2>/dev/null | tr '\n' ' ')
  for coin in $COINS; do
    echo " $EXISTING_IDS " | grep -qw " $coin " || { FETCH_LIST="$FETCH_LIST $coin"; echo "  ➕ Nueva: $coin"; }
  done
fi
FETCH_LIST=$(echo "$FETCH_LIST" | xargs)
[ -z "$FETCH_LIST" ] && echo "✅ Sin pendientes" && exit 0

echo "📡 Consultando: $FETCH_LIST"
NEW_ARRAY="[]"

# 🔍 Fetch + Extracción de cierres por fecha exacta
for coin in $FETCH_LIST; do
  echo "  🔎 $coin ..."
  RESP=$(curl -sS --max-time 20 --retry 2 --retry-delay 5 \
    "https://api.coingecko.com/api/v3/coins/${coin}/market_chart?vs_currency=usd&days=35&interval=daily" 2>&1) || continue

  # Validar respuesta
  if [ -z "$RESP" ] || echo "$RESP" | jq -e 'has("error")' >/dev/null 2>&1; then
    echo "  ❌ SKIP $coin (API)"
    continue
  fi

  # ✅ Extraer cierres por COINCIDENCIA EXACTA de fecha UTC
  ENTRY=$(echo "$RESP" | jq --arg coin "$coin" --arg now "$NOW_ISO" \
    --arg d1 "$YESTERDAY" --arg d2 "$DAY2" --arg d7 "$D7" \
    --arg d8 "$D8" --arg d30 "$D30" --arg d31 "$D31" '
    
    # Función: obtener último precio del día (simula "close") por fecha exacta
    def get_close(target_date):
      .prices 
      | map(select((.[0] / 1000 | todate | split("T")[0]) == target_date))
      | if length > 0 then last | .[1] else null end;
    
    {
      id: $coin,
      last_fetched: ($now | now * 1000),
      current_price: (.prices[-1][1] // null),
      closes: {
        d1:  (. | get_close($d1)),
        d2:  (. | get_close($d2)),
        d7:  (. | get_close($d7)),
        d8:  (. | get_close($d8)),
        d30: (. | get_close($d30)),
        d31: (. | get_close($d31))
      }
    }
  ' 2>/dev/null)

  if [ -z "$ENTRY" ] || [ "$ENTRY" = "null" ] || [ "$(echo "$ENTRY" | jq '.current_price == null')" = "true" ]; then
    echo "  ❌ SKIP $coin (parse)"
    continue
  fi

  NEW_ARRAY=$(echo "$NEW_ARRAY" | jq --argjson e "$ENTRY" '. + [$e]')
  echo "  ✅ $coin → current: $(echo "$ENTRY" | jq -r '.current_price'), d1: $(echo "$ENTRY" | jq -r '.closes.d1 // "N/A")"
  sleep 6
done

# 🧩 Fusionar con snapshot anterior
FINAL_JSON=$(jq -n \
  --argjson old "$EXISTING" \
  --argjson new "$NEW_ARRAY" \
  --arg today "$TODAY" '
    ($old.coins | map({(.id): .}) | add // {}) as $old_map |
    ($new | map({(.id): .}) | add // {}) as $new_map |
    {
      updated: $today,
      coins: ($old_map * $new_map | to_entries | map(.value))
    }
')

echo "$FINAL_JSON" > "$OUTFILE"
echo "✅ Generado $OUTFILE con $(echo "$FINAL_JSON" | jq '.coins | length') monedas"

# 📦 Commit & Push
git config user.name "github-actions[bot]" 2>/dev/null || true
git config user.email "41898282+github-actions[bot]@users.noreply.github.com" 2>/dev/null || true
git add "$OUTFILE" 2>/dev/null || true
if git diff --cached --quiet 2>/dev/null; then
  echo "📦 Sin cambios"
else
  git commit -m "📊 snapshot $TODAY ($(echo "$FINAL_JSON" | jq '.coins | length') coins)" 2>/dev/null || true
  git push 2>/dev/null || echo "⚠️ Push fallido"
fi

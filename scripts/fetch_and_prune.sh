#!/usr/bin/env bash
# Desactivamos set -e para evitar abortos por grep/curl/jq que manejamos manualmente
# Mantenemos set -u y set -o pipefail para capturar errores reales de tuberías
set -uo pipefail
cd "$(dirname "$0")/.."

OUTFILE="data/snapshots.json"
COINS_FILE="coins_list.txt"
mkdir -p data

# 🪙 1️⃣ Leer monedas (soporta saltos de línea, comas o espacios)
DEFAULT_COINS="bitcoin ethereum solana dogecoin cardano"
if [ -f "$COINS_FILE" ]; then
  COINS=$(tr ',\n' ' ' < "$COINS_FILE" | xargs)
  for dc in $DEFAULT_COINS; do
    if ! echo "$COINS" | grep -qw "$dc"; then
      COINS="$COINS $dc"
    fi
  done
else
  COINS="$DEFAULT_COINS"
fi
COINS=$(echo "$COINS" | xargs)
echo "📥 Monedas a consultar: $COINS"

# 📅 2️⃣ Fechas UTC exactas (formato YYYY-MM-DD)
TODAY=$(date -u +%Y-%m-%d)
YESTERDAY=$(date -u -d "yesterday" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)
DAY2=$(date -u -d "2 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-2d +%Y-%m-%d)
D7=$(date -u -d "7 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-7d +%Y-%m-%d)
D8=$(date -u -d "8 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-8d +%Y-%m-%d)
D30=$(date -u -d "30 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-30d +%Y-%m-%d)
D31=$(date -u -d "31 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-31d +%Y-%m-%d)
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# 📦 3️⃣ Cargar snapshot existente o iniciar vacío
EXISTING='{"updated":"0000-00-00","coins":[]}'
[ -f "$OUTFILE" ] && EXISTING=$(cat "$OUTFILE")

# 🔄 4️⃣ Decidir qué monedas consultar (nuevo día = refrescar, pero saltar <48h)
LAST_DATE=$(echo "$EXISTING" | jq -r '.updated // "0000-00-00"')
FETCH_LIST=""

if [ "$TODAY" != "$LAST_DATE" ]; then
  echo "🌅 Nuevo día ($TODAY). Verificando pendientes..."
  # Monedas actualizadas hace menos de 48h
  SKIP_COINS=$(echo "$EXISTING" | jq -r --arg now "$(date -u +%s)000" '
    .coins[] | select(.last_fetched != null)
    | select(($now | tonumber) - .last_fetched < 172800000)
    | .id' 2>/dev/null | tr '\n' ' ')
  
  for coin in $COINS; do
    if echo " $SKIP_COINS " | grep -qw " $coin "; then
      echo "  ⏭ SKIP $coin (actualizada <48h)"
    else
      FETCH_LIST="$FETCH_LIST $coin"
    fi
  done
else
  echo "📅 Mismo día. Solo buscando monedas nuevas..."
  EXISTING_IDS=$(echo "$EXISTING" | jq -r '.coins[].id' 2>/dev/null | tr '\n' ' ')
  for coin in $COINS; do
    if ! echo " $EXISTING_IDS " | grep -qw " $coin "; then
      FETCH_LIST="$FETCH_LIST $coin"
      echo "  ➕ Nueva: $coin"
    fi
  done
fi
FETCH_LIST=$(echo "$FETCH_LIST" | xargs)

if [ -z "$FETCH_LIST" ]; then
  echo "✅ Sin pendientes. Snapshot vigente."
  exit 0
fi

echo "📡 Consultando: $FETCH_LIST"
NEW_ARRAY="[]"

# 🔍 5️⃣ Fetch + Extracción exacta de 6 cierres UTC
for coin in $FETCH_LIST; do
  echo "  🔎 $coin ..."
  RESP=$(curl -sS --max-time 15 --retry 2 --retry-delay 5 \
    "https://api.coingecko.com/api/v3/coins/${coin}/market_chart?vs_currency=usd&days=35&interval=daily" 2>&1)

  if [ -z "$RESP" ] || echo "$RESP" | jq -e 'has("error")' 2>/dev/null | grep -q true; then
    echo "  ❌ SKIP $coin (API error/limit)"
    continue
  fi

  # Extraer SOLO los 6 cierres por coincidencia exacta de fecha UTC
  ENTRY=$(echo "$RESP" | jq --arg coin "$coin" --arg now "$NOW_ISO" \
    --arg d1 "$YESTERDAY" --arg d2 "$DAY2" --arg d7 "$D7" \
    --arg d8 "$D8" --arg d30 "$D30" --arg d31 "$D31" '
    def find_close(target_date):
      .prices | map(select((.[0] / 1000 | todate | split("T")[0]) == target_date))
      | if length > 0 then .[0][1] else null end;
    {
      id: $coin,
      last_fetched: ($now | now * 1000),
      current_price: (.prices[-1][1] // null),
      closes: {
        d1: (. | find_close($d1)),
        d2: (. | find_close($d2)),
        d7: (. | find_close($d7)),
        d8: (. | find_close($d8)),
        d30: (. | find_close($d30)),
        d31: (. | find_close($d31))
      }
    }
  ' 2>/dev/null)

  if [ -z "$ENTRY" ] || [ "$ENTRY" = "null" ] || [ "$(echo "$ENTRY" | jq '.current_price == null')" = "true" ]; then
    echo "  ❌ SKIP $coin (sin datos válidos)"
    continue
  fi

  NEW_ARRAY=$(echo "$NEW_ARRAY" | jq --argjson e "$ENTRY" '. + [$e]')
  echo "  ✅ $coin → current: $(echo "$ENTRY" | jq -r '.current_price')"
  sleep 6 # Respetar límite gratuito (~10 req/min)
done

# 🧩 6️⃣ Fusión segura (nuevos sobrescriben, antiguos se conservan)
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

# 📦 7️⃣ Commit & Push
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add "$OUTFILE"
if git diff --cached --quiet; then
  echo "📦 Sin cambios nuevos"
else
  git commit -m "📊 snapshot $TODAY ($(echo "$FINAL_JSON" | jq '.coins | length') coins)"
  git push
fi

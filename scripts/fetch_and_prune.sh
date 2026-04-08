#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

OUTFILE="data/snapshots.json"
COINS_FILE="coins_list.txt"
mkdir -p data

# ✅ 1️⃣ Leer lista de monedas (soporta comas, espacios o saltos de línea)
DEFAULT_COINS="bitcoin ethereum solana dogecoin cardano"
if [ -f "$COINS_FILE" ]; then
  COINS=$(tr '[:space:],' ' ' < "$COINS_FILE" | xargs)
  # Añadir defaults si faltan
  for dc in $DEFAULT_COINS; do
    echo "$COINS" | grep -qw "$dc" || COINS="$COINS $dc"
  done
else
  COINS="$DEFAULT_COINS"
fi
COINS=$(echo "$COINS" | xargs)

# ✅ 2️⃣ Fechas objetivo en UTC (formato YYYY-MM-DD para coincidencia exacta)
TODAY=$(date -u +%Y-%m-%d)
YESTERDAY=$(date -u -d "yesterday" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)
DAY2=$(date -u -d "2 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-2d +%Y-%m-%d)
D7=$(date -u -d "7 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-7d +%Y-%m-%d)
D8=$(date -u -d "8 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-8d +%Y-%m-%d)
D30=$(date -u -d "30 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-30d +%Y-%m-%d)
D31=$(date -u -d "31 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-31d +%Y-%m-%d)

NOW_MS=$(date -u +%s)000

# ✅ 3️⃣ Cargar snapshot existente
if [ -f "$OUTFILE" ]; then
  EXISTING=$(cat "$OUTFILE")
else
  EXISTING='{"updated":"0000-00-00","coins":[]}'
fi

LAST_DATE=$(echo "$EXISTING" | jq -r '.updated // "0000-00-00"')

# ✅ 4️⃣ Lógica de actualización: nuevo día = refrescar, pero respetar <48h
if [ "$TODAY" != "$LAST_DATE" ]; then
  echo "🌅 Nuevo día detectado ($TODAY). Actualizando históricos..."
  
  # Monedas a saltar (actualizadas <48h)
  SKIP_COINS=$(echo "$EXISTING" | jq -r --arg now "$NOW_MS" '
    .coins[] | select(.last_fetched != null)
    | select(($now | tonumber) - .last_fetched < 172800000)
    | .id' 2>/dev/null | tr '\n' ' ')
  
  FETCH_LIST=""
  for coin in $COINS; do
    if echo " ${SKIP_COINS} " | grep -qw " ${coin} "; then
      echo "  ⏭ SKIP $coin (actualizada <48h)"
    else
      FETCH_LIST="$FETCH_LIST $coin"
    fi
  done
  FETCH_LIST=$(echo "$FETCH_LIST" | xargs)
  
  if [ -z "$FETCH_LIST" ]; then
    echo "✅ No hay monedas pendientes. Snapshot actualizado."
    exit 0
  fi
else
  echo "📅 Mismo día ($TODAY). Solo se verificarán nuevas monedas."
  FETCH_LIST=""
  # Buscar monedas nuevas que no estén en el snapshot
  EXISTING_IDS=$(echo "$EXISTING" | jq -r '.coins[].id' 2>/dev/null | tr '\n' ' ')
  for coin in $COINS; do
    if ! echo " ${EXISTING_IDS} " | grep -qw " ${coin} "; then
      FETCH_LIST="$FETCH_LIST $coin"
      echo "  ➕ Nueva moneda: $coin"
    fi
  done
  FETCH_LIST=$(echo "$FETCH_LIST" | xargs)
  if [ -z "$FETCH_LIST" ]; then
    echo "✅ Sin cambios. Snapshot vigente."
    exit 0
  fi
fi

echo "📥 Consultando: $FETCH_LIST"
NEW_DATA="[]"

# ✅ 5️⃣ Fetch & Extracción de cierres exactos
for coin in $FETCH_LIST; do
  echo "  🔍 $coin ..."
  
  # Fetch 35 días para tener margen de seguridad
  RESP=$(curl -sS --retry 2 --retry-delay 5 \
    "https://api.coingecko.com/api/v3/coins/${coin}/market_chart?vs_currency=usd&days=35&interval=daily")
  
  if [ -z "$RESP" ] || echo "$RESP" | jq -e '.error' >/dev/null 2>&1; then
    echo "  ❌ SKIP $coin (API error o rate limit)"
    continue
  fi

  # ✅ Extraer SOLO los 6 cierres por coincidencia exacta de fecha UTC
  ENTRY=$(echo "$RESP" | jq --arg coin "$coin" --arg now "$NOW_MS" \
    --arg d1 "$YESTERDAY" --arg d2 "$DAY2" --arg d7 "$D7" \
    --arg d8 "$D8" --arg d30 "$D30" --arg d31 "$D31" '
    
    # Función: buscar precio por fecha exacta en array [timestamp, price]
    def find_close(target_date):
      .prices 
      | map(select((.[0] / 1000 | todate | split("T")[0]) == target_date))
      | if length > 0 then .[0][1] else null end;
    
    {
      id: $coin,
      last_fetched: ($now | tonumber),
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

  if [ -z "$ENTRY" ] || [ "$ENTRY" = "null" ]; then
    echo "  ❌ SKIP $coin (Parse error)"
    continue
  fi

  # Validar que al menos tengamos current_price
  HAS_PRICE=$(echo "$ENTRY" | jq '.current_price != null')
  if [ "$HAS_PRICE" != "true" ]; then
    echo "  ❌ SKIP $coin (Sin precio actual)"
    continue
  fi

  NEW_DATA=$(echo "$NEW_DATA" | jq --argjson e "$ENTRY" '. + [$e]')
  echo "  ✅ $coin: current=$(echo "$ENTRY" | jq -r '.current_price'), d1=$(echo "$ENTRY" | jq -r '.closes.d1 // "N/A")"
  
  # Rate limit seguro para API gratuita
  sleep 8
done

# ✅ 6️⃣ Fusión inteligente: nuevos datos sobrescriben, saltados se conservan
FINAL_JSON=$(jq -n \
  --argjson old "$EXISTING" \
  --argjson new "$NEW_DATA" \
  --arg today "$TODAY" '
    ($old.coins | map({(.id): .}) | add // {}) as $old_map |
    ($new | map({(.id): .}) | add // {}) as $new_map |
    # Merge: nuevo > viejo
    ($old_map * $new_map | to_entries | map(.value)) as $merged |
    {
      updated: $today,
      coins: $merged
    }
')

# ✅ 7️⃣ Validar y guardar
if ! echo "$FINAL_JSON" | jq empty 2>/dev/null; then
  echo "❌ ERROR: JSON inválido generado"
  exit 1
fi
echo "$FINAL_JSON" > "$OUTFILE"

COUNT=$(echo "$FINAL_JSON" | jq '.coins | length')
echo "✅ Generado $OUTFILE con $COUNT monedas"

# ✅ 8️⃣ Commit & Push automático (solo si hay cambios)
git config user.name "github-actions[bot]" 2>/dev/null || true
git config user.email "41898282+github-actions[bot]@users.noreply.github.com" 2>/dev/null || true
git add "$OUTFILE" 2>/dev/null || true
if git diff --cached --quiet 2>/dev/null; then
  echo "📦 Sin cambios nuevos para commitear"
else
  git commit -m "📊 snapshot $TODAY ($COUNT coins, 6 cierres)" 2>/dev/null || true
  git push 2>/dev/null || echo "⚠️ Push fallido (ejecución local?)"
fi

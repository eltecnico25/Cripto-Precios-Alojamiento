#!/usr/bin/env bash
# Solo -u y pipefail; manejamos errores manualmente para evitar exit 2
set -uo pipefail
cd "$(dirname "$0")/.."

OUTFILE="data/snapshots.json"
COINS_FILE="coins_list.txt"
mkdir -p data

# 🪙 Leer lista de monedas
DEFAULT_COINS="bitcoin ethereum solana dogecoin cardano"
if [ -f "$COINS_FILE" ]; then
  COINS=$(tr ',\n' ' ' < "$COINS_FILE" | xargs)
  for dc in $DEFAULT_COINS; do
    echo "$COINS" | grep -qw "$dc" 2>/dev/null || COINS="$COINS $dc"
  done
else
  COINS="$DEFAULT_COINS"
fi
COINS=$(echo "$COINS" | xargs)
echo "📥 Monedas: $COINS"

# 📅 Fechas UTC exactas (YYYY-MM-DD) para coincidencia de cierre diario
TODAY=$(date -u +%Y-%m-%d)
YESTERDAY=$(date -u -d "yesterday" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)
DAY2=$(date -u -d "2 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-2d +%Y-%m-%d)
D7=$(date -u -d "7 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-7d +%Y-%m-%d)
D8=$(date -u -d "8 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-8d +%Y-%m-%d)
D30=$(date -u -d "30 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-30d +%Y-%m-%d)
D31=$(date -u -d "31 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-31d +%Y-%m-%d)
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# 📦 Cargar snapshot existente o iniciar vacío
EXISTING='{"updated":"0000-00-00","coins":[]}'
[ -f "$OUTFILE" ] && EXISTING=$(cat "$OUTFILE" 2>/dev/null) || true

# 🔄 Decidir qué monedas consultar
LAST_DATE=$(echo "$EXISTING" | jq -r '.updated // "0000-00-00"' 2>/dev/null) || LAST_DATE="0000-00-00"
FETCH_LIST=""

if [ "$TODAY" != "$LAST_DATE" ]; then
  echo "🌅 Nuevo día detectado ($TODAY)"
  # Monedas actualizadas hace menos de 48h (en milisegundos)
  SKIP_COINS=$(echo "$EXISTING" | jq -r --arg now "$(date -u +%s)000" '
    .coins[] | select(.last_fetched != null)
    | select(($now | tonumber) - .last_fetched < 172800000)
    | .id' 2>/dev/null | tr '\n' ' ') || SKIP_COINS=""
  
  for coin in $COINS; do
    if echo " $SKIP_COINS " | grep -qw " $coin " 2>/dev/null; then
      echo "  ⏭ SKIP $coin (actualizada <48h)"
    else
      FETCH_LIST="$FETCH_LIST $coin"
    fi
  done
else
  echo "📅 Mismo día ($TODAY). Solo buscando monedas nuevas..."
  EXISTING_IDS=$(echo "$EXISTING" | jq -r '.coins[].id' 2>/dev/null | tr '\n' ' ') || EXISTING_IDS=""
  for coin in $COINS; do
    if ! echo " $EXISTING_IDS " | grep -qw " $coin " 2>/dev/null; then
      FETCH_LIST="$FETCH_LIST $coin"
      echo "  ➕ Nueva moneda: $coin"
    fi
  done
fi

FETCH_LIST=$(echo "$FETCH_LIST" | xargs)
if [ -z "$FETCH_LIST" ]; then
  echo "✅ Sin monedas pendientes. Snapshot vigente."
  exit 0
fi

echo "📡 Consultando: $FETCH_LIST"
NEW_ARRAY="[]"

# 🔍 Fetch + Extracción de cierres por COINCIDENCIA EXACTA de fecha UTC
for coin in $FETCH_LIST; do
  echo "  🔎 $coin ..."
  
  # Fetch con timeout y retry
  RESP=$(curl -sS --max-time 20 --retry 2 --retry-delay 5 \
    "https://api.coingecko.com/api/v3/coins/${coin}/market_chart?vs_currency=usd&days=35&interval=daily" 2>&1) || {
    echo "  ❌ SKIP $coin (curl error)"
    continue
  }

  # Validar respuesta JSON
  if [ -z "$RESP" ] || ! echo "$RESP" | jq empty 2>/dev/null; then
    echo "  ❌ SKIP $coin (JSON inválido)"
    continue
  fi
  
  # Verificar si hay error en la respuesta de la API
  if echo "$RESP" | jq -e 'has("error")' 2>/dev/null | grep -q true; then
    echo "  ❌ SKIP $coin (API error: $(echo "$RESP" | jq -r '.error' 2>/dev/null))"
    continue
  fi

  # ✅ Extraer cierres por COINCIDENCIA EXACTA de fecha UTC (no por proximidad de timestamp)
  ENTRY=$(echo "$RESP" | jq --arg coin "$coin" --arg now "$NOW_ISO" \
    --arg d1 "$YESTERDAY" --arg d2 "$DAY2" --arg d7 "$D7" \
    --arg d8 "$D8" --arg d30 "$D30" --arg d31 "$D31" '
    
    # Función: obtener el ÚLTIMO precio del día (simula "close") por fecha exacta UTC
    def get_daily_close(target_date):
      .prices 
      | map(select((.[0] / 1000 | todate | split("T")[0]) == target_date))
      | if length > 0 then last | .[1] else null end;
    
    {
      id: $coin,
      last_fetched: ($now | now * 1000),
      current_price: (.prices[-1][1] // null),
      closes: {
        d1:  (. | get_daily_close($d1)),
        d2:  (. | get_daily_close($d2)),
        d7:  (. | get_daily_close($d7)),
        d8:  (. | get_daily_close($d8)),
        d30: (. | get_daily_close($d30)),
        d31: (. | get_daily_close($d31))
      }
    }
  ' 2>/dev/null)

  # Validar que se obtuvo al menos el precio actual
  if [ -z "$ENTRY" ] || [ "$ENTRY" = "null" ]; then
    echo "  ❌ SKIP $coin (jq parse error)"
    continue
  fi
  
  HAS_PRICE=$(echo "$ENTRY" | jq '.current_price != null' 2>/dev/null) || HAS_PRICE="false"
  if [ "$HAS_PRICE" != "true" ]; then
    echo "  ❌ SKIP $coin (sin precio actual)"
    continue
  fi

  # Agregar al array de nuevos datos
  NEW_ARRAY=$(echo "$NEW_ARRAY" | jq --argjson e "$ENTRY" '. + [$e]' 2>/dev/null) || {
    echo "  ❌ SKIP $coin (error al construir JSON)"
    continue
  }
  
  echo "  ✅ $coin → current: $(echo "$ENTRY" | jq -r '.current_price'), d1: $(echo "$ENTRY" | jq -r '.closes.d1 // "N/A")"
  
  # Rate limit respetuoso para API gratuita (~10 req/min)
  sleep 6
done

# 🧩 Fusionar con snapshot anterior usando jq (seguro, sin concatenación manual)
FINAL_JSON=$(jq -n \
  --argjson old "$EXISTING" \
  --argjson new "$NEW_ARRAY" \
  --arg today "$TODAY" '
    # Convertir arrays a mapas para merge fácil
    ($old.coins // [] | map({(.id): .}) | add // {}) as $old_map |
    ($new | map({(.id): .}) | add // {}) as $new_map |
    # Merge: nuevos datos sobrescriben, antiguos se conservan
    ($old_map * $new_map | to_entries | map(.value)) as $merged |
    {
      updated: $today,
      coins: $merged
    }
')

# Validar JSON final antes de guardar
if ! echo "$FINAL_JSON" | jq empty 2>/dev/null; then
  echo "❌ ERROR: JSON final inválido"
  exit 1
fi

# Guardar archivo
echo "$FINAL_JSON" > "$OUTFILE"
COUNT=$(echo "$FINAL_JSON" | jq '.coins | length' 2>/dev/null) || COUNT=0
echo "✅ Generado $OUTFILE con $COUNT monedas"

# 📦 Commit & Push automático
git config user.name "github-actions[bot]" 2>/dev/null || true
git config user.email "41898282+github-actions[bot]@users.noreply.github.com" 2>/dev/null || true
git add "$OUTFILE" 2>/dev/null || true

if git diff --cached --quiet 2>/dev/null; then
  echo "📦 Sin cambios nuevos para commitear"
else
  git commit -m "📊 snapshot $TODAY ($COUNT coins)" 2>/dev/null || true
  git push 2>/dev/null || echo "⚠️ Push fallido (ejecución local?)"
fi

#!/usr/bin/env bash
# Mantenemos -u y pipefail, pero añadimos trampa de errores para que NADA falle en silencio
set -uo pipefail
trap 'echo "❌ ERROR en línea $LINENO. Revisa los logs."; exit 1' ERR

cd "$(dirname "$0")/.."
OUTFILE="data/snapshots.json"
COINS_FILE="coins_list.txt"
mkdir -p data

TODAY=$(date -u +%Y-%m-%d)
CUTOFF=$(date -u -d "2 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-2d +%Y-%m-%d)
echo "=== 🚀 Fetch & Prune | $TODAY ==="

# --- 1. Leer y depurar coins_list.txt ---
declare -A COIN_DATES
PRUNED_LIST=""

if [ -f "$COINS_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(echo "$line" | xargs)
    [ -z "$line" ] && continue
    
    IFS=',' read -r coin cdate <<< "$line"
    coin=$(echo "$coin" | xargs)
    cdate=$(echo "${cdate:-}" | xargs)
    
    [ -z "$coin" ] && continue
    
    # Validar fecha o usar hoy
    if [[ ! "$cdate" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || [[ "$cdate" < "$CUTOFF" ]]; then
      echo "  🗑 PRUNED: $coin ($cdate)"
      PRUNED_LIST="$PRUNED_LIST $coin"
    else
      COIN_DATES["$coin"]="$cdate"
    fi
  done < "$COINS_FILE"
fi

# Defaults seguros
for dc in bitcoin ethereum solana dogecoin cardano; do
  [ -z "${COIN_DATES[$dc]+x}" ] && COIN_DATES["$dc"]="$TODAY"
done

# Reescribir txt limpio
> "$COINS_FILE"
for c in "${!COIN_DATES[@]}"; do echo "$c,${COIN_DATES[$c]}" >> "$COINS_FILE"; done
sort -o "$COINS_FILE" "$COINS_FILE"
echo "  ✅ Coins activas: $(wc -l < "$COINS_FILE")"

# --- 2. Evaluar estado del JSON ---
EXISTING_DATE=""
[ -f "$OUTFILE" ] && EXISTING_DATE=$(jq -r '.date // ""' "$OUTFILE" 2>/dev/null) || true

SAME_DAY=0
[ "$EXISTING_DATE" = "$TODAY" ] && SAME_DAY=1
echo "  📅 JSON date: ${EXISTING_DATE:-none} | Mode: $([ $SAME_DAY -eq 1 ] && echo "SAME DAY" || echo "NEW DAY")"

# --- 3. Determinar qué fetchear ---
FETCH_LIST=()
for coin in "${!COIN_DATES[@]}"; do
  IN_JSON=0
  if [ $SAME_DAY -eq 1 ] && [ -f "$OUTFILE" ]; then
    jq -e --arg c "$coin" '.coins[$c]' "$OUTFILE" >/dev/null 2>&1 && IN_JSON=1
  fi
  
  if [ $SAME_DAY -eq 1 ] && [ $IN_JSON -eq 1 ]; then
    echo "  ⏭ SKIP: $coin"
  else
    echo "  📥 FETCH: $coin"
    FETCH_LIST+=("$coin")
  fi
done

[ ${#FETCH_LIST[@]} -eq 0 ] && echo "✅ Nada que actualizar. Saliendo." && exit 0

# --- 4. Fetch & Build JSON seguro con jq ---
# Inicializar mapa de monedas
if [ $SAME_DAY -eq 1 ] && [ -f "$OUTFILE" ] && jq empty "$OUTFILE" 2>/dev/null; then
  COINS_MAP=$(jq '.coins // {}' "$OUTFILE")
else
  COINS_MAP='{}'
fi

for coin in "${FETCH_LIST[@]}"; do
  echo "  🔍 Obteniendo $coin ..."
  RESP=$(curl -sS --max-time 15 --retry 2 "https://api.coingecko.com/api/v3/coins/${coin}/market_chart?vs_currency=usd&days=35&interval=daily")
  
  # Validar respuesta
  echo "$RESP" | jq -e '.error' >/dev/null 2>&1 && { echo "  ❌ API error para $coin"; continue; }
  [ -z "$(echo "$RESP" | jq '.prices[0][1] // empty' 2>/dev/null)" ] && { echo "  ❌ Sin precios para $coin"; continue; }

  # Extraer cierres a 23:59 UTC (simulado con punto más cercano del día)
  ENTRY=$(echo "$RESP" | jq --arg c "$coin" '
    .prices as $p |
    ($p[-1][0]) as $now |
    {
      d1:  ($p | map(select(.[0] < ($now - 86400000))) | last | .[1] // null),
      d7:  ($p | map(select(.[0] < ($now - 604800000))) | last | .[1] // null),
      d30: ($p | map(select(.[0] < ($now - 2505600000))) | last | .[1] // null)
    }
  ')

  # Fusionar en el mapa
  COINS_MAP=$(echo "$COINS_MAP" | jq --arg c "$coin" --argjson e "$ENTRY" '.[$c] = $e')
  echo "  ✅ $coin procesado"
  sleep 6
done

# --- 5. Limpiar, validar y guardar ---
COINS_MAP=$(echo "$COINS_MAP" | jq '
  to_entries | map(.value |= del(.d3, .d9, .d32, .h24, .h48)) | from_entries
')

FINAL_JSON=$(jq -n --arg date "$TODAY" --argjson coins "$COINS_MAP" '{date:$date, coins:$coins}')
echo "$FINAL_JSON" | jq '.' > "$OUTFILE" || { echo "❌ JSON inválido generado"; exit 1; }
echo "✅ Guardado $OUTFILE ($(echo "$FINAL_JSON" | jq '.coins | length') monedas)"

# --- 6. Git push seguro ---
git config user.name "github-actions[bot]" 2>/dev/null || true
git config user.email "41898282+github-actions[bot]@users.noreply.github.com" 2>/dev/null || true
git add "$OUTFILE" "$COINS_FILE"

if git diff --cached --quiet; then
  echo "📦 Sin cambios para commitear"
else
  git commit -m "📊 snapshot $TODAY ($(date -u +%H:%M))"
  git push
  echo "🚀 Push exitoso"
fi

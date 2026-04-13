#!/usr/bin/env bash
# Solo -u y pipefail; manejamos errores manualmente
set -uo pipefail
cd "$(dirname "$0")/.."
OUTFILE="data/snapshots.json"
COINS_FILE="coins_list.txt"
mkdir -p data

echo "🚀 INICIO: $(date -u)"
TODAY=$(date -u +%Y-%m-%d)
CUTOFF=$(date -u -d "2 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-2d +%Y-%m-%d)

echo "📅 TODAY: $TODAY | CUTOFF: $CUTOFF"

# --- 1. Leer y depurar coins_list.txt ---
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
      echo "  🗑 PRUNED: $coin"
      PRUNED_LIST="$PRUNED_LIST $coin"
    else
      COIN_DATES["$coin"]="$cdate"
    fi
  done < "$COINS_FILE"
else
  echo "  ℹ $COINS_FILE no encontrado"
fi

# Reescribir txt limpio
> "$COINS_FILE"
for coin in "${!COIN_DATES[@]}"; do echo "$coin,${COIN_DATES[$coin]}" >> "$COINS_FILE"; done
sort -o "$COINS_FILE" "$COINS_FILE" 2>/dev/null || true
echo "  ✅ Active: $(wc -l < "$COINS_FILE" 2>/dev/null || echo 0)"

# --- 2. Cargar JSON base ---
EXISTING_DATE=""
[ -f "$OUTFILE" ] && EXISTING_DATE=$(jq -r '.date // ""' "$OUTFILE" 2>/dev/null) || EXISTING_DATE=""
COINS_JSON=$(jq '.coins // {}' "$OUTFILE" 2>/dev/null) || COINS_JSON='{}'
echo "  📂 JSON existente: ${EXISTING_DATE:-vacio}"

# --- 3. Determinar qué consultar ---
FETCH_LIST=()
for coin in "${!COIN_DATES[@]}"; do
  if [ "$EXISTING_DATE" = "$TODAY" ]; then
    jq -e --arg c "$coin" '.coins[$c]' "$OUTFILE" >/dev/null 2>&1 && echo "  ⏭ SKIP: $coin" || { echo "  📥 FETCH: $coin"; FETCH_LIST+=("$coin"); }
  else
    echo "  📥 FETCH: $coin"
    FETCH_LIST+=("$coin")
  fi
done
echo "  📦 A consultar: ${FETCH_LIST[*]:-Ninguna}"

# --- Helpers (LOS MISMOS QUE YA FUNCIONABAN) ---
round_price() {
  local p="$1"
  if [ -z "$p" ] || [ "$p" = "null" ]; then
    echo "null"
  else
    echo "$p" | awk '{if($1>=1) printf "%.2f",$1; else printf "%.8f",$1}'
  fi
}

get_price_at_2359() {
  local json_data="$1"
  local target_date="$2"
  local price
  price=$(echo "$json_data" | jq --arg td "$target_date" '
    .prices 
    | map(select((.[0] / 1000 | todate | split("T")[0]) == $td))
    | if length > 0 then last | .[1] else null end
  ' 2>/dev/null) || price="null"
  round_price "$price"
}

# --- 4. Fetch & Merge (CON CLAVES DE FECHA ABSOLUTA) ---
for coin in "${FETCH_LIST[@]}"; do
  echo "  🔍 $coin ..."
  RESP=$(curl -sS --max-time 20 --retry 2 "https://api.coingecko.com/api/v3/coins/${coin}/market_chart?vs_currency=usd&days=35" 2>&1) || { echo "  ❌ curl"; continue; }
  echo "$RESP" | jq empty >/dev/null 2>&1 || { echo "  ❌ JSON inválido"; continue; }

  # Calcular las 6 fechas UTC
  D1=$(date -u -d "1 day ago" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)
  D2=$(date -u -d "2 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-2d +%Y-%m-%d)
  D7=$(date -u -d "7 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-7d +%Y-%m-%d)
  D8=$(date -u -d "8 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-8d +%Y-%m-%d)
  D30=$(date -u -d "30 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-30d +%Y-%m-%d)
  D31=$(date -u -d "31 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-31d +%Y-%m-%d)

  # Extraer precios con helpers probados
  P1=$(get_price_at_2359 "$RESP" "$D1")
  P2=$(get_price_at_2359 "$RESP" "$D2")
  P7=$(get_price_at_2359 "$RESP" "$D7")
  P8=$(get_price_at_2359 "$RESP" "$D8")
  P30=$(get_price_at_2359 "$RESP" "$D30")
  P31=$(get_price_at_2359 "$RESP" "$D31")

  # ✅ Construir ENTRY con claves de fecha absoluta (NO d1/d2)
  ENTRY=$(jq -n \
    --arg d1 "$D1" --arg p1 "$P1" \
    --arg d2 "$D2" --arg p2 "$P2" \
    --arg d7 "$D7" --arg p7 "$P7" \
    --arg d8 "$D8" --arg p8 "$P8" \
    --arg d30 "$D30" --arg p30 "$P30" \
    --arg d31 "$D31" --arg p31 "$P31" \
    '{($d1):$p1, ($d2):$p2, ($d7):$p7, ($d8):$p8, ($d30):$p30, ($d31):$p31}')

  # Validar ENTRY
  if [ -z "$ENTRY" ] || ! echo "$ENTRY" | jq empty 2>/dev/null; then
    echo "  ❌ ENTRY inválido"; continue
  fi

  # 🔑 COMPACTAR COINS_JSON antes de --argjson (evita error de saltos de línea)
  COINS_JSON=$(echo "$COINS_JSON" | jq -c '.')
  
  # Fusionar
  COINS_JSON=$(echo "$COINS_JSON" | jq --arg c "$coin" --argjson e "$ENTRY" '.[$c] = $e' 2>/dev/null) || { echo "  ❌ merge falló"; continue; }
  echo "  ✅ $coin → $D1, $D2, $D7, $D8, $D30, $D31"
  sleep 6
done

# --- 5. Limpieza y escritura ---
for pruned in $PRUNED_LIST; do COINS_JSON=$(echo "$COINS_JSON" | jq --arg c "$pruned" 'del(.[$c])' 2>/dev/null) || true; done

# Compactar antes del merge final
COINS_JSON=$(echo "$COINS_JSON" | jq -c '.')

FINAL_JSON=$(jq -n --arg date "$TODAY" --argjson coins "$COINS_JSON" '{date:$date, coins:$coins}')
if ! echo "$FINAL_JSON" | jq empty 2>/dev/null; then
  echo "❌ JSON final inválido"; exit 1
fi
echo "$FINAL_JSON" > "$OUTFILE"
echo "💾 JSON escrito: $TODAY"

# 🔐 SHA256
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$OUTFILE" > "${OUTFILE}.sha256"; fi

# --- 6. Commit & Push ---
git config user.name "github-actions[bot]" 2>/dev/null || true
git config user.email "41898282+github-actions[bot]@users.noreply.github.com" 2>/dev/null || true
git add "$OUTFILE" "$COINS_FILE" "${OUTFILE}.sha256" 2>/dev/null || true

if git diff --cached --quiet 2>/dev/null; then
  echo "📦 Sin cambios nuevos"
else
  git commit -m "📊 snapshot $TODAY" >/dev/null 2>&1
  git push >/dev/null 2>&1 || echo "⚠️ Push fallido"
fi
echo "🏁 FINALIZADO"

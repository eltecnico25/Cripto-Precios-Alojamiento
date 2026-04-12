#!/usr/bin/env bash
# Solo -u y pipefail; manejamos errores manualmente para evitar exit 1
set -uo pipefail
cd "$(dirname "$0")/.."

OUTFILE="data/snapshots.json"
CHECKSUM_FILE="${OUTFILE}.sha256"
COINS_FILE="coins_list.txt"
mkdir -p data

TODAY=$(date -u +%Y-%m-%d)
CUTOFF=$(date -u -d "2 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-2d +%Y-%m-%d)

echo "=== Fetch & Prune — $TODAY ==="

# --- Step 1: Leer coins_list.txt, eliminar entradas >2 días ---
declare -A COIN_DATES
PRUNED_LIST=""
if [ -f "$COINS_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$line" ] && continue
    coin=$(echo "$line" | cut -d',' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    cdate=$(echo "$line" | cut -d',' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$coin" ] && continue
    # Si no tiene fecha o es anterior al cutoff, se elimina
    if [ -z "$cdate" ] || [[ "$cdate" < "$CUTOFF" ]]; then
      echo "  🗑 PRUNED: $coin (date: ${cdate:-none}, older than 2 days)"
      PRUNED_LIST="$PRUNED_LIST $coin"
    else
      COIN_DATES["$coin"]="$cdate"
    fi
  done < "$COINS_FILE"
else
  echo "  ℹ No coins_list.txt found, using defaults"
fi

# Reescribir coins_list.txt limpio
> "$COINS_FILE"
for coin in "${!COIN_DATES[@]}"; do
  echo "$coin,${COIN_DATES[$coin]}" >> "$COINS_FILE"
done
sort -o "$COINS_FILE" "$COINS_FILE" 2>/dev/null || true
echo "  ✅ Active coins: $(wc -l < "$COINS_FILE" 2>/dev/null || echo 0)"

# --- Step 2: Cargar JSON existente, verificar fecha ---
EXISTING_DATE=""
if [ -f "$OUTFILE" ] && jq empty "$OUTFILE" 2>/dev/null; then
  EXISTING_DATE=$(jq -r '.date // ""' "$OUTFILE" 2>/dev/null) || EXISTING_DATE=""
fi
echo "  📅 Existing JSON date: ${EXISTING_DATE:-none}"
echo "  📅 Today: $TODAY"

SAME_DAY=0
if [ "$EXISTING_DATE" = "$TODAY" ]; then
  SAME_DAY=1
  echo "  🔄 Mode: SAME DAY — only fetch new coins"
else
  echo "  🌅 Mode: NEW DAY — fetch all coins"
fi

# --- Step 3: Determinar qué monedas consultar ---
FETCH_ALL=()    # Existentes: necesitan d1, d7, d30
FETCH_NEW=()    # Nuevas: necesitan d1, d2, d7, d8, d30, d31

for coin in "${!COIN_DATES[@]}"; do
  IN_JSON=0
  if [ "$SAME_DAY" -eq 1 ] && [ -f "$OUTFILE" ]; then
    IN_JSON=$(jq --arg c "$coin" 'if .coins and .coins[$c] then 1 else 0 end' "$OUTFILE" 2>/dev/null) || IN_JSON=0
  fi
  if [ "$SAME_DAY" -eq 1 ] && [ "$IN_JSON" -eq 1 ]; then
    echo "  ⏭ SKIP: $coin (already in today's JSON)"
  elif [ "$SAME_DAY" -eq 1 ] && [ "$IN_JSON" -eq 0 ]; then
    echo "  ➕ NEW: $coin (not in JSON, full fetch)"
    FETCH_NEW+=("$coin")
  else
    # New day: verificar si ya existe en JSON
    if [ -f "$OUTFILE" ] && jq -e --arg c "$coin" '.coins[$c] != null' "$OUTFILE" >/dev/null 2>&1; then
      echo "  🔄 UPDATE: $coin (existing, d1/d7/d30)"
      FETCH_ALL+=("$coin")
    else
      echo "  ➕ ADD: $coin (new, full fetch)"
      FETCH_NEW+=("$coin")
    fi
  fi
done

echo "  📦 Coins to update (d1,d7,d30): ${FETCH_ALL[*]:-none}"
echo "  📦 Coins to add (full): ${FETCH_NEW[*]:-none}"

# --- Helper: Formatear precio (>=1 → 2 decimales, <1 → 8 decimales) ---
round_price() {
  local p="$1"
  if [ -z "$p" ] || [ "$p" = "null" ]; then
    echo "null"
  else
    echo "$p" | awk '{if($1>=1) printf "%.2f",$1; else printf "%.8f",$1}'
  fi
}

# --- Helper: Obtener precio a las 23:59 UTC de una fecha específica ---
get_price_at_2359() {
  local json_data="$1"
  local target_date="$2"  # YYYY-MM-DD
  local price
  price=$(echo "$json_data" | jq --arg td "$target_date" '
    .prices 
    | map(select((.[0] / 1000 | todate | split("T")[0]) == $td))
    | if length > 0 then last | .[1] else null end
  ' 2>/dev/null) || price="null"
  round_price "$price"
}

# --- Step 4: Fetch y construcción de entradas ---
if [ "$SAME_DAY" -eq 1 ] && [ -f "$OUTFILE" ]; then
  COINS_JSON=$(jq '.coins // {}' "$OUTFILE" 2>/dev/null) || COINS_JSON='{}'
else
  COINS_JSON='{}'
fi

fetch_coin_data() {
  local coin="$1"
  local is_new="$2"  # 1=new, 0=existing
  echo "  🔍 Fetching $coin (new=$is_new) ..."
  local RESP
  RESP=$(curl -sS --max-time 20 --retry 2 --retry-delay 5 \
    "https://api.coingecko.com/api/v3/coins/${coin}/market_chart?vs_currency=usd&days=35" 2>&1) || {
    echo "  ❌ ERROR: $coin — curl failed"
    return 1
  }
  # Validar JSON
  if [ -z "$RESP" ] || ! echo "$RESP" | jq empty 2>/dev/null; then
    echo "  ❌ ERROR: $coin — invalid JSON response"
    return 1
  fi
  # Calcular fechas objetivo
  local d1 d7 d30
  d1=$(date -u -d "1 day ago" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)
  d7=$(date -u -d "7 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-7d +%Y-%m-%d)
  d30=$(date -u -d "30 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-30d +%Y-%m-%d)
  
  local p1 p7 p30
  p1=$(get_price_at_2359 "$RESP" "$d1")
  p7=$(get_price_at_2359 "$RESP" "$d7")
  p30=$(get_price_at_2359 "$RESP" "$d30")
  
  local entry
  if [ "$is_new" -eq 1 ]; then
    # Nueva moneda: incluir 6 cierres
    local d2 d8 d31 p2 p8 p31
    d2=$(date -u -d "2 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-2d +%Y-%m-%d)
    d8=$(date -u -d "8 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-8d +%Y-%m-%d)
    d31=$(date -u -d "31 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-31d +%Y-%m-%d)
    p2=$(get_price_at_2359 "$RESP" "$d2")
    p8=$(get_price_at_2359 "$RESP" "$d8")
    p31=$(get_price_at_2359 "$RESP" "$d31")
    entry=$(jq -n \
      --argjson d1 "$p1" --argjson d2 "$p2" \
      --argjson d7 "$p7" --argjson d8 "$p8" \
      --argjson d30 "$p30" --argjson d31 "$p31" \
      '{d1:$d1, d2:$d2, d7:$d7, d8:$d8, d30:$d30, d31:$d31}')
  else
    # Existente: solo 3 cierres
    entry=$(jq -n \
      --argjson d1 "$p1" --argjson d7 "$p7" --argjson d30 "$p30" \
      '{d1:$d1, d7:$d7, d30:$d30}')
  fi
  
  # Fusionar en COINS_JSON
  COINS_JSON=$(echo "$COINS_JSON" | jq --arg c "$coin" --argjson e "$entry" '.[$c] = $e' 2>/dev/null) || {
    echo "  ❌ ERROR: $coin — jq merge failed"
    return 1
  }
  echo "  ✅ OK: $coin"
  return 0
}

# Fetch existentes (d1, d7, d30)
for coin in "${FETCH_ALL[@]}"; do
  fetch_coin_data "$coin" 0 || true
  sleep 8
done
# Fetch nuevas (d1, d2, d7, d8, d30, d31)
for coin in "${FETCH_NEW[@]}"; do
  fetch_coin_data "$coin" 1 || true
  sleep 8
done

# --- Step 5: Limpiar campos obsoletos ---
COINS_JSON=$(echo "$COINS_JSON" | jq '
  to_entries | map(
    .value |= (del(.d3) | del(.d9) | del(.d32))
  ) | from_entries
' 2>/dev/null) || true

# Eliminar monedas pruned del JSON
for pruned in $PRUNED_LIST; do
  COINS_JSON=$(echo "$COINS_JSON" | jq --arg c "$pruned" 'del(.[$c])' 2>/dev/null) || true
done

# --- Construir JSON final ---
FINAL_JSON=$(jq -n --arg date "$TODAY" --argjson coins "$COINS_JSON" \
  '{date: $date, coins: $coins}' 2>/dev/null) || {
  echo "❌ ERROR: Failed to build final JSON"
  exit 1
}

# Validar y guardar
if ! echo "$FINAL_JSON" | jq empty 2>/dev/null; then
  echo "❌ ERROR: Final JSON is invalid"
  exit 1
fi
echo "$FINAL_JSON" > "$OUTFILE"

# 🔐 GENERAR SHA256 PARA INTEGRIDAD
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$OUTFILE" > "$CHECKSUM_FILE"
elif command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$OUTFILE" > "$CHECKSUM_FILE"
else
  echo "⚠️ WARNING: sha256sum/shasum not found. Skipping checksum."
fi
if [ -f "$CHECKSUM_FILE" ]; then
  HASH=$(cut -d' ' -f1 "$CHECKSUM_FILE")
  echo "✅ SHA256: $HASH"
fi

COUNT=$(echo "$FINAL_JSON" | jq '.coins | length' 2>/dev/null) || COUNT=0
echo "✅ Generated $OUTFILE with $COUNT coins"

# --- Commit & Push (Incluye .sha256) ---
git config user.name "github-actions[bot]" 2>/dev/null || true
git config user.email "41898282+github-actions[bot]@users.noreply.github.com" 2>/dev/null || true
git add "$OUTFILE" "$COINS_FILE" "$CHECKSUM_FILE" 2>/dev/null || true

if git diff --cached --quiet 2>/dev/null; then
  echo "📦 No changes to commit"
else
  git commit -m "📊 snapshot $TODAY ($COUNT coins) [sha256: ${HASH:-none}]" 2>/dev/null || true
  git push 2>/dev/null || echo "⚠️ Push failed (local execution?)"
fi

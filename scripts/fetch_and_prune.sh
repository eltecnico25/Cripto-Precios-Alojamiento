#!/usr/bin/env bash
# === DEBUG MODE ===
exec > >(tee -a "/tmp/fetch-debug-$(date +%s).log") 2>&1
set -x  # Imprime cada comando antes de ejecutarlo
echo "=== Script started at $(date -u) ==="
echo "PWD: $(pwd)"
echo "Files in repo: $(ls -la)"
echo "coins_list.txt content:"
cat coins_list.txt 2>/dev/null || echo "(not found)"
echo "=== END DEBUG INFO ==="

# Solo -u y pipefail; manejamos errores manualmente para evitar exit 1
set -uo pipefail
cd "$(dirname "$0")/.."

OUTFILE="data/snapshots.json"
COINS_FILE="coins_list.txt"
SYM_MAP_FILE="data/symbol_map.json"
mkdir -p data

TODAY=$(date -u +%Y-%m-%d)
TODAY_EPOCH=$(date -u -d "$TODAY" +%s 2>/dev/null || date -u -j -f "%Y-%m-%d" "$TODAY" +%s)
CUTOFF_EPOCH=$((TODAY_EPOCH - 172800))  # 2 días en segundos

echo "=== Fetch & Prune — $TODAY ==="

# --- 🗺️ Módulo: Símbolo → ID de CoinGecko ---
# Cargar mapa existente
declare -A SYM_TO_ID
if [ -f "$SYM_MAP_FILE" ]; then
  while IFS='=' read -r sym id; do
    [ -n "$sym" ] && [ -n "$id" ] && SYM_TO_ID["$sym"]="$id"
  done < <(jq -r '. | to_entries[] | "\(.key)=\(.value)"' "$SYM_MAP_FILE" 2>/dev/null)
fi

# Mapeo manual de abreviaturas comunes
MANUAL_MAP=(
  "btc=bitcoin" "eth=ethereum" "sol=solana" "doge=dogecoin" "ada=cardano"
  "bnb=binancecoin" "xrp=ripple" "dot=polkadot" "avax=avalanche-2" "matic=polygon"
  "link=chainlink" "uni=uniswap" "ltc=litecoin" "atom=cosmos" "xlm=stellar"
  "shib=shiba-inu" "trx=tron" "near=near" "apt=aptos" "sui=sui"
  "pepe=pepe" "arb=arbitrum" "op=optimism" "fil=filecoin" "ton=the-open-network"
  "etc=ethereum-classic" "hbar=hedera-hashgraph" "cro=cronos" "vet=vechain"
  "algo=algorand" "aave=aave" "inj=injective-protocol" "rndr=render-token"
  "paxg=pax-gold" "usdc=usd-coin" "usdt=tether" "dai=dai" "busd=binance-usd"
)
for entry in "${MANUAL_MAP[@]}"; do
  sym="${entry%%=*}"; id="${entry#*=}"
  SYM_TO_ID["$sym"]="$id"
done

# Función: resolver símbolo a ID (con fallback a API de búsqueda)
resolve_symbol() {
  local sym="${1,,}"  # lowercase
  # 1. Buscar en mapa local
  if [ -n "${SYM_TO_ID[$sym]+x}" ]; then
    echo "${SYM_TO_ID[$sym]}"
    return 0
  fi
  # 2. Buscar en API de CoinGecko
  echo "  🔍 Searching API for '$sym' ..."
  local resp
  resp=$(curl -sS --max-time 10 "https://api.coingecko.com/api/v3/search?query=$sym" 2>/dev/null) || return 1
  local best_id
  best_id=$(echo "$resp" | jq -r '
    .coins // [] 
    | map(select(.symbol | ascii_downcase == "'"$sym"'"))
    | sort_by(.market_cap_rank // 999999)
    | .[0].id // empty
  ' 2>/dev/null)
  
  if [ -n "$best_id" ]; then
    SYM_TO_ID["$sym"]="$best_id"
    # Guardar mapa actualizado
    jq -n --arg s "$sym" --arg i "$best_id" '
      (if input then input else {} end) as $old | $old + {($s): $i}
    ' "$SYM_MAP_FILE" 2>/dev/null > "${SYM_MAP_FILE}.tmp" && mv "${SYM_MAP_FILE}.tmp" "$SYM_MAP_FILE" 2>/dev/null || true
    echo "$best_id"
    return 0
  fi
  return 1
}

# --- 🗑️ Step 1: Pruning de coins_list.txt ---
declare -A ACTIVE_COINS
PRUNED_LIST=""

if [ -f "$COINS_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$line" ] && continue
    
    # Soportar formato: "btc" o "btc,2026-04-07"
    if [[ "$line" == *","* ]]; then
      coin_sym=$(echo "$line" | cut -d',' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      cdate=$(echo "$line" | cut -d',' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    else
      coin_sym="$line"
      cdate="$TODAY"
    fi
    
    [ -z "$coin_sym" ] && continue
    
    # Resolver símbolo a ID
    coin_id=$(resolve_symbol "$coin_sym") || {
      echo "  ❌ SKIP: '$coin_sym' → no CoinGecko ID found"
      PRUNED_LIST="$PRUNED_LIST $coin_sym"
      continue
    }
    
    # Validar fecha y comparar con cutoff (usando epoch)
    if [ -n "$cdate" ] && [[ "$cdate" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      cdate_epoch=$(date -u -d "$cdate" +%s 2>/dev/null || date -u -j -f "%Y-%m-%d" "$cdate" +%s 2>/dev/null) || cdate_epoch=0
      if [ "$cdate_epoch" -lt "$CUTOFF_EPOCH" ]; then
        echo "  🗑 PRUNED: $coin_sym ($cdate) — older than 2 days"
        PRUNED_LIST="$PRUNED_LIST $coin_sym"
        continue
      fi
    else
      echo "  ⚠ WARN: $coin_sym — invalid date '$cdate', using today"
      cdate="$TODAY"
    fi
    
    # Guardar como ID (no símbolo) para consistencia
    ACTIVE_COINS["$coin_id"]="$cdate"
  done < "$COINS_FILE"
else
  echo "  ℹ No coins_list.txt found, using defaults"
fi

# Asegurar defaults (como IDs)
for sym in btc eth sol doge ada; do
  id=$(resolve_symbol "$sym") || continue
  [ -z "${ACTIVE_COINS[$id]+x}" ] && ACTIVE_COINS["$id"]="$TODAY"
done

# Reescribir coins_list.txt limpio (usando IDs)
> "$COINS_FILE"
for coin_id in "${!ACTIVE_COINS[@]}"; do
  echo "$coin_id,${ACTIVE_COINS[$coin_id]}" >> "$COINS_FILE"
done
sort -o "$COINS_FILE" "$COINS_FILE" 2>/dev/null || true

echo "  ✅ Active coins: $(wc -l < "$COINS_FILE" 2>/dev/null || echo 0)"

# --- 📦 Step 2: Cargar JSON existente ---
EXISTING_DATE=""
if [ -f "$OUTFILE" ] && jq empty "$OUTFILE" 2>/dev/null; then
  EXISTING_DATE=$(jq -r '.date // ""' "$OUTFILE" 2>/dev/null) || EXISTING_DATE=""
fi

echo "  📅 Existing JSON date: ${EXISTING_DATE:-none}"
echo "  📅 Today: $TODAY"

SAME_DAY=0
[ "$EXISTING_DATE" = "$TODAY" ] && SAME_DAY=1
[ "$SAME_DAY" -eq 1 ] && echo "  🔄 Mode: SAME DAY — only fetch new coins" || echo "  🌅 Mode: NEW DAY — fetch all coins"

# --- 🔍 Step 3: Determinar qué monedas consultar ---
FETCH_ALL=()    # Existentes: d1, d7, d30
FETCH_NEW=()    # Nuevas: d1, d2, d7, d8, d30, d31

for coin_id in "${!ACTIVE_COINS[@]}"; do
  IN_JSON=0
  if [ "$SAME_DAY" -eq 1 ] && [ -f "$OUTFILE" ]; then
    IN_JSON=$(jq --arg c "$coin_id" 'if .coins and .coins[$c] then 1 else 0 end' "$OUTFILE" 2>/dev/null) || IN_JSON=0
  fi
  
  if [ "$SAME_DAY" -eq 1 ] && [ "$IN_JSON" -eq 1 ]; then
    echo "  ⏭ SKIP: $coin_id (already in today's JSON)"
  elif [ "$SAME_DAY" -eq 1 ] && [ "$IN_JSON" -eq 0 ]; then
    echo "  ➕ NEW: $coin_id (not in JSON, full fetch)"
    FETCH_NEW+=("$coin_id")
  else
    if [ -f "$OUTFILE" ] && jq -e --arg c "$coin_id" '.coins[$c] != null' "$OUTFILE" >/dev/null 2>&1; then
      echo "  🔄 UPDATE: $coin_id (existing, d1/d7/d30)"
      FETCH_ALL+=("$coin_id")
    else
      echo "  ➕ ADD: $coin_id (new, full fetch)"
      FETCH_NEW+=("$coin_id")
    fi
  fi
done

echo "  📦 Coins to update (d1,d7,d30): ${FETCH_ALL[*]:-none}"
echo "  📦 Coins to add (full): ${FETCH_NEW[*]:-none}"

# --- 🔢 Helper: Formatear precio ---
round_price() {
  local p="$1"
  if [ -z "$p" ] || [ "$p" = "null" ]; then
    echo "null"
  else
    echo "$p" | awk '{if($1>=1) printf "%.2f",$1; else printf "%.8f",$1}'
  fi
}

# --- 🎯 Helper: Obtener precio más cercano a 23:59 UTC de una fecha ---
get_price_at_2359() {
  local json_data="$1"
  local target_date="$2"  # YYYY-MM-DD
  
  # Timestamp objetivo: target_date a las 23:59:00 UTC
  local target_ts
  target_ts=$(date -u -d "${target_date} 23:59:00" +%s 2>/dev/null || date -u -j -f "%Y-%m-%d %H:%M:%S" "${target_date} 23:59:00" +%s 2>/dev/null) || return 1
  local target_ms=$((target_ts * 1000))
  
  local price
  price=$(echo "$json_data" | jq --argjson tms "$target_ms" '
    .prices // []
    | map(select(.[0] != null and .[1] != null))
    | min_by((.ts - $tms) | fabs)
    | .[1] // null
  ' 2>/dev/null) || price="null"
  
  round_price "$price"
}

# --- 📥 Step 4: Fetch y construcción de entradas ---
if [ "$SAME_DAY" -eq 1 ] && [ -f "$OUTFILE" ]; then
  COINS_JSON=$(jq '.coins // {}' "$OUTFILE" 2>/dev/null) || COINS_JSON='{}'
else
  COINS_JSON='{}'
fi

fetch_coin_data() {
  local coin_id="$1"
  local is_new="$2"  # 1=new, 0=existing
  
  echo "  🔍 Fetching $coin_id (new=$is_new) ..."
  
  local RESP
  RESP=$(curl -sS --max-time 20 --retry 2 --retry-delay 5 \
    "https://api.coingecko.com/api/v3/coins/${coin_id}/market_chart?vs_currency=usd&days=35&interval=daily" 2>&1) || {
    echo "  ❌ ERROR: $coin_id — curl failed"
    return 1
  }
  
  # Validar JSON y errores de API
  if [ -z "$RESP" ] || ! echo "$RESP" | jq empty 2>/dev/null; then
    echo "  ❌ ERROR: $coin_id — invalid JSON"
    return 1
  fi
  if echo "$RESP" | jq -e 'has("error")' 2>/dev/null | grep -q true; then
    echo "  ❌ ERROR: $coin_id — API: $(echo "$RESP" | jq -r '.error' 2>/dev/null)"
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
  
  # Validar que al menos tengamos precio actual
  local current_price
  current_price=$(echo "$RESP" | jq '.prices[-1][1] // null' 2>/dev/null) || current_price="null"
  if [ "$current_price" = "null" ] || [ -z "$current_price" ]; then
    echo "  ❌ ERROR: $coin_id — no current price"
    return 1
  fi
  
  local entry
  if [ "$is_new" -eq 1 ]; then
    # Nueva moneda: 6 cierres
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
    # Existente: 3 cierres
    entry=$(jq -n \
      --argjson d1 "$p1" --argjson d7 "$p7" --argjson d30 "$p30" \
      '{d1:$d1, d7:$d7, d30:$d30}')
  fi
  
  # Fusionar en COINS_JSON
  COINS_JSON=$(echo "$COINS_JSON" | jq --arg c "$coin_id" --argjson e "$entry" '.[$c] = $e' 2>/dev/null) || {
    echo "  ❌ ERROR: $coin_id — jq merge failed"
    return 1
  }
  
  echo "  ✅ OK: $coin_id → current=$(round_price "$current_price"), d1=$p1"
  return 0
}

# Fetch existentes
for coin_id in "${FETCH_ALL[@]}"; do
  fetch_coin_data "$coin_id" 0 || true
  sleep 8
done

# Fetch nuevas
for coin_id in "${FETCH_NEW[@]}"; do
  fetch_coin_data "$coin_id" 1 || true
  sleep 8
done

# --- 🧹 Step 5: Limpiar campos obsoletos ---
COINS_JSON=$(echo "$COINS_JSON" | jq '
  to_entries | map(
    .value |= (del(.d3) | del(.d9) | del(.d32) | del(.h24) | del(.h48) | del(.d29))
  ) | from_entries
' 2>/dev/null) || true

# Eliminar monedas pruned del JSON
for pruned in $PRUNED_LIST; do
  COINS_JSON=$(echo "$COINS_JSON" | jq --arg c "$pruned" 'del(.[$c])' 2>/dev/null) || true
done

# --- 📦 Construir JSON final ---
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
COUNT=$(echo "$FINAL_JSON" | jq '.coins | length' 2>/dev/null) || COUNT=0
echo "✅ Generated $OUTFILE with $COUNT coins"

# --- 📤 Commit & Push ---
git config user.name "github-actions[bot]" 2>/dev/null || true
git config user.email "41898282+github-actions[bot]@users.noreply.github.com" 2>/dev/null || true
git add "$OUTFILE" "$COINS_FILE" "$SYM_MAP_FILE" 2>/dev/null || true

if git diff --cached --quiet 2>/dev/null; then
  echo "📦 No changes to commit"
else
  git commit -m "📊 snapshot $TODAY ($COUNT coins)" 2>/dev/null || true
  git push 2>/dev/null || echo "⚠️ Push failed (local execution?)"
fi

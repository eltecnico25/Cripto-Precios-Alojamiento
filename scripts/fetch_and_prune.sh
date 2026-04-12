#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
OUTFILE="data/snapshots.json"
COINS_FILE="coins_list.txt"
mkdir -p data

echo "🚀 INICIO: $(date -u)"
TODAY=$(date -u +%Y-%m-%d)
CUTOFF=$(date -u -d "2 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-2d +%Y-%m-%d)

# 📅 Claves absolutas UTC (siempre 6 registros)
D1=$(date -u -d "1 day ago" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)
D2=$(date -u -d "2 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-2d +%Y-%m-%d)
D7=$(date -u -d "7 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-7d +%Y-%m-%d)
D8=$(date -u -d "8 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-8d +%Y-%m-%d)
D30=$(date -u -d "30 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-30d +%Y-%m-%d)
D31=$(date -u -d "31 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-31d +%Y-%m-%d)

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

# --- 4. Fetch & Merge (EXTRACCIÓN SEGURA EN 1 jq) ---
for coin in "${FETCH_LIST[@]}"; do
  echo "  🔍 $coin ..."
  RESP=$(curl -sS --max-time 20 --retry 2 "https://api.coingecko.com/api/v3/coins/${coin}/market_chart?vs_currency=usd&days=35" 2>&1) || { echo "  ❌ curl"; continue; }
  echo "$RESP" | jq empty >/dev/null 2>&1 || { echo "  ❌ JSON inválido"; continue; }

  # ✅ Extracción + formateo en 1 llamada jq: evita --argjson con strings inválidos
  ENTRY=$(echo "$RESP" | jq --arg d1 "$D1" --arg d2 "$D2" --arg d7 "$D7" --arg d8 "$D8" --arg d30 "$D30" --arg d31 "$D31" 
    # Función: obtener último precio del día objetivo (simula close UTC)
    def get_close(t):
      .prices 
      | map(select((.[0]/1000 | todate | split("T")[0]) == t))
      | if length > 0 then last | .[1] else null end;
    
    # Función: formatear precio (>=1 → 2 decimales, <1 → 8 decimales)
    def fmt(p):
      if p == null then null
      elif p >= 1 then (p * 100 | round / 100)
      else (p * 100000000 | round / 100000000)
      end;
    
    '{
      ($d1):  (. | get_close($d1) | fmt),
      ($d2):  (. | get_close($d2) | fmt),
      ($d7):  (. | get_close($d7) | fmt),
      ($d8):  (. | get_close($d8) | fmt),
      ($d30): (. | get_close($d30) | fmt),
      ($d31): (. | get_close($d31) | fmt)
    }
  ' 2>/dev/null)

  # Validar que ENTRY es JSON válido y no vacío
  if [ -z "$ENTRY" ] || [ "$ENTRY" = "null" ] || ! echo "$ENTRY" | jq empty 2>/dev/null; then
    echo "  ❌ No se extrajeron precios válidos"; continue
  fi

  # Fusionar en COINS_JSON
  COINS_JSON=$(echo "$COINS_JSON" | jq --arg c "$coin" --argjson e "$ENTRY" '.[$c] = $e' 2>/dev/null) || { echo "  ❌ merge falló"; continue; }
  echo "  ✅ $coin → $(echo "$ENTRY" | jq -r 'to_entries | map(.key) | join(", ")')"
  sleep 6
done

# --- 5. Limpieza, validación y ESCRITURA FORZADA ---
for pruned in $PRUNED_LIST; do COINS_JSON=$(echo "$COINS_JSON" | jq --arg c "$pruned" 'del(.[$c])' 2>/dev/null) || true; done

FINAL_JSON=$(jq -n --arg date "$TODAY" --argjson coins "$COINS_JSON" '{date:$date, coins:$coins}')
if ! echo "$FINAL_JSON" | jq empty 2>/dev/null; then
  echo "❌ JSON final inválido. Abortando."; exit 1
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

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

OUTFILE="data/snapshots.json"
COINS_FILE="coins_list.txt"
mkdir -p data

# 1️⃣ Leer lista de monedas (soporta comas, espacios o saltos de línea)
if [ -f "$COINS_FILE" ]; then
  COINS=$(tr '[:space:],' ' ' < "$COINS_FILE" | xargs)
else
  COINS="bitcoin ethereum solana dogecoin cardano"
fi

# 2️⃣ Cargar snapshot existente o iniciar vacío
NOW_MS=$(date -u +%s)000
TODAY=$(date -u +%Y-%m-%d)
if [ -f "$OUTFILE" ]; then
  EXISTING=$(cat "$OUTFILE")
else
  EXISTING='{"updated":"0000-00-00","coins":[]}'
fi

# 3️⃣ Verificar si cambió la fecha
LAST_DATE=$(echo "$EXISTING" | jq -r '.updated // "0000-00-00"')
if [ "$TODAY" = "$LAST_DATE" ]; then
  echo "📅 Mismo día ($TODAY). Solo se verificarán nuevas monedas."
else
  echo "🌅 Nuevo día detectado ($TODAY). Iniciando actualización..."
fi

# 4️⃣ Determinar monedas a consultar (saltar las actualizadas <48h para ahorrar API)
SKIP_COINS=$(echo "$EXISTING" | jq -r --arg now "$NOW_MS" '
  .coins[] | select(.last_fetched != null)
  | select(($now | tonumber) - .last_fetched < 172800000)
  | .id' 2>/dev/null | tr '\n' ' ')

FETCH_LIST=""
for coin in $COINS; do
  if echo " ${SKIP_COINS} " | grep -q " ${coin} "; then
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

echo "📥 Consultando: $FETCH_LIST"
NEW_DATA="[]"

# 5️⃣ Fetch & Parse (interval=daily garantiza precios de cierre UTC)
for coin in $FETCH_LIST; do
  echo "  🔍 $coin ..."
  RESP=$(curl -sS --retry 2 --retry-delay 5 \
    "https://api.coingecko.com/api/v3/coins/${coin}/market_chart?vs_currency=usd&days=32&interval=daily")

  if [ -z "$RESP" ] || echo "$RESP" | jq -e '.error' >/dev/null 2>&1; then
    echo "  ❌ SKIP $coin (API error o rate limit)"
    continue
  fi

  # Extraer precio actual y array de cierres diarios {date, price}
  ENTRY=$(echo "$RESP" | jq --arg coin "$coin" --arg now "$NOW_MS" '
    {
      id: $coin,
      last_fetched: ($now | tonumber),
      current_price: .prices[-1][1],
      closes: [.prices[] | {date: (.[0] / 1000 | todate | split("T")[0]), price: .[1]}]
    }
  ' 2>/dev/null)

  if [ -z "$ENTRY" ] || [ "$ENTRY" = "null" ]; then
    echo "  ❌ SKIP $coin (Parse error)"
    continue
  fi

  NEW_DATA=$(echo "$NEW_DATA" | jq --argjson e "$ENTRY" '. + [$e]')
  sleep 8 # Respetar límite de API gratuita (~7-10 req/min)
done

# 6️⃣ Fusionar inteligente: Nuevos datos sobrescriben, se conservan los saltados
FINAL_JSON=$(jq -n \
  --argjson old "$EXISTING" \
  --argjson new "$NEW_DATA" \
  --arg today "$TODAY" '
    ($old.coins | map({(.id): .}) | add // {}) as $old_map |
    ($new | map({(.id): .}) | add // {}) as $new_map |
    # Fusionar (nuevo > viejo) y reconstruir array
    ($old_map * $new_map | to_entries | map(.value)) as $merged |
    {
      updated: $today,
      coins: $merged
    }
')

# 7️⃣ Validar y guardar
if ! echo "$FINAL_JSON" | jq empty 2>/dev/null; then
  echo "❌ ERROR: JSON inválido generado"
  exit 1
fi
echo "$FINAL_JSON" > "$OUTFILE"

COUNT=$(echo "$FINAL_JSON" | jq '.coins | length')
echo "✅ Generado $OUTFILE con $COUNT monedas"

# 8️⃣ Commit & Push automático
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add "$OUTFILE"
if git diff --cached --quiet; then
  echo "📦 Sin cambios nuevos para commitear"
else
  git commit -m "data: snapshot $TODAY ($COUNT coins)"
  git push
fi

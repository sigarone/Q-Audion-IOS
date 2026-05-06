#!/usr/bin/env bash
# W415 — pull a runtime log dump uploaded by the iOS app via
# Settings → Diagnostica → "Carica al server".
#
# Usage:
#   ./scripts/fetch-ios-log.sh <fileId>
#   ./scripts/fetch-ios-log.sh <fileId> --grep dial
#   ./scripts/fetch-ios-log.sh <fileId> --tail 200
#
# Auth: needs an authorized JWT in env. Two paths:
#   1. QAUDION_USER_TOKEN (current production path — files endpoint
#      authenticates with the uploader's JWT, so any signed-in user
#      can fetch their own dumps).
#   2. QAUDION_ADMIN_KEY (future — when we add an admin override on
#      the server-side that bypasses ownership; not used today).
#
# Output:
#   - downloads to ./.cache/ios-logs/<fileId>.log
#   - prints first 50 lines (header + start of buffer)
#   - if --grep <pat>: filters and prints matching lines
#   - if --tail <N>: prints last N lines
#   - default: prints summary stats + first 30 errors

set -euo pipefail

SERVER="${QAUDION_SERVER:-https://voip.bcrypto.com}"
FILE_ID="${1:-}"
shift || true

if [[ -z "$FILE_ID" ]]; then
  echo "Usage: $0 <fileId> [--grep PAT] [--tail N]" >&2
  exit 2
fi

if [[ -z "${QAUDION_USER_TOKEN:-}" ]]; then
  echo "ERROR: QAUDION_USER_TOKEN env var not set." >&2
  echo "  Set it from a logged-in iOS session — copy from Settings → Diagnostica → 'Esporta diagnostica' card (the JWT is shown there)." >&2
  echo "  OR if you have admin access, paste the JWT for any account that uploaded the log:" >&2
  echo "    export QAUDION_USER_TOKEN='<jwt>'" >&2
  exit 3
fi

CACHE_DIR=".cache/ios-logs"
mkdir -p "$CACHE_DIR"
OUT="$CACHE_DIR/$FILE_ID.log"

echo "[fetch-ios-log] GET $SERVER/api/v1/files/$FILE_ID"
HTTP_CODE=$(curl -sS -w "%{http_code}" -o "$OUT" \
  -H "Authorization: Bearer $QAUDION_USER_TOKEN" \
  "$SERVER/api/v1/files/$FILE_ID")

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "[fetch-ios-log] HTTP $HTTP_CODE — failed."
  cat "$OUT" | head -5
  rm -f "$OUT"
  exit 4
fi

SIZE=$(wc -c < "$OUT")
LINES=$(wc -l < "$OUT")
echo "[fetch-ios-log] saved $OUT ($SIZE bytes, $LINES lines)"
echo ""

# Process flags
MODE="default"
ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --grep) MODE="grep"; ARG="$2"; shift 2 ;;
    --tail) MODE="tail"; ARG="$2"; shift 2 ;;
    *) echo "[fetch-ios-log] unknown arg $1" >&2; shift ;;
  esac
done

case "$MODE" in
  grep)
    echo "=== matches for /$ARG/ ==="
    grep -n "$ARG" "$OUT" || echo "(no matches)"
    ;;
  tail)
    echo "=== last $ARG lines ==="
    tail -n "$ARG" "$OUT"
    ;;
  default)
    echo "=== HEADER (first 14 lines) ==="
    head -14 "$OUT"
    echo ""
    echo "=== ERROR / WARN summary (first 30) ==="
    grep -E " (ERROR|WARN) " "$OUT" | head -30 || echo "(no error/warn entries)"
    echo ""
    echo "=== TAGS distribution ==="
    awk '{
      # capture the [tag] field. Format: ISO_TS LEVEL [tag] body
      match($0, /\[[a-zA-Z_-]+\]/);
      if (RLENGTH > 0) print substr($0, RSTART, RLENGTH);
    }' "$OUT" | sort | uniq -c | sort -rn | head -20
    echo ""
    echo "Run again with --grep <pat> or --tail <N> for more detail."
    ;;
esac

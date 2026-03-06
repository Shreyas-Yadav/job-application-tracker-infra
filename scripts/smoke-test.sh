#!/bin/bash
set -e
BACKEND=${1:-"http://localhost:5000"}
FRONTEND=${2:-"http://localhost:3000"}

# Wait for backend to be ready (up to 2 min)
for i in $(seq 1 12); do
  curl -sf "$BACKEND/health" > /dev/null 2>&1 && break
  echo "Waiting for backend ($i/12)..." && sleep 10
done

curl -sf "$BACKEND/health" | grep -q '"status":"ok"' || { echo "FAIL: /health"; exit 1; }
echo "PASS: /health"

STATUS=$(curl -so /dev/null -w "%{http_code}" "$BACKEND/api/applications")
[ "$STATUS" = "200" ] || { echo "FAIL: /api/applications → $STATUS"; exit 1; }
echo "PASS: /api/applications"

STATUS=$(curl -so /dev/null -w "%{http_code}" "$FRONTEND")
[ "$STATUS" = "200" ] || { echo "FAIL: frontend → $STATUS"; exit 1; }
echo "PASS: frontend"

echo "=== All smoke tests passed ==="

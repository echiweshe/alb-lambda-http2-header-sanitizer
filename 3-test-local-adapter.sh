#!/bin/bash
set -e

PROJECT_ROOT=$(pwd)
ADAPTER_DIR="$PROJECT_ROOT/aws-lambda-web-adapter"
CMD_DIR="$ADAPTER_DIR/cmd/aws-lambda-web-adapter"
BIN="$ADAPTER_DIR/bin/aws-lambda-web-adapter"

echo "🔍 Checking for Go binary..."
if [ ! -f "$BIN" ]; then
  echo "🔨 Building adapter..."
  (cd "$ADAPTER_DIR" && go mod init aws-lambda-web-adapter 2>/dev/null || true)
  (cd "$ADAPTER_DIR" && go build -o "$BIN" ./cmd/aws-lambda-web-adapter)
else
  echo "✅ Adapter binary already exists."
fi

echo "🚀 Starting adapter in background on :8080..."
"$BIN" &
PID=$!
sleep 1  # Give the server a moment to start

echo "📡 Sending curl request..."
curl -v http://localhost:8080/ 2>&1 | tee response.log

echo ""
echo "🧪 Verifying headers..."
if grep -qi "Connection: keep-alive" response.log && grep -qi "Keep-Alive:" response.log; then
  echo "✅ Headers found: Adapter is returning raw Connection and Keep-Alive."
else
  echo "❌ Expected headers not found. Check main.go or server response."
fi

echo "🛑 Stopping adapter server..."
kill "$PID"
rm -f response.log

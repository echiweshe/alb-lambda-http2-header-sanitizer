#!/bin/bash
set -e

PROJECT_ROOT=$(pwd)
ADAPTER_DIR="$PROJECT_ROOT/aws-lambda-web-adapter"
BIN_DIR="$ADAPTER_DIR/bin"
LAYER_DIR="$ADAPTER_DIR/custom-lambda-layer"
EXT_DIR="$LAYER_DIR/extensions/aws-lambda-web-adapter"
ZIP_FILE="$ADAPTER_DIR/custom-lambda-adapter-layer.zip"
BINARY_NAME="aws-lambda-web-adapter"
BINARY_PATH="$BIN_DIR/$BINARY_NAME"

mkdir -p "$EXT_DIR"

# Build if missing
if [ ! -f "$BINARY_PATH" ]; then
    echo "🔨 Building adapter binary..."
    (cd "$ADAPTER_DIR" && go build -o "$BINARY_PATH" ./cmd/aws-lambda-web-adapter)
else
    echo "✅ Binary already exists. Skipping build..."
fi

# Copy binary
echo "📁 Copying binary to Lambda Layer structure..."
cp "$BINARY_PATH" "$EXT_DIR/aws-lambda-web-adapter"

# Zip layer
echo "📦 Creating Lambda Layer ZIP..."
rm -f "$ZIP_FILE"
(cd "$LAYER_DIR" && zip -r "$ZIP_FILE" .)

echo ""
echo "✅ Lambda Layer ZIP created:"
echo "  $ZIP_FILE"

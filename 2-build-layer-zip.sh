#!/bin/bash

# Script for building the Lambda Web Adapter Layer with header sanitization
# Purpose: Builds and packages the Lambda Web Adapter with HTTP/2 header sanitization

set -o pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to safely create directories
create_directory() {
    local dir="$1"
    if [ -d "$dir" ]; then
        echo -e "${YELLOW}⚠️ Directory already exists: $dir${NC}"
    else
        mkdir -p "$dir" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ Created directory: $dir${NC}"
        else
            echo -e "${RED}❌ Failed to create directory: $dir${NC}"
            return 1
        fi
    fi
    return 0
}

# Function to check environment
check_environment() {
    # Check if Go is installed
    if ! command -v go &> /dev/null; then
        echo -e "${RED}❌ Error: Go is not installed or not in PATH${NC}"
        echo -e "${YELLOW}⚠️ Please install Go before continuing${NC}"
        return 1
    fi
    
    GO_VERSION=$(go version)
    echo -e "${GREEN}✅ Using $GO_VERSION${NC}"
    
    # Check if adapter directory exists
    if [ ! -d "$ADAPTER_DIR" ]; then
        echo -e "${RED}❌ Adapter directory not found: $ADAPTER_DIR${NC}"
        echo -e "${YELLOW}⚠️ Run ./1-local-adapter-setup.sh first${NC}"
        return 1
    fi
    
    return 0
}

# Function to clean up existing files
clean_existing_files() {
    echo -e "${BLUE}🧹 Cleaning up existing files...${NC}"
    
    # Check and remove existing zip file
    if [ -f "$ZIP_FILE" ]; then
        echo -e "${YELLOW}⚠️ Existing ZIP file found: $ZIP_FILE${NC}"
        read -p "Remove this file? (y/n): " remove_zip
        if [ "$remove_zip" = "y" ]; then
            rm -f "$ZIP_FILE" 2>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ Removed existing ZIP file${NC}"
            else
                echo -e "${RED}❌ Failed to remove ZIP file${NC}"
                ZIP_FILE="$ADAPTER_DIR/custom-lambda-adapter-layer-$(date +%s).zip"
                echo -e "${YELLOW}⚠️ Using alternative ZIP file name: $ZIP_FILE${NC}"
            fi
        else
            ZIP_FILE="$ADAPTER_DIR/custom-lambda-adapter-layer-$(date +%s).zip"
            echo -e "${YELLOW}⚠️ Using alternative ZIP file name: $ZIP_FILE${NC}"
        fi
    fi
    
    # Check and clean layer directory
    if [ -d "$LAYER_DIR" ]; then
        echo -e "${YELLOW}⚠️ Existing layer directory found: $LAYER_DIR${NC}"
        read -p "Remove this directory? (y/n): " remove_dir
        if [ "$remove_dir" = "y" ]; then
            rm -rf "$LAYER_DIR" 2>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ Removed existing layer directory${NC}"
            else
                echo -e "${RED}❌ Failed to remove layer directory${NC}"
                LAYER_DIR="$ADAPTER_DIR/custom-lambda-layer-$(date +%s)"
                EXT_DIR="$LAYER_DIR/extensions"
                echo -e "${YELLOW}⚠️ Using alternative layer directory: $LAYER_DIR${NC}"
            fi
        else
            LAYER_DIR="$ADAPTER_DIR/custom-lambda-layer-$(date +%s)"
            EXT_DIR="$LAYER_DIR/extensions"
            echo -e "${YELLOW}⚠️ Using alternative layer directory: $LAYER_DIR${NC}"
        fi
    fi
}

# Main script starts here
echo -e "${CYAN}🔨 Building Lambda Web Adapter Layer with HTTP/2 header sanitization...${NC}"

# Store original directory
ORIGINAL_DIR=$(pwd)

# Setup paths
PROJECT_ROOT=$ORIGINAL_DIR
ADAPTER_DIR="$PROJECT_ROOT/aws-lambda-web-adapter"
BIN_DIR="$ADAPTER_DIR/bin"
LAYER_DIR="$ADAPTER_DIR/custom-lambda-layer"
EXT_DIR="$LAYER_DIR/extensions"
ZIP_FILE="$ADAPTER_DIR/custom-lambda-adapter-layer.zip"
BINARY_NAME="aws-lambda-web-adapter"
BINARY_PATH="$BIN_DIR/$BINARY_NAME"

# Check environment before proceeding
check_environment || exit 1

# Clean up existing files
clean_existing_files

# Ensure directories exist
echo -e "${BLUE}📁 Creating fresh directories...${NC}"
create_directory "$EXT_DIR" || exit 1
create_directory "$BIN_DIR" || exit 1

# Building with Go for Linux
echo -e "${BLUE}🔧 Building adapter with Go for Linux...${NC}"
cd "$ADAPTER_DIR" || {
    echo -e "${RED}❌ Failed to change to adapter directory${NC}"
    exit 1
}

# Verify Go source files exist
MAIN_FILE="$ADAPTER_DIR/cmd/aws-lambda-web-adapter/main.go"
if [ ! -f "$MAIN_FILE" ]; then
    echo -e "${RED}❌ main.go not found!${NC}"
    echo -e "${YELLOW}⚠️ Run ./1-local-adapter-setup.sh first${NC}"
    exit 1
fi

# Set Go environment for Linux compilation
echo -e "${BLUE}🔧 Setting Go environment for Linux compilation...${NC}"
export GOOS=linux
export GOARCH=amd64
export CGO_ENABLED=0  # Disable CGO for static binary

# Initialize Go module if needed
if [ ! -f "$ADAPTER_DIR/go.mod" ]; then
    echo -e "${YELLOW}⚠️ Initializing Go module...${NC}"
    go mod init aws-lambda-web-adapter 2>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to initialize Go module${NC}"
        # Continue anyway as it might still work
    fi
fi

# Build the adapter
echo -e "${BLUE}🔧 Building static binary for Lambda...${NC}"
go build -ldflags="-s -w" -o "$BINARY_PATH" ./cmd/aws-lambda-web-adapter

if [ $? -ne 0 ] || [ ! -f "$BINARY_PATH" ]; then
    echo -e "${RED}❌ Go build failed!${NC}"
    echo -e "${YELLOW}⚠️ Check Go code for errors${NC}"
    exit 1
fi

# Get binary size and info
BINARY_SIZE=$(ls -lh "$BINARY_PATH" 2>/dev/null | awk '{print $5}')
echo -e "${GREEN}✅ Binary built successfully: $BINARY_SIZE${NC}"

# Copy binary into the layer structure
echo -e "${BLUE}📦 Copying binary into Lambda Layer layout...${NC}"
cp "$BINARY_PATH" "$EXT_DIR/aws-lambda-web-adapter" || {
    echo -e "${RED}❌ Failed to copy binary to layer${NC}"
    exit 1
}
chmod +x "$EXT_DIR/aws-lambda-web-adapter" || {
    echo -e "${YELLOW}⚠️ Failed to set execute permissions on binary${NC}"
}

# Create a bootstrap file
echo -e "${BLUE}📄 Creating bootstrap file...${NC}"
BOOTSTRAP_PATH="$EXT_DIR/bootstrap"
cat << 'EOF' > "$BOOTSTRAP_PATH"
#!/bin/bash
# Script to ensure permissions and launch adapter
set -e

# Log startup
echo "AWS Lambda Web Adapter with HTTP/2 header sanitization starting..."

# Make adapter executable
chmod +x /opt/extensions/aws-lambda-web-adapter

# Run adapter
exec /opt/extensions/aws-lambda-web-adapter
EOF

chmod +x "$BOOTSTRAP_PATH" || {
    echo -e "${YELLOW}⚠️ Failed to set execute permissions on bootstrap${NC}"
}

# Create ZIP
echo -e "${BLUE}📦 Creating Lambda Layer ZIP...${NC}"

# Check if zip command is available
ZIP_COMMAND=""
if command -v zip &> /dev/null; then
    ZIP_COMMAND="zip"
elif command -v python3 &> /dev/null; then
    # Use Python as fallback
    ZIP_COMMAND="python"
else
    echo -e "${RED}❌ Neither zip nor python3 is available${NC}"
    echo -e "${YELLOW}⚠️ Please install zip or python3${NC}"
    exit 1
fi

# Create the ZIP file
cd "$LAYER_DIR" || {
    echo -e "${RED}❌ Failed to change to layer directory${NC}"
    exit 1
}

if [ "$ZIP_COMMAND" = "zip" ]; then
    echo -e "${BLUE}Using zip command...${NC}"
    zip -r "$ZIP_FILE" . >/dev/null 2>&1
    ZIP_STATUS=$?
else
    echo -e "${BLUE}Using Python for zip creation...${NC}"
    python3 -c "
import zipfile, os
with zipfile.ZipFile('$ZIP_FILE', 'w', zipfile.ZIP_DEFLATED) as zipf:
    for root, dirs, files in os.walk('.'):
        for file in files:
            file_path = os.path.join(root, file)
            zipf.write(file_path)
" 2>/dev/null
    ZIP_STATUS=$?
fi

if [ $ZIP_STATUS -ne 0 ]; then
    echo -e "${RED}❌ Failed to create ZIP file${NC}"
    exit 1
fi

# Return to original directory
cd "$ORIGINAL_DIR"

# Verify the ZIP file
if [ -f "$ZIP_FILE" ]; then
    ZIP_SIZE=$(ls -lh "$ZIP_FILE" | awk '{print $5}')
    echo ""
    echo -e "${GREEN}✅ Lambda Layer ZIP created successfully:${NC}"
    echo -e "  ${CYAN}Path: $ZIP_FILE${NC}"
    echo -e "  ${CYAN}Size: $ZIP_SIZE${NC}"
    
    echo ""
    echo -e "${YELLOW}DEPLOYMENT INSTRUCTIONS:${NC}"
    echo -e "1. Upload this ZIP as a Lambda Layer"
    echo -e "2. Add the layer to your Lambda function"
    echo -e "3. Set this environment variable in your Lambda:"
    echo -e "   ${CYAN}AWS_LAMBDA_EXEC_WRAPPER: /opt/extensions/bootstrap${NC}"
    echo ""
    echo -e "${GREEN}✅ The adapter will now sanitize HTTP/2 headers automatically.${NC}"
else
    echo -e "${RED}❌ ZIP file creation failed${NC}"
    exit 1
fi

# Restore normal Go environment
export GOOS=""
export GOARCH=""
export CGO_ENABLED=""

echo -e "${CYAN}🎉 Done!${NC}"
#!/bin/bash

# Enhanced script for setting up the Lambda Web Adapter with HTTP/2 header sanitization
# Purpose: Prepares the local development environment with necessary files and code
# Includes robust error handling for corner cases

# Exit on error, but with custom handling
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

# Function to safely create a file
create_file() {
    local file="$1"
    local content="$2"
    local force="$3"
    
    if [ -f "$file" ] && [ "$force" != "force" ]; then
        echo -e "${YELLOW}⚠️ File already exists: $file${NC}"
        read -p "Overwrite? (y/n): " overwrite
        if [ "$overwrite" != "y" ]; then
            echo -e "${YELLOW}⚠️ Skipping file creation: $file${NC}"
            return 0
        fi
    fi
    
    echo "$content" > "$file" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Created/Updated file: $file${NC}"
    else
        echo -e "${RED}❌ Failed to create file: $file${NC}"
        return 1
    fi
    return 0
}

# Function to check for running processes
check_processes() {
    local process_name="$1"
    local running=$(pgrep -f "$process_name" 2>/dev/null || echo "")
    if [ -n "$running" ]; then
        echo -e "${YELLOW}⚠️ Found running process: $process_name (PID: $running)${NC}"
        read -p "Terminate process? (y/n): " terminate
        if [ "$terminate" = "y" ]; then
            kill $running 2>/dev/null
            sleep 1
            if pgrep -f "$process_name" >/dev/null; then
                echo -e "${YELLOW}⚠️ Process still running, trying force kill...${NC}"
                kill -9 $running 2>/dev/null
                sleep 1
            fi
            echo -e "${GREEN}✅ Process terminated${NC}"
        else
            echo -e "${YELLOW}⚠️ Process left running${NC}"
        fi
    fi
}

# Function to clean up existing directories if requested
clean_setup() {
    echo -e "${YELLOW}⚠️ Existing setup detected. Would you like to clean up before proceeding?${NC}"
    read -p "This will delete existing files and directories. Continue? (y/n): " cleanup
    if [ "$cleanup" = "y" ]; then
        echo -e "${BLUE}🧹 Cleaning up previous setup...${NC}"
        
        # Check for running processes
        check_processes "aws-lambda-web-adapter"
        check_processes "flask"
        
        # Remove directories
        rm -rf "$ADAPTER_DIR" 2>/dev/null
        rm -f "$PROJECT_ROOT/lambda.py" 2>/dev/null
        rm -f "$PROJECT_ROOT/ec2.py" 2>/dev/null
        
        echo -e "${GREEN}✅ Cleanup completed${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠️ Continuing without cleanup. Some operations may fail if files already exist.${NC}"
        return 1
    fi
}

# Main script starts here
echo -e "${CYAN}🚀 Setting up Lambda Web Adapter with HTTP/2 header sanitization...${NC}"

# Setup paths
PROJECT_ROOT=$(pwd)
ADAPTER_DIR="$PROJECT_ROOT/aws-lambda-web-adapter"
SRC_DIR="$ADAPTER_DIR/src"
CMD_DIR="$ADAPTER_DIR/cmd/aws-lambda-web-adapter"
LAYER_DIR="$ADAPTER_DIR/custom-lambda-layer"
EXT_DIR="$LAYER_DIR/extensions/aws-lambda-web-adapter"
BIN_DIR="$ADAPTER_DIR/bin"

# Check if setup already exists and offer cleanup
if [ -d "$ADAPTER_DIR" ]; then
    clean_setup
fi

# Ensure directories exist
echo -e "${BLUE}📁 Creating directory structure...${NC}"
create_directory "$ADAPTER_DIR" || exit 1
create_directory "$SRC_DIR" || exit 1
create_directory "$CMD_DIR" || exit 1
create_directory "$LAYER_DIR" || exit 1
create_directory "$(dirname "$EXT_DIR")" || exit 1
create_directory "$BIN_DIR" || exit 1
echo -e "${GREEN}✅ Directory structure created successfully${NC}"

# Create lib.rs with header sanitization function
echo -e "${BLUE}🧼 Creating sanitization code in lib.rs...${NC}"
LIB_RS_CONTENT=$(cat << 'EOF'
use http::{HeaderMap, Response};
use hyper::Body;

fn sanitize_headers<T>(response: &mut Response<T>) {
    let disallowed = [
        "connection",
        "keep-alive",
        "proxy-connection",
        "transfer-encoding",
        "upgrade",
    ];
    let headers = response.headers_mut();
    for name in disallowed.iter() {
        headers.remove(*name);
    }
}
EOF
)
create_file "$SRC_DIR/lib.rs" "$LIB_RS_CONTENT" || exit 1

# Inject sanitize_headers call into adapter.rs if it exists
ADAPTER_RS_PATH="$SRC_DIR/adapter.rs"
if [ -f "$ADAPTER_RS_PATH" ]; then
    echo -e "${BLUE}💉 Injecting sanitize_headers call into adapter.rs...${NC}"
    
    # Make a backup of the original file
    cp "$ADAPTER_RS_PATH" "$ADAPTER_RS_PATH.bak" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}⚠️ Failed to create backup of adapter.rs${NC}"
    else
        echo -e "${GREEN}✅ Created backup: $ADAPTER_RS_PATH.bak${NC}"
    fi
    
    # Find the line with the response creation
    RESPONSE_LINE=$(grep -n "let mut response =" "$ADAPTER_RS_PATH" 2>/dev/null | head -1 | cut -d: -f1)
    
    if [ -n "$RESPONSE_LINE" ]; then
        # Insert our sanitization call after that line
        LINE_AFTER=$((RESPONSE_LINE + 1))
        sed -i "${LINE_AFTER}i\\    crate::sanitize_headers(\&mut response);" "$ADAPTER_RS_PATH" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ Sanitization call injected into adapter.rs${NC}"
        else
            echo -e "${RED}❌ Failed to inject code into adapter.rs${NC}"
            echo -e "${YELLOW}⚠️ You may need to manually add: crate::sanitize_headers(&mut response);${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️ Could not locate response line in adapter.rs. Manual injection may be required.${NC}"
        echo -e "${YELLOW}⚠️ Add this line after response creation: crate::sanitize_headers(&mut response);${NC}"
    fi
else
    # Try with hyper.rs instead, which is an alternative location
    HYPER_RS_PATH="$SRC_DIR/adapter/hyper.rs"
    if [ -f "$HYPER_RS_PATH" ]; then
        echo -e "${BLUE}💉 Injecting sanitize_headers call into hyper.rs...${NC}"
        
        # Create adapter directory if it doesn't exist
        create_directory "$SRC_DIR/adapter"
        
        # Make a backup of the original file
        cp "$HYPER_RS_PATH" "$HYPER_RS_PATH.bak" 2>/dev/null
        if [ $? -ne 0 ]; then
            echo -e "${YELLOW}⚠️ Failed to create backup of hyper.rs${NC}"
        else
            echo -e "${GREEN}✅ Created backup: $HYPER_RS_PATH.bak${NC}"
        fi
        
        # Find the line with the response creation
        RESPONSE_LINE=$(grep -n "let mut response =" "$HYPER_RS_PATH" 2>/dev/null | head -1 | cut -d: -f1)
        
        if [ -n "$RESPONSE_LINE" ]; then
            # Insert our sanitization call after that line
            LINE_AFTER=$((RESPONSE_LINE + 1))
            sed -i "${LINE_AFTER}i\\    crate::sanitize_headers(\&mut response);" "$HYPER_RS_PATH" 2>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ Sanitization call injected into hyper.rs${NC}"
            else
                echo -e "${RED}❌ Failed to inject code into hyper.rs${NC}"
                echo -e "${YELLOW}⚠️ You may need to manually add: crate::sanitize_headers(&mut response);${NC}"
            fi
        else
            echo -e "${YELLOW}⚠️ Could not locate response line in hyper.rs. Manual injection may be required.${NC}"
            echo -e "${YELLOW}⚠️ Add this line after response creation: crate::sanitize_headers(&mut response);${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️ Neither adapter.rs nor hyper.rs found. Creating new adapter files...${NC}"
        
        # Create adapter directory if it doesn't exist
        create_directory "$SRC_DIR/adapter"
        
        echo -e "${YELLOW}⚠️ You'll need to manually complete the adapter implementation${NC}"
        echo -e "${YELLOW}⚠️ Make sure to add: crate::sanitize_headers(&mut response); after response creation${NC}"
    fi
fi

# Create main.go for local testing
echo -e "${BLUE}🖥️ Creating main.go for local testing...${NC}"
MAIN_GO_CONTENT=$(cat << 'EOF'
package main

import (
    "fmt"
    "log"
    "net/http"
)

func main() {
    log.Println("Starting Lambda Web Adapter mock server on :8080")

    http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "text/plain")
        w.Header().Set("Connection", "keep-alive")
        w.Header().Set("Keep-Alive", "timeout=72")
        w.WriteHeader(200)
        fmt.Fprintln(w, "Adapter mock response with keep-alive headers")
    })

    log.Fatal(http.ListenAndServe(":8080", nil))
}
EOF
)
create_file "$CMD_DIR/main.go" "$MAIN_GO_CONTENT" || exit 1

# Create lambda.py test file
echo -e "${BLUE}🐍 Creating lambda.py for testing...${NC}"
LAMBDA_PY_CONTENT=$(cat << 'EOF'
def handler(event, context):
    query_params = event.get("queryStringParameters", {})
    if query_params is None:
        query_params = {}
    connection = query_params.get("connection", "true")
    keepAlive = query_params.get("keep-alive", "true")
    
    headers = {}
    if connection == "true": 
        headers.update({"Connection": "keep-alive"})
    if keepAlive == "true": 
        headers.update({"Keep-Alive": "timeout=72"})
    
    return {
        "statusCode": 200,
        "headers": headers,
        "body": "Successful request to Lambda without web adapter (python)"
    }
EOF
)
create_file "$PROJECT_ROOT/lambda.py" "$LAMBDA_PY_CONTENT" || exit 1

# Create ec2.py for simulating non-Lambda targets
echo -e "${BLUE}🐍 Creating ec2.py for simulation...${NC}"
EC2_PY_CONTENT=$(cat << 'EOF'
from flask import Flask, Response

app = Flask(__name__)

@app.route("/")
def root():
    return Response("Successful request to EC2 (python)",
                    headers={"Connection": "keep-alive", "Keep-Alive": "timeout=72"},
                    mimetype="text/plain")

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=5000)
EOF
)
create_file "$PROJECT_ROOT/ec2.py" "$EC2_PY_CONTENT" || exit 1

# Check dependencies
echo -e "${BLUE}🔍 Checking required dependencies...${NC}"

# Check for Go
if command -v go >/dev/null 2>&1; then
    GO_VERSION=$(go version)
    echo -e "${GREEN}✅ Go is installed: $GO_VERSION${NC}"
else
    echo -e "${YELLOW}⚠️ Go is not installed. You will need it to build the adapter.${NC}"
    echo -e "${YELLOW}⚠️ Install Go from https://golang.org/dl/${NC}"
fi

# Check for Python and Flask
if command -v python3 >/dev/null 2>&1; then
    PYTHON_VERSION=$(python3 --version)
    echo -e "${GREEN}✅ Python is installed: $PYTHON_VERSION${NC}"
    
    # Check for Flask
    if python3 -c "import flask" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Flask is installed${NC}"
    else
        echo -e "${YELLOW}⚠️ Flask is not installed. You will need it for EC2 simulation.${NC}"
        echo -e "${YELLOW}⚠️ Install with: pip3 install flask${NC}"
    fi
else
    echo -e "${YELLOW}⚠️ Python 3 is not installed. You will need it for Lambda testing.${NC}"
    echo -e "${YELLOW}⚠️ Install Python 3 from https://www.python.org/downloads/${NC}"
fi

echo ""
echo -e "${GREEN}✅ Local Lambda Web Adapter setup completed successfully.${NC}"
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo -e "${YELLOW}1. Build the adapter with: 'cd $ADAPTER_DIR && go build -o bin/aws-lambda-web-adapter ./cmd/aws-lambda-web-adapter'${NC}"
echo -e "${YELLOW}2. Test the adapter with: './3-test-local-adapter.sh'${NC}"
echo -e "${YELLOW}3. Build the Lambda Layer with: './2-build-layer-zip.sh'${NC}"
echo ""
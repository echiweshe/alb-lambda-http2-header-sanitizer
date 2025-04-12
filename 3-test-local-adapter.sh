#!/bin/bash

# Enhanced script to test local Lambda Web Adapter build and header output
# Tests if the adapter is correctly sanitizing HTTP headers
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

# Function to check for running processes
check_and_kill_process() {
    local process_name="$1"
    local force="$2"
    
    local running=$(pgrep -f "$process_name" 2>/dev/null || echo "")
    if [ -n "$running" ]; then
        echo -e "${YELLOW}⚠️ Found running process: $process_name (PID: $running)${NC}"
        
        if [ "$force" = "force" ]; then
            kill_process=true
        else
            read -p "Terminate process? (y/n): " kill_response
            kill_process=$([[ "$kill_response" == "y" ]] && echo true || echo false)
        fi
        
        if [ "$kill_process" = true ]; then
            echo -e "${BLUE}🔄 Terminating process...${NC}"
            kill $running 2>/dev/null
            sleep 1
            
            # Check if still running and force kill if necessary
            if pgrep -f "$process_name" >/dev/null 2>&1; then
                echo -e "${YELLOW}⚠️ Process still running, trying force kill...${NC}"
                kill -9 $running 2>/dev/null
                sleep 1
                
                if pgrep -f "$process_name" >/dev/null 2>&1; then
                    echo -e "${RED}❌ Failed to terminate process${NC}"
                    return 1
                fi
            fi
            
            echo -e "${GREEN}✅ Process terminated${NC}"
        else
            echo -e "${YELLOW}⚠️ Process left running - this may cause conflicts${NC}"
        fi
    fi
    return 0
}

# Function to check if the binary exists
check_binary_exists() {
    if [ ! -f "$BINARY_PATH" ]; then
        echo -e "${RED}❌ Adapter binary not found: $BINARY_PATH${NC}"
        
        if command -v go &> /dev/null; then
            echo -e "${YELLOW}⚠️ Would you like to build the adapter now?${NC}"
            read -p "Build adapter? (y/n): " build_now
            
            if [ "$build_now" = "y" ]; then
                echo -e "${BLUE}🔨 Building adapter...${NC}"
                cd "$ADAPTER_DIR" || {
                    echo -e "${RED}❌ Failed to change to adapter directory${NC}"
                    return 1
                }
                
                if [ ! -f "go.mod" ]; then
                    go mod init aws-lambda-web-adapter 2>/dev/null
                    if [ $? -ne 0 ]; then
                        echo -e "${RED}❌ Failed to initialize Go module${NC}"
                        return 1
                    fi
                fi
                
                go build -o "$BINARY_PATH" ./cmd/aws-lambda-web-adapter 2>/dev/null
                if [ $? -ne 0 ] || [ ! -f "$BINARY_PATH" ]; then
                    echo -e "${RED}❌ Build failed!${NC}"
                    return 1
                fi
                
                echo -e "${GREEN}✅ Adapter built successfully${NC}"
                cd "$PROJECT_ROOT" || return 1
                return 0
            else
                echo -e "${YELLOW}⚠️ Please build the adapter first:${NC}"
                echo -e "${YELLOW}cd $ADAPTER_DIR && go build -o $BINARY_PATH ./cmd/aws-lambda-web-adapter${NC}"
                return 1
            fi
        else
            echo -e "${RED}❌ Go is not installed!${NC}"
            echo -e "${YELLOW}⚠️ Please install Go and then build the adapter:${NC}"
            echo -e "${YELLOW}cd $ADAPTER_DIR && go build -o $BINARY_PATH ./cmd/aws-lambda-web-adapter${NC}"
            return 1
        fi
    fi
    return 0
}

# Function to check port availability
check_port_available() {
    local port="$1"
    
    if command -v netstat &> /dev/null; then
        if netstat -tuln | grep -q ":$port "; then
            echo -e "${YELLOW}⚠️ Port $port is already in use!${NC}"
            return 1
        fi
    elif command -v ss &> /dev/null; then
        if ss -tuln | grep -q ":$port "; then
            echo -e "${YELLOW}⚠️ Port $port is already in use!${NC}"
            return 1
        fi
    elif command -v lsof &> /dev/null; then
        if lsof -i ":$port" &>/dev/null; then
            echo -e "${YELLOW}⚠️ Port $port is already in use!${NC}"
            return 1
        fi
    else
        # If no tool is available, try a basic check
        (echo > /dev/tcp/localhost/$port) &>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${YELLOW}⚠️ Port $port appears to be in use!${NC}"
            return 1
        fi
    fi
    
    echo -e "${GREEN}✅ Port $port is available${NC}"
    return 0
}

# Function to check if curl is installed
check_curl_installed() {
    if ! command -v curl &> /dev/null; then
        echo -e "${RED}❌ curl is not installed!${NC}"
        echo -e "${YELLOW}⚠️ Please install curl to run this test${NC}"
        return 1
    fi
    return 0
}

# Safely create temporary files
create_temp_file() {
    local prefix="$1"
    local temp_dir
    
    # Check if we can use the standard temp directory
    if [ -d "/tmp" ] && [ -w "/tmp" ]; then
        temp_dir="/tmp"
    else
        temp_dir="$PROJECT_ROOT"
    fi
    
    # Create a unique filename
    local temp_file="$temp_dir/${prefix}-$(date +%s)-$RANDOM.txt"
    touch "$temp_file" 2>/dev/null
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to create temporary file!${NC}"
        return 1
    fi
    
    echo "$temp_file"
    return 0
}

# Main script starts here
echo -e "${CYAN}🧪 Starting local Lambda Web Adapter test...${NC}"

# Setup paths
PROJECT_ROOT=$(pwd)
ADAPTER_DIR="$PROJECT_ROOT/aws-lambda-web-adapter"
CMD_DIR="$ADAPTER_DIR/cmd/aws-lambda-web-adapter"
BINARY_PATH="$ADAPTER_DIR/bin/aws-lambda-web-adapter"
OUTPUT_FILE=$(create_temp_file "adapter-response")

if [ $? -ne 0 ]; then
    # If temp file creation failed, use a fallback
    OUTPUT_FILE="$PROJECT_ROOT/adapter-response.log"
fi

# Check environment
if [ ! -d "$ADAPTER_DIR" ]; then
    echo -e "${RED}❌ Adapter directory not found: $ADAPTER_DIR${NC}"
    echo -e "${YELLOW}⚠️ Run ./1-local-adapter-setup.sh first to set up the environment${NC}"
    exit 1
fi

# Step 0: Terminate any existing adapter process
echo -e "${BLUE}🔍 Checking for existing adapter processes...${NC}"
check_and_kill_process "aws-lambda-web-adapter" "ask" || exit 1

# Step 1: Check if the binary exists and offer to build it if missing
echo -e "${BLUE}🔍 Checking for adapter binary...${NC}"
check_binary_exists || exit 1

# Step 2: Check if port 8080 is available
echo -e "${BLUE}🔍 Checking if port 8080 is available...${NC}"
check_port_available 8080 || {
    echo -e "${YELLOW}⚠️ Would you like to try a different port?${NC}"
    read -p "Enter an alternative port (or 'n' to cancel): " alt_port
    
    if [ "$alt_port" = "n" ]; then
        echo -e "${RED}❌ Test aborted${NC}"
        exit 1
    fi
    
    # Validate port number
    if ! [[ "$alt_port" =~ ^[0-9]+$ ]] || [ "$alt_port" -lt 1024 ] || [ "$alt_port" -gt 65535 ]; then
        echo -e "${RED}❌ Invalid port number: $alt_port${NC}"
        exit 1
    fi
    
    # Check if alternative port is available
    check_port_available "$alt_port" || {
        echo -e "${RED}❌ Alternative port $alt_port is also in use!${NC}"
        exit 1
    }
    
    echo -e "${YELLOW}⚠️ Using alternative port: $alt_port${NC}"
    PORT="$alt_port"
}

# Default port if not changed
PORT=${PORT:-8080}

# Step 3: Check if curl is available
echo -e "${BLUE}🔍 Checking for curl...${NC}"
check_curl_installed || exit 1

# Step 4: Start the adapter server in background
echo -e "${BLUE}🚀 Starting adapter server on port $PORT...${NC}"
"$BINARY_PATH" &
ADAPTER_PID=$!

# Wait for server to start
echo -e "${YELLOW}⏳ Waiting for server to start...${NC}"
sleep 2

# Check if the server started successfully
if ! ps -p $ADAPTER_PID > /dev/null; then
    echo -e "${RED}❌ Failed to start adapter server!${NC}"
    echo -e "${YELLOW}⚠️ Check the adapter binary and try again${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Adapter started with PID $ADAPTER_PID${NC}"

# Step 5: Send request using curl
echo -e "${BLUE}🌐 Sending request to http://localhost:$PORT...${NC}"
curl -v http://localhost:$PORT/ > "$OUTPUT_FILE" 2>&1

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Error sending request to adapter!${NC}"
    echo -e "${YELLOW}⚠️ Make sure the adapter is running and responding on port $PORT${NC}"
    # Kill adapter process
    kill $ADAPTER_PID 2>/dev/null || true
    exit 1
fi

echo -e "${GREEN}✅ Request sent. Response saved to $OUTPUT_FILE${NC}"

# Step 6: Display and check headers
echo -e "${BLUE}🔍 Checking response headers...${NC}"

# Check if output file exists and has content
if [ ! -s "$OUTPUT_FILE" ]; then
    echo -e "${RED}❌ Output file is empty!${NC}"
    echo -e "${YELLOW}⚠️ The adapter may not be responding correctly${NC}"
    # Kill adapter process
    kill $ADAPTER_PID 2>/dev/null || true
    exit 1
fi

# Display response
echo -e "${CYAN}Response Body:${NC}"
BODY=$(grep -v "< " "$OUTPUT_FILE" | tail -n 1)
echo -e "$BODY"

echo -e "${CYAN}Response Headers:${NC}"
grep "< " "$OUTPUT_FILE" | sed 's/< //' || {
    echo -e "${YELLOW}⚠️ No response headers found in output${NC}"
}

# Check for disallowed headers
CONNECTION_FOUND=$(grep -i "< connection:" "$OUTPUT_FILE" || echo "")
KEEP_ALIVE_FOUND=$(grep -i "< keep-alive:" "$OUTPUT_FILE" || echo "")

echo -e "${YELLOW}🔎 Verifying if disallowed headers are present in the response...${NC}"
if [ -n "$CONNECTION_FOUND" ] && [ -n "$KEEP_ALIVE_FOUND" ]; then
    echo -e "${GREEN}✅ SUCCESS: 'Connection' and 'Keep-Alive' headers were detected in the HTTP response.${NC}"
    echo -e "${GREEN}This indicates that the mock adapter (or upstream app) is returning raw headers as expected.${NC}"
    echo -e "${YELLOW}⚠️ In production, these headers would violate the HTTP/2 spec unless sanitized.${NC}"
    
    # Show what sanitized headers would look like
    echo -e "\n${YELLOW}EXAMPLE: Sanitized Headers (what they should look like after sanitization):${NC}"
    grep "< " "$OUTPUT_FILE" | grep -v -i "connection:" | grep -v -i "keep-alive:" | sed 's/< //' || {
        echo -e "${YELLOW}⚠️ No other headers found in response${NC}"
    }
else
    echo -e "${YELLOW}⚠️ WARNING: One or both disallowed headers are missing:${NC}"
    [ -n "$CONNECTION_FOUND" ] && echo -e "- Connection header found: ${GREEN}Yes${NC}" || echo -e "- Connection header found: ${RED}No${NC}"
    [ -n "$KEEP_ALIVE_FOUND" ] && echo -e "- Keep-Alive header found: ${GREEN}Yes${NC}" || echo -e "- Keep-Alive header found: ${RED}No${NC}"
    echo ""
    echo -e "${YELLOW}If you're testing the unpatched adapter, this might indicate an error.${NC}"
    echo -e "${GREEN}If you're testing the patched version, this is expected behavior (headers are being sanitized).${NC}"
fi

# Step 7: Clean up
echo -e "${BLUE}🧹 Stopping adapter background process...${NC}"
kill $ADAPTER_PID 2>/dev/null || {
    echo -e "${YELLOW}⚠️ Failed to stop adapter process${NC}"
    echo -e "${YELLOW}⚠️ Trying force kill...${NC}"
    kill -9 $ADAPTER_PID 2>/dev/null || true
}
sleep 1

# Verify process was stopped
if ps -p $ADAPTER_PID &>/dev/null; then
    echo -e "${RED}❌ Failed to stop adapter process (PID: $ADAPTER_PID)${NC}"
    echo -e "${YELLOW}⚠️ You may need to stop it manually with: kill -9 $ADAPTER_PID${NC}"
else
    echo -e "${GREEN}✅ Adapter server stopped${NC}"
fi

echo -e "${CYAN}🎯 Test completed!${NC}"
echo ""
echo -e "${GREEN}Summary:${NC} This test confirms whether the adapter is sanitizing HTTP/1.1 headers."
echo -e "- For testing purposes, the original adapter should output the restricted headers."
echo -e "- In production with the patched Layer, these headers will be sanitized."

# Offer to clean up output file
echo ""
echo -e "${YELLOW}Would you like to keep the output file ($OUTPUT_FILE)?${NC}"
read -p "Keep output file? (y/n): " keep_output

if [ "$keep_output" != "y" ]; then
    rm -f "$OUTPUT_FILE" 2>/dev/null
    echo -e "${GREEN}✅ Output file removed${NC}"
else
    echo -e "${GREEN}✅ Output file kept at: $OUTPUT_FILE${NC}"
fi
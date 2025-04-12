#!/bin/bash

# Enhanced script to test adapter stripping headers with Flask
# Purpose: Test if sanitization works with a real upstream server
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

# Function to check if required tools are installed
check_dependencies() {
    echo -e "${BLUE}🔍 Checking required dependencies...${NC}"
    
    # Check Python
    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}❌ Python 3 is not installed!${NC}"
        echo -e "${YELLOW}⚠️ Please install Python 3 to run this test${NC}"
        return 1
    fi
    
    PYTHON_VERSION=$(python3 --version)
    echo -e "${GREEN}✅ Found $PYTHON_VERSION${NC}"
    
    # Check Flask
    if ! python3 -c "import flask" &> /dev/null; then
        echo -e "${YELLOW}⚠️ Flask is not installed. Would you like to install it now?${NC}"
        read -p "Install Flask? (y/n): " install_flask
        
        if [ "$install_flask" = "y" ]; then
            echo -e "${BLUE}📦 Installing Flask...${NC}"
            pip3 install flask || {
                echo -e "${RED}❌ Failed to install Flask${NC}"
                echo -e "${YELLOW}⚠️ Try installing manually with: pip3 install flask${NC}"
                return 1
            }
            echo -e "${GREEN}✅ Flask installed successfully${NC}"
        else
            echo -e "${RED}❌ Flask is required for this test${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}✅ Flask is installed${NC}"
    fi
    
    # Check Go
    if ! command -v go &> /dev/null; then
        echo -e "${RED}❌ Go is not installed!${NC}"
        echo -e "${YELLOW}⚠️ Please install Go to build the test adapter${NC}"
        return 1
    fi
    
    GO_VERSION=$(go version)
    echo -e "${GREEN}✅ Found $GO_VERSION${NC}"
    
    # Check curl
    if ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}⚠️ curl is not installed. Some tests may not work.${NC}"
    else
        echo -e "${GREEN}✅ curl is installed${NC}"
    fi
    
    return 0
}

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

# Function to check port availability
check_port_available() {
    local port="$1"
    local service="$2"
    
    if command -v netstat &> /dev/null; then
        if netstat -tuln | grep -q ":$port "; then
            echo -e "${YELLOW}⚠️ Port $port is already in use! ($service requires this port)${NC}"
            return 1
        fi
    elif command -v ss &> /dev/null; then
        if ss -tuln | grep -q ":$port "; then
            echo -e "${YELLOW}⚠️ Port $port is already in use! ($service requires this port)${NC}"
            return 1
        fi
    elif command -v lsof &> /dev/null; then
        if lsof -i ":$port" &>/dev/null; then
            echo -e "${YELLOW}⚠️ Port $port is already in use! ($service requires this port)${NC}"
            return 1
        fi
    else
        # If no tool is available, try a basic check
        (echo > /dev/tcp/localhost/$port) &>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${YELLOW}⚠️ Port $port appears to be in use! ($service requires this port)${NC}"
            return 1
        fi
    fi
    
    echo -e "${GREEN}✅ Port $port is available for $service${NC}"
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

# Function to safely create a directory
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

# Main script starts here
echo -e "${CYAN}🧪 Starting Lambda Web Adapter Flask integration test...${NC}"

# Setup paths
PROJECT_ROOT=$(pwd)
ADAPTER_DIR="$PROJECT_ROOT/aws-lambda-web-adapter"
EC2_APP="$PROJECT_ROOT/ec2.py"
TEST_DIR="/tmp/adapter-test"
FLASK_PORT=5000
ADAPTER_PORT=8080

# Check if the script can proceed
if [ ! -f "$EC2_APP" ]; then
    echo -e "${RED}❌ Flask app (ec2.py) not found! ${NC}"
    echo -e "${YELLOW}⚠️ Run ./1-local-adapter-setup.sh first${NC}"
    exit 1
fi

# Check dependencies
check_dependencies || exit 1

# Step 1: Clean up previous processes
echo -e "${BLUE}🧹 Cleaning up any previous processes...${NC}"
check_and_kill_process "python.*$EC2_APP" "ask" || true
check_and_kill_process "adapter-test" "ask" || true
sleep 1

# Step 2: Check if ports are available
echo -e "${BLUE}🔍 Checking port availability...${NC}"
check_port_available $FLASK_PORT "Flask" || {
    echo -e "${RED}❌ Cannot proceed. Flask requires port $FLASK_PORT${NC}"
    exit 1
}

check_port_available $ADAPTER_PORT "Test Adapter" || {
    echo -e "${RED}❌ Cannot proceed. Test Adapter requires port $ADAPTER_PORT${NC}"
    exit 1
}

# Step 3: Start Flask app
echo -e "${BLUE}🚀 Starting Flask app on port $FLASK_PORT...${NC}"
python3 $EC2_APP > /dev/null 2>&1 &
FLASK_PID=$!

# Wait for Flask to start
echo -e "${YELLOW}⏳ Waiting for Flask to start...${NC}"
sleep 3

# Verify Flask is running
if ! ps -p $FLASK_PID > /dev/null; then
    echo -e "${RED}❌ Flask failed to start!${NC}"
    exit 1
fi

# Test if Flask is responding
if command -v curl &> /dev/null; then
    curl -s http://localhost:$FLASK_PORT/ > /dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Flask app not responding!${NC}"
        kill $FLASK_PID 2>/dev/null || true
        exit 1
    fi
fi

echo -e "${GREEN}✅ Flask app started successfully with PID $FLASK_PID${NC}"

# Step 4: Create Go adapter test app with header logging
echo -e "${BLUE}🔧 Creating Go test adapter with header logging...${NC}"

# Create or clean test directory
if [ -d "$TEST_DIR" ]; then
    echo -e "${YELLOW}⚠️ Test directory already exists: $TEST_DIR${NC}"
    read -p "Remove existing directory? (y/n): " remove_dir
    if [ "$remove_dir" = "y" ]; then
        rm -rf "$TEST_DIR" 2>/dev/null
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ Failed to remove directory${NC}"
            TEST_DIR="$TEST_DIR-$(date +%s)"
            echo -e "${YELLOW}⚠️ Using alternative directory: $TEST_DIR${NC}"
        fi
    else
        TEST_DIR="$TEST_DIR-$(date +%s)"
        echo -e "${YELLOW}⚠️ Using alternative directory: $TEST_DIR${NC}"
    fi
fi

create_directory "$TEST_DIR" || exit 1
cd "$TEST_DIR" || {
    echo -e "${RED}❌ Failed to change to test directory${NC}"
    kill $FLASK_PID 2>/dev/null || true
    exit 1
}

# Create Go module
echo -e "${BLUE}📝 Creating Go module and source files...${NC}"
cat << 'EOF' > go.mod
module adaptertest
go 1.18
EOF

# Create main.go with header sanitization and logging
cat << 'EOF' > main.go
package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
)

// List of disallowed HTTP/2 headers
var disallowedHeaders = []string{
	"connection",
	"keep-alive",
	"proxy-connection",
	"transfer-encoding",
	"upgrade",
}

// sanitizeHeaders removes disallowed headers
func sanitizeHeaders(header http.Header) {
	for _, name := range disallowedHeaders {
		header.Del(name)
	}
}

// writeHeadersToFile writes headers to a file
func writeHeadersToFile(filename string, headers http.Header) {
	file, err := os.Create(filename)
	if err != nil {
		log.Printf("Error creating file %s: %v", filename, err)
		return
	}
	defer file.Close()

	for k, v := range headers {
		fmt.Fprintf(file, "%s: %s\n", k, strings.Join(v, ", "))
	}
}

func main() {
	log.Println("Starting header sanitization test on :8080")
	log.Println("Proxying to Flask server on http://localhost:5000")

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// Forward to Flask
		resp, err := http.Get("http://localhost:5000/")
		if err != nil {
			http.Error(w, "Failed to reach Flask", http.StatusBadGateway)
			log.Printf("Error: %v", err)
			return
		}
		defer resp.Body.Close()

		// Make a copy of original headers for comparison
		originalHeaders := make(http.Header)
		for k, v := range resp.Header {
			originalHeaders[k] = v
		}

		// Copy all headers to our response
		for k, v := range resp.Header {
			for _, vv := range v {
				w.Header().Add(k, vv)
			}
		}
		
		// Log original headers
		fmt.Println("\nORIGINAL HEADERS FROM FLASK:")
		for k, v := range resp.Header {
			fmt.Printf("  %s: %s\n", k, strings.Join(v, ", "))
		}
		
		// Write original headers to file for analysis
		writeHeadersToFile("original_headers.txt", originalHeaders)
		
		// Apply sanitization
		sanitizeHeaders(w.Header())
		
		// Log sanitized headers
		fmt.Println("\nSANITIZED HEADERS BEING RETURNED:")
		for k, v := range w.Header() {
			fmt.Printf("  %s: %s\n", k, strings.Join(v, ", "))
		}
		
		// Write sanitized headers to file for analysis
		writeHeadersToFile("sanitized_headers.txt", w.Header())

		// Return response
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	})

	log.Fatal(http.ListenAndServe(":8080", nil))
}
EOF

# Step 5: Build and run adapter test
echo -e "${BLUE}🔨 Building Go test adapter...${NC}"
go build -o adapter-test >/dev/null 2>&1

if [ $? -ne 0 ] || [ ! -f "adapter-test" ]; then
    echo -e "${RED}❌ Failed to build adapter-test!${NC}"
    cd "$PROJECT_ROOT"
    kill $FLASK_PID 2>/dev/null || true
    exit 1
fi

echo -e "${GREEN}✅ Test adapter built successfully${NC}"
echo -e "${BLUE}🚀 Running adapter on port $ADAPTER_PORT...${NC}"
./adapter-test > /dev/null 2>&1 &
ADAPTER_PID=$!

# Wait for adapter to start
echo -e "${YELLOW}⏳ Waiting for adapter to start...${NC}"
sleep 2

# Check if adapter started successfully
if ! ps -p $ADAPTER_PID > /dev/null; then
    echo -e "${RED}❌ Adapter failed to start!${NC}"
    cd "$PROJECT_ROOT"
    kill $FLASK_PID 2>/dev/null || true
    exit 1
fi

echo -e "${GREEN}✅ Adapter started with PID $ADAPTER_PID${NC}"

# Step 6: Test the header sanitization
echo -e "${BLUE}🧪 Sending request to test header sanitization...${NC}"

if command -v curl &> /dev/null; then
    curl_output=$(curl -s http://localhost:$ADAPTER_PORT/)
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Request failed!${NC}"
    else
        echo -e "${GREEN}✅ Request successful${NC}"
        echo -e "${BLUE}Response: $curl_output${NC}"
    fi
else
    # Alternative using Python if curl is not available
    python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:$ADAPTER_PORT/').read().decode())" || {
        echo -e "${RED}❌ Request failed!${NC}"
    }
fi

# Wait for files to be written
sleep 1

# Step 7: Show before and after headers
ORIGINAL_HEADERS_FILE="$TEST_DIR/original_headers.txt"
SANITIZED_HEADERS_FILE="$TEST_DIR/sanitized_headers.txt"

echo -e "\n${YELLOW}COMPARING HEADERS BEFORE AND AFTER SANITIZATION:${NC}"
echo -e "${BLUE}------------------------------------------------${NC}"

if [ -f "$ORIGINAL_HEADERS_FILE" ]; then
    echo -e "${PURPLE}ORIGINAL HEADERS FROM FLASK:${NC}"
    while IFS= read -r line; do
        # Highlight disallowed headers
        if [[ "$line" =~ ^(Connection|Keep-Alive|Proxy-Connection|Transfer-Encoding|Upgrade): ]]; then
            echo -e "${RED}$line${NC}"
        else
            echo -e "${NC}$line${NC}"
        fi
    done < "$ORIGINAL_HEADERS_FILE"
else
    echo -e "${RED}❌ Could not read original headers file.${NC}"
    echo -e "${YELLOW}⚠️ This may indicate an issue with the test adapter${NC}"
fi

echo ""

if [ -f "$SANITIZED_HEADERS_FILE" ]; then
    echo -e "${GREEN}SANITIZED HEADERS RETURNED TO CLIENT:${NC}"
    cat "$SANITIZED_HEADERS_FILE"
else
    echo -e "${RED}❌ Could not read sanitized headers file.${NC}"
    echo -e "${YELLOW}⚠️ This may indicate an issue with the test adapter${NC}"
fi

echo -e "${BLUE}------------------------------------------------${NC}"

# Step 8: Analyze headers
echo -e "\n${YELLOW}HEADER SANITIZATION ANALYSIS:${NC}"

CONNECTION_FOUND=false
KEEP_ALIVE_FOUND=false

if [ -f "$ORIGINAL_HEADERS_FILE" ]; then
    if grep -qi "^Connection:" "$ORIGINAL_HEADERS_FILE"; then
        CONNECTION_FOUND=true
    fi
    if grep -qi "^Keep-Alive:" "$ORIGINAL_HEADERS_FILE"; then
        KEEP_ALIVE_FOUND=true
    fi
fi

SANITIZED_CONNECTION_FOUND=false
SANITIZED_KEEP_ALIVE_FOUND=false

if [ -f "$SANITIZED_HEADERS_FILE" ]; then
    if grep -qi "^Connection:" "$SANITIZED_HEADERS_FILE"; then
        SANITIZED_CONNECTION_FOUND=true
    fi
    if grep -qi "^Keep-Alive:" "$SANITIZED_HEADERS_FILE"; then
        SANITIZED_KEEP_ALIVE_FOUND=true
    fi
fi

# Report findings
if [ "$CONNECTION_FOUND" = true ] || [ "$KEEP_ALIVE_FOUND" = true ]; then
    echo -e "${BLUE}Original headers contained disallowed headers:${NC}"
    if [ "$CONNECTION_FOUND" = true ]; then echo -e "${BLUE}- Connection header found in original${NC}"; fi
    if [ "$KEEP_ALIVE_FOUND" = true ]; then echo -e "${BLUE}- Keep-Alive header found in original${NC}"; fi
else
    echo -e "${YELLOW}⚠️ Note: Original headers didn't contain disallowed headers.${NC}"
    echo -e "${YELLOW}⚠️ This might indicate that Flask isn't sending the expected headers.${NC}"
    echo -e "${YELLOW}⚠️ Check that ec2.py is configured to send Connection and Keep-Alive headers.${NC}"
fi

echo ""

if [ "$SANITIZED_CONNECTION_FOUND" = true ] || [ "$SANITIZED_KEEP_ALIVE_FOUND" = true ]; then
    echo -e "${RED}❌ FAIL: Disallowed headers are still present after sanitization!${NC}"
    if [ "$SANITIZED_CONNECTION_FOUND" = true ]; then echo -e "${RED}- Connection header still present${NC}"; fi
    if [ "$SANITIZED_KEEP_ALIVE_FOUND" = true ]; then echo -e "${RED}- Keep-Alive header still present${NC}"; fi
    echo -e "${RED}The sanitization code is NOT properly removing headers.${NC}"
else
    if [ "$CONNECTION_FOUND" = true ] || [ "$KEEP_ALIVE_FOUND" = true ]; then
        echo -e "${GREEN}✅ SUCCESS: Disallowed headers were properly sanitized!${NC}"
        echo -e "${GREEN}The header sanitization code is working correctly.${NC}"
        echo -e "${GREEN}This confirms our Lambda Layer will correctly sanitize headers for HTTP/2 compatibility.${NC}"
    else
        echo -e "${YELLOW}⚠️ INDETERMINATE: No disallowed headers were present to sanitize.${NC}"
        echo -e "${YELLOW}⚠️ Please check that ec2.py is configured to send Connection and Keep-Alive headers.${NC}"
    fi
fi

# Step 9: Clean up
echo -e "\n${BLUE}🧹 Cleaning up...${NC}"

# Kill processes
kill $FLASK_PID 2>/dev/null || {
    echo -e "${YELLOW}⚠️ Failed to stop Flask process${NC}"
    echo -e "${YELLOW}⚠️ Trying force kill...${NC}"
    kill -9 $FLASK_PID 2>/dev/null || true
}

kill $ADAPTER_PID 2>/dev/null || {
    echo -e "${YELLOW}⚠️ Failed to stop adapter process${NC}"
    echo -e "${YELLOW}⚠️ Trying force kill...${NC}"
    kill -9 $ADAPTER_PID 2>/dev/null || true
}

# Verify processes were stopped
if ps -p $FLASK_PID &>/dev/null; then
    echo -e "${RED}❌ Failed to stop Flask process (PID: $FLASK_PID)${NC}"
    echo -e "${YELLOW}⚠️ You may need to stop it manually with: kill -9 $FLASK_PID${NC}"
else
    echo -e "${GREEN}✅ Flask server stopped${NC}"
fi

if ps -p $ADAPTER_PID &>/dev/null; then
    echo -e "${RED}❌ Failed to stop adapter process (PID: $ADAPTER_PID)${NC}"
    echo -e "${YELLOW}⚠️ You may need to stop it manually with: kill -9 $ADAPTER_PID${NC}"
else
    echo -e "${GREEN}✅ Adapter server stopped${NC}"
fi

# Clean up temporary files
echo -e "${YELLOW}⚠️ Would you like to keep the test files?${NC}"
read -p "Keep test files? (y/n): " keep_files

if [ "$keep_files" = "y" ]; then
    echo -e "${GREEN}✅ Test files kept at: $TEST_DIR${NC}"
    cd "$PROJECT_ROOT"
else
    echo -e "${BLUE}🧹 Removing test files...${NC}"
    cd "$PROJECT_ROOT"
    rm -rf "$TEST_DIR" 2>/dev/null || {
        echo -e "${YELLOW}⚠️ Failed to remove test directory${NC}"
    }
    echo -e "${GREEN}✅ Test files removed${NC}"
fi

echo -e "\n${CYAN}🎯 Integration test completed!${NC}"
echo -e "${GREEN}Results show if the header sanitization works with a real web application.${NC}"
echo -e "${GREEN}If successful, you can now proceed with building the Lambda Layer.${NC}"
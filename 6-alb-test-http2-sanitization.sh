#!/bin/bash
# HTTP/2 Header Sanitization Test Script - Improved for corner cases

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Set this to your ALB DNS name from CloudFormation output
if [[ $# -eq 0 ]]; then
    echo -e "${RED}Error:${NC} ALB DNS name required as argument"
    echo -e "Usage: $0 <alb-dns-name>"
    exit 1
fi

ALB_DNS="$1"
VERBOSE=false

# Parse additional options
for arg in "$@"; do
    case $arg in
        --verbose)
            VERBOSE=true
            shift
            ;;
    esac
done

# Function to run a test and analyze headers
function run_test() {
    NAME=$1
    URL=$2
    EXPECT_SANITIZED=$3
    OUTPUT_FILE="${NAME}.out"

    echo -e "\n${BLUE}============================"
    echo -e "TEST: ${YELLOW}$NAME${BLUE}"
    echo -e "URL: ${YELLOW}$URL${BLUE}"
    echo -e "=============================${NC}"

    # Run curl with HTTP/2 and verbose output
    echo -e "Running: curl -vsk --http2 $URL"
    
    # Use --fail-with-body to continue even if there's an HTTP error
    curl -vsk --http2 --fail-with-body "$URL" 2>&1 | tee "$OUTPUT_FILE" || true
    
    # Extract HTTP status code
    HTTP_STATUS=$(grep -oP "< HTTP/[0-9.]+ \K[0-9]+" "$OUTPUT_FILE" | tail -1)
    if [[ -z "$HTTP_STATUS" ]]; then
        HTTP_STATUS="unknown"
    fi
    
    # Check if request actually used HTTP/2
    if grep -q "Using HTTP/2" "$OUTPUT_FILE" || grep -q "using HTTP/2" "$OUTPUT_FILE"; then
        echo -e "${GREEN}✓ HTTP/2 protocol was successfully used${NC}"
        HTTP2_USED=true
    else
        echo -e "${YELLOW}⚠ HTTP/2 protocol was NOT used for this request${NC}"
        HTTP2_USED=false
    fi
    
    # Extract and display headers - only look at response headers (lines starting with <)
    echo -e "\n${BLUE}--- Response Analysis ---${NC}"
    echo -e "${YELLOW}HTTP Status:${NC} $HTTP_STATUS"
    
    # Check for disallowed headers in the response
    CONN_HEADER=$(grep -i "< connection:" "$OUTPUT_FILE" | grep -vi "< connection: close" || echo "")
    KEEP_ALIVE_HEADER=$(grep -i "< keep-alive:" "$OUTPUT_FILE" || echo "")
    
    # Display content-type too for reference
    CONTENT_TYPE=$(grep -i "< content-type:" "$OUTPUT_FILE" || echo "")
    if [[ -n "$CONTENT_TYPE" ]]; then
        echo -e "${BLUE}Content-Type:${NC} $CONTENT_TYPE"
    fi
    
    # Analyze disallowed headers
    CONNECTION_PRESENT=false
    if [[ -n "$CONN_HEADER" ]]; then
        echo -e "${RED}✗ 'Connection' header found in response:${NC} $CONN_HEADER"
        CONNECTION_PRESENT=true
    else
        echo -e "${GREEN}✓ No disallowed 'Connection' header found in response${NC}"
    fi
    
    KEEPALIVE_PRESENT=false
    if [[ -n "$KEEP_ALIVE_HEADER" ]]; then
        echo -e "${RED}✗ 'Keep-Alive' header found in response:${NC} $KEEP_ALIVE_HEADER"
        KEEPALIVE_PRESENT=true
    else
        echo -e "${GREEN}✓ No 'Keep-Alive' header found in response${NC}"
    fi
    
    # Check for protocol error (indicates HTTP/2 failure due to headers)
    PROTOCOL_ERROR=false
    if grep -qi "PROTOCOL_ERROR" "$OUTPUT_FILE"; then
        echo -e "${RED}⚠ HTTP/2 PROTOCOL_ERROR detected!${NC}"
        echo -e "${YELLOW}This indicates HTTP/2 connection failed due to illegal headers${NC}"
        PROTOCOL_ERROR=true
    fi
    
    # Check request body for error messages
    if [[ "$HTTP_STATUS" == "502" || "$HTTP_STATUS" == "500" ]]; then
        ERROR_MSG=$(cat "$OUTPUT_FILE" | grep -A 10 -B 2 "Error\|error\|ERROR\|<!DOCTYPE\|<html" || echo "")
        if [[ -n "$ERROR_MSG" ]]; then
            echo -e "${RED}Error response detected:${NC}"
            echo "$ERROR_MSG" | head -5
        fi
    fi
    
    # Determine if test passed based on expected sanitization AND HTTP status
    if [[ "$EXPECT_SANITIZED" == "true" ]]; then
        # For tests where we expect sanitization
        if [[ "$CONNECTION_PRESENT" == "false" && "$KEEPALIVE_PRESENT" == "false" ]]; then
            # Headers are properly sanitized, now check status
            if [[ "$HTTP_STATUS" =~ ^(200|201|202|203|204|205|206)$ ]]; then
                echo -e "${GREEN}✅ PASS: Headers properly sanitized and response successful${NC}"
                return 0
            else
                echo -e "${RED}❌ FAIL: Headers sanitized but service returned error status $HTTP_STATUS${NC}"
                return 1
            fi
        else
            echo -e "${RED}❌ FAIL: Headers were not sanitized properly${NC}"
            return 1
        fi
    elif [[ "$EXPECT_SANITIZED" == "false" ]]; then
        # For tests where we don't expect sanitization (vanilla test)
        if [[ "$PROTOCOL_ERROR" == "true" || "$CONNECTION_PRESENT" == "true" || "$KEEPALIVE_PRESENT" == "true" ]]; then
            echo -e "${GREEN}✅ PASS: Non-sanitized headers detected as expected${NC}"
            return 0
        else
            echo -e "${RED}❌ FAIL: Headers were unexpectedly sanitized${NC}"
            return 1
        fi
    elif [[ "$EXPECT_SANITIZED" == "ignore" ]]; then
        # Special case for just checking HTTP status
        if [[ "$HTTP_STATUS" =~ ^(200|201|202|203|204|205|206)$ ]]; then
            echo -e "${GREEN}✅ PASS: Service returned successful status${NC}"
            return 0
        else
            echo -e "${RED}❌ FAIL: Service returned error status $HTTP_STATUS${NC}"
            return 1
        fi
    fi
}

# Run test cases
echo -e "${BLUE}Starting HTTP/2 header sanitization tests against: ${YELLOW}$ALB_DNS${NC}"

# Check if HTTPS works (required for true HTTP/2 testing)
echo -e "${YELLOW}Checking if HTTPS is available...${NC}"
if curl -ks "https://$ALB_DNS" -o /dev/null -w "%{http_code}" | grep -q "200"; then
    echo -e "${GREEN}HTTPS is available, proceeding with HTTPS tests${NC}"
    USE_HTTPS=true
    PROTOCOL="https"
else
    echo -e "${YELLOW}Warning: HTTPS doesn't appear to be working, falling back to HTTP${NC}"
    echo -e "${YELLOW}Note: True HTTP/2 testing requires HTTPS${NC}"
    USE_HTTPS=false
    PROTOCOL="http"
fi

# Track overall test status
TEST_STATUS=0

# 1. Vanilla Lambda (expects headers to NOT be sanitized)
echo -e "\n${YELLOW}Test Case 1: Vanilla Lambda - NO sanitization expected${NC}"
run_test "vanilla-lambda" "$PROTOCOL://$ALB_DNS/vanilla" "false"
if [[ $? -ne 0 ]]; then TEST_STATUS=1; fi

# 2. Patched Lambda (expects headers to be sanitized AND successful response)
echo -e "\n${YELLOW}Test Case 2: Patched Lambda - WITH sanitization expected${NC}"
run_test "patched-lambda" "$PROTOCOL://$ALB_DNS/patched" "true"
if [[ $? -ne 0 ]]; then 
    TEST_STATUS=1
    echo -e "${YELLOW}⚠ WARNING: Patched Lambda test failed. This may indicate an issue with the Lambda Adapter configuration.${NC}"
    echo -e "${YELLOW}⚠ Check CloudWatch logs for more details and verify the adapter path is correct.${NC}"
fi

# 3. EC2 instance (expects ALB to handle sanitization automatically)
echo -e "\n${YELLOW}Test Case 3: EC2 Instance - WITH sanitization expected (by ALB)${NC}"
run_test "ec2-instance" "$PROTOCOL://$ALB_DNS/ec2" "true"
if [[ $? -ne 0 ]]; then TEST_STATUS=1; fi

# Summary
echo -e "\n${BLUE}==========================="
echo -e "SUMMARY OF TEST RESULTS"
echo -e "===========================${NC}"

echo -e "1. Vanilla Lambda ($PROTOCOL://$ALB_DNS/vanilla)"
echo -e "   ${YELLOW}Expected:${NC} Headers NOT sanitized - should cause HTTP/2 issues"
echo -e "   ${YELLOW}Purpose:${NC} Demonstrates the problem we're solving"

echo -e "\n2. Patched Lambda ($PROTOCOL://$ALB_DNS/patched)"
echo -e "   ${YELLOW}Expected:${NC} Headers ARE sanitized AND successful response"
echo -e "   ${YELLOW}Purpose:${NC} Demonstrates our Lambda Adapter's sanitization works"
if grep -q "❌ FAIL" patched-lambda.out; then
    echo -e "   ${RED}⚠ FIX NEEDED:${NC} Check Lambda environment variable AWS_LAMBDA_EXEC_WRAPPER"
    echo -e "   Likely paths: /opt/bootstrap or /opt/extensions/bootstrap"
    echo -e "   Check CloudWatch logs for HTTP2TestPatchedLambda"
fi

echo -e "\n3. EC2 Instance ($PROTOCOL://$ALB_DNS/ec2)"
echo -e "   ${YELLOW}Expected:${NC} Headers ARE sanitized by ALB - successful response"
echo -e "   ${YELLOW}Purpose:${NC} Control case showing ALB's standard behavior with EC2"

# Final result
if [[ $TEST_STATUS -eq 0 ]]; then
    echo -e "\n${GREEN}✅ All tests PASSED${NC}"
    echo -e "Your HTTP/2 header sanitization solution is working as expected!"
else
    echo -e "\n${RED}❌ Some tests FAILED${NC}"
    echo -e "Review the output files (*.out) for more details."
    
    if grep -q "502 Bad Gateway" patched-lambda.out; then
        echo -e "\n${YELLOW}Common issue: Lambda Adapter path is incorrect${NC}"
        echo -e "1. Check CloudWatch logs for HTTP2TestPatchedLambda"
        echo -e "2. Update the AWS_LAMBDA_EXEC_WRAPPER environment variable:"
        echo -e "   - Try /opt/bootstrap"
        echo -e "   - Try /opt/extensions/bootstrap"
        echo -e "   - Check actual Layer structure with a test Lambda"
    fi
    
    if [[ "$USE_HTTPS" != "true" ]]; then
        echo -e "\n${YELLOW}Note: You're not using HTTPS, which is required for true HTTP/2 testing.${NC}"
        echo -e "${YELLOW}Consider adding an SSL certificate to your ALB for proper HTTP/2 testing.${NC}"
    fi
fi

echo -e "\n${BLUE}HTTP/2 Header Sanitization Test Complete${NC}"
exit $TEST_STATUS
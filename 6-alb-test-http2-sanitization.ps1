# PowerShell script to test HTTP/2 header sanitization with AWS ALB
param (
    [Parameter(Mandatory=$true)]
    [string]$AlbDnsName,
    
    [switch]$HideCurlOutput = $false
)

# Set curl path
$curlPath = "C:\Program Files\curl-8.13.0_1-win64-mingw\bin\curl.exe"
if (-not (Test-Path $curlPath)) {
    $curlPath = "curl.exe"
}

$Protocol = "https"
$Target = "${Protocol}://${AlbDnsName}"

Write-Host "Starting HTTP/2 header sanitization test for $AlbDnsName" -ForegroundColor Cyan
Write-Host "Using curl: $curlPath" -ForegroundColor Gray

# Check curl HTTP/2 support
$versionOutput = & "$curlPath" --version
$hasHttp2 = $versionOutput -match "HTTP2"
if (-not $hasHttp2) {
    Write-Host "ERROR: curl.exe does not support HTTP/2 (--http2)" -ForegroundColor Red
    exit 1
}

# Check if HTTPS is available
Write-Host "Checking if HTTPS is available on ALB..." -ForegroundColor Blue
try {
    $status = (& "$curlPath" -ks -o NUL -w "%{http_code}" "$Target")
    if ($status -eq "200") {
        Write-Host "HTTPS is available. Using HTTPS for HTTP/2 tests" -ForegroundColor Green
    } else {
        Write-Host "HTTPS returned status $status. Falling back to HTTP" -ForegroundColor Yellow
        $Protocol = "http"
    }
} catch {
    Write-Host "Failed to check HTTPS status. Falling back to HTTP" -ForegroundColor Yellow
    $Protocol = "http"
}

function Run-Test {
    param (
        [string]$Name,
        [string]$Path,
        [bool]$ExpectSuccess = $false,
        [string]$Description = ""
    )
    
    $Url = "${Protocol}://${AlbDnsName}/$Path"
    $tempFile = [System.IO.Path]::GetTempFileName()

    Write-Host ""
    Write-Host "=============================" -ForegroundColor Blue
    Write-Host "TEST: $Name" -ForegroundColor Yellow
    Write-Host "URL:  $Url" -ForegroundColor Yellow
    if ($Description) {
        Write-Host "GOAL: " -ForegroundColor Yellow -NoNewline
        Write-Host "$Description"
    }
    Write-Host "=============================" -ForegroundColor Blue

    $cmdDisplay = "curl --http2 -vsk $Url"
    Write-Host "Running: $cmdDisplay" -ForegroundColor Gray
    
    # Execute curl and capture output
    if (-not $HideCurlOutput) {
        # Capture and display output
        $output = & "$curlPath" --http2 -vsk $Url 2>&1
        $output | Out-File $tempFile
        
        # Display output without errors
        foreach ($line in $output) {
            if ($line -notmatch "System.Management.Automation.RemoteException") {
                Write-Host $line
            }
        }
    } else {
        # Just capture output without showing it
        $curlOutput = & "$curlPath" --http2 -vsk $Url 2>&1
        $curlOutput | Out-File $tempFile
    }
    
    # Read file for analysis
    $curlOutText = Get-Content $tempFile -Raw
    
    # Key checks for test analysis
    $isHttp2 = $curlOutText -match "using HTTP/2"
    $httpStatusMatch = $curlOutText -match "HTTP/[12](?:\.[01])? (\d+)"
    $httpStatus = if ($httpStatusMatch) { $matches[1] } else { "Unknown" }
    $hasConnection = $curlOutText -match "(?i)< connection:"
    $hasKeepAlive = $curlOutText -match "(?i)< keep-alive:"
    $hasProtocolError = $curlOutText -match "HTTP/2 stream .* was not closed cleanly: PROTOCOL_ERROR"
    
    # Extract content type
    $contentType = ""
    if ($curlOutText -match "(?i)< content-type:(.*)") {
        $contentType = $matches[1].Trim()
    }

    # Display results
    Write-Host ""
    Write-Host "--- Response Analysis ---" -ForegroundColor Blue
    Write-Host "HTTP Status: $httpStatus" -ForegroundColor Yellow
    
    if ($contentType) {
        Write-Host "Content-Type: < content-type:$contentType" -ForegroundColor Blue
    }
    
    # Check headers
    if ($hasConnection) {
        Write-Host "X 'Connection' header found in response" -ForegroundColor Red
    } else {
        Write-Host "√ No disallowed 'Connection' header found in response" -ForegroundColor Green
    }
    
    if ($hasKeepAlive) {
        Write-Host "X 'Keep-Alive' header found in response" -ForegroundColor Red
    } else {
        Write-Host "√ No 'Keep-Alive' header found in response" -ForegroundColor Green
    }
    
    # Results determination
    $success = $false
    
    if ($ExpectSuccess) {
        # For sanitized endpoints (patched Lambda, EC2)
        if ($httpStatus -eq "200" -and -not $hasConnection -and -not $hasKeepAlive -and -not $hasProtocolError) {
            Write-Host "√ PASS: Headers properly sanitized and response successful" -ForegroundColor Green
            $success = $true
        } else {
            Write-Host "X FAIL: Headers not properly sanitized or response unsuccessful" -ForegroundColor Red
        }
    } else {
        # For vanilla Lambda (expecting non-sanitized headers)
        if ($hasProtocolError -or $hasConnection -or $hasKeepAlive) {
            Write-Host "√ PASS: Non-sanitized headers detected as expected" -ForegroundColor Green
            $success = $true
        } else {
            Write-Host "X FAIL: Headers appear to be sanitized (unexpected for vanilla Lambda)" -ForegroundColor Red
        }
    }
    
    # Cleanup
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    
    return @{
        Success = $success
        Url = $Url
    }
}

# Run the three tests
$result1 = Run-Test -Name "vanilla-lambda" -Path "vanilla" -Description "Should have unsanitized headers to show the problem"
$result2 = Run-Test -Name "patched-lambda" -Path "patched" -ExpectSuccess $true -Description "Should have sanitized headers to show our solution"
$result3 = Run-Test -Name "ec2-instance" -Path "ec2" -ExpectSuccess $true -Description "Control case: ALB naturally sanitizes EC2 headers"

# Print summary
Write-Host ""
Write-Host "===========================" -ForegroundColor Blue
Write-Host "SUMMARY OF TEST RESULTS" -ForegroundColor Blue
Write-Host "===========================" -ForegroundColor Blue

Write-Host "1. Vanilla Lambda ($($result1.Url))" -ForegroundColor White
Write-Host "   Expected: " -ForegroundColor Yellow -NoNewline
Write-Host "Headers NOT sanitized - should cause HTTP/2 issues"
Write-Host "   Purpose: " -ForegroundColor Yellow -NoNewline
Write-Host "Demonstrates the problem we're solving"

Write-Host ""
Write-Host "2. Patched Lambda ($($result2.Url))" -ForegroundColor White
Write-Host "   Expected: " -ForegroundColor Yellow -NoNewline
Write-Host "Headers ARE sanitized AND successful response"
Write-Host "   Purpose: " -ForegroundColor Yellow -NoNewline
Write-Host "Demonstrates our Lambda Adapter's sanitization works"

Write-Host ""
Write-Host "3. EC2 Instance ($($result3.Url))" -ForegroundColor White
Write-Host "   Expected: " -ForegroundColor Yellow -NoNewline
Write-Host "Headers ARE sanitized by ALB - successful response"
Write-Host "   Purpose: " -ForegroundColor Yellow -NoNewline
Write-Host "Control case showing ALB's standard behavior with EC2"

Write-Host ""
if ($result1.Success -and $result2.Success -and $result3.Success) {
    Write-Host "√ All tests PASSED" -ForegroundColor Green
    Write-Host "Your HTTP/2 header sanitization solution is working as expected!" -ForegroundColor White
} else {
    Write-Host "X Some tests FAILED" -ForegroundColor Red
    if (-not $result1.Success) {
        Write-Host "- Vanilla Lambda test failed: Headers should NOT be sanitized" -ForegroundColor Red
    }
    if (-not $result2.Success) {
        Write-Host "- Patched Lambda test failed: Headers should be sanitized" -ForegroundColor Red
    }
    if (-not $result3.Success) {
        Write-Host "- EC2 test failed: ALB should naturally sanitize headers" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "HTTP/2 Header Sanitization Test Complete" -ForegroundColor Blue
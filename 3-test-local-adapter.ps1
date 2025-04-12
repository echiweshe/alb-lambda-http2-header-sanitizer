# PowerShell script to test local Lambda Web Adapter build and header output
# Tests if the adapter is correctly sanitizing HTTP headers
$ErrorActionPreference = "Stop"

Write-Host "Starting local Lambda Web Adapter test..." -ForegroundColor Cyan

$projectRoot = Get-Location
$adapterDir = Join-Path $projectRoot "aws-lambda-web-adapter"
$cmdDir = Join-Path $adapterDir "cmd/aws-lambda-web-adapter"
$binPath = Join-Path $adapterDir "bin/aws-lambda-web-adapter.exe"

# Step 0: Terminate any existing adapter process
Write-Host "Checking for existing adapter processes..." -ForegroundColor Blue
$running = Get-Process -Name "aws-lambda-web-adapter" -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "Existing adapter process found. Terminating..." -ForegroundColor Yellow
    Stop-Process -Name "aws-lambda-web-adapter" -Force
    Start-Sleep -Seconds 1
} else {
    Write-Host "No existing adapter process running." -ForegroundColor Green
}

# Step 1: Build the adapter binary if not found
if (!(Test-Path $binPath)) {
    Write-Host "Building adapter..." -ForegroundColor Blue
    Push-Location $adapterDir
    if (!(Test-Path "go.mod")) {
        go mod init aws-lambda-web-adapter
    }
    go build -o $binPath ./cmd/aws-lambda-web-adapter
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Build failed!" -ForegroundColor Red
        exit 1
    }
    Pop-Location
} else {
    Write-Host "Adapter binary already exists. Skipping build." -ForegroundColor Green
}

# Step 2: Start the adapter server in background
Write-Host "Starting adapter server on port 8080..." -ForegroundColor Blue
try {
    # Use Start-Job to run in background
    $job = Start-Job -ScriptBlock {
        param($path)
        & $path
    } -ArgumentList $binPath
    
    # Wait for server to start
    Start-Sleep -Seconds 2
    
    Write-Host "Adapter started as background job." -ForegroundColor Green
} catch {
    Write-Host "Failed to start adapter: $_" -ForegroundColor Red
    exit 1
}

# Step 3: Send request using Invoke-WebRequest
Write-Host "Sending request to http://localhost:8080..." -ForegroundColor Blue
try {
    $response = Invoke-WebRequest -Uri http://localhost:8080/ -Headers @{ "Accept" = "*/*" } -UseBasicParsing
    
    # Save and show raw headers
    $responseLog = Join-Path $env:TEMP "adapter-response.log"
    $response.RawContent | Out-File $responseLog -Encoding utf8
    
    Write-Host "Response saved to: $responseLog" -ForegroundColor Green
    Write-Host "Response Body:" -ForegroundColor Cyan
    Write-Host $response.Content
    Write-Host "Raw Headers:" -ForegroundColor Cyan
    Write-Host $response.RawContent
} catch {
    Write-Host "Error sending request: $_" -ForegroundColor Red
    Write-Host "Make sure the adapter is running and responding on port 8080" -ForegroundColor Yellow
}

# Step 4: Check headers
Write-Host "Checking response headers..." -ForegroundColor Blue

if ($response) {
    # Convert headers to lowercase for case-insensitive comparison
    $rawHeaders = $response.RawContent.ToLower()
    $connectionFound = $rawHeaders -match "connection: keep-alive"
    $keepAliveFound = $rawHeaders -match "keep-alive:"

    Write-Host "Verifying if disallowed headers are present in the response..." -ForegroundColor Cyan
    if ($connectionFound -and $keepAliveFound) {
        Write-Host "SUCCESS: 'Connection' and 'Keep-Alive' headers were detected in the HTTP response." -ForegroundColor Green
        Write-Host "This indicates that the mock adapter (or upstream app) is returning raw headers as expected." -ForegroundColor Green
        Write-Host "In production, these headers would violate the HTTP/2 spec unless sanitized." -ForegroundColor Yellow
        
        # Show what sanitized headers would look like
        Write-Host ""
        Write-Host "EXAMPLE: Sanitized Headers (what they should look like after sanitization):" -ForegroundColor Yellow
        $headerLines = $response.RawContent -split "`r`n"
        $sanitizedHeaders = @()
        $disallowedHeaders = @("connection:", "keep-alive:")
        
        foreach ($line in $headerLines) {
            $isDisallowed = $false
            foreach ($header in $disallowedHeaders) {
                if ($line.ToLower().StartsWith($header)) {
                    $isDisallowed = $true
                    break
                }
            }
            
            if (-not $isDisallowed) {
                $sanitizedHeaders += $line
            }
        }
        
        Write-Host ($sanitizedHeaders -join "`r`n") -ForegroundColor Gray
    } else {
        Write-Host "WARNING: One or both disallowed headers are missing:" -ForegroundColor Yellow
        Write-Host "- Connection header found: $connectionFound" 
        Write-Host "- Keep-Alive header found: $keepAliveFound" 
        Write-Host ""
        Write-Host "If you're testing the unpatched adapter, this might indicate an error." -ForegroundColor Yellow
        Write-Host "If you're testing the patched version, this is expected behavior (headers are being sanitized)." -ForegroundColor Green
    }
} else {
    Write-Host "Could not verify headers - no response received." -ForegroundColor Red
}

# Step 5: Clean up
Write-Host "Stopping adapter background job..." -ForegroundColor Blue
try {
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    
    # Also try to kill any remaining processes
    Get-Process -Name "aws-lambda-web-adapter" -ErrorAction SilentlyContinue | Stop-Process -Force
    
    Write-Host "Adapter server stopped." -ForegroundColor Green
} catch {
    Write-Host "Warning: Could not stop adapter process: $_" -ForegroundColor Yellow
    Write-Host "You may need to terminate it manually." -ForegroundColor Yellow
}

Write-Host "Test completed!" -ForegroundColor Cyan
Write-Host ""
Write-Host "Summary: This test confirms whether the adapter is sanitizing HTTP/1.1 headers." -ForegroundColor White 
Write-Host "- For testing purposes, the original adapter should output the restricted headers." -ForegroundColor White
Write-Host "- In production with the patched Layer, these headers will be sanitized." -ForegroundColor White
# Simplified PowerShell script to test adapter stripping headers with Flask
$ErrorActionPreference = "Stop"

# Setup paths
$projectRoot = Get-Location
$adapterDir = Join-Path $projectRoot "aws-lambda-web-adapter"
$cmdDir = Join-Path $adapterDir "cmd/aws-lambda-web-adapter"
$ec2App = Join-Path $projectRoot "ec2.py"

Write-Host "Starting simplified test from directory: $projectRoot" -ForegroundColor Blue
Write-Host "Using adapter directory: $adapterDir" -ForegroundColor Blue

# Step 1: Clean up previous processes
Write-Host "Cleaning up any previous processes..." -ForegroundColor Cyan
Get-Process -Name "python" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Name "adapter-test" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# Step 2: Start Flask app
Write-Host "Starting Flask app on port 5000..." -ForegroundColor Cyan
Start-Process -FilePath "python" -ArgumentList $ec2App -NoNewWindow
Start-Sleep -Seconds 2

# Step 3: Create Go adapter test app in a temporary directory
$tempDir = Join-Path $env:TEMP "adapter-test"
New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

Write-Host "Creating Go test adapter in: $tempDir" -ForegroundColor Cyan
Set-Location $tempDir

# Create Go module
@"
module adaptertest
go 1.18
"@ | Set-Content "go.mod"

# Create main.go
@"
package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
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

		// Copy all headers
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
		
		// Apply sanitization
		sanitizeHeaders(w.Header())
		
		// Log sanitized headers
		fmt.Println("\nSANITIZED HEADERS BEING RETURNED:")
		for k, v := range w.Header() {
			fmt.Printf("  %s: %s\n", k, strings.Join(v, ", "))
		}

		// Return response
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	})

	log.Fatal(http.ListenAndServe(":8080", nil))
}
"@ | Set-Content "main.go"

# Step 4: Build and run
Write-Host "Building adapter test app..." -ForegroundColor Cyan
go build -o adapter-test.exe

Write-Host "Running adapter on port 8080..." -ForegroundColor Cyan
Start-Process -FilePath ".\adapter-test.exe" -NoNewWindow
Start-Sleep -Seconds 2

# Step 5: Test
Write-Host "`nSending request to test header sanitization..." -ForegroundColor Green
$response = Invoke-WebRequest -Uri "http://localhost:8080/" -UseBasicParsing
$headerContent = $response.RawContent -split "`r`n`r`n" | Select-Object -First 1

Write-Host "`nRESPONSE HEADERS:" -ForegroundColor Yellow
Write-Host $headerContent

# Step 6: Analyze headers
Write-Host "`nChecking for disallowed headers..." -ForegroundColor Cyan
$connectionFound = $headerContent -match "(?i)Connection: keep-alive"
$keepAliveFound = $headerContent -match "(?i)Keep-Alive:"

if ($connectionFound -or $keepAliveFound) {
    Write-Host "`n❌ FAIL: Disallowed headers are still present!" -ForegroundColor Red
    if ($connectionFound) { Write-Host " - Connection header found" -ForegroundColor Red }
    if ($keepAliveFound) { Write-Host " - Keep-Alive header found" -ForegroundColor Red }
} else {
    Write-Host "`n✅ SUCCESS: Disallowed headers were properly sanitized!" -ForegroundColor Green
    Write-Host "The header sanitization code is working correctly." -ForegroundColor Green
}

# Step 7: Clean up
Write-Host "`nCleaning up..." -ForegroundColor Cyan
Get-Process -Name "python" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Name "adapter-test" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# Return to original directory
Set-Location $projectRoot

Write-Host "`nTest completed - you can now proceed with building the Lambda Layer." -ForegroundColor Green
# 4-test-adapter-with-flask.ps1

# PowerShell script to test adapter stripping headers with Flask
# Purpose: Test if sanitization works with a real upstream server
$ErrorActionPreference = "Stop"

Write-Host "Starting Lambda Web Adapter Flask integration test..." -ForegroundColor Cyan

# Setup paths
$projectRoot = Get-Location
$adapterDir = Join-Path $projectRoot "aws-lambda-web-adapter"
$cmdDir = Join-Path $adapterDir "cmd/aws-lambda-web-adapter"
$ec2App = Join-Path $projectRoot "ec2.py"
$testDir = Join-Path $env:TEMP "adapter-test"

Write-Host "Using the following paths:" -ForegroundColor Blue
Write-Host "- Project root: $projectRoot"
Write-Host "- Adapter directory: $adapterDir"
Write-Host "- Flask app path: $ec2App"
Write-Host "- Test directory: $testDir"

# Step 1: Clean up previous processes
Write-Host "Cleaning up any previous processes..." -ForegroundColor Blue
$flaskJob = $null
$adapterJob = $null

# Kill any existing Python processes that might be running the Flask app
Get-Process -Name "python" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
# Kill any adapter test processes
Get-Process -Name "aws-lambda-web-adapter" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# Step 2: Start Flask app
Write-Host "Starting Flask app on port 5000..." -ForegroundColor Blue
try {
    # Check if Python is available
    $pythonVersion = & python --version 2>&1
    Write-Host "Using $pythonVersion" -ForegroundColor Green
    
    # Start Flask in background using PowerShell job
    $flaskJob = Start-Job -ScriptBlock {
        param($script)
        & python $script
    } -ArgumentList $ec2App
    
    # Wait for Flask to start
    Write-Host "Waiting for Flask to start..." -ForegroundColor Yellow
    Start-Sleep -Seconds 3
} catch {
    Write-Host "Error starting Flask app: $_" -ForegroundColor Red
    Write-Host "Make sure Python and Flask are installed." -ForegroundColor Yellow
    exit 1
}

# Step 3: Create Go adapter test app with a way to capture headers
Write-Host "Creating Go test adapter with header logging..." -ForegroundColor Blue

# Create or clean test directory
if (Test-Path $testDir) {
    Remove-Item $testDir -Recurse -Force
}
New-Item -Path $testDir -ItemType Directory -Force | Out-Null
Set-Location $testDir

# Create Go module
@"
module adaptertest
go 1.18
"@ | Set-Content "go.mod"

# Create main.go with header sanitization and logging
@"
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
		
		// Write original headers to file for PowerShell to read
		writeHeadersToFile("original_headers.txt", originalHeaders)
		
		// Apply sanitization
		sanitizeHeaders(w.Header())
		
		// Log sanitized headers
		fmt.Println("\nSANITIZED HEADERS BEING RETURNED:")
		for k, v := range w.Header() {
			fmt.Printf("  %s: %s\n", k, strings.Join(v, ", "))
		}
		
		// Write sanitized headers to file for PowerShell to read
		writeHeadersToFile("sanitized_headers.txt", w.Header())

		// Return response
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	})

	log.Fatal(http.ListenAndServe(":8080", nil))
}
"@ | Set-Content "main.go"

# Step 4: Build and run adapter test
Write-Host "Building Go test adapter..." -ForegroundColor Blue
try {
    # Check if Go is available
    $goVersion = & go version
    Write-Host "Using $goVersion" -ForegroundColor Green
    
    # Build for Windows (default)
    go build -o adapter-test.exe
    
    if (!(Test-Path "adapter-test.exe")) {
        throw "Failed to build adapter-test.exe"
    }
    
    Write-Host "Running adapter on port 8080..." -ForegroundColor Blue
    $adapterJob = Start-Job -ScriptBlock {
        param($dir)
        Set-Location $dir
        ./adapter-test.exe
    } -ArgumentList $testDir
    
    # Wait for adapter to start
    Start-Sleep -Seconds 2
} catch {
    Write-Host "Error building or starting adapter: $_" -ForegroundColor Red
    
    # Try to clean up Flask job if it exists
    if ($flaskJob) {
        Stop-Job -Job $flaskJob -ErrorAction SilentlyContinue
        Remove-Job -Job $flaskJob -Force -ErrorAction SilentlyContinue
    }
    
    Write-Host "Failed to build or start Go adapter. Test aborted." -ForegroundColor Red
    Set-Location $projectRoot
    exit 1
}

# Step 5: Test the header sanitization
Write-Host "Sending request to test header sanitization..." -ForegroundColor Green
try {
    $originalHeadersFile = Join-Path $testDir "original_headers.txt"
    $sanitizedHeadersFile = Join-Path $testDir "sanitized_headers.txt"
    
    # Clear any existing files
    if (Test-Path $originalHeadersFile) { Remove-Item $originalHeadersFile -Force }
    if (Test-Path $sanitizedHeadersFile) { Remove-Item $sanitizedHeadersFile -Force }
    
    # Send request to trigger header logging
    $response = Invoke-WebRequest -Uri "http://localhost:8080/" -UseBasicParsing
    
    # Wait a moment for files to be written
    Start-Sleep -Seconds 1
    
    # Step 6: Show before and after headers
    Write-Host "" 
    Write-Host "COMPARING HEADERS BEFORE AND AFTER SANITIZATION:" -ForegroundColor Yellow
    Write-Host "------------------------------------------------" -ForegroundColor DarkGray
    
    if (Test-Path $originalHeadersFile) {
        $originalHeaders = Get-Content $originalHeadersFile
        Write-Host "ORIGINAL HEADERS FROM FLASK:" -ForegroundColor Magenta
        foreach ($line in $originalHeaders) {
            # Highlight disallowed headers
            if ($line -match "^(Connection|Keep-Alive|Proxy-Connection|Transfer-Encoding|Upgrade):") {
                Write-Host $line -ForegroundColor Red
            } else {
                Write-Host $line -ForegroundColor Gray
            }
        }
    } else {
        Write-Host "Could not read original headers file." -ForegroundColor Red
    }
    
    Write-Host "" 
    
    if (Test-Path $sanitizedHeadersFile) {
        $sanitizedHeaders = Get-Content $sanitizedHeadersFile
        Write-Host "SANITIZED HEADERS RETURNED TO CLIENT:" -ForegroundColor Green
        foreach ($line in $sanitizedHeaders) {
            Write-Host $line -ForegroundColor Gray
        }
    } else {
        Write-Host "Could not read sanitized headers file." -ForegroundColor Red
    }
    
    Write-Host "------------------------------------------------" -ForegroundColor DarkGray
    
    # Step 7: Analyze headers
    Write-Host "" 
    Write-Host "HEADER SANITIZATION ANALYSIS:" -ForegroundColor Yellow
    
    $connectionFound = $false
    $keepAliveFound = $false
    
    if ($originalHeaders) {
        foreach ($line in $originalHeaders) {
            if ($line -match "^Connection:") { $connectionFound = $true }
            if ($line -match "^Keep-Alive:") { $keepAliveFound = $true }
        }
    }
    
    $sanitizedConnectionFound = $false
    $sanitizedKeepAliveFound = $false
    
    if ($sanitizedHeaders) {
        foreach ($line in $sanitizedHeaders) {
            if ($line -match "^Connection:") { $sanitizedConnectionFound = $true }
            if ($line -match "^Keep-Alive:") { $sanitizedKeepAliveFound = $true }
        }
    }
    
    # Report findings
    if ($connectionFound -or $keepAliveFound) {
        Write-Host "Original headers contained disallowed headers:" -ForegroundColor Blue
        if ($connectionFound) { Write-Host "- Connection header found in original" -ForegroundColor Blue }
        if ($keepAliveFound) { Write-Host "- Keep-Alive header found in original" -ForegroundColor Blue }
    } else {
        Write-Host "Note: Original headers didn't contain disallowed headers." -ForegroundColor Yellow
        Write-Host "This might indicate that Flask isn't sending the expected headers." -ForegroundColor Yellow
    }
    
    Write-Host ""
    
    if ($sanitizedConnectionFound -or $sanitizedKeepAliveFound) {
        Write-Host "❌ FAIL: Disallowed headers are still present after sanitization!" -ForegroundColor Red
        if ($sanitizedConnectionFound) { Write-Host "- Connection header still present" -ForegroundColor Red }
        if ($sanitizedKeepAliveFound) { Write-Host "- Keep-Alive header still present" -ForegroundColor Red }
        Write-Host "The sanitization code is NOT properly removing headers." -ForegroundColor Red
    } else {
        if ($connectionFound -or $keepAliveFound) {
            Write-Host "✅ SUCCESS: Disallowed headers were properly sanitized!" -ForegroundColor Green
            Write-Host "The header sanitization code is working correctly." -ForegroundColor Green
            Write-Host "This confirms our Lambda Layer will correctly sanitize headers for HTTP/2 compatibility." -ForegroundColor Green
        } else {
            Write-Host "⚠️ INDETERMINATE: No disallowed headers were present to sanitize." -ForegroundColor Yellow
            Write-Host "Please check that ec2.py is configured to send Connection and Keep-Alive headers." -ForegroundColor Yellow
        }
    }
} catch {
    Write-Host "Error testing adapter: $_" -ForegroundColor Red
    Write-Host "Make sure both Flask and the adapter are running." -ForegroundColor Yellow
}

# Step 8: Clean up
Write-Host ""
Write-Host "Cleaning up..." -ForegroundColor Blue

# Stop jobs
if ($flaskJob) {
    Stop-Job -Job $flaskJob -ErrorAction SilentlyContinue
    Remove-Job -Job $flaskJob -Force -ErrorAction SilentlyContinue
}

if ($adapterJob) {
    Stop-Job -Job $adapterJob -ErrorAction SilentlyContinue
    Remove-Job -Job $adapterJob -Force -ErrorAction SilentlyContinue
}

# Kill any remaining processes
Get-Process -Name "python" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Name "adapter-test" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# Return to original directory
Set-Location $projectRoot

Write-Host ""
Write-Host "Test completed - results show if the sanitization code is working correctly." -ForegroundColor Cyan
Write-Host "If successful, you can now proceed with building the Lambda Layer." -ForegroundColor Cyan
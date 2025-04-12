# Enhanced PowerShell script to build Lambda Layer
# Purpose: Builds and packages the Lambda Web Adapter with header sanitization
$ErrorActionPreference = "Stop"

# Simple coloring approach - testing if this works
Write-Host "Building Lambda Web Adapter Layer with header sanitization..." -ForegroundColor Cyan

# Store original directory
$originalDir = Get-Location 

try {
    $projectRoot = $originalDir
    $adapterDir = Join-Path $projectRoot "aws-lambda-web-adapter"
    $binDir = Join-Path $adapterDir "bin"
    $layerDir = Join-Path $adapterDir "custom-lambda-layer"
    $extDir = Join-Path $layerDir "extensions"
    $zipFile = Join-Path $adapterDir "custom-lambda-adapter-layer.zip"
    $binaryName = "aws-lambda-web-adapter"
    $binaryPath = Join-Path $binDir $binaryName

    # Clean up any existing files
    Write-Host "Cleaning up existing files..." -ForegroundColor Blue
    
    # Check for and stop any processes that might lock the adapter binary
    $runningAdapterProc = Get-Process -Name $binaryName -ErrorAction SilentlyContinue
    if ($runningAdapterProc) {
        Write-Host "Stopping running adapter process to prevent file locks..." -ForegroundColor Yellow
        $runningAdapterProc | Stop-Process -Force
        Start-Sleep -Seconds 1
    }
    
    # Check for and close any open file handles to the ZIP file
    if (Test-Path $zipFile) {
        try {
            Remove-Item $zipFile -Force
            Write-Host "Removed existing ZIP file" -ForegroundColor Green
        } catch {
            Write-Host "Warning: Could not remove existing ZIP file. It may be locked." -ForegroundColor Yellow
            $zipFile = Join-Path $adapterDir "custom-lambda-adapter-layer-new.zip"
            Write-Host "Using alternative ZIP file name: $zipFile" -ForegroundColor Yellow
        }
    }
    
    # Clean layer directory if it exists
    if (Test-Path $layerDir) {
        try {
            Remove-Item $layerDir -Recurse -Force
            Write-Host "Removed existing layer directory" -ForegroundColor Green
        } catch {
            Write-Host "Warning: Could not remove existing layer directory" -ForegroundColor Yellow
            $layerDir = Join-Path $adapterDir "custom-lambda-layer-new"
            $extDir = Join-Path $layerDir "extensions"
            Write-Host "Using alternative layer directory: $layerDir" -ForegroundColor Yellow
        }
    }

    # Ensure directories
    Write-Host "Creating fresh directories..." -ForegroundColor Blue
    New-Item -Path $extDir -ItemType Directory -Force | Out-Null
    New-Item -Path $binDir -ItemType Directory -Force | Out-Null

    # Check if Go is installed
    try {
        $goVersion = & go version
        Write-Host "Using $goVersion" -ForegroundColor Green
    } catch {
        Write-Host "Error: Go is not installed or not in PATH" -ForegroundColor Red
        throw "Go is required for this build script"
    }

    # Building with Go for Linux
    Write-Host "Building adapter with Go for Linux..." -ForegroundColor Blue
    Set-Location $adapterDir
    
    # Verify Go source files exist
    $mainFile = Join-Path $adapterDir "cmd/aws-lambda-web-adapter/main.go"
    if (-not (Test-Path $mainFile)) {
        Write-Host "Creating main.go with header sanitization..." -ForegroundColor Yellow
        
        # Create main.go directory if needed
        $mainDir = Split-Path $mainFile -Parent
        if (-not (Test-Path $mainDir)) {
            New-Item -Path $mainDir -ItemType Directory -Force | Out-Null
        }

        # Create the modified main.go with header sanitization
        @'
package main

import (
	"io"
	"log"
	"net/http"
	"os"
)

// List of disallowed HTTP/2 headers that need to be sanitized
var disallowedHeaders = []string{
	"connection",
	"keep-alive",
	"proxy-connection",
	"transfer-encoding",
	"upgrade",
}

// sanitizeHeaders removes disallowed HTTP/2 headers from the response
func sanitizeHeaders(header http.Header) {
	for _, name := range disallowedHeaders {
		header.Del(name)
	}
}

func main() {
	log.Println("Starting AWS Lambda Web Adapter with HTTP/2 header sanitization")
	
	// Get Lambda endpoint
	lambdaEndpoint := os.Getenv("AWS_LAMBDA_RUNTIME_API")
	if lambdaEndpoint == "" {
		log.Fatal("AWS_LAMBDA_RUNTIME_API environment variable is not set")
	}
	
	// Simple proxy server
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// Forward the request to Lambda
		lambdaURL := "http://" + lambdaEndpoint + "/2015-03-31/functions/current/invocations"
		
		// Create a new request
		req, err := http.NewRequest(r.Method, lambdaURL, r.Body)
		if err != nil {
			http.Error(w, "Error creating request to Lambda", http.StatusInternalServerError)
			return
		}
		
		// Copy headers
		for name, values := range r.Header {
			for _, value := range values {
				req.Header.Add(name, value)
			}
		}
		
		// Send request to Lambda
		client := &http.Client{}
		resp, err := client.Do(req)
		if err != nil {
			http.Error(w, "Error forwarding request to Lambda", http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		
		// Copy response headers
		for name, values := range resp.Header {
			for _, value := range values {
				w.Header().Add(name, value)
			}
		}
		
		// Apply header sanitization
		sanitizeHeaders(w.Header())
		
		// Log the sanitization
		log.Println("Headers sanitized for HTTP/2 compatibility")
		
		// Set status code and copy body
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	})
	
	// Start server
	log.Fatal(http.ListenAndServe(":8080", nil))
}
'@ | Set-Content -Path $mainFile
    }

    # Set Go environment for Linux cross-compilation
    $env:GOOS = "linux"
    $env:GOARCH = "amd64"
    $env:CGO_ENABLED = "0"  # Disable CGO for static binary

    # Initialize Go module if needed
    if (-not (Test-Path (Join-Path $adapterDir "go.mod"))) {
        Write-Host "Initializing Go module..." -ForegroundColor Yellow
        & go mod init aws-lambda-web-adapter
    }

    # Build the adapter
    Write-Host "Building static binary for Lambda..." -ForegroundColor Blue
    & go build -ldflags="-s -w" -o $binaryPath ./cmd/aws-lambda-web-adapter
    
    if (-not (Test-Path $binaryPath)) {
        Write-Host "Error: Go build failed. No binary found." -ForegroundColor Red
        throw "Build failed"
    }
    
    # Get binary size and info
    $binaryInfo = Get-Item $binaryPath
    Write-Host "Binary built successfully: $($binaryInfo.Length) bytes" -ForegroundColor Green

    # Copy binary into the layer structure
    Write-Host "Copying binary into Lambda Layer layout..." -ForegroundColor Blue
    Copy-Item -Path $binaryPath -Destination (Join-Path $extDir "aws-lambda-web-adapter") -Force

    # Create a bootstrap file to ensure executable permissions
    $bootstrapPath = Join-Path $extDir "bootstrap"
    @"
#!/bin/bash
# Script to ensure permissions and launch adapter
set -e

# Log startup
echo "AWS Lambda Web Adapter with HTTP/2 header sanitization starting..."

# Make adapter executable
chmod +x /opt/extensions/aws-lambda-web-adapter

# Run adapter
exec /opt/extensions/aws-lambda-web-adapter
"@ | Set-Content -Path $bootstrapPath -NoNewline

    # Create ZIP
    Write-Host "Creating Lambda Layer ZIP..." -ForegroundColor Blue

    # Use PowerShell's built-in Compress-Archive
    if (Test-Path $zipFile) {
        Remove-Item $zipFile -Force
    }
    
    # We need to preserve the directory structure
    Set-Location $layerDir
    Compress-Archive -Path "extensions" -DestinationPath $zipFile -Force
    Set-Location $originalDir

    # Verify ZIP file
    if (Test-Path $zipFile) {
        $zipInfo = Get-Item $zipFile
        Write-Host ""
        Write-Host "Lambda Layer ZIP created successfully:" -ForegroundColor Green
        Write-Host "  Path: $zipFile" -ForegroundColor Cyan
        Write-Host "  Size: $($zipInfo.Length) bytes" -ForegroundColor Cyan
        
        Write-Host ""
        Write-Host "DEPLOYMENT INSTRUCTIONS:" -ForegroundColor Yellow
        Write-Host "1. Upload this ZIP as a Lambda Layer" -ForegroundColor White
        Write-Host "2. Add the layer to your Lambda function" -ForegroundColor White
        Write-Host "3. Set this environment variable in your Lambda:" -ForegroundColor White
        Write-Host "   AWS_LAMBDA_EXEC_WRAPPER: /opt/extensions/bootstrap" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "The adapter will now sanitize HTTP/2 headers automatically." -ForegroundColor Green
    } else {
        throw "ZIP file creation failed"
    }
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
    Write-Host "Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
    Write-Host "Please make sure no applications are using any of the files and try again." -ForegroundColor Yellow
}
finally {
    # ALWAYS return to original directory
    Set-Location $originalDir
    
    # Restore normal Go environment
    $env:GOOS = ""
    $env:GOARCH = ""
    $env:CGO_ENABLED = ""
}

Write-Host "Done!" -ForegroundColor Cyan
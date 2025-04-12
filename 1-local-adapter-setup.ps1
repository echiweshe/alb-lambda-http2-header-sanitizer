# Enhanced script for setting up the Lambda Web Adapter with header sanitization
# Purpose: Prepares the local development environment with necessary files and code
$ErrorActionPreference = "Stop"

Write-Host "🚀 Setting up Lambda Web Adapter with header sanitization..." -ForegroundColor Cyan

# Setup paths
$projectRoot = Get-Location
$adapterDir = Join-Path $projectRoot "aws-lambda-web-adapter"
$srcDir = Join-Path $adapterDir "src"
$cmdDir = Join-Path $adapterDir "cmd/aws-lambda-web-adapter"
$layerDir = Join-Path $adapterDir "custom-lambda-layer"
$extDir = Join-Path $layerDir "extensions/aws-lambda-web-adapter"
$binDir = Join-Path $adapterDir "bin"

# Ensure directories exist
Write-Host "Creating directory structure..." -ForegroundColor Blue
try {
    New-Item -Path $srcDir -ItemType Directory -Force | Out-Null
    New-Item -Path $cmdDir -ItemType Directory -Force | Out-Null
    New-Item -Path $extDir -ItemType Directory -Force | Out-Null
    New-Item -Path $binDir -ItemType Directory -Force | Out-Null
    Write-Host "✅ Directories created successfully." -ForegroundColor Green
} catch {
    Write-Host "❌ Failed to create directories: $_" -ForegroundColor Red
    exit 1
}

# Create lib.rs with header sanitization function
Write-Host "Creating sanitization code in lib.rs..." -ForegroundColor Blue
try {
    @'
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
'@ | Set-Content -Path (Join-Path $srcDir "lib.rs")
    Write-Host "✅ lib.rs created successfully." -ForegroundColor Green
} catch {
    Write-Host "❌ Failed to create lib.rs: $_" -ForegroundColor Red
    exit 1
}

# Inject sanitize_headers call into adapter.rs if it exists
$adapterRsPath = Join-Path $srcDir "adapter.rs"
if (Test-Path $adapterRsPath) {
    Write-Host "Injecting sanitize_headers call into adapter.rs..." -ForegroundColor Blue
    try {
        $adapterLines = Get-Content $adapterRsPath
        $injectionPoint = $adapterLines | Select-String -Pattern 'let\s+mut\s+response\s*=.*' | Select-Object -First 1

        if ($injectionPoint) {
            $index = $injectionPoint.LineNumber - 1
            $linesBefore = $adapterLines[0..$index]
            $linesAfter = $adapterLines[($index + 1)..($adapterLines.Length - 1)]

            $newContent = @(
                $linesBefore
                '    crate::sanitize_headers(&mut response);'
                $linesAfter
            )

            $newContent | Set-Content -Path $adapterRsPath
            Write-Host "✅ Sanitization call injected into adapter.rs" -ForegroundColor Green
        } else {
            Write-Host "⚠️ Could not locate response line in adapter.rs. Manual injection may be required." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "❌ Failed to inject code into adapter.rs: $_" -ForegroundColor Red
        Write-Host "Manual injection may be required." -ForegroundColor Yellow
    }
} else {
    # Try with hyper.rs instead, which is an alternative location
    $hyperRsPath = Join-Path $srcDir "adapter/hyper.rs"
    if (Test-Path $hyperRsPath) {
        Write-Host "Injecting sanitize_headers call into hyper.rs..." -ForegroundColor Blue
        try {
            $hyperLines = Get-Content $hyperRsPath
            $injectionPoint = $hyperLines | Select-String -Pattern 'let\s+mut\s+response\s*=.*' | Select-Object -First 1

            if ($injectionPoint) {
                $index = $injectionPoint.LineNumber - 1
                $linesBefore = $hyperLines[0..$index]
                $linesAfter = $hyperLines[($index + 1)..($hyperLines.Length - 1)]

                $newContent = @(
                    $linesBefore
                    ' crate::sanitize_headers(&mut response);'
                    $linesAfter
                )

                $newContent | Set-Content -Path $hyperRsPath
                Write-Host "✅ Sanitization call injected into hyper.rs" -ForegroundColor Green
            } else {
                Write-Host "⚠️ Could not locate response line in hyper.rs. Manual injection may be required." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "❌ Failed to inject code into hyper.rs: $_" -ForegroundColor Red
            Write-Host "Manual injection may be required." -ForegroundColor Yellow
        }
    } else {
        Write-Host "⚠️ Neither adapter.rs nor hyper.rs found. You'll need to manually add sanitization call to the adapter code." -ForegroundColor Yellow
    }
}

# Create main.go for local testing
Write-Host "Creating main.go for local testing..." -ForegroundColor Blue
try {
    @'
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
'@ | Set-Content -Path (Join-Path $cmdDir "main.go")
    Write-Host "✅ main.go created successfully." -ForegroundColor Green
} catch {
    Write-Host "❌ Failed to create main.go: $_" -ForegroundColor Red
    exit 1
}

# Create lambda.py test file
Write-Host "Creating lambda.py for testing..." -ForegroundColor Blue
try {
    @'
def handler(event, context):
    enableConnection = event.get("queryStringParameters", {})
    if enableConnection is None:
        enableConnection = {}
    connection = enableConnection.get("connection", "true")
    keepAlive = enableConnection.get("keep-alive", "true")
    
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
'@ | Set-Content -Path (Join-Path $projectRoot "lambda.py")
    Write-Host "✅ lambda.py created successfully." -ForegroundColor Green
} catch {
    Write-Host "❌ Failed to create lambda.py: $_" -ForegroundColor Red
    exit 1
}

# Create ec2.py for simulating non-Lambda targets
Write-Host "Creating ec2.py for simulation..." -ForegroundColor Blue
try {
    @'
from flask import Flask, Response

app = Flask(__name__)

@app.route("/")
def root():
    return Response("Successful request to EC2 (python)",
                    headers={"Connection": "keep-alive", "Keep-Alive": "timeout=72"},
                    mimetype="text/plain")

if __name__ == "__main__":
    app.run(port=5000)
'@ | Set-Content -Path (Join-Path $projectRoot "ec2.py")
    Write-Host "✅ ec2.py created successfully." -ForegroundColor Green
} catch {
    Write-Host "❌ Failed to create ec2.py: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "✅ Local Lambda Web Adapter setup completed successfully." -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "1. Build the adapter with: 'cd $adapterDir && go build -o bin/aws-lambda-web-adapter.exe ./cmd/aws-lambda-web-adapter'" -ForegroundColor Yellow
Write-Host "2. Test the adapter with: './3-test-local-adapter.ps1'" -ForegroundColor Yellow
Write-Host "3. Build the Lambda Layer with: './2-build-layer-zip.ps1'" -ForegroundColor Yellow
Write-Host ""
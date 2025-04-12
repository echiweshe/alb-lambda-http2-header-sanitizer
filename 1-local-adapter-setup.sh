#!/bin/bash

set -e

echo "🔧 Setting up local Lambda Web Adapter environment..."

PROJECT_ROOT=$(pwd)
ADAPTER_DIR="$PROJECT_ROOT/aws-lambda-web-adapter"
LAYER_DIR="$ADAPTER_DIR/custom-lambda-layer"
EXT_DIR="$LAYER_DIR/extensions"
BIN_DIR="$ADAPTER_DIR/bin"

mkdir -p "$EXT_DIR"
mkdir -p "$BIN_DIR"

# === 1. PATCHED lib.rs ===
echo "📦 Writing patched lib.rs..."
cat << 'EOF' > "$ADAPTER_DIR/src/lib.rs"
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

// Example usage:
// let mut response = handle_request(...);
// sanitize_headers(&mut response);
EOF

# === 2. lambda.py ===
echo "🐍 Creating lambda.py..."
cat << 'EOF' > "$PROJECT_ROOT/lambda.py"
def handler(event, context):
    enableConnection = event["queryStringParameters"].get('connection', 'true')
    enableKeepAlive = event["queryStringParameters"].get('keep-alive', 'true')
    headers = {}
    if enableConnection == 'true': headers.update({"Connection": "keep-alive"})
    if enableKeepAlive == 'true': headers.update({"Keep-Alive": "timeout=72"})
    response = {
        "statusCode": 200,
        "headers": headers,
        "body": "Successful request to Lambda without web adapter (python)"
    }
    return response
EOF

# === 3. ec2.py ===
echo "🐍 Creating ec2.py with working Flask startup block..."
cat << 'EOF' > "$PROJECT_ROOT/ec2.py"
from flask import Flask, Response

app = Flask(__name__)

@app.route("/")
def root():
    return Response("Successful request to EC2 (python)",
                    headers={"Connection": "keep-alive", "Keep-Alive": "timeout=72"},
                    mimetype="text/plain")

if __name__ == "__main__":
    app.run(port=5000)
EOF

# === 4. test-local.sh ===
echo "🧪 Creating curl test script..."
cat << 'EOF' > "$PROJECT_ROOT/test-local.sh"
#!/bin/bash
set -e

# Replace with your ALB DNS name when testing in cloud
ALB_DNS="your-alb-dns-name-here"

curl -vsk --http2 https://$ALB_DNS/lambda
curl -vsk --http2 https://$ALB_DNS/ec2
EOF

chmod +x "$PROJECT_ROOT/test-local.sh"

echo ""
echo "✅ Local adapter setup complete."
echo "Next steps:"
echo "1. Run 'go build' to compile your adapter"
echo "2. Launch 'ec2.py' using: python3 ec2.py"
echo "3. Use adapter to forward requests to Flask and test header stripping"

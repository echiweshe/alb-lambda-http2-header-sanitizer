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

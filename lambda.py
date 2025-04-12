def handler(event, context):
    query_params = event.get("queryStringParameters", {})
    if query_params is None:
        query_params = {}
    connection = query_params.get("connection", "true")
    keepAlive = query_params.get("keep-alive", "true")
    
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

from flask import Flask, Response

app = Flask(__name__)

@app.route("/")
def root():
    return Response("Successful request to EC2 (python)",
                    headers={"Connection": "keep-alive", "Keep-Alive": "timeout=72"},
                    mimetype="text/plain")

if __name__ == "__main__":
    app.run(port=5000)

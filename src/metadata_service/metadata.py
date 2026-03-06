from flask import Flask, jsonify, request

app = Flask(__name__)

# Temporary Security Credentials matching the lab's scenario
MOCK_CREDS = {
    "Code": "Success",
    "LastUpdated": "2026-03-01T12:00:00Z",
    "Type": "AWS-HMAC",
    "AccessKeyId": "AKIAIOSFODNN7EXAMPLE",
    "SecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    "Token": "IQoJb3JpZ2luX2VjEBAaCXVzLWVhc3QtMSJGMEQCICH8m0...[simulated_long_token_string]...",
    "Expiration": "2026-03-02T12:00:00Z"
}

@app.route('/latest/meta-data/iam/security-credentials/', methods=['GET'])
def list_roles():
    """Returns the role name"""
    return "web-server-role", 200

@app.route('/latest/meta-data/iam/security-credentials/web-server-role', methods=['GET'])
def get_credentials():
    """Returns the temporary IAM credentials in JSON format"""
    return jsonify(MOCK_CREDS), 200

# Catch-all for basic metadata enumeration
@app.route('/latest/meta-data/', defaults={'path': ''}, methods=['GET'])
@app.route('/latest/meta-data/<path:path>', methods=['GET'])
def catch_all(path):
    if path == "":
        return "iam/\nhostname\nlocal-ipv4\npublic-keys/", 200
    elif path == "iam":
        return "security-credentials/", 200
    elif path == "iam/":
        return "security-credentials/", 200
    return "404 - Not Found", 404

if __name__ == '__main__':
    # Binds to localhost only;iptables will route 169.254.169.254 requests here.
    app.run(host='127.0.0.1', port=8080, debug=False)

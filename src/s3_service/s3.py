from flask import Flask, request, jsonify

app = Flask(__name__)

# The Access Key returned by the metadata service
REQUIRED_ACCESS_KEY = "AKIAIOSFODNN7EXAMPLE"

# Fake SSH Key for the 'monitor-admin' user
# (This will be generated and placed here by the setup script, or we can hardcode a placeholder
# that the setup script will replace). For the lab, let's serve files directly from a directory
# to make it robust.

import os
# We will serve the contents of a local directory /opt/s3_data/nebula-monitoring-backups
S3_DATA_DIR = "/opt/s3_data/nebula-monitoring-backups"

def authenticate(request):
    """
    Simulates checking the Authorization header or x-amz-security-token to verify the attacker
    is using the stolen IAM credentials.
    """
    # Simple check: the attacker might pass it in the Authorization header or simply as a token.
    # To keep it accessible for a CTF setup without requiring full AWS SigV4 signing validation,
    # we'll look for the AccessKeyId in the auth header or a custom header, or query param.
    
    auth_header = request.headers.get('Authorization', '')
    token_header = request.headers.get('X-Amz-Security-Token', '')
    auth_query = request.args.get('AWSAccessKeyId', '')
    
    if REQUIRED_ACCESS_KEY in auth_header or REQUIRED_ACCESS_KEY in token_header or REQUIRED_ACCESS_KEY in auth_query:
        return True
        
    return False

@app.route('/', methods=['GET'])
def mock_s3_root():
    return '''<?xml version="1.0" encoding="UTF-8"?>
<Error>
  <Code>AccessDenied</Code>
  <Message>Access Denied</Message>
  <RequestId>1A2B3C4D5E6F7G8</RequestId>
</Error>''', 403

@app.route('/nebula-monitoring-backups', methods=['GET'])
@app.route('/nebula-monitoring-backups/', methods=['GET'])
def list_bucket():
    if not authenticate(request):
        return mock_s3_root()
        
    # Simulate an S3 bucket listing
    return '''<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Name>nebula-monitoring-backups</Name>
    <Prefix></Prefix>
    <KeyCount>2</KeyCount>
    <IsTruncated>false</IsTruncated>
    <Contents>
        <Key>monitor-admin_id_rsa</Key>
        <LastModified>2026-02-14T09:33:14.000Z</LastModified>
        <ETag>"828ef3...a3"</ETag>
        <Size>2602</Size>
        <StorageClass>STANDARD</StorageClass>
    </Contents>
    <Contents>
        <Key>readme.txt</Key>
        <LastModified>2026-02-14T09:35:10.000Z</LastModified>
        <ETag>"1c4f5...b2"</ETag>
        <Size>125</Size>
        <StorageClass>STANDARD</StorageClass>
    </Contents>
</ListBucketResult>''', 200

@app.route('/nebula-monitoring-backups/<filename>', methods=['GET'])
def get_file(filename):
    if not authenticate(request):
        return mock_s3_root()
        
    # Protect against path traversal
    safe_filename = os.path.basename(filename)
    file_path = os.path.join(S3_DATA_DIR, safe_filename)
    
    if os.path.exists(file_path):
        with open(file_path, 'r') as f:
            return f.read(), 200
    else:
        return '''<?xml version="1.0" encoding="UTF-8"?>
<Error>
  <Code>NoSuchKey</Code>
  <Message>The specified key does not exist.</Message>
</Error>''', 404

if __name__ == '__main__':
    # Listen on localhost, S3 simulation port
    app.run(host='127.0.0.1', port=8081, debug=False)

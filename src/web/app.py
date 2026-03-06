import os
import psutil
import requests
from flask import Flask, render_template, request, jsonify

app = Flask(__name__)

@app.route('/')
def dashboard():
    # Gather mock or real system metrics for the dashboard
    cpu_usage = psutil.cpu_percent(interval=1)
    memory = psutil.virtual_memory()
    mem_usage = memory.percent
    
    # Mocking some service health data
    services = [
        {"name": "Database Service", "status": "Healthy", "uptime": "14d 2h"},
        {"name": "Message Broker", "status": "Healthy", "uptime": "8d 14h"},
        {"name": "Auth API", "status": "Warning", "uptime": "2d 5h"},
        {"name": "Backup Storage (Internal)", "status": "Healthy", "uptime": "45d 1h", "url": "http://127.0.0.1:8081"}
    ]
    
    return render_template('index.html', cpu=cpu_usage, mem=mem_usage, services=services)

@app.route('/check', methods=['GET'])
def check_url():
    """
    VULNERABLE ENDPOINT: Server-Side Request Forgery (SSRF)
    Takes a 'url' parameter and fetches it via the 'requests' library without any sanitization.
    """
    url = request.args.get('url')
    
    if not url:
        return jsonify({"error": "No URL provided", "status": "failed"}), 400
        
    try:
        # Intentionally vulnerable to SSRF
        response = requests.get(url, timeout=5)
        
        return jsonify({
            "status": "success",
            "url": url,
            "http_status": response.status_code,
            "content_preview": response.text[:8192] + "..." if len(response.text) > 8192 else response.text
        })
    except requests.exceptions.RequestException as e:
        return jsonify({
            "status": "error",
            "url": url,
            "error_message": str(e)
        }), 500

if __name__ == '__main__':
    # Run widely accessible, suitable for a lab VM
    app.run(host='0.0.0.0', port=80, debug=False)

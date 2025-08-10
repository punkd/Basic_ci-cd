# app.py - Secure Flask App
from flask import Flask
from flask_talisman import Talisman
import os

app = Flask(__name__)

# Security headers
Talisman(app, force_https=False)  # Set to True in production

@app.route('/')
def hello_world():
    return '<h1>Hello, Secure World!</h1>'

@app.route('/health')
def health_check():
    return {'status': 'healthy', 'version': '1.0.0'}, 200

if __name__ == '__main__':
    # Don't run debug in production
    app.run(host='0.0.0.0', port=int(os.environ.get('PORT', 5000)))
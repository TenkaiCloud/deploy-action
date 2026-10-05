"""A Tenkai that answers a Deploy Hook from a script, for the tests of deploy.sh.

Usage: mock_tenkai.py <port> <secret> <trigger status> <read answer>...

A read answer is "started", "succeeded", "failed", or an HTTP status such as "503". The last one repeats.
Each request is written to stdout as "<method> <path>".
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, secret, trigger_status, *reads = sys.argv[1:]
deployment_id = "0199b1c2-0000-7000-8000-000000000001"
labels = {"started": "Checking health", "succeeded": "Activated", "failed": "Failed"}
read_count = 0


class Tenkai(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def answer(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        print(f"{self.command} {self.path}", flush=True)

        if self.headers.get("Authorization") == f"Bearer {secret}":
            return True

        self.answer(401, {"error": "invalid_deploy_hook_secret", "message": "Send the secret of this Deploy Hook as a bearer token"})

        return False

    def do_POST(self):
        if not self.authorized():
            return

        if trigger_status != "202":
            self.answer(int(trigger_status), {"error": "mutation_in_progress", "message": "Another Deployment of this Web Application is in progress"})

            return

        url = f"http://127.0.0.1:{port}{self.path}/deployments/{deployment_id}"
        self.answer(202, {"deployment": {"id": deployment_id, "url": url}})

    def do_GET(self):
        global read_count

        if not self.authorized():
            return

        read = reads[min(read_count, len(reads) - 1)]
        read_count += 1

        if read.isdigit():
            self.answer(int(read), {"error": "unavailable", "message": "Tenkai is unavailable"})

            return

        details = "Image build failed" if read == "failed" else "Deployment started"
        self.answer(200, {"deployment": {"id": deployment_id, "statusName": read, "statusLabel": read.capitalize(), "phaseName": read, "phaseLabel": labels[read], "statusDetails": details}})


HTTPServer(("127.0.0.1", int(port)), Tenkai).serve_forever()

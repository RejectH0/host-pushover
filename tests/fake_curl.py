#!/usr/bin/env python3
"""A closed network stub: every request is answered from synthetic test files."""
import hashlib
import json
import os
import sys
import time
from pathlib import Path

args = sys.argv[1:]
root = Path(os.environ["HP_TEST_NETWORK"])
with (root / "requests.jsonl").open("a") as stream:
    stream.write(json.dumps(args) + "\n")


def option(name, default=None):
    return args[args.index(name) + 1] if name in args else default


def respond(code, body=b"", etag=""):
    if code != 304:
        Path(option("--output")).write_bytes(body)
    headers = option("--dump-header")
    if headers:
        Path(headers).write_text(f"HTTP/2 {code}\r\nETag: {etag}\r\n\r\n")
    print(code, end="")


fault_file = root / "fault"
fault = fault_file.read_text().strip() if fault_file.exists() else ""
if fault == "block":
    (root / "blocked").touch()
    while fault_file.read_text().strip() == "block":
        time.sleep(0.05)
if fault == "timeout":
    print("000", end="")
    sys.exit(28)
if fault == "dns-once":
    fault_file.unlink()
    print("000", end="")
    sys.exit(6)
if fault == "http-error":
    respond(503, b"service unavailable")
    sys.exit(0)

url = args[-1]
if url.startswith("https://api.pushover.net/1/"):
    respond(200, b'{"status":1,"request":"synthetic"}')
elif url.startswith("https://github.com/RejectH0/host-pushover/releases/"):
    if "/latest/" in url:
        version = (root / "latest").read_text().strip()
    else:
        version = url.split("/download/v", 1)[1].split("/", 1)[0]
    path = root / version / url.rsplit("/", 1)[1]
    if not path.is_file():
        respond(404, b"not found")
    else:
        body = path.read_bytes()
        etag = '"' + hashlib.sha256(body).hexdigest() + '"'
        if option("--header") == f"If-None-Match: {etag}" or fault == "force-304":
            respond(304, etag=etag)
        else:
            respond(200, body, etag)
else:
    raise SystemExit("Unexpected network destination; real network access is disabled")

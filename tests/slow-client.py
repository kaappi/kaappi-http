#!/usr/bin/env python3
"""Sends an HTTP request one byte at a time to prove a fiber-based server
doesn't stall other connections while this one trickles in. See
test-fiber-server.sh."""
import socket
import sys
import time

port = int(sys.argv[1])
delay = float(sys.argv[2])

body = b"trickle"
request = (
    b"POST /slow HTTP/1.1\r\n"
    b"Host: 127.0.0.1\r\n"
    b"Content-Length: " + str(len(body)).encode() + b"\r\n"
    b"Connection: close\r\n"
    b"\r\n"
)

sock = socket.create_connection(("127.0.0.1", port))
sock.sendall(request)
for byte in body:
    sock.sendall(bytes([byte]))
    time.sleep(delay)

chunks = []
while True:
    chunk = sock.recv(4096)
    if not chunk:
        break
    chunks.append(chunk)
sock.close()

response = b"".join(chunks)
body_start = response.find(b"\r\n\r\n")
print(response[body_start + 4:].decode() if body_start >= 0 else "")

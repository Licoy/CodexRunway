#!/usr/bin/env python3
"""Loopback-only HTTP CONNECT / SOCKS5 and TLS fixture; never forwards traffic."""

import argparse
import base64
import json
import os
from pathlib import Path
import signal
import socket
import socketserver
import ssl
import subprocess
import threading


USERNAME = b"fixture-user"
PASSWORD = b"fixture-password"
TARGET = "proxy-target.invalid"
MAX_HEADERS = 16 * 1024


class State:
    def __init__(self, directory):
        self.path = directory / "state.json"
        self.lock = threading.Lock()
        self.values = dict(
            proxy_connections=0, authentication_attempts=0,
            authentication_successes=0, tunneled_requests=0,
            target_received_proxy_authorization=False,
            target_received_proxy_credentials=False,
            authorities=[], errors=[])
        self.change()

    def change(self, **changes):
        with self.lock:
            for name, value in changes.items():
                if isinstance(value, bool):
                    self.values[name] |= value
                elif isinstance(value, list):
                    self.values[name].extend(value)
                else:
                    self.values[name] += value
            temporary = self.path.with_suffix(".tmp")
            temporary.write_text(json.dumps(self.values), encoding="utf-8")
            os.replace(temporary, self.path)


def read_exact(connection, length):
    result = bytearray()
    while len(result) < length:
        chunk = connection.recv(length - len(result))
        if not chunk:
            raise EOFError("connection closed")
        result.extend(chunk)
    return bytes(result)


def read_headers(connection):
    result = bytearray()
    while not result.endswith(b"\r\n\r\n"):
        if len(result) >= MAX_HEADERS:
            raise ValueError("headers exceed fixture limit")
        result.extend(read_exact(connection, 1))
    return bytes(result)


def record_target(state, headers):
    authorization = base64.b64encode(USERNAME + b":" + PASSWORD)
    state.change(**{
        "tunneled_requests": 1,
        "target_received_proxy_authorization": b"proxy-authorization:" in headers.lower(),
        "target_received_proxy_credentials": any(
            secret in headers for secret in (USERNAME, PASSWORD, authorization)),
    })


def serve_target(connection, server):
    with server.tls.wrap_socket(connection, server_side=True) as secured:
        headers = read_headers(secured)
        if not headers.startswith(b"GET /payload HTTP/1.1\r\n"):
            raise ValueError("unexpected target request")
        record_target(server.state, headers)
        body = json.dumps({"ok": True, "transport": server.mode}).encode()
        response = (b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                    + b"Content-Length: " + str(len(body)).encode()
                    + b"\r\nConnection: close\r\n\r\n" + body)
        secured.sendall(response)


def validate_authority(server, host, port):
    if (host, port) != (TARGET, 443):
        raise ValueError("unexpected proxy destination")
    server.state.change(authorities=[f"{host}:{port}"])


def http_connect(connection, server):
    headers = read_headers(connection)
    request_line, *header_lines = headers.split(b"\r\n")
    method, authority, version = request_line.decode("ascii").split(" ")
    if method != "CONNECT" or version != "HTTP/1.1":
        raise ValueError("expected HTTP CONNECT")
    host, port = authority.rsplit(":", 1)
    validate_authority(server, host, int(port))
    supplied = next((line.split(b":", 1)[1].strip() for line in header_lines
                     if line.lower().startswith(b"proxy-authorization:")), None)
    expected = b"Basic " + base64.b64encode(USERNAME + b":" + PASSWORD)
    if server.auth_required:
        if supplied is not None:
            server.state.change(authentication_attempts=1)
        if supplied != expected:
            connection.sendall(
                b"HTTP/1.1 407 Proxy Authentication Required\r\n"
                b'Proxy-Authenticate: Basic realm="CodexRunwayFixture"\r\n'
                b"Content-Length: 0\r\nConnection: close\r\n\r\n")
            return False
        server.state.change(authentication_successes=1)
    connection.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
    return True


def socks_connect(connection, server):
    version, count = read_exact(connection, 2)
    methods = read_exact(connection, count)
    selected = 2 if server.auth_required else 0
    if version != 5 or selected not in methods:
        connection.sendall(b"\x05\xff")
        return False
    connection.sendall(bytes((5, selected)))
    if selected == 2:
        version, count = read_exact(connection, 2)
        username = read_exact(connection, count)
        password = read_exact(connection, read_exact(connection, 1)[0])
        accepted = version == 1 and username == USERNAME and password == PASSWORD
        server.state.change(authentication_attempts=1, authentication_successes=int(accepted))
        connection.sendall(bytes((1, 0 if accepted else 1)))
        if not accepted:
            return False
    version, command, reserved, address_type = read_exact(connection, 4)
    if (version, command, reserved) != (5, 1, 0):
        raise ValueError("expected SOCKS5 CONNECT")
    if address_type == 3:
        host = read_exact(connection, read_exact(connection, 1)[0]).decode("ascii")
    elif address_type == 1:
        host = socket.inet_ntop(socket.AF_INET, read_exact(connection, 4))
    elif address_type == 4:
        host = socket.inet_ntop(socket.AF_INET6, read_exact(connection, 16))
    else:
        raise ValueError("unsupported SOCKS address type")
    port = int.from_bytes(read_exact(connection, 2), "big")
    validate_authority(server, host, port)
    connection.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
    return True


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        server = self.server
        server.state.change(proxy_connections=1)
        try:
            if (http_connect(self.request, server) if server.mode == "http"
                    else socks_connect(self.request, server)):
                serve_target(self.request, server)
        except (EOFError, ConnectionError, socket.timeout):
            # URLSession can close an authentication attempt or a cancelled request.
            pass
        except Exception as error:
            # Record only the exception type, never request headers or credentials.
            server.state.change(errors=[type(error).__name__])


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = False


def make_certificate(directory):
    config = directory / "openssl.cnf"
    config.write_text("""[req]
distinguished_name=subject
x509_extensions=extensions
prompt=no
[subject]
CN=proxy-target.invalid
[extensions]
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage=serverAuth
subjectAltName=DNS:proxy-target.invalid
""", encoding="utf-8")
    certificate = directory / "certificate.pem"
    private_key = directory / "private-key.pem"
    subprocess.run([
        "/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
        "-days", "2", "-config", str(config), "-keyout", str(private_key), "-out", str(certificate),
    ], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    private_key.chmod(0o600)
    (directory / "certificate.der").write_bytes(ssl.PEM_cert_to_DER_cert(certificate.read_text()))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.set_alpn_protocols(["http/1.1"])
    context.load_cert_chain(str(certificate), str(private_key))
    return context


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--mode", required=True, choices=("http", "socks5"))
    parser.add_argument("--authentication", action="store_true")
    options = parser.parse_args()
    tls = make_certificate(options.directory)
    state = State(options.directory)
    proxy = Server(("127.0.0.1", 0), Handler)
    unavailable = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    unavailable.bind(("127.0.0.1", 0))  # Reserved without listen: connections are refused.
    proxy.mode, proxy.tls, proxy.state = options.mode, tls, state
    proxy.auth_required = options.authentication
    threading.Thread(target=proxy.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
    metadata = dict(proxy_port=proxy.server_address[1],
                    unavailable_port=unavailable.getsockname()[1])
    temporary = options.directory / "ready.tmp"
    temporary.write_text(json.dumps(metadata), encoding="utf-8")
    os.replace(temporary, options.directory / "ready.json")
    stopped = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stopped.set())
    signal.signal(signal.SIGINT, lambda *_: stopped.set())
    try:
        while not stopped.wait(0.5):
            pass
    finally:
        proxy.shutdown()
        proxy.server_close()
        unavailable.close()


if __name__ == "__main__":
    main()

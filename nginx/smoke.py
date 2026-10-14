import http.client
import http.server
import json
import os
import socket
import socketserver
import ssl
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path


root = Path(__file__).resolve().parent.parent
stage = 'startup'
completed = []
receipts = []
receipt_lock = threading.Lock()
private_diagnostic = None


def mark(value):
    global stage
    stage = value
    completed.append(value)


def remember_diagnostic(contents):
    global private_diagnostic
    descriptor, private_diagnostic = tempfile.mkstemp(prefix='xunara-nginx-diagnostic-')
    with os.fdopen(descriptor, 'wb') as output:
        output.write(contents)


def run(arguments, **options):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **options)
    if result.returncode:
        remember_diagnostic(result.stdout + b'\n' + result.stderr)
        raise RuntimeError('isolated command failed; diagnostics withheld')
    return result.stdout


def render(environment, mode='https', part='full', valid=True):
    settings = {key: value for key, value in os.environ.items() if not key.startswith('XUNARA_')}
    settings.update(environment)
    result = subprocess.run(['python3', str(root / 'nginx/render.py'), '--mode', mode, '--part', part],
        env=settings, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    assert (result.returncode == 0) == valid
    if not valid:
        assert result.stdout == b''
        assert b'placeholder' not in result.stderr
    return result.stdout


class Backend(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


class Handler(http.server.BaseHTTPRequestHandler):
    def handle_request(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        with receipt_lock:
            receipts.append({'method': self.command, 'path': self.path,
                'host': self.headers.get('Host'), 'scheme': self.headers.get('X-Forwarded-Proto'), 'body': body})
        payload = json.dumps({'fixture': 'isolated-nginx-only', 'method': self.command}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(payload)

    do_GET = handle_request
    do_HEAD = handle_request
    do_POST = handle_request

    def log_message(self, *arguments):
        return


def free_port():
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        return listener.getsockname()[1]


def request(port, hostname, pathname, context=None, method='GET', headers=None, body=None):
    connection = http.client.HTTPSConnection('127.0.0.1', port, context=context, timeout=8) if context else \
        http.client.HTTPConnection('127.0.0.1', port, timeout=8)
    try:
        connection.request(method, pathname, body=body, headers={'Host': hostname, **(headers or {})})
        response = connection.getresponse()
        payload = response.read()
        return response.status, dict(response.getheaders()), payload
    finally:
        connection.close()


def generate_certificates(directory):
    directory.mkdir(mode=0o700)
    run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '1',
        '-subj', '/CN=Xunara isolated nginx test CA', '-keyout', str(directory / 'ca.key'),
        '-out', str(directory / 'ca.pem'), '-addext', 'basicConstraints=critical,CA:TRUE'])
    run(['openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-sha256',
        '-subj', '/CN=portal.test', '-keyout', str(directory / 'server.key'), '-out', str(directory / 'server.csr')])
    (directory / 'server.ext').write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n'
        'extendedKeyUsage=serverAuth\nsubjectAltName=DNS:portal.test,DNS:team.test,IP:127.0.0.1,IP:::1\n')
    run(['openssl', 'x509', '-req', '-in', str(directory / 'server.csr'), '-CA', str(directory / 'ca.pem'),
        '-CAkey', str(directory / 'ca.key'), '-set_serial', '1', '-days', '1', '-sha256',
        '-extfile', str(directory / 'server.ext'), '-out', str(directory / 'server.pem')])
    for private_file in ['ca.key', 'server.key']:
        (directory / private_file).chmod(0o600)
    (directory / 'invalid.key').write_text('isolated-invalid-key-fixture')
    (directory / 'invalid.key').chmod(0o600)


def main():
    global stage
    image = 'xunara-nginx-smoke:' + uuid.uuid4().hex
    container = 'xunara-nginx-smoke-' + uuid.uuid4().hex
    backend = Backend(('127.0.0.1', 0), Handler)
    threading.Thread(target=backend.serve_forever, daemon=True).start()
    container_started = False
    image_built = False
    try:
        with tempfile.TemporaryDirectory(prefix='xunara-nginx-smoke-') as temporary:
            work = Path(temporary)
            generate_certificates(work / 'tls')
            for surface in ['web', 'admin']:
                (work / surface).mkdir(mode=0o755)
                (work / surface / 'index.html').write_text('<main>isolated ' + surface + ' fixture</main>')
                (work / surface / 'index.html').chmod(0o644)
            port = free_port()
            environment = {'XUNARA_HTTP_PORT': str(port), 'XUNARA_UPSTREAM': '127.0.0.1:' + str(backend.server_port),
                'XUNARA_HTTPS_ORIGINS': ' '.join('https://' + hostname + ':' + str(port)
                    for hostname in ['portal.test', 'team.test', '127.0.0.1', '[::1]']),
                'XUNARA_TLS_CERTIFICATE': '/fixture/tls/server.pem', 'XUNARA_TLS_KEY': '/fixture/tls/server.key'}
            configuration = render(environment)
            (work / 'site.conf').write_bytes(configuration)
            assert render(environment, part='upgrade-map').strip() in configuration
            assert render(environment, part='upgrade-location').strip() in configuration
            plain = render({}, mode='http')
            assert b'listen 80;' in plain and b'ssl_certificate ' not in plain and b'@XUNARA_' not in plain
            default_tls = render({**environment, 'XUNARA_HTTP_PORT': '443',
                'XUNARA_HTTPS_ORIGINS': 'https://portal.test https://portal.test:443'})
            assert b'"portal.test" "https://portal.test"' in default_tls
            assert b'"portal.test:443" "https://portal.test"' in default_tls
            mark('production-renderer-http-https-default-ports-and-shared-fragments')

            invalid = [
                ('XUNARA_HTTP_PORT', '0'), ('XUNARA_HTTP_PORT', '65536'), ('XUNARA_HTTP_PORT', '80;bad'),
                ('XUNARA_UPSTREAM', '127.0.0.1:9090;bad'), ('XUNARA_UPSTREAM', '127.0.0.1'),
                ('XUNARA_UPSTREAM', 'http://127.0.0.1:9090'), ('XUNARA_UPSTREAM', 'host:abc'),
                ('XUNARA_HTTPS_ORIGINS', ''), ('XUNARA_HTTPS_ORIGINS', 'http://portal.test'),
                ('XUNARA_HTTPS_ORIGINS', 'https://user:placeholder@portal.test'),
                ('XUNARA_HTTPS_ORIGINS', 'https://portal.test/'), ('XUNARA_HTTPS_ORIGINS', 'https://portal.test?probe=1'),
                ('XUNARA_HTTPS_ORIGINS', 'https://portal.test#probe'), ('XUNARA_HTTPS_ORIGINS', 'https://portal.test:0'),
                ('XUNARA_HTTPS_ORIGINS', 'https://portal.test:65536'), ('XUNARA_HTTPS_ORIGINS', 'https://portal.test:'),
                ('XUNARA_HTTPS_ORIGINS', 'https://*.portal.test'), ('XUNARA_HTTPS_ORIGINS', 'https://-portal.test'),
                ('XUNARA_HTTPS_ORIGINS', 'https://portal.test;bad'), ('XUNARA_HTTPS_ORIGINS', 'https://portal.test\nssl_protocols;'),
                ('XUNARA_HTTPS_ORIGINS', ' '.join('https://portal.test' for index in range(129))),
                ('XUNARA_TLS_KEY', 'relative.key'), ('XUNARA_TLS_KEY', '/key;bad'), ('XUNARA_TLS_CERTIFICATE', '/cert\ninvalid'),
            ]
            for key, value in invalid:
                render({**environment, key: value}, valid=False)
            render(environment, mode='http', part='upgrade-map', valid=False)
            ipv6 = render({**environment, 'XUNARA_UPSTREAM': '[::1]:9190'})
            assert b'server [::1]:9190;' in ipv6
            mark('configuration-injection-and-origin-boundaries-fail-before-output')

            stage = 'isolated-nginx-image-build-and-runtime-start'
            run(['docker', 'build', '--quiet', '-t', image, '-'],
                input=b'FROM nginx:1.27-alpine\nRUN apk add --no-cache python3\n', timeout=240)
            image_built = True
            run(['docker', 'run', '--detach', '--name', container, '--network', 'host',
                '-v', str(work) + ':/fixture:ro', '-v', str(work / 'site.conf') + ':/etc/nginx/conf.d/default.conf:ro',
                '-v', str(work / 'web') + ':/srv/xunara/web:ro', '-v', str(work / 'admin') + ':/srv/xunara/admin:ro', image])
            container_started = True
            context = ssl.create_default_context(cafile=str(work / 'tls/ca.pem'))
            for attempt in range(60):
                try:
                    assert request(port, 'portal.test:' + str(port), '/login', context=context)[0] == 200
                    break
                except (OSError, AssertionError, http.client.HTTPException):
                    time.sleep(0.2)
            else:
                raise RuntimeError('isolated nginx not ready')
            mark('real-nginx-verified-tls-and-single-listener')

            with receipt_lock:
                receipts.clear()
            assert request(port, 'portal.test:' + str(port), '/t/alice/api/v2/network/addresses', context=context)[0] == 200
            with receipt_lock:
                assert len(receipts) == 1 and receipts[0]['path'] == '/t/alice/api/v2/network/addresses'
                assert receipts[0]['host'] == 'portal.test:' + str(port)
                receipts.clear()
            assert b'isolated web fixture' in request(port, 'portal.test:' + str(port), '/t/alice/dashboard', context=context)[2]
            with receipt_lock:
                assert not receipts
            mark('shared-console-api-keeps-canonical-port-and-ui-is-not-control-protocol')
            for pathname in ['/device/fixture/login', '/t/alice/register/fixture', '/t/alice/ssh/check/fixture']:
                assert request(port, 'portal.test:' + str(port), pathname, context=context)[0] == 200
                with receipt_lock:
                    assert len(receipts) == 1 and receipts[0]['path'] == pathname
                    receipts.clear()
            mark('shared-device-and-ssh-authorization-reach-core-not-spa')
            status, headers, _ = request(port, 'portal.test:' + str(port), '/t/alice/dashboard')
            assert status == 308 and headers['Location'] == 'https://portal.test:' + str(port) + '/t/alice/dashboard'
            assert request(port, 'portal.test:' + str(port), '/t/alice/api/v1/auth/session')[0] == 400

            for hostname in ['portal.test', 'team.test', '127.0.0.1', '[::1]', 'PORTAL.TEST']:
                for pathname in ['/', '/login', '/register', '/settings', '/devices/fixture-id', '/admin/login', '/api']:
                    status, headers, payload = request(port, hostname + ':' + str(port), pathname)
                    assert status == 308
                    assert headers['Location'] == 'https://' + hostname.lower() + ':' + str(port) + pathname
                    assert headers.get('Cache-Control') == 'no-store' and 'Set-Cookie' not in headers
            assert request(port, 'portal.test:' + str(port), '/login', method='HEAD')[0] == 308
            mark('same-port-http-navigation-keeps-explicit-tenant-ip-and-path')

            for hostname in ['untrusted.invalid:' + str(port), 'unknown.team.test:' + str(port), 'portal.test',
                    'portal.test:' + str(port + 1), 'portal.test.' + ':' + str(port)]:
                status, headers, payload = request(port, hostname, '/login')
                assert status == 400 and 'Location' not in headers and 'Set-Cookie' not in headers
            mark('unknown-host-never-falls-back-to-other-tenant')

            for pathname in ['/api/v1/account/export', '/api/v1/auth/login', '/key', '/ts2021', '/health', '/version',
                    '/oidc/provider/callback', '/oauth2/provider/callback', '/passkey/login', '/register/fixture-id',
                    '/setup', '/signup', '/logout', '/.well-known/xunara-test-ca.pem', '/login?probe=1', '/settings?return_to=/dns']:
                status, headers, payload = request(port, 'portal.test:' + str(port), pathname)
                assert status == 400 and 'Location' not in headers and 'Set-Cookie' not in headers
            for method in ['POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS']:
                status, headers, payload = request(port, 'portal.test:' + str(port), '/login', method=method)
                assert status == 400 and 'Location' not in headers
            mark('http-api-callback-query-and-write-methods-not-redirected')

            for headers in [{'Authorization': 'Bearer probe-placeholder'}, {'Cookie': 'probe=placeholder'},
                    {'X-CSRF-Token': 'probe-placeholder'}, {'Upgrade': 'tailscale-control-protocol'}, {'Content-Length': '1'}]:
                status, response_headers, payload = request(port, 'portal.test:' + str(port), '/login', headers=headers,
                    body=b'x' if 'Content-Length' in headers else None)
                assert status == 400 and 'Location' not in response_headers
            status, response_headers, payload = request(port, 'portal.test:' + str(port), '/login',
                headers={'Transfer-Encoding': 'chunked'}, body=b'0\r\n\r\n')
            assert status == 400 and 'Location' not in response_headers
            status, response_headers, payload = request(port, 'untrusted.invalid:' + str(port), '/login',
                headers={'X-Forwarded-Host': 'portal.test:' + str(port), 'X-Forwarded-Proto': 'https'})
            assert status == 400 and 'Location' not in response_headers
            with receipt_lock:
                assert receipts == []
            mark('no-plaintext-credential-body-upgrade-or-backend-request')

            for pathname in ['/change-password', '/t/team/change-password', '/reset-password', '/t/team/reset-password']:
                status, headers, payload = request(port, 'portal.test:' + str(port), pathname)
                assert status == 308 and headers['Location'] == 'https://portal.test:' + str(port) + pathname
                assert request(port, 'portal.test:' + str(port), pathname, context=context)[0] == 200
                assert request(port, 'portal.test:' + str(port), pathname, method='POST', body=b'probe')[0] == 400
            with receipt_lock:
                assert receipts == []
            mark('temporary-password-pages-navigate-only-no-plaintext-writes')

            assert request(port, 'team.test:' + str(port), '/admin/login', context=context)[0] == 200
            status, headers, payload = request(port, 'team.test:' + str(port), '/health', context=context)
            assert status == 200 and json.loads(payload)['fixture'] == 'isolated-nginx-only'
            assert request(port, 'portal.test:' + str(port), '/api/v1/account/export', context=context,
                method='POST', headers={'Content-Type': 'application/json'}, body=b'{"probe":true}')[0] == 200
            with receipt_lock:
                assert len(receipts) == 2 and all(receipt['scheme'] == 'https' for receipt in receipts)
                assert receipts[-1]['method'] == 'POST' and receipts[-1]['body'] == b'{"probe":true}'
                assert receipts[0]['host'] == 'team.test:' + str(port)
            mark('https-spa-admin-and-backend-method-forwarding-unchanged')

            result = run(['docker', 'run', '--rm', '--entrypoint', 'sh',
                '-v', str(work) + ':/fixture:ro', '-v', str(root) + ':/source:ro', image, '/source/nginx/installer-smoke.sh'])
            stages = result.decode().strip().splitlines()
            assert len(stages) == 8 and all(line.startswith('installer-') for line in stages)
            for value in stages:
                mark(value)
            print(json.dumps({'passed': True, 'stages': len(completed), 'production_changed': False,
                'plaintext_backend_requests': 0, 'reload_control': 'isolated-systemd-fixture', 'tls_verification': True}))
    except Exception:
        if container_started and not private_diagnostic:
            result = subprocess.run(['docker', 'logs', container], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            remember_diagnostic(result.stdout + b'\n' + result.stderr)
        raise
    finally:
        if container_started:
            subprocess.run(['docker', 'rm', '--force', container], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if image_built:
            subprocess.run(['docker', 'image', 'rm', image], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        backend.shutdown()
        backend.server_close()


if __name__ == '__main__':
    try:
        main()
    except Exception as failure:
        print(json.dumps({'passed': False, 'stage': stage, 'error_type': type(failure).__name__}))
        if private_diagnostic:
            print(json.dumps({'private_diagnostic_file': private_diagnostic}))
        raise SystemExit(1)

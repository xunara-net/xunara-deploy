import argparse
import ipaddress
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit


def port_number(value):
    if not re.fullmatch(r'[0-9]{1,5}', value) or not 1 <= int(value) <= 65535:
        raise ValueError('invalid listener or upstream port')
    return str(int(value))


def authority(value):
    try:
        parsed = urlsplit('https://' + value)
        if parsed.username is not None or parsed.password is not None or parsed.path or parsed.query or parsed.fragment:
            raise ValueError()
        hostname = parsed.hostname
        if not hostname or any(character not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.:[]' for character in value):
            raise ValueError()
        try:
            address = ipaddress.ip_address(hostname)
            hostname = '[' + str(address) + ']' if address.version == 6 else str(address)
        except ValueError:
            if len(hostname) > 253 or re.fullmatch(r'[0-9.]+', hostname):
                raise ValueError()
            if any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label) for label in hostname.split('.')):
                raise ValueError()
        explicit_port = parsed.port
        if value.endswith(':') or (explicit_port is not None and not 1 <= explicit_port <= 65535):
            raise ValueError()
        return hostname, explicit_port
    except ValueError:
        raise ValueError('invalid authority') from None


def origin_entries(value):
    origins = value.split()
    if not origins or len(origins) > 128:
        raise ValueError('provide a bounded HTTPS origin allowlist')
    entries = {}
    for origin in origins:
        if not origin.startswith('https://'):
            raise ValueError('HTTPS origins must use https')
        hostname, explicit_port = authority(origin[len('https://'):])
        port = explicit_port or 443
        target = 'https://' + hostname + (':' + str(port) if port != 443 else '')
        # 每个 Host 只映射回自己的网络；未知 Host 不回落到默认租户。
        keys = [hostname, hostname + ':443'] if port == 443 else [hostname + ':' + str(port)]
        for key in keys:
            entries[key] = target
    return entries


def http_upgrade_map(entries):
    lines = ['# 明文入口只接受显式 HTTPS origin；不使用请求输入拼接主机名。',
        'map_hash_bucket_size 512;', 'map $http_host $xunara_http_upgrade_origin {', '    default "";']
    lines.extend('    "' + key + '" "' + target + '";' for key, target in sorted(entries.items()))
    lines.extend(['}', '', 'map $uri $xunara_http_navigation {', '    default 0;', '    "/" 1;',
        '    "~^/(api/|register/)" 0;',
        '    "~^/t/[a-z0-9][a-z0-9-]{0,31}/(api/|register/)" 0;',
        '    "~^/t/[a-z0-9][a-z0-9-]{0,31}/(login|register|dashboard|devices|network|topology|permissions|members|authentication|dns|routes|api|security|plan|audit|settings|reset-password|change-password)(/.*)?$" 1;',
        '    "~^/(login|register|dashboard|devices|network|topology|permissions|members|dns|routes|api|security|plan|audit|settings|reset-password|change-password)(/.*)?$" 1;',
        '    "~^/admin(/.*)?$" 1;', '}'])
    return '\n'.join(lines)


def http_upgrade_location():
    lines = ['    # named location 保留原方法，不能把明文 POST 改写成 GET 后放行。',
        '    error_page 497 = @xunara_http_upgrade;', '    location @xunara_http_upgrade {',
        '        access_log off;', '        default_type text/plain;', '        charset utf-8;',
        '        add_header Cache-Control "no-store" always;']
    conditions = ['$xunara_http_upgrade_origin = ""', '$xunara_http_navigation = 0',
        '$request_method !~ "^(GET|HEAD)$"', '$args != ""', '$http_authorization != ""',
        '$http_cookie != ""', '$http_x_csrf_token != ""', '$http_upgrade != ""',
        '$http_content_length !~ "^(|0)$"', '$http_transfer_encoding != ""']
    for condition in conditions:
        lines.extend(['        if (' + condition + ') {',
            '            return 400 "请直接使用 HTTPS 访问；登录和 API 请求不接受明文。\\n";', '        }'])
    lines.extend(['        return 308 $xunara_http_upgrade_origin$request_uri;', '    }'])
    return '\n'.join(lines)


def certificate_path(value):
    if not value.startswith('/') or not re.fullmatch(r'/[a-zA-Z0-9_./-]+', value):
        raise ValueError('provide absolute certificate and key file paths')
    return value


def render(mode, part, environment):
    if part != 'full' and mode != 'https':
        raise ValueError('HTTP upgrade fragments require HTTPS mode')
    upgrade_map = ''
    tls_settings = ''
    if mode == 'https':
        entries = origin_entries(environment.get('XUNARA_HTTPS_ORIGINS', ''))
        upgrade_map = http_upgrade_map(entries)
        upgrade_location = http_upgrade_location()
        if part == 'upgrade-map':
            return upgrade_map + '\n'
        if part == 'upgrade-location':
            return upgrade_location + '\n'
        certificate = certificate_path(environment.get('XUNARA_TLS_CERTIFICATE', ''))
        key_file = certificate_path(environment.get('XUNARA_TLS_KEY', ''))
        tls_settings = '\n'.join(['    ssl_certificate ' + certificate + ';',
            '    ssl_certificate_key ' + key_file + ';', '    ssl_protocols TLSv1.2 TLSv1.3;',
            '    ssl_ciphers HIGH:!aNULL:!MD5;', '    ssl_session_tickets off;', '', upgrade_location])
    listener = port_number(environment.get('XUNARA_HTTP_PORT') or ('443' if mode == 'https' else '80'))
    hostname, upstream_port = authority(environment.get('XUNARA_UPSTREAM') or '127.0.0.1:9090')
    if upstream_port is None:
        raise ValueError('upstream requires an explicit port')
    upstream = hostname + ':' + port_number(str(upstream_port))
    template = Path(__file__).with_name('xunara.conf').read_text(encoding='utf-8')
    replacements = {'@XUNARA_HTTP_PORT_IPV4@': listener + (' ssl' if mode == 'https' else ''),
        '@XUNARA_HTTP_PORT@': listener + (' ssl' if mode == 'https' else ''),
        '@XUNARA_UPSTREAM@': upstream, '@XUNARA_HTTP_UPGRADE_MAP@': upgrade_map,
        '@XUNARA_TLS_SETTINGS@': tls_settings}
    for marker, value in replacements.items():
        template = template.replace(marker, value)
    if re.search(r'@XUNARA_[A-Z_]+@', template):
        raise ValueError('unrendered configuration marker')
    return '# Xunara managed nginx mode: ' + mode + '\n' + template


def main():
    parser = argparse.ArgumentParser(description='Render the single Xunara nginx site template')
    parser.add_argument('--mode', choices=['http', 'https'], required=True)
    parser.add_argument('--part', choices=['full', 'upgrade-map', 'upgrade-location'], default='full')
    arguments = parser.parse_args()
    try:
        result = render(arguments.mode, arguments.part, os.environ)
    except ValueError as failure:
        # 只输出固定校验原因，不回显带用户信息或查询参数的输入。
        sys.stderr.write('nginx configuration rejected: ' + str(failure) + '\n')
        return 2
    sys.stdout.buffer.write(result.encode('utf-8'))
    return 0


if __name__ == '__main__':
    sys.exit(main())

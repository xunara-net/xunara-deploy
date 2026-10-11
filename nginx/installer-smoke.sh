#!/bin/sh
set -eu

config=/etc/nginx/conf.d/xunara.conf
install -d -m 0755 /etc/nginx/conf.d /srv/xunara/web /usr/local/bin
cp /fixture/site.conf "$config"
chmod 0600 "$config"
original=$(sha256sum "$config" | cut -d ' ' -f 1)
printf 'original-static\n' >/srv/xunara/web/index.html
printf 'obsolete\n' >/srv/xunara/web/obsolete.txt
cat >/usr/local/bin/systemctl <<'SYSTEMCTL'
#!/bin/sh
case "$1" in
is-active) test ! -e /tmp/mock-inactive ;;
reload|start)
    printf '%s\n' "$1" >>/tmp/service-calls
    test ! -e /tmp/mock-reload-failure
    ;;
*) exit 2 ;;
esac
SYSTEMCTL
chmod 0755 /usr/local/bin/systemctl

assert_config() {
    test "$(sha256sum "$config" | cut -d ' ' -f 1)" = "$original"
    test "$(stat -L -c '%a' "$config")" = 600
}
expect_failure() {
    if "$@" >/tmp/install-output 2>&1; then
        echo 'installer unexpectedly succeeded' >&2
        exit 1
    fi
    assert_config
}

# 只替代 systemd 调度；renderer、文件操作与 nginx -t 都是真实实现。
XUNARA_HTTP_PORT=81 XUNARA_UPSTREAM=127.0.0.1:9 \
    sh /source/install-web.sh /fixture/web /fixture/admin >/tmp/install-output 2>&1
assert_config
cmp /fixture/web/index.html /srv/xunara/web/index.html
test ! -e /srv/xunara/web/obsolete.txt
grep -q 'mode: preserve' /tmp/install-output
echo 'installer-auto-preserves-custom-tls-and-cleans-obsolete-static'

expect_failure env XUNARA_NGINX_MODE=http XUNARA_HTTP_PORT='80;bad' \
    sh /source/install-web.sh /fixture/web
expect_failure env XUNARA_NGINX_MODE=https XUNARA_HTTPS_ORIGINS='https://portal.test/?probe=1' \
    sh /source/install-web.sh /fixture/web
cmp /fixture/web/index.html /srv/xunara/web/index.html
echo 'installer-invalid-input-does-not-change-config-or-static'

expect_failure env XUNARA_NGINX_MODE=https XUNARA_HTTP_PORT=443 \
    XUNARA_HTTPS_ORIGINS=https://portal.test XUNARA_TLS_CERTIFICATE=/fixture/tls/server.pem \
    XUNARA_TLS_KEY=/fixture/tls/invalid.key sh /source/install-web.sh /fixture/web
grep -q 'nginx validation failed' /tmp/install-output
cmp /fixture/web/index.html /srv/xunara/web/index.html
echo 'installer-real-nginx-validation-failure-restores-file-and-mode'

touch /tmp/mock-reload-failure
expect_failure env XUNARA_NGINX_MODE=https XUNARA_HTTP_PORT=443 \
    XUNARA_HTTPS_ORIGINS=https://portal.test XUNARA_TLS_CERTIFICATE=/fixture/tls/server.pem \
    XUNARA_TLS_KEY=/fixture/tls/server.key sh /source/install-web.sh /fixture/web
grep -q 'nginx reload failed' /tmp/install-output
grep -q 'frontend files may already' /tmp/install-output
test "$(tail -1 /tmp/service-calls)" = reload
find /tmp/mock-reload-failure -maxdepth 0 -delete
echo 'installer-reload-failure-is-not-success-and-never-restarts'

backup_count=0
for backup in /var/lib/xunara-deploy/nginx.*; do
    test -d "$backup"
    test "$(stat -c '%a' "$backup")" = 700
    test "$(stat -c '%a' "$backup/nginx.conf")" = 600
    test "$(sha256sum "$backup/nginx.conf" | cut -d ' ' -f 1)" = "$original"
    backup_count=$((backup_count + 1))
done
test "$backup_count" -ge 2
echo 'installer-private-original-config-backups'

mv "$config" /etc/nginx/original-xunara.conf
ln -s /etc/nginx/original-xunara.conf "$config"
sh /source/install-web.sh /fixture/web >/tmp/install-output 2>&1
test -L "$config"
assert_config
expect_failure env XUNARA_NGINX_MODE=http sh /source/install-web.sh /fixture/web
test -L "$config"
echo 'installer-preserves-symlink-and-refuses-implicit-target-replacement'

find "$config" -maxdepth 0 -type l -delete
expect_missing_failure() {
    if "$@" >/tmp/install-output 2>&1; then exit 1; fi
    test ! -e "$config"
}
expect_missing_failure env XUNARA_NGINX_MODE=preserve sh /source/install-web.sh /fixture/web
echo 'installer-missing-preserved-site-is-an-error'

touch /tmp/mock-inactive
sh /source/install-web.sh /fixture/web >/tmp/install-output 2>&1
grep -q '# Xunara managed nginx mode: http' "$config"
grep -q 'mode: http' /tmp/install-output
test "$(tail -1 /tmp/service-calls)" = start
echo 'installer-new-site-keeps-http-bootstrap-and-starts-only-if-inactive'

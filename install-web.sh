#!/bin/sh
# 安装 Xunara 静态前端（用户控制台 + 超级管理员后台）并写入 nginx 同源配置。
#
#   sudo ./install-web.sh <xunara-web/dist 目录> [xunara-admin/dist 目录]
#
# 只传 web 时跳过 admin；两个都传时 /admin/ 同源挂载超管后台。
# 静态文件安装到 /srv/xunara/{web,admin}，nginx 配置写到
# /etc/nginx/conf.d/xunara.conf，控制面 API 反代到 127.0.0.1:9090。
set -eu

WEB=${1:-}
if [ -z "$WEB" ] || [ ! -f "$WEB/index.html" ]; then
	echo "usage: $0 <xunara-web dist directory> [xunara-admin dist directory]" >&2
	exit 2
fi
ADMIN=${2:-}
if [ -n "$ADMIN" ] && [ ! -f "$ADMIN/index.html" ]; then
	echo "error: $ADMIN/index.html not found (run the frontend build first)" >&2
	exit 2
fi
if [ "$(id -u)" -ne 0 ]; then
	echo "error: run as root (writes /srv and /etc/nginx)" >&2
	exit 2
fi

here=$(cd "$(dirname "$0")" && pwd)
root=/srv/xunara

install -d -o root -g root -m 0755 "$root/web"
# --delete 保证旧构建里删掉的页面不会残留；dist 内容原样拷贝。
if command -v rsync >/dev/null 2>&1; then
	rsync -a --delete "$WEB"/ "$root/web"/
else
	find "$root/web" -mindepth 1 -delete 2>/dev/null || true
	cp -a "$WEB"/. "$root/web"/
fi

if [ -n "$ADMIN" ]; then
	install -d -o root -g root -m 0755 "$root/admin"
	if command -v rsync >/dev/null 2>&1; then
		rsync -a --delete "$ADMIN"/ "$root/admin"/
	else
		find "$root/admin" -mindepth 1 -delete 2>/dev/null || true
		cp -a "$ADMIN"/. "$root/admin"/
	fi
fi

install -d -o root -g root -m 0755 /etc/nginx/conf.d
install -o root -g root -m 0644 "$here/nginx/xunara.conf" /etc/nginx/conf.d/xunara.conf

if command -v nginx >/dev/null 2>&1; then
	nginx -t
	systemctl reload nginx 2>/dev/null || systemctl restart nginx || true
fi

echo "installed web:   $root/web"
if [ -n "$ADMIN" ]; then
	echo "installed admin: $root/admin"
fi
echo "nginx config: /etc/nginx/conf.d/xunara.conf"
echo "确保 80/443 已在防火墙放行；控制面 API 由 nginx 反代到 127.0.0.1:9090。"

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
config=/etc/nginx/conf.d/xunara.conf
mode=${XUNARA_NGINX_MODE:-auto}
case "$mode" in
auto)
	if [ -e "$config" ]; then mode=preserve; else mode=http; fi
	;;
preserve|http|https) ;;
*) echo "error: XUNARA_NGINX_MODE must be auto, preserve, http or https" >&2; exit 2 ;;
esac
if [ "$mode" = preserve ] && [ ! -f "$config" ]; then
	echo "error: preserve mode requires an existing nginx site" >&2
	exit 2
fi
if [ "$mode" != preserve ] && [ -L "$config" ]; then
	echo "error: a symlinked nginx site must use preserve mode" >&2
	exit 2
fi
if ! command -v nginx >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
	echo "error: install nginx and systemd before installing this site" >&2
	exit 2
fi
umask 077
work=$(mktemp -d)
config_changed=false
complete=false
backup=
published=
original_mode=
original_owner=
original_group=
restore_config() {
	if [ -n "$backup" ]; then
		published=$(mktemp "$config.restored.XXXXXX")
		install -o "$original_owner" -g "$original_group" -m "$original_mode" "$backup/nginx.conf" "$published"
		mv "$published" "$config"
	else
		if [ -f "$config" ]; then find "$config" -maxdepth 0 -type f -delete; fi
	fi
}
cleanup() {
	run_status=$?
	trap - 0
	if [ "$config_changed" = true ] && [ "$complete" = false ]; then
		restore_config
		echo "error: nginx configuration restored; frontend files may already have been updated" >&2
	fi
	if [ -n "$published" ] && [ -f "$published" ]; then find "$published" -maxdepth 0 -type f -delete; fi
	find "$work" -depth -delete
	exit "$run_status"
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$mode" != preserve ]; then
	if ! command -v python3 >/dev/null 2>&1; then
		echo "error: Python 3 is required to render nginx configuration" >&2
		exit 2
	fi
	python3 "$here/nginx/render.py" --mode "$mode" >"$work/candidate.conf"
	install -d -o root -g root -m 0755 /etc/nginx/conf.d
	if [ -f "$config" ]; then
		original_mode=$(stat -c '%a' "$config")
		original_owner=$(stat -c '%u' "$config")
		original_group=$(stat -c '%g' "$config")
		install -d -o root -g root -m 0700 /var/lib/xunara-deploy
		backup=$(mktemp -d /var/lib/xunara-deploy/nginx.XXXXXX)
		install -o root -g root -m 0600 "$config" "$backup/nginx.conf"
	fi
	published=$(mktemp "$config.new.XXXXXX")
	install -o root -g root -m 0644 "$work/candidate.conf" "$published"
	# 配置失败发生在静态复制之前；原 nginx worker 在重载前仍使用旧配置。
	config_changed=true
	mv "$published" "$config"
fi
if ! nginx -t >"$work/nginx-validation.log" 2>&1; then
	echo "error: nginx validation failed; diagnostics are not printed to avoid leaking configuration" >&2
	exit 1
fi

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

if systemctl is-active --quiet nginx; then
	if ! systemctl reload nginx >"$work/nginx-reload.log" 2>&1; then
		echo "error: nginx reload failed; do not assume the new configuration is active" >&2
		exit 1
	fi
else
	if ! systemctl start nginx >"$work/nginx-start.log" 2>&1; then
		echo "error: nginx start failed" >&2
		exit 1
	fi
fi
complete=true

echo "installed web:   $root/web"
if [ -n "$ADMIN" ]; then
	echo "installed admin: $root/admin"
fi
echo "nginx config: $config   mode: $mode"
if [ -n "$backup" ]; then echo "private nginx backup: $backup"; fi
echo "已有站点默认保留配置；公网登录和 API 请直接使用 HTTPS，中继端口保持独立。"

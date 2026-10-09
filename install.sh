#!/bin/sh
# Xunara 控制面安装 / 升级脚本（systemd 主机）。
#
#   sudo ./install.sh <xunarad 二进制> [其他二进制 ...]
#
# 可重复执行：脚本先备份旧二进制（回滚用），再安装服务账号、状态目录、单元
# 文件，最后 enable + restart。重复执行就是升级路径。
#
# 其他二进制按 basename 安装到同一前缀，常用的是：
#   xunara       管理 CLI（直接读写状态目录）
#   xunara-agent 原生客户端
#   xunara-relay DERP/STUN 中继
#
# 设置 XUNARA_DERP_HOST 后会一并部署 xunara-relay、生成自签名证书与 DERP map，
# 并把控制面接到该 map 上：
#
#   sudo XUNARA_DERP_HOST=derp.example.com ./install.sh \
#       ./xunarad ./xunara ./xunara-agent ./xunara-relay
#
# 可选环境变量：
#   XUNARA_SERVER_URL        控制面对外基址（默认 http://<主机名>:9090）
#   XUNARA_LISTEN            控制面监听地址（默认 0.0.0.0:9090；nginx 同源部署时
#                            改成 127.0.0.1:9190 并把公网端口交给 nginx）
#   XUNARA_GRPC_LISTEN       平台 gRPC 监听地址（默认 127.0.0.1:9191）
#   XUNARA_EXTRA_ARGS        追加到 ExecStart 的额外参数（如
#                            "-derp-map /var/lib/xunara-veil/derp.json -plans builtin"）
#   XUNARA_PASSKEY           true/false，WebAuthn 需要 https 或 localhost（默认 false）
#   XUNARA_PREFIX            安装前缀（默认 /opt/xunara）
#   XUNARA_STATE             控制面状态目录（默认 /var/lib/xunara）
#   XUNARA_DERP_PORT         中继公网端口（默认 9091）
#   XUNARA_CONTROL_ADDR     控制面地址（默认 127.0.0.1:9090）
#   XUNARA_STUN_PORT         开启 STUN 的 UDP 端口；不设置则不启用
#   XUNARA_RELAY_MANAGED     设为 1 时中继走托管注册（需要 /etc/xunara/xunarad.env
#                            里的 XUNARA_RELAY_ENROLL_TOKEN，且控制面已实现
#                            /api/relay/v1/enroll）
#   XUNARA_RELAY_CONTROL_URL 托管模式下控制面基址（默认 http://127.0.0.1:9090）
#   XUNARA_RELAY_NAME        控制台显示的中继名称（默认主机名）
#   XUNARA_RELAY_VISIBILITY  private | organization | public（默认 private）
set -eu

BIN=${1:-}
if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
	echo "usage: $0 <path to the xunarad binary> [extra binaries ...]" >&2
	exit 2
fi
if [ "$(id -u)" -ne 0 ]; then
	echo "error: run as root (the service is a system unit)" >&2
	exit 2
fi

here=$(cd "$(dirname "$0")" && pwd)
prefix=${XUNARA_PREFIX:-/opt/xunara}
state=${XUNARA_STATE:-/var/lib/xunara}
conf=/etc/xunara
relay_state=/var/lib/xunara-relay
relay_map=$relay_state/derp.json
derp_port=${XUNARA_DERP_PORT:-9091}
control_addr=${XUNARA_CONTROL_ADDR:-127.0.0.1:9090}
server_url=${XUNARA_SERVER_URL:-http://$(hostname -f 2>/dev/null || hostname):9090}
listen_addr=${XUNARA_LISTEN:-0.0.0.0:9090}
grpc_listen=${XUNARA_GRPC_LISTEN:-127.0.0.1:9191}
passkey=${XUNARA_PASSKEY:-false}
trusted_proxy=${XUNARA_TRUSTED_PROXY:-false}
org_config=${XUNARA_ORG_CONFIG:-}
managed_derp_map=${XUNARA_MANAGED_DERP_MAP:-}

case "$trusted_proxy" in
	true|false) ;;
	*) echo "error: XUNARA_TRUSTED_PROXY must be true or false" >&2; exit 2 ;;
esac
if [ -n "$org_config" ]; then
	[ -f "$org_config" ] || { echo "error: XUNARA_ORG_CONFIG must point to an existing file" >&2; exit 2; }
	tenant_args="-org-config $org_config -platform-state-dir $state"
else
	[ -z "$managed_derp_map" ] || { echo "error: XUNARA_MANAGED_DERP_MAP requires XUNARA_ORG_CONFIG" >&2; exit 2; }
	tenant_args="-server-url $server_url -state-dir $state -allow-local-login -passkey=$passkey"
fi

# sed 替换值里可能出现的分隔符与反斜杠，避免把单元文件写坏。
escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# 控制面必须用独立的非特权账号运行。
if ! id xunara >/dev/null 2>&1; then
	useradd --system --home-dir "$state" --shell /usr/sbin/nologin \
		--comment "Xunara control plane" xunara
fi

install -d -o root -g root -m 0755 "$prefix/bin"
install -d -o root -g root -m 0755 "$conf"
install -d -o xunara -g xunara -m 0700 "$state"

# 留一份正在运行的二进制，坏升级一次 mv 就能回滚。
if [ -f "$prefix/bin/xunarad" ]; then
	cp -p "$prefix/bin/xunarad" "$prefix/bin/xunarad.previous"
fi
if [ "$(readlink -f "$BIN")" != "$(readlink -f "$prefix/bin/xunarad" 2>/dev/null)" ]; then
	install -o root -g root -m 0755 "$BIN" "$prefix/bin/xunarad"
fi

shift
for extra in "$@"; do
	[ -f "$extra" ] || { echo "error: $extra is not a file" >&2; exit 2; }
	install -o root -g root -m 0755 "$extra" "$prefix/bin/$(basename "$extra")"
	echo "installed $prefix/bin/$(basename "$extra")"
done

# 中继可选：它需要一个客户端能访问到的公网端口，不是每个部署都有。
# 只有设置 XUNARA_DERP_HOST 时才渲染中继单元并把 DERP map 接进控制面。
relay_extra_args=""
if [ -n "${XUNARA_DERP_HOST:-}" ]; then
	if [ ! -x "$prefix/bin/xunara-relay" ]; then
		echo "error: XUNARA_DERP_HOST is set but $prefix/bin/xunara-relay is missing" >&2
		exit 2
	fi
	if [ -n "${XUNARA_STUN_PORT:-}" ]; then
		stun_args="-stun -stun-port $XUNARA_STUN_PORT"
	else
		stun_args="-stun=false"
	fi
	if [ "${XUNARA_RELAY_MANAGED:-0}" = "1" ]; then
		relay_mode_args="-control-url $(escape "${XUNARA_RELAY_CONTROL_URL:-http://127.0.0.1:9090}") -enroll-token-env XUNARA_RELAY_ENROLL_TOKEN"
		[ -n "${XUNARA_RELAY_NAME:-}" ] || XUNARA_RELAY_NAME=$(hostname -f 2>/dev/null || hostname)
		relay_mode_args="$relay_mode_args -relay-name $(escape "$XUNARA_RELAY_NAME") -relay-visibility ${XUNARA_RELAY_VISIBILITY:-private}"
	else
		if [ -n "$org_config" ]; then
			relay_mode_args="-verify-url http://$control_addr/api/relay/v1/admit"
		else
			relay_mode_args="-verify-url http://$control_addr/derp/admit"
		fi
	fi

	install -d -o xunara -g xunara -m 0700 "$relay_state"
	sed -e "s|@XUNARA_DERP_HOST@|$(escape "$XUNARA_DERP_HOST")|" \
		-e "s|@XUNARA_DERP_PORT@|$derp_port|" \
		-e "s|@XUNARA_RELAY_MODE_ARGS@|$(escape "$relay_mode_args")|" \
		-e "s|@XUNARA_STUN_ARGS@|$stun_args|" \
		"$here/systemd/xunara-relay.service" >/etc/systemd/system/xunara-relay.service
	chmod 0644 /etc/systemd/system/xunara-relay.service

	# 先离线生成证书、中继密钥与 DERP map，让控制面启动时一定拿得到 map。
	# 中继每次启动都会重写同一份 map；只有证书变化时指纹才会变。
	"$prefix/bin/xunara-relay" -listen "127.0.0.1:$derp_port" \
		-hostname "$XUNARA_DERP_HOST" -state-dir "$relay_state" \
		-cert-mode selfsigned -cert-dir "$relay_state/certs" \
		-derp-map-out "$relay_map" -derp-map-only
	chown -R xunara:xunara "$relay_state"

	if [ -n "$org_config" ]; then
		managed_derp_map=${managed_derp_map:-$relay_map}
	else
		relay_extra_args="-derp-map $relay_map"
	fi
fi

if [ -n "$managed_derp_map" ]; then
	tenant_args="$tenant_args -managed-derp-map $managed_derp_map"
fi

# 渲染控制面单元：监听地址、server-url、passkey、DERP map 与额外参数都在这里落定。
sed -e "s|@XUNARA_LISTEN@|$(escape "$listen_addr")|" \
	-e "s|@XUNARA_GRPC_LISTEN@|$(escape "$grpc_listen")|" \
	-e "s|@XUNARA_TENANT_ARGS@|$(escape "$tenant_args")|" \
	-e "s|@XUNARA_TRUSTED_PROXY@|$trusted_proxy|" \
	-e "s|@XUNARA_EXTRA_ARGS@|$(escape "$relay_extra_args ${XUNARA_EXTRA_ARGS:-}")|" \
	"$here/systemd/xunarad.service" >/etc/systemd/system/xunarad.service
chmod 0644 /etc/systemd/system/xunarad.service

if [ ! -f "$conf/xunarad.env" ]; then
	install -o root -g root -m 0600 "$here/env/xunarad.env.example" "$conf/xunarad.env"
	echo "wrote $conf/xunarad.env (mode 0600); add secrets there, not on the command line"
fi

systemctl daemon-reload
systemctl enable xunarad >/dev/null
systemctl restart xunarad
sleep 1
systemctl --no-pager --lines=0 status xunarad || true

# 中继绑定公网 DERP 端口，可能和控制面重启前的监听冲突，因此在控制面之后启动。
if [ -n "${XUNARA_DERP_HOST:-}" ]; then
	systemctl enable xunara-relay >/dev/null
	systemctl restart xunara-relay
	sleep 1
	systemctl --no-pager --lines=0 status xunara-relay || true
fi

echo
echo "installed $("$prefix/bin/xunarad" -version 2>/dev/null || echo "$BIN")"
echo "state: $state   config: $conf   unit: /etc/systemd/system/xunarad.service"
echo "listen: $listen_addr   server-url: $server_url"
if [ -n "${XUNARA_DERP_HOST:-}" ]; then
	echo "relay: $XUNARA_DERP_HOST:$derp_port   map: $relay_map (CertName 即 sha256-raw 指纹)"
fi

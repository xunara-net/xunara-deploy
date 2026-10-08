# xunara-deploy

Xunara 玄序的**部署仓库**：把所有组件装到一台主机（systemd）或一个 Compose
项目（Docker）里，不包含业务代码。

组件来自各自仓库：

| 组件 | 仓库 | 作用 |
|---|---|---|
| `xunarad` | [xunara-server](https://github.com/xunara-net/xunara-server) | Tailscale 兼容控制面（HTTP 9090 / 平台 gRPC 9191） |
| `xunara-relay` | [xunara-relay](https://github.com/xunara-net/xunara-relay) | DERP/STUN 中继（公网 9091、可选 UDP 3478） |
| `xunara-web` | [xunara-web](https://github.com/xunara-net/xunara-web) | 用户控制台（Vue 3），挂在 `/` |
| `xunara-admin` | [xunara-admin](https://github.com/xunara-net/xunara-admin) | 超级管理员后台（Vue 3），挂在 `/admin/` |

## 目录

```text
install.sh                      systemd 安装/升级：xunarad + 可选中继、CLI、客户端
install-web.sh                  安装两个前端 dist + nginx 同源配置
systemd/xunarad.service         控制面单元模板（install.sh 渲染 @…@ 占位符）
systemd/xunara-relay.service    中继单元模板（自签名证书 + DERP map 输出）
env/xunarad.env.example         /etc/xunara/xunarad.env 模板（secret 只放这里）
policy/policy.hujson.example    ACL 基线（默认 allow-all 会被安全页判为高危）
nginx/xunara.conf               同源站点：控制台 / 管理后台 / 控制面 API
docker/docker-compose.yml       控制面 + 中继 + 前端一体化编排
docker/Dockerfile.{server,relay,web}   从源码构建镜像
docker/xunara.env.example       Compose 环境文件模板
```

## 端口

| 端口 | 归属 | 暴露范围 |
|---|---|---|
| 80/443 | nginx（xunara-web / xunara-admin / 控制面 API 反代） | 公网 |
| 9090 | xunarad HTTP（nginx 的上游） | 仅本机/容器网络 |
| 9091 | xunara-relay DERP（客户端直连，**不要**经过 nginx） | 公网 |
| 3478/udp | STUN（可选，能提高直连成功率） | 公网 |
| 9191 | 平台 gRPC `PlatformService`（Bearer token，fail closed） | 仅本机/内网 |

## systemd 部署（单机）

```sh
# 1) 构建（版本号写进 /version 与控制台页脚）
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \
  -ldflags "-s -w -X github.com/xunara-net/xunara-server/control.Version=$(git describe --tags --always --dirty)" \
  -o /tmp/xunarad ./cmd/xunarad          # 在 xunara-server 仓库

# 2) 安装控制面
scp /tmp/xunarad root@host:/tmp/
ssh root@host 'XUNARA_SERVER_URL=http://host:9090 ./install.sh /tmp/xunarad'
```

`install.sh` 可重复执行，就是升级路径：先备份 `/opt/xunara/bin/xunarad.previous`，
再安装账号、状态目录、单元文件，最后 `enable --now`。

安装参数（都通过环境变量传入）：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `XUNARA_SERVER_URL` | `http://<主机名>:9090` | 对外基址，必须与浏览器访问地址一致 |
| `XUNARA_LISTEN` | `0.0.0.0:9090` | 控制面监听地址；nginx 同源部署时改成 `127.0.0.1:9190` |
| `XUNARA_GRPC_LISTEN` | `127.0.0.1:9191` | 平台 gRPC，保持内网 |
| `XUNARA_EXTRA_ARGS` | 空 | 追加到 ExecStart（如 `-derp-map … -plans builtin`） |
| `XUNARA_PASSKEY` | `false` | WebAuthn 需要 https 或 localhost |
| `XUNARA_DERP_HOST` | 空 | 设置后一并部署 `xunara-relay` 并接入 DERP map |

`install-web.sh` 同样接受 `XUNARA_HTTP_PORT`（默认 80）与 `XUNARA_UPSTREAM`
（默认 `127.0.0.1:9090`）；公网端口让给 nginx 时把上游指到控制面的实际端口。

### 首次初始化（必做）

全新部署**没有**管理员密码，第一次必须用服务写出的一次性令牌创建管理员：

```sh
sudo cat /var/lib/xunara/setup-token     # 32 字节随机，0600
```

浏览器打开 `http://<host>/setup`（或旧版控制台 `/console`），填入令牌、登录名与
密码（至少 12 个字符）。提交后令牌文件立即删除，账号成为 `owner`，审计记录
`admin.bootstrap`。

### 前端静态站点

```sh
# 在 xunara-web / xunara-admin 仓库各自 npm ci && npm run build
scp -r xunara-web/dist root@host:/tmp/web-dist
scp -r xunara-admin/dist root@host:/tmp/admin-dist
ssh root@host './install-web.sh /tmp/web-dist /tmp/admin-dist'
```

`install-web.sh` 把静态文件装到 `/srv/xunara/{web,admin}`，写入
`/etc/nginx/conf.d/xunara.conf` 并 `nginx -t`。控制面**必须**保持
`-listen 0.0.0.0:9090`（上游）且只对 nginx 可达。

会话 Cookie 是 HttpOnly + SameSite=Lax：**控制台必须和 API 同源**，不要把
`xunara-web` 单独部署到另一个域名。

## 中继（DERP）

没有 DERP 时客户端可以注册但 netmap 里 `LiveDERPs=0`，界面上表现为一直「连接中」。

```sh
# 在 xunara-relay 仓库构建 xunara-relay 后：
ssh root@host 'XUNARA_SERVER_URL=http://host:9090 \
  XUNARA_DERP_HOST=derp.example.com XUNARA_STUN_PORT=3478 \
  ./install.sh /tmp/xunarad /tmp/xunara-relay'
```

脚本会安装中继、渲染 `xunara-relay.service`、生成自签名证书与
`/var/lib/xunara-relay/derp.json`，并把 `-derp-map` 接进控制面单元。中继有两种模式：

- **独立模式（默认）**：`-verify-url http://127.0.0.1:9090/derp/admit`，准入问控制面，
  控制面不可达即拒绝放行。
- **托管模式**：`XUNARA_RELAY_MANAGED=1` 时用 `-control-url` + 一次性
  `XUNARA_RELAY_ENROLL_TOKEN` 注册并心跳。注册契约见 xunara-relay 仓库
  `docs/relay-protocol.md`。控制面已实现 `/api/relay/v1/*`（注册与心跳），中继配额由
  套餐的 `max_relays` 控制（内置 Free 1 / Pro 5 / Business 20）；独立模式仍然可用。

```sh
sudo journalctl -u xunara-relay -n 20   # 证书指纹打印在启动日志里
sudo cat /var/lib/xunara-relay/derp.json # CertName 即 sha256-raw 指纹
```

## Docker 部署

```sh
cd docker
cp xunara.env.example .env && chmod 600 .env   # 填 XUNARA_SERVER_URL / XUNARA_DERP_HOST / secret
docker compose up -d
```

默认使用 GHCR 镜像（`ghcr.io/xunara-net/*`）；从源码构建：

```sh
# xunara-server / xunara-relay 仓库内（把 Dockerfile 拷到仓库根的 docker/ 下，或直接用 -f）
docker build -f docker/Dockerfile.server -t ghcr.io/xunara-net/xunara-server:dev .
# 前端镜像在部署仓库构建（会从 GitHub 拉两个前端仓库并各自构建）
docker build -f docker/Dockerfile.web -t ghcr.io/xunara-net/xunara-web:dev .
```

## 升级与回滚

```sh
sudo systemctl stop xunarad
sudo tar czf /root/xunara-state-$(date +%F).tar.gz -C /var/lib xunara
sudo systemctl start xunarad
```

回滚二进制（状态格式不兼容时需要同时回滚状态备份）：

```sh
sudo install -m 0755 /opt/xunara/bin/xunarad.previous /opt/xunara/bin/xunarad
sudo systemctl restart xunarad
```

升级后确认：`systemctl status xunarad`、`journalctl -u xunarad -n 50`、
`curl -fsS http://127.0.0.1:9090/health`、浏览器打开 `/` 与 `/admin/`。

## 状态与备份

控制面状态全在 `/var/lib/xunara`：节点、用户、Session、预认证密钥、审计、策略
快照、Flux 密文。**备份该目录即可**（先 `systemctl stop xunarad` 保证一致）。
Session 存在状态目录而不是进程内存：重启不掉登录，也是多实例的前提。

中继状态在 `/var/lib/xunara-relay`：DERP 节点密钥、自签名证书与 `derp.json`。
丢失后需要重新下发指纹。

## 配置

改 `/etc/systemd/system/xunarad.service` 的 `ExecStart`（监听地址、`-server-url`、
策略、DERP、Reach/Flux 开关等）后：

```sh
sudo systemctl daemon-reload && sudo systemctl restart xunarad
```

Secret 只写 `/etc/xunara/xunarad.env`（OIDC client secret、平台 token、webhook
签名密钥、DNS token），由 `*-env` 标志读取，不出现在 `ps`。

## HTTPS 与通行密钥

WebAuthn 只在安全上下文可用（`https://` 或 `localhost`），因此默认
`-passkey=false`。拿到 TLS 后：把 `xunarad.service` 的 `-server-url` 改成
`https://域名`、`-passkey=true`，在 nginx 里启用 `nginx/xunara.conf` 末尾的 443
示例块，然后 `systemctl daemon-reload && systemctl restart xunarad`。WebAuthn 的
RP ID 是域名，**不要**用 IP 部署通行密钥。

## 排障

| 现象 | 原因与处理 |
|---|---|
| 首页 502 | nginx 上游不可达：`systemctl status xunarad`、`curl 127.0.0.1:9090/health` |
| 登录后立刻掉线 | 控制台与 API 不同源（Cookie SameSite=Lax），检查是否按 `nginx/xunara.conf` 同源托管 |
| 客户端一直「连接中」 | 没有可用 DERP：检查 `-derp-map` 是否接进控制面、9091 是否公网可达 |
| `/admin/` 404 | 未安装 admin dist，或未在 `install-web.sh` 传第二个参数 |
| 升级后二进制没变 | 运行中的二进制被 systemd 占用时 `install` 会写失败：先 `systemctl stop xunarad` |
| 平台 API 401 | 未配 `XUNARA_PLATFORM_ADMIN_TOKEN`，平台 API 默认 fail closed |

## 相关仓库

- [xunara-server](https://github.com/xunara-net/xunara-server) · [xunara-relay](https://github.com/xunara-net/xunara-relay)
- [xunara-web](https://github.com/xunara-net/xunara-web) · [xunara-admin](https://github.com/xunara-net/xunara-admin)
- [xunara-docs](https://github.com/xunara-net/xunara-docs)（规范、ADR、运维手册）

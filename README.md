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
| 80/443（或任意单端口，如 9090） | nginx（xunara-web / xunara-admin / 控制面 API 反代） | 公网 |
| 9090 → 9190 | xunarad HTTP（nginx 的**上游**，`XUNARA_LISTEN=127.0.0.1:9190`） | 仅本机/容器网络 |
| 9091 | xunara-relay DERP（客户端直连，**不要**经过 nginx） | 公网 |
| 3478/udp | STUN（可选，能提高直连成功率） | 公网 |
| 9191 | 平台 gRPC `PlatformService`（Bearer token，fail closed） | 仅本机/内网 |

只有 nginx 面对公网：它是唯一同时提供用户控制台、超管后台与控制面 API 的入口，
三个角色因此天然同源。控制面**不要**再监听公网地址。若主机只放行了 9090，
就让 nginx 监听 9090（`XUNARA_HTTP_PORT=9090 XUNARA_UPSTREAM=127.0.0.1:9190`），
控制面退到 9190。

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
| `XUNARA_EXTRA_ARGS` | 空 | 追加到 ExecStart（如 `-derp-map /var/lib/xunara-relay/derp.json`） |

控制面单元默认带 `-trusted-proxy`（控制面只经同机 nginx 暴露）：限流按
`X-Forwarded-For` 的**最后一跳**计，也就是 nginx 追加的真实客户端地址；直接把
控制面暴露到公网时必须去掉它，否则匿名调用者可以伪造该头绕过限流。
| `XUNARA_PASSKEY` | `false` | WebAuthn 需要 https 或 localhost |
| `XUNARA_DERP_HOST` | 空 | 设置后一并部署 `xunara-relay` 并接入 DERP map |

`install-web.sh` 同样接受 `XUNARA_HTTP_PORT`（默认 80，公网端口让给 nginx 时改成
对外端口，如 9090）与 `XUNARA_UPSTREAM`（默认 `127.0.0.1:9090`，指向控制面的实际
监听地址）。两个值必须与 `XUNARA_LISTEN` 对得上：

```sh
# 单端口同源部署（主机只放行 9090）：控制面退到 9190，nginx 占 9090
ssh root@host 'XUNARA_LISTEN=127.0.0.1:9190 XUNARA_GRPC_LISTEN=127.0.0.1:9191 \
  XUNARA_SERVER_URL=http://host:9090 ./install.sh /tmp/xunarad'
ssh root@host 'XUNARA_HTTP_PORT=9090 XUNARA_UPSTREAM=127.0.0.1:9190 \
  ./install-web.sh /tmp/web-dist /tmp/admin-dist'
```

同源站点里 `/` 是用户控制台（未登录会跳到 `/login`），`/admin/` 是超管后台，
控制面 API 与客户端协议端点按前缀反代。`/login` 的 GET 交给控制台 SPA，POST 仍然
是控制面的旧版表单登录。

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
`/etc/nginx/conf.d/xunara.conf` 并 `nginx -t`。控制面只对 nginx 可达（`127.0.0.1`），
公网端口归 nginx。

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

## 套餐（可选）

`-plans` 为空时**没有**任何套餐配额，这是自托管的默认：所有租户无限设备、无限成员。
只有真的要卖套餐（Free / Pro / Business 或自己的 JSON 目录）时才加：

```sh
XUNARA_EXTRA_ARGS="-plans builtin"   # 或 -plans /etc/xunara/plans.json
```

内置目录：Free 10 设备 / 1 成员，Pro 50 / 5，Business 200 / 50。配额在
Xunara 控制面强制（例如第 11 台设备返回 `DEVICE_LIMIT_REACHED`），Headscale/Tailscale
客户端协议不参与商业规则。租户套餐用超管后台或 `PATCH
/api/platform/v1/organizations/{org}/plan` 调整。

## 多租户与自助注册

默认注册策略是 `invite`：由管理员发放一次性邀请码，注册出来的是**本租户的成员**。
用 `-registration` 调整：

```sh
XUNARA_EXTRA_ARGS="-registration open"    # 任何人可注册（单租户部署注册为 member）
XUNARA_EXTRA_ARGS="-registration closed"  # 只允许管理员建号
```

托管（一账号一 tailnet）需要三件事一起配：`-org-config` 里的 `self_service`、
`-platform-state-dir`（托管组织与地址池记录）与 `-plans`（新租户必须落在套餐上）。
入口站自身必须 `registration: "open"`，否则 xunarad 启动即报错：

```json
{
  "organizations": [
    {"id": "portal", "name": "Xunara Cloud", "domains": ["app.example.com"],
     "server_url": "https://app.example.com", "state_dir": "/var/lib/xunara/portal",
     "registration": "open"}
  ],
  "self_service": {
    "site": "portal",
    "domain_suffix": "tailnet.example.com",
    "scheme": "https",
    "port": "9090",
    "cookie_domain": "example.com",
    "plan": "free"
  }
}
```

```sh
XUNARA_EXTRA_ARGS="-org-config /etc/xunara/orgs.json \
  -platform-state-dir /var/lib/xunara/platform -plans builtin"
```

要求与行为：

- `app.example.com` 需要解析到 nginx；`*.tailnet.example.com` 泛解析到同一地址。
  `nginx/xunara.conf` 用 `server_name _`，任意租户域名都会被正确转发。
- 访客在入口站注册后自动成为新租户 `<login>.tailnet.example.com` 的 owner；
  配置 `cookie_domain` 时浏览器带着会话直接进入控制台，否则到新域名再登录一次。
- 新租户的状态目录由平台在 `-platform-state-dir/orgs/` 下自动创建，备份/迁移
  必须连同该目录一起；每个租户有自己的 Noise 密钥与 SQLite。
- 入口站限流 5 租户/小时/IP；删除租户仍走平台 API（`DELETE
  /api/platform/v1/organizations/{org}`）。
- 只开放非标准端口（例如 nginx 独占 9090）时，`self_service.port` 必须写成该
  公网端口，否则新租户拿到的 URL 会指向 80/443。

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
| 平台 API 401 / `/admin/` 登录失败 | 未配 `XUNARA_PLATFORM_ADMIN_TOKEN`，平台 API 默认 fail closed。写入 `/etc/xunara/xunarad.env`（0600）后 `systemctl restart xunarad` |
| `/admin/` 500 | nginx 把 `/admin/index.html` 解析到了用户控制台的 root：确认 `location /admin/` 里有 `root /srv/xunara;` |
| 注册报 `USER_LIMIT_REACHED` | 套餐成员配额：内置 Free 的 `max_users=1`（单租户等于「只有第一个用户」）。用平台 API/超管后台把租户调到 Pro/Business，或对自托管部署**不要**加 `-plans`（空值即关闭套餐配额） |
| 首页一直是旧版控制台样式 | 浏览器命中了控制面内嵌的 `/console`；正式站点请用 `/`（用户控制台）与 `/admin/`（超管后台） |

## 相关仓库

- [xunara-server](https://github.com/xunara-net/xunara-server) · [xunara-relay](https://github.com/xunara-net/xunara-relay)
- [xunara-web](https://github.com/xunara-net/xunara-web) · [xunara-admin](https://github.com/xunara-net/xunara-admin)
- [xunara-docs](https://github.com/xunara-net/xunara-docs)（规范、ADR、运维手册）

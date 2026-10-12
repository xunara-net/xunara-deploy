# nginx 同源站点配置

`xunara.conf` 由 `install-web.sh` 安装到 `/etc/nginx/conf.d/xunara.conf`，
把用户控制台、超管后台与控制面 API 放在同一个源上（会话 Cookie 依赖同源）。

- `/` → `/srv/xunara/web`（xunara-web）
- `/admin/` → `/srv/xunara/admin`（xunara-admin）
- `/api/*`、`/key`、`/ts2021`、`/derp/*`、`/.well-known/*`、`/console` 等 → `127.0.0.1:9090`
- 9091 DERP 端口必须由中继直接对外，**不要**放进 nginx 反代（证书指纹固定会失效）

GET `/login` 属于用户 SPA；不要为了第三方登录按查询参数增加代理例外。
升级后的提供方按钮通过 `/api/v1/auth/start` 开始浏览器认证，仍由既有 `/api/*`
反代规则处理，OIDC 回调走 `/oidc/*`，原生 OAuth2 回调走 `/oauth2/*`。
Web 保留旧提供方书签的薄转接。应先升级服务端与 nginx 再升级 Web，回调仍须在
提供方精确登记；不要从请求输入生成。systemd 和 Docker 配置均保持 GET `/login`
为 SPA，兼容 POST `/login` 转后端，不按查询参数选择旧模板。

OAuth2 提供方与密钥引用以[服务端配置说明](https://github.com/xunara-net/xunara-server/blob/main/docs/oauth2-login.md)
为准；不要把 app secret 放入 nginx、URL 或进程参数。仅更新反代不会自动启用任何
真实第三方提供方，仍需应用登记、HTTPS、client ID 和私密密钥引用。

仅放行一个公网端口时，可将该端口直接切换为 HTTPS，并让安全的旧 HTTP 页面导航
308 跳转到同租户同路径。两种入口共用同一套页面、服务和数据库，但不是两套登录。
自签测试 CA、权限、客户端信任、组织 URL 同步及回滚边界见
[自签 HTTPS 测试部署](self-signed-https.md)。中继 9091 的 TLS 与指纹不随站点证书修改。

已经启用 HTTPS 的站点改用受信任证书，按
[正式证书安装与轮换](production-certificate.md)检查完整链、域名与密钥，再只
reload nginx。单域证书不覆盖其他租户；SNI、暂存私钥清理和续期边界必须分别验收。

## 单一渲染器与升级保护

`render.py` 是 systemd 站点的唯一生产渲染实现；`install-web.sh` 和 CI 都调用它。
默认 `auto` 已有站点就保留，避免前端升级覆盖 TLS、多租户、自定义 CA 下载等配置。
新站才采用原 HTTP 引导模式；它不是安全的公网登录部署。显式 `http` / `https`
重新渲染会替换完整站点；证书签发、控制面 URL 与第三方回调迁移仍需单独完成。
Docker 原模板保持不变，本切片不提供完整 Compose TLS 安装或证书自动续期。

HTTPS 模式使用精确 origin allowlist：每个允许 Host 只跳回自己的固定 origin；
未知 Host 不回落到主域或其他租户，不使用未经约束的转发头。标准 443 接受域名
和域名加 `:443`，其他端口必须精确匹配；允许明确 IPv4 / IPv6 origin。通配 SAN
并不意味着 HTTP 接受任意子域，新租户需要明确加入 allowlist 才有 HTTP 导航。

497 进入 named location，保留原始方法；仅无 query GET/HEAD 页面路由允许跳转。
API、协议、设备批准、认证回调、初始化等后端路径均拒绝；认证头、Cookie、CSRF、
Upgrade、非零 Content-Length 和 Transfer-Encoding 也拒绝。返回固定 400、无
Location / Set-Cookie，入口不记录访问日志，不发明文请求到 Core。
正常 HTTPS 的 SPA、API 方法、OAuth 回调及 TS2021 Upgrade 原样保留。
已经发到 HTTP 的内容无法撤回，因此绝不能用跳转代替正确的 HTTPS 客户端地址。

已有自定义 TLS 站点可只生成入口片段。前置条件：Python 3、已有有效 TLS 站点，
执行目录为 `xunara-deploy`；以下在权限为 0700 的临时目录输出文件，不直接覆盖生产：

```sh
umask 077
work="$(mktemp -d)"
export XUNARA_HTTPS_ORIGINS='https://xunara.example.test:9090 https://team.xunara.example.test:9090'
python3 nginx/render.py --mode https --part upgrade-map > "$work/upgrade-map.conf"
python3 nginx/render.py --mode https --part upgrade-location > "$work/upgrade-location.conf"
```

备份原配置后，把 map 片段放在 `http` 上下文**所有 map 之前**，且全局只能有一份
`map_hash_bucket_size`；替换旧重定向 map，不残留未知 Host fallback。在相应 TLS
server 中用 location 片段替换旧 `error_page 497`，不复制第二套反代规则。多站点
必须合并全局 map 与 origin 列表，不能把片段重复 include。维护窗口 `nginx -t`
成功才 reload；检查真实请求后才算生效，失败仅恢复 nginx，不覆盖正在使用的数据库。

## 验证

前置条件：Python 3、OpenSSL、Docker，能取得 `nginx:1.27-alpine` 与 Alpine Python
包。执行目录为 `xunara-deploy`，运行 `python3 nginx/smoke.py`：16 阶段验证真实
nginx 的同端口 HTTP/HTTPS、TLS 验证、租户/Host/方法/凭据边界和安装器失败恢复。
隔离容器内仅 systemd 调度用显式 fixture，其余 renderer、文件复制与 `nginx -t`
都是真实实现；不修改生产文件或使用真实账户。重载 fixture 不等于生产 systemd 验收。

成员邀请同样走 `/api/*` 同源反代。新代码只展示一次，注册地址与代码分开发送，
不添加带代码链接或把认证凭据拼进 nginx 访问日志。决策与验收范围以服务端
[ADR-0014](https://github.com/xunara-net/xunara-server/blob/main/docs/adr/ADR-0014-browser-auth-and-member-invitations.md) 为准。

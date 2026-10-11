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

仅放行一个公网端口时，可将该端口直接切换为 HTTPS，并让旧 HTTP 链接 308 跳转。
自签测试 CA、权限、客户端信任、组织 URL 同步及回滚边界见
[自签 HTTPS 测试部署](self-signed-https.md)。中继 9091 的 TLS 与指纹不随站点证书修改。

成员邀请同样走 `/api/*` 同源反代。新代码只展示一次，注册地址与代码分开发送，
不添加带代码链接或把认证凭据拼进 nginx 访问日志。决策与验收范围以服务端
[ADR-0014](https://github.com/xunara-net/xunara-server/blob/main/docs/adr/ADR-0014-browser-auth-and-member-invitations.md) 为准。

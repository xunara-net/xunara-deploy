# nginx 同源站点配置

`xunara.conf` 由 `install-web.sh` 安装到 `/etc/nginx/conf.d/xunara.conf`，
把用户控制台、超管后台与控制面 API 放在同一个源上（会话 Cookie 依赖同源）。

- `/` → `/srv/xunara/web`（xunara-web）
- `/admin/` → `/srv/xunara/admin`（xunara-admin）
- `/api/*`、`/key`、`/ts2021`、`/derp/*`、`/.well-known/*`、`/console` 等 → `127.0.0.1:9090`
- 9091 DERP 端口必须由中继直接对外，**不要**放进 nginx 反代（证书指纹固定会失效）

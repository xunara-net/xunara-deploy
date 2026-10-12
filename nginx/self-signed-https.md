# 自签 HTTPS 测试部署

本说明用于测试环境，不把私有测试 CA 当作公网受信任证书。用户控制台、超级管理后台和控制面 API 仍在同一个源；9091 的 DERP 保持直连，不更换中继的证书或指纹。

已有 HTTPS 站点取得正式证书后，使用[正式证书轮换手册](production-certificate.md)，
不重复迁移 URL 或重建业务数据；仅被新证书覆盖的域名移除测试 CA 下载入口。

## 迁移前检查

- 记录服务端 `/version`、前端构建提交、有效组织、数据库版本、设备数、套餐、网段和中继进程。
- 在 root 私有目录备份二进制、nginx、组织配置、环境文件、前端入口和全部状态。数据库备份必须在暂停业务写入、停止控制面并排空旧 nginx worker 后执行。
- 仅更新控制面 URL 的 scheme，不重新初始化账户、不删除重建租户、不重新分配网段或设备 IP。现有 managed 组织的 `server_url` 是不可变业务字段，不能用普通更新 API 猜测替代；部署迁移须离线、限定旧值、逐表检查并保留回滚记录。
- 多租户同时检查静态组织、managed 组织、自助开通的 `scheme` 和已有 IdP 的精确回调；HTTPS 后才会签发 `Secure` Cookie。只给 nginx 加证书而不改控制面 URL 不算迁移完成。

## 生成私有测试 CA 与服务证书

前置条件：Linux、OpenSSL 3、root 权限。执行目录为 `xunara-deploy`；先将示例域名及 SAN 替换为实际域名、租户域名或受控单层通配域名。不要向浏览器公开私钥。

```sh
sudo -i
umask 077
tls_dir="/etc/xunara/tls/test-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 700 "$tls_dir"
openssl req -x509 -newkey rsa:3072 -noenc -sha256 -days 30 \
  -subj '/CN=Xunara Test Root CA' \
  -keyout "$tls_dir/root-ca.key" -out "$tls_dir/root-ca.pem" \
  -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' -addext 'subjectKeyIdentifier=hash'
openssl req -new -newkey rsa:3072 -noenc -sha256 \
  -subj '/CN=xunara.example.test' \
  -keyout "$tls_dir/server.key" -out "$tls_dir/server.csr"
cat > "$tls_dir/server.ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
subjectAltName=DNS:xunara.example.test,DNS:*.xunara.example.test,IP:127.0.0.1
EOF
openssl x509 -req -in "$tls_dir/server.csr" \
  -CA "$tls_dir/root-ca.pem" -CAkey "$tls_dir/root-ca.key" \
  -set_serial "0x$(openssl rand -hex 16)" -days 29 -sha256 \
  -extfile "$tls_dir/server.ext" -out "$tls_dir/server.pem"
cat "$tls_dir/server.pem" "$tls_dir/root-ca.pem" > "$tls_dir/server-chain.pem"
chmod 600 "$tls_dir/root-ca.key" "$tls_dir/server.key"
openssl verify -CAfile "$tls_dir/root-ca.pem" "$tls_dir/server.pem"
openssl x509 -in "$tls_dir/root-ca.pem" -noout -sha256 -fingerprint
```

通过可信 SSH 或运维记录发布 CA 指纹。首次下载证书不能仅凭下载地址信任它，应先核对该指纹。测试 CA 30 天、服务证书 29 天有效；到期前重新签发并更新客户端信任，或者改用受信任的正式证书。

## 同一公网端口改为 HTTPS

以单租户公网 9090、上游 `127.0.0.1:9190` 为例，修改已渲染的 nginx server 块；以下是配置片段，不是另一份不完整的站点模板。证书路径替换为上一步的真实目录，原有 SPA、API、OAuth2/OIDC 和 TS2021 locations 均保留。

```nginx
listen 9090 ssl;
listen [::]:9090 ssl;
ssl_certificate /etc/xunara/tls/test-TIMESTAMP/server-chain.pem;
ssl_certificate_key /etc/xunara/tls/test-TIMESTAMP/server.key;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers HIGH:!aNULL:!MD5;
ssl_session_tickets off;
```

HTTP 升级规则不再手写另一份宽泛 `error_page 497 =308`。按
[单一渲染器手册](README.md#单一渲染器与升级保护)生成 map / named location 片段，
精确登记主域及每个租户 origin，放在正确上下文后替换旧规则。未知 Host 返回 400，
不回到默认租户；只允许无 query、无凭据和无请求体的 GET/HEAD 页面导航。API、
回调、机器协议和写方法不跳转、不发后端。所有登录和带凭据请求直接使用 HTTPS；
重定向无法保护已在 HTTP 发送的密码或令牌。

如开放 CA 下载，仅复制公有的 `root-ca.pem`，公开目录须显式 `0755`、证书 `0644`；Python 的 `mkdir(mode=0o755)` 仍受 `umask 077` 影响，应再显式 `chmod`，否则 nginx worker 无法遍历该目录。通过精确 location 提供 `/.well-known/xunara-test-ca.pem`，不要开放整个 `/etc/xunara/tls`。测试站点不启用 HSTS。

在维护窗口执行 `nginx -t`、重启控制面、重载 nginx，确认 API、TLS 和原始数据后再开放业务。开放后可能已有新写入，回退代码或配置时**不得直接覆盖旧数据库快照**。私有备份恢复也要保留原 uid/gid，否则控制面运行用户可能无法读取状态。

`install-web.sh` 默认 `auto` 已有站点保留配置，新站才用 HTTP 引导模板；也可以
显式 `preserve`。仅在确实要重新生成整个站点时指定 `https`，不要用显式 `http`
降级原 TLS。已有 CA 下载等自定义 location 时只更新入口片段，保留其他配置。

## 验收与客户端

前置条件：已经按可信指纹取得测试 CA，实际站点域名在 SAN 内。客户端执行目录不限；以下替换域名和 CA 文件路径后执行，正常验证证书，不使用全局跳过 TLS 校验。

```sh
curl --cacert /path/to/xunara-test-ca.pem --fail https://xunara.example.test:9090/health
curl --cacert /path/to/xunara-test-ca.pem --fail https://xunara.example.test:9090/version
openssl s_client -connect xunara.example.test:9090 -servername xunara.example.test \
  -CAfile /path/to/xunara-test-ca.pem -verify_return_error </dev/null
```

浏览器和官方客户端初次使用会遇到未受信任 CA；在测试设备上导入并信任该公有 CA，再使用 HTTPS 控制面地址。浏览器临时允许访问不等于给客户端安装了 CA。客户端的控制面 URL 也须改为 HTTPS，不能声称已有 HTTP 客户端会无感切换。不要在真实第三方提供方未登记应用和回调、未配置私密密钥时展示可用登录入口。

初次完整 HTTPS 迁移验收至少覆盖：TLS 1.2/1.3、证书链、HTTP 308 的限定目标与
明文 API/回调/POST 拒绝、完整前端文件哈希、真实用户与超管登录、Secure Cookie、
匿名 API 拒绝、手机菜单及官方上游 TS2021/Noise/HTTP2 的 HTTPS 链路。后续仅升级
HTTP guard 时，不为验证重置密码或登录真实人类账号，应区分原站只读与隔离写入。
握手和未知节点拒绝不等于注册设备或建立 WireGuard 业务连接。

上游依据：[nginx HTTPS 配置](https://nginx.org/en/docs/http/configuring_https_servers.html)、[497 明文访问 HTTPS 端口](https://nginx.org/en/docs/http/ngx_http_ssl_module.html#error_processing)、[OpenSSL req](https://docs.openssl.org/3.0/man1/openssl-req/)。第三方配置以[服务端 OAuth2 文档](https://github.com/xunara-net/xunara-server/blob/main/docs/oauth2-login.md)为准。

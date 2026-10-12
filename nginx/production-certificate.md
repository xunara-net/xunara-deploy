# 正式证书安装与轮换

本手册用于**已经启用 HTTPS** 的同源站点，替换私有测试证书或即将到期的正式
证书；不是 HTTP→HTTPS 数据迁移。控制面 URL、组织、提供方回调、账户和设备
保持不变，只校验证书、修改 nginx TLS 配置并 reload。首次 HTTPS 迁移仍按
[自签测试部署的迁移检查](self-signed-https.md#迁移前检查)与
[入口手册](README.md)执行，不重新初始化平台。

## 私密文件与覆盖范围

- 只使用证书包的 nginx 完整链与对应私钥；ZIP 也含私钥，必须按凭据保护。
  不提交 Git、不放站点目录、不打印私钥、不把私钥内容放入 URL、参数或日志。
- 上传/解压暂存目录 0700、证书和私钥 0600；安装目录为 root 所有且 0700。
  完成验收后移除暂存私钥，只保留受保护的运行文件、必要回滚备份和用户原包。
- SAN 必须覆盖实际客户端域名；单域证书不覆盖 IP、租户子域或 `nip.io` 域名。
  多域站点按 SNI 分开配置，不能用主域证书替换其他租户的有效链。
- 9091 DERP 直连证书与既有 pin 独立，**不得跟随网站换证书**。

## 验证并安装文件

前置条件：Linux、Bash、OpenSSL 3、root 权限、受保护的上传目录；执行目录为
`xunara-deploy`。先把示例域名与上传路径替换为实际值。以下命令只检查和安装
文件，不修改 nginx、不输出私钥；失败应停止，不继续部署。

```bash
sudo -i
set -euo pipefail
umask 077
tls_dir="/etc/xunara/tls/production-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 700 "$tls_dir"
install -m 600 /private/upload/fullchain.pem "$tls_dir/fullchain.pem"
install -m 600 /private/upload/privkey.key "$tls_dir/privkey.key"
openssl x509 -in "$tls_dir/fullchain.pem" -noout -checkend 604800
openssl verify -purpose sslserver -verify_hostname xunara.example.test \
  -untrusted "$tls_dir/fullchain.pem" "$tls_dir/fullchain.pem"
openssl x509 -in "$tls_dir/fullchain.pem" -pubkey -noout > "$tls_dir/certificate-public.pem"
openssl pkey -in "$tls_dir/privkey.key" -pubout > "$tls_dir/key-public.pem"
cmp -s "$tls_dir/certificate-public.pem" "$tls_dir/key-public.pem"
```

`verify` 使用系统信任链，不通过信任待部署的叶子证书来伪造验证成功；公钥比较
确认私钥匹配。`checkend` 这里只检查未来七天，**不提供自动续期**。

## 更新既有站点

在 root 私有回滚目录备份原 nginx 配置及原证书路径指向的文件，权限分别为
0700/0600。不删除旧链，不修改业务数据库，不以旧数据库快照回退证书。

只有一个证书域名的站点，可以仅替换原 `ssl_certificate` 和
`ssl_certificate_key` 路径。多租户已有其他域名时，为正式证书域名建立精确
`server_name` 的 TLS server，保留其他域名原有的 SNI 服务与链；新 server 必须
保留同一份既有 SPA/API/回调/TS2021 转发规则，不创造第二套认证或业务后端。
以下仅为 TLS 指令片段，路径替换为刚安装的真实目录：

```nginx
server_name xunara.example.test;
ssl_certificate /etc/xunara/tls/production-TIMESTAMP/fullchain.pem;
ssl_certificate_key /etc/xunara/tls/production-TIMESTAMP/privkey.key;
```

主域已使用受信任链时，原测试 CA 下载入口改为精确 `410`，避免误导新客户端；
不要仅删除 location 而使 SPA 回落成 `200`。仍使用测试链的其他域名可保留原
CA 下载。不能把一次主域替换当作所有租户域名都已取得正式证书。

先 `nginx -t` 再 `systemctl reload nginx`，等待新 worker 接管，再确认实际
SNI 返回的是新叶子证书。配置/TLS 验收失败只恢复 nginx 配置并 reload；不要
重启 Core 或 Relay，也不要恢复开放业务后的旧数据库快照。前端后续升级采用
默认 `auto` 或显式 `preserve`，防止覆盖这一 SNI 配置。

## 公网验收与续期

前置条件：从能访问公网域名的客户端执行，已替换示例域名；执行目录不限。
使用系统默认根证书，不能用 `-k`、旧测试 CA 或信任新叶子的方式验收主域。

```sh
curl --fail https://xunara.example.test:9090/health
curl --fail https://xunara.example.test:9090/version
openssl s_client -connect xunara.example.test:9090 \
  -servername xunara.example.test -verify_hostname xunara.example.test \
  -verify_return_error </dev/null
```

检查控制密钥、完整前端资产、匿名权限拒绝、安全 HTTP 页面跳转和官方 SDK
HTTPS/TS2021/Noise；其他租户 SNI/健康及中继保持原状。服务器缺乏公网回环能力
时可先用本机连接配合真实 SNI 验证，再从外部独立复核，不能因此跳过公网验收。
只读升级验收不登录原人类账号、不改密码、不注册或过期真实设备。

现代且信任发行方根证书的客户端使用正式域名通常不再需要导入测试 CA；旧系统
或其他测试域名的信任要求仍需分别处理。客户端直接配置 HTTPS 控制面地址，
明文跳转不能保护已发送的凭据。本流程不申请或自动续期证书，应在到期前取得
新证书并重复验证/轮换；ACME 自动化需要另外配置与验收。

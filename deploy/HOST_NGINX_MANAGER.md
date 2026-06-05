# VPS Nginx 代理管理脚本

`deploy/host-nginx-manager.sh` 是给当前 VPS 这种“已有宿主 nginx，且不再使用 Nginx Proxy Manager”的场景准备的轻量管理脚本。

它只管理标准 HTTP/HTTPS 反向代理站点，不会自动改动你当前已经手写的：

- `stream` / `ssl_preread`
- Rathole SNI 转发
- 假证书拦截
- 直接 IP 访问 `444` 拦截
- 其他手工放在 `/etc/nginx/nginx.conf` 里的全局规则

## 当前 VPS 判断

从审计结果看，这台机器适合继续使用宿主 nginx：

- `80` 和 `443` 已由系统 nginx 监听
- `8443`、`54443` 当前用于 `stream` / Rathole SNI 转发
- `3001` 当前有 Node 服务监听，适合通过 nginx 子域名反代
- Certbot 已存在，并已有 `metapi.cni.de5.net` 证书
- 防火墙当前未启用，安全边界主要依赖云厂商安全组和 nginx 规则

因此，普通 Web/API 服务建议统一挂到 `443`，例如：

- `metapi.cni.de5.net -> 127.0.0.1:3001`
- `api.example.com -> 127.0.0.1:3002`

特殊的 `stream` / Rathole 入口继续手工维护，不建议塞进这个脚本。

## 安装到 VPS

```bash
curl -fsSL https://raw.githubusercontent.com/zczy-k/nginx-proxy-manager/develop/deploy/host-nginx-manager.sh -o /usr/local/sbin/host-nginx-manager
sudo chmod +x /usr/local/sbin/host-nginx-manager
```

查看帮助：

```bash
host-nginx-manager help
```

## 新增普通反向代理

如果后端是本机 `3001` 端口：

```bash
sudo host-nginx-manager add metapi.cni.de5.net 127.0.0.1:3001 --email you@example.com
```

这会：

- 写入 `/etc/nginx/sites-available/vpspm-metapi.cni.de5.net.conf`
- 创建 `/etc/nginx/sites-enabled/vpspm-metapi.cni.de5.net.conf` 链接
- 先创建 HTTP 站点用于 ACME 验证
- 使用 `certbot certonly --webroot` 申请证书
- 启用 HTTPS 并将 HTTP 跳转到 HTTPS
- `nginx -t` 通过后才 reload nginx
- 如果新配置失败，会回滚旧配置

## 只创建 HTTP，不立即申请证书

```bash
sudo host-nginx-manager add metapi.cni.de5.net 127.0.0.1:3001 --no-ssl
```

稍后再启用 HTTPS：

```bash
sudo host-nginx-manager enable-ssl metapi.cni.de5.net --email you@example.com
```

## 后端是自签 HTTPS

例如后端是 `https://127.0.0.1:58000`，且证书不可被公网 CA 验证：

```bash
sudo host-nginx-manager add nas.example.com 127.0.0.1:58000 \
  --upstream-scheme https \
  --backend-insecure \
  --client-max-body-size 0 \
  --email you@example.com
```

## 查看和维护

```bash
sudo host-nginx-manager list
sudo host-nginx-manager show metapi.cni.de5.net
sudo host-nginx-manager test
sudo host-nginx-manager reload
```

删除站点：

```bash
sudo host-nginx-manager remove metapi.cni.de5.net --yes
```

删除站点并尝试删除证书：

```bash
sudo host-nginx-manager remove metapi.cni.de5.net --delete-cert --yes
```

## 重要边界

这个脚本不要用来管理：

- `8443` / `54443` 这类 `stream` 入口
- Rathole 的 SNI 透传
- 非 HTTP 协议
- 已经手工写在 `/etc/nginx/nginx.conf` 里的复杂规则

这些继续手工维护更稳。

如果需要把现有手工规则迁移成脚本管理，建议逐条迁移：先加一个新子域名验证，再替换旧配置，不要一次性改公网入口。
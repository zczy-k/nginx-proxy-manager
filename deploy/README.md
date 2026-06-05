# Nginx Proxy Manager - 裸机部署工具

无需 Docker，直接使用系统 Nginx + Node.js 部署 NPM。

## 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/zczy-k/nginx-proxy-manager/develop/deploy/setup.sh | sudo bash -s -- install
```

## 其他命令

| 命令 | 说明 |
|------|------|
| `curl -fsSL .../setup.sh \| sudo bash` | 交互式菜单 |
| `curl -fsSL .../setup.sh \| sudo bash -s -- install-local` | 安装 (强制本地编译) |
| `curl -fsSL .../setup.sh \| sudo bash -s -- uninstall` | 卸载 |
| `curl -fsSL .../setup.sh \| sudo bash -s -- upgrade` | 升级 |
| `curl -fsSL .../setup.sh \| sudo bash -s -- health` | 健康检查 |
| `curl -fsSL .../setup.sh \| sudo bash -s -- status` | 查看状态 |

## 设计原则

- **不修改上游源码** — 通过 Nginx Wrapper (dpkg-divert) + 运行时配置实现适配
- **可安全 merge 上游更新** — fork 中的 deploy/ 目录独立于上游代码
- **资源节约** — 2C1G 服务器 ~150MB，为 Docker 版的 1/3
- **共存隔离** — 与服务器上其他 Nginx 站点互不干扰

## 共存隔离设计

NPM 设计为可以与服务器上的其他服务（如其他网站、隧道、API 代理等）共存。

**NPM 不触碰的内容:**

- `sites-enabled/` — 不添加、不删除、不修改
- `stream {}` — 检测到已有 server 块时跳过注入
- 不创建 80/443 端口的 server 块 (除非 sites-enabled 为空)
- 不修改用户已有的 nginx server 配置

**NPM 向 nginx 共享环境添加的内容:**

- `http {}` 末尾 2 行 include (加载 NPM 管理面板和代理配置)
- `set $server "127.0.0.1"` / `set $port "80"` — 变量默认值 (被 NPM proxy host 覆盖)
- `log_format proxy` / `log_format standard` — NPM 专属日志格式
- `proxy_cache_path` — NPM 专属缓存路径 (位于 `/var/lib/nginx/cache/`)
- `map $host $forward_scheme` 等 3 个 map — NPM 代理模板依赖

**唯一的冲突风险:** 如果你的 nginx.conf 中也定义了 `map $host $forward_scheme`、`map $http_x_forwarded_proto $x_forwarded_proto` 或 `map $http_x_forwarded_scheme $x_forwarded_scheme`，需要移除你的定义，NPM 的 map 会自动处理。安装脚本会检测并警告此冲突。

## 技术细节

### Nginx Wrapper

上游 `internal/nginx.js` 直接调用 `/usr/sbin/nginx` (不带 sudo)。Docker 中后端以 root 运行无问题，裸机以 npm 用户运行则权限不足。

解决: 通过 `dpkg-divert` 将原始 nginx 转移到 `nginx.real`，在原位置放置 wrapper 脚本。apt 升级 nginx 时不会覆盖 wrapper。

### 后端端口

后端固定监听 3000 端口 (源码硬编码)。管理面板通过 Nginx 反向代理连接到 `127.0.0.1:3000`。HTTP/HTTPS 代理端口可自定义。

### 数据隔离

- 安装目录: `/opt/nginx-proxy-manager`
- 数据目录: `/data/npm` (数据库、keys)
- Nginx 数据: `/data/nginx` (代理配置、日志、证书)
- Nginx 配置: `/etc/nginx/npm-conf.d` (隔离目录)

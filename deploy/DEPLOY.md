# Nginx Proxy Manager 裸机部署说明

这个部署方案是给低配置 VPS 准备的独立裸机运行方案，目标是：

- 不修改上游源码
- 不依赖 Docker
- 尽量降低 2 核 1G 机器的内存占用
- 尽量不影响 VPS 上的其他项目
- 支持重装、升级、状态查看、健康检查和快速卸载

部署入口脚本是：`deploy/setup.sh`

## 方案特点

新的部署器不会去改项目源码本身，而是在源码外面搭一层隔离运行环境：

- 私有 Node.js 运行时：`/opt/npm-bare/tools/node`
- 私有 Certbot 运行时：`/opt/npm-bare/tools/certbot`
- 私有 nginx 实例：由 `systemd` 单独管理
- 私有运行数据：`/var/lib/npm-bare`
- 私有日志路径：`/var/log/npm-bare`
- 私有服务：
  - `npm-bare-nginx.service`
  - `npm-bare-backend.service`

脚本通过 `systemd` 的 bind mount 把上游程序期望看到的这些路径映射到私有目录里：

- `/data`
- `/etc/nginx`
- `/etc/letsencrypt`
- `/usr/sbin/nginx`

这样上游代码仍然按原来的方式运行，但不会直接接管宿主机的共享 nginx 配置树。

## 重要限制

这个项目的上游模板决定了代理入口仍然必须使用：

- `80`
- `443`

也就是说，管理后台端口可以改，但代理业务端口不能像普通应用那样随意换成 `8080/8443` 后仍保持完整兼容。这不是本脚本的限制，而是上游生成的 nginx host 模板决定的。

默认管理后台端口是：`81`

## 快速开始

优先使用预构建产物，最省内存：

```bash
curl -fsSL https://raw.githubusercontent.com/zczy-k/nginx-proxy-manager/develop/deploy/setup.sh | sudo bash -s -- install
```

强制本地构建：

```bash
curl -fsSL https://raw.githubusercontent.com/zczy-k/nginx-proxy-manager/develop/deploy/setup.sh | sudo bash -s -- install-local
```

## 常用命令

```bash
setup.sh install
setup.sh install-local
setup.sh reinstall
setup.sh reinstall-local
setup.sh upgrade
setup.sh status
setup.sh health
setup.sh logs
setup.sh uninstall
```

## 常见用法

指定管理后台端口安装：

```bash
sudo bash deploy/setup.sh install --admin-port 8081
```

基于指定 git 引用重新部署：

```bash
sudo bash deploy/setup.sh reinstall --ref develop
```

强制本地重建：

```bash
sudo bash deploy/setup.sh reinstall-local --ref develop
```

卸载但保留数据：

```bash
sudo bash deploy/setup.sh uninstall --keep-data --yes
```

## 安装内容

- 应用源码：`/opt/npm-bare/app/source`
- Node 运行时：`/opt/npm-bare/tools/node`
- Certbot 运行时：`/opt/npm-bare/tools/certbot`
- 运行状态目录：`/var/lib/npm-bare`
- 日志目录：`/var/log/npm-bare`

## 状态与健康检查

```bash
sudo bash deploy/setup.sh status
sudo bash deploy/setup.sh health
sudo journalctl -u npm-bare-backend -u npm-bare-nginx -f
```

## 升级与重装

- `upgrade`：保留现有数据并重新部署当前运行方案
- `reinstall`：重新拉源码并重新铺运行时，默认优先使用预构建产物
- `reinstall-local`：重新拉源码并强制本地构建

SQLite 数据、证书目录和 nginx 生成配置会保留在私有状态目录中，不会因为普通升级被清空。

## 卸载说明

`uninstall` 会移除：

- 私有运行时目录
- `systemd` 服务
- 私有 nginx / Node / Certbot 运行环境

它不会主动卸载系统公共软件包，例如：

- `nginx`
- `curl`
- `python3`

这样做是为了避免误伤 VPS 上其他项目。

如果不加 `--keep-data`，脚本会一并清理状态目录和日志目录。

## 适合新手的建议

第一次部署时，优先用：

```bash
sudo bash deploy/setup.sh install
```

如果 release 预构建产物可用，这条路径最省内存，也最适合 2 核 1G 机器。

如果你后面要同步 fork 或上游代码，建议流程是：

1. 同步代码仓库。
2. 重新执行 `reinstall` 或 `upgrade`。
3. 执行 `status` 和 `health` 检查结果。

这样比手工改系统 nginx 配置稳定得多，也更容易回滚和排障。
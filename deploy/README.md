# Nginx Proxy Manager - 裸机部署工具

位于 `deploy/` 目录，提供无需 Docker 的部署方案。

## 快速开始

```bash
# 克隆本仓库到服务器
git clone --depth 1 https://github.com/zczy-k/nginx-proxy-manager.git /opt/nginx-proxy-manager

# 进入目录并运行脚本
cd /opt/nginx-proxy-manager && sudo bash deploy/setup.sh
```

> 直接运行 `sudo bash deploy/setup.sh` 即可进入交互式菜单，所有操作通过菜单选择完成。

## 特性

- **零 Docker** — 直接使用系统 Nginx + Node.js
- **端口自定义** — 安装时自定义 HTTP/HTTPS/管理/后端端口
- **隔离安装** — 独立 Nginx 配置目录，不干扰其他站点
- **健康检查** — 安装后自动检查服务/端口/HTTP/数据库状态
- **升级管理** — 支持从 origin 和上游官方仓库升级
- **完整卸载** — 保留数据 / 完全清除 双模式
- **资源节约** — 2C1G 服务器 ~150MB 内存，仅为 Docker 版的 1/3

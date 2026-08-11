# geodata-sync

定时从 [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) 拉取最新的
`geoip.dat` / `geosite.dat`，缓存到 Cloudflare R2，并通过 Cloudflare Worker 对外提供 HTTPS 下载，
供本地网络无法直连 GitHub 的设备（如运行 ImmortalWrt 的路由器）定时拉取更新。

## 架构

```
GitHub (v2ray-rules-dat releases)
        │  Cron Trigger 定时抓取（scheduled handler）
        ▼
   Cloudflare R2（geoip.dat / geosite.dat / checksums.txt）
        │  HTTPS（Cloudflare 自动签发证书，fetch handler）
        ▼
   路由器等客户端设备
```

## 目录结构

```
.
├── wrangler.toml               Worker 配置：R2 绑定、Cron Trigger
├── package.json                 声明 wrangler 依赖，供 Workers Builds 执行部署
├── src/index.js                 Worker 主逻辑（抓取、校验、存储、分发）
├── update-geodata-client-cf.sh  路由器端客户端脚本
└── .dev.vars.example             本地调试用的密钥示例（不会被提交）
```

## 端点说明

| 路径 | 方法 | 说明 |
|---|---|---|
| `/geoip.dat` | GET | 下载 geoip.dat |
| `/geosite.dat` | GET | 下载 geosite.dat |
| `/checksums.txt` | GET | 两个文件的 sha256，客户端用于判断是否需要更新 |
| `/sync?token=<ADMIN_TOKEN>` | GET | 手动触发一次抓取同步，需要正确的 ADMIN_TOKEN |

详细部署步骤见项目部署教程（Cloudflare Workers Builds Git 集成 + ImmortalWrt 客户端配置）。

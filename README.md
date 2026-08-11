# geodata-sync

定时从 [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) 拉取最新的
`geoip.dat` / `geosite.dat`，缓存到 Cloudflare R2，并通过 Cloudflare Worker 对外提供 HTTPS 下载，
供本地网络无法直连 GitHub 的设备（如运行 ImmortalWrt 的路由器）定时拉取更新，替代直连 GitHub 下载。

## 架构

```
GitHub (v2ray-rules-dat releases)
        │  Cron Trigger 定时抓取（scheduled handler，每天一次）
        ▼
   Cloudflare R2（geoip.dat / geosite.dat / checksums.txt）
        │  HTTPS（Cloudflare 自动签发证书，fetch handler）
        ▼
   路由器等客户端设备（先比对 checksums.txt 再按需下载，节省流量）
```

**为什么这么设计：**
- 路由器本地网络访问 GitHub 可能不稳定或被限制，改为访问自己的 Cloudflare Worker，走的是普通 HTTPS 请求，流量特征和访问任何网站没有区别
- Cloudflare 自定义域名的 TLS 证书全自动签发续期，不需要自己管理证书文件
- 客户端每次只需先请求几十字节的 `checksums.txt` 判断是否有更新，没变化就不下载大文件，省流量
- 下载后先用 sha256 校验完整性，通过校验才会原地替换旧文件；客户端不做备份，直接替换，节省软路由本就紧张的存储空间——因为替换前已经校验过内容可信，不需要额外保留旧文件用于回滚
- Cloudflare R2 端同理：每次抓取到新内容直接以同一个 key（`geoip.dat`/`geosite.dat`）覆盖写入，旧版本对象不会被保留，不会产生冗余存储占用

## 目录结构

```
geodata-sync/
├── .dev.vars.example              本地调试用的密钥示例文件（说明用）
├── .gitignore                     忽略 node_modules / .wrangler / .dev.vars
├── README.md                      本文档
├── package.json                   声明 wrangler 依赖，供 Workers Builds 执行部署命令
├── wrangler.toml                  Worker 配置：R2 绑定 + Cron Trigger
├── src/
│   └── index.js                   Worker 主逻辑（抓取 / 校验 / 存储 / 分发 / 手动同步接口）
└── update-geodata-client-cf.sh    路由器端客户端脚本
```

## 端点说明

部署完成后，Worker 会提供以下端点（`<domain>` 是你的 `*.workers.dev` 地址或绑定的自定义域名）：

| 路径 | 方法 | 说明 |
|---|---|---|
| `https://<domain>/geoip.dat` | GET | 下载 geoip.dat |
| `https://<domain>/geosite.dat` | GET | 下载 geosite.dat |
| `https://<domain>/checksums.txt` | GET | 两个文件的 sha256 + 更新时间，客户端用于判断是否需要更新 |
| `https://<domain>/sync?token=<ADMIN_TOKEN>` | GET | 手动触发一次抓取同步，需要正确的 token，浏览器直接打开链接即可 |

---

## 一、Cloudflare 端部署教程（Workers Builds，全程网页操作）

### 前置条件

- 一个 Cloudflare 账号（免费版即可，Cron Triggers 免费版可用）
- 一个 GitHub 账号

### 第一步：把本仓库内容上传到你自己的 GitHub 仓库

1. 在 GitHub 新建一个空仓库，比如 `geodata-sync`
2. 进入仓库页面 → **Add file** → **Upload files**，把本项目所有文件（含 `src/index.js`，保持目录结构）拖进去上传
3. 网页上传时把 `src/index.js` 拖进去会自动帮你建好 `src/` 子目录；`.gitignore`、`.dev.vars.example` 这类以 `.` 开头的文件正常能被识别，不用担心被过滤
4. 点击 **Commit changes** 完成上传

（如果你熟悉命令行，也可以用 `git init && git add . && git commit && git push` 的方式，效果一样）

### 第二步：创建 R2 存储桶（一次性操作）

Git 集成不会自动帮你建桶，需要手动创建一次：

- **网页端**：Cloudflare Dashboard → **R2** → **Create bucket** → 名字填 `geodata-sync`（要和 `wrangler.toml` 里的 `bucket_name` 完全一致，如果改了名字这里也要对应改）
- 或者命令行：`wrangler r2 bucket create geodata-sync`

### 第三步：连接 GitHub 仓库到 Cloudflare Worker

1. Cloudflare Dashboard → **Workers & Pages** → **Create** → 选择 **Import a repository**（或类似入口，取决于当前 UI 版本）
2. 授权 Cloudflare 访问你的 GitHub 账号，选择刚才上传的 `geodata-sync` 仓库
3. 配置构建设置：
   - **Build command**：留空（这个项目不需要打包编译）
   - **Deploy command**：`npx wrangler deploy`
   - **Root directory**：仓库根目录，默认即可
4. 点击部署。Cloudflare 会自动 `npm install` 拉取 `wrangler` 依赖，然后执行部署命令，`wrangler.toml` 里声明的 R2 绑定和 Cron Trigger 会自动配置生效

### 第四步：设置 ADMIN_TOKEN（不要写进代码或仓库里）

Dashboard → 你的 Worker → **Settings** → **Variables and Secrets** → **Add** → 类型选 **Secret**：

```
Name: ADMIN_TOKEN
Value: <自己设置一个复杂随机字符串，记下来>
```

这个值只保存在 Cloudflare 侧，和仓库代码完全分离，以后 Git 推送触发的重新部署也不会丢失或需要重新设置。

### 第五步：手动触发第一次同步

浏览器直接打开（或用 curl）：

```
https://geodata-sync.<你的子域>.workers.dev/sync?token=<你设置的ADMIN_TOKEN>
```

正常会看到类似下面的 JSON 返回，说明抓取成功：

```json
{
  "geoip.dat": { "ok": true, "updated": true, "sha256": "..." },
  "geosite.dat": { "ok": true, "updated": true, "sha256": "..." }
}
```

如果显示 `"updated": false`，说明内容和已存储版本一致，属于正常情况（比如短时间内点了两次）。

### 第六步：验证文件已生成

```sh
curl https://geodata-sync.<你的子域>.workers.dev/checksums.txt
curl -o geoip.dat https://geodata-sync.<你的子域>.workers.dev/geoip.dat
```

### 第七步：确认定时任务已生效

Dashboard → 你的 Worker → **Triggers** 标签页，能看到 Cron Trigger `0 22 * * *`（UTC 时间，对应北京时间次日早上 6 点），以后每天自动抓取一次，不需要手动干预。如果想改频率或时间，直接改 `wrangler.toml` 里的 `crons` 字段并 push 到仓库即可自动生效——Cloudflare 的 cron 表达式固定按 UTC 计时，换算北京时间时记得减 8 小时（比如想要北京时间某天 X 点执行，`crons` 就填 `X-8` 点，结果是负数就加 24 变成前一天）。

### 第八步（推荐）：绑定自定义域名

Dashboard → 你的 Worker → **Custom Domains** → 添加你自己的域名。证书由 Cloudflare 全自动签发和续期，不需要你上传或管理任何证书文件。绑定完之后，上面用到的地址都可以换成你自己的域名。

### 日常维护

以后想调整代码（比如改抓取频率、加新的文件源），只需要：

```sh
git add .
git commit -m "说明改了什么"
git push
```

push 之后 Cloudflare 会自动重新构建部署，Worker 的 **Deployments** 标签页能看到每次构建记录和日志，出问题也可以一键回滚到上一个版本。

### 故障排查

- **`/sync` 返回 401**：token 填错了，检查有没有多余空格或复制不完整
- **`/sync` 返回 500 提示未配置 ADMIN_TOKEN**：第四步的 Secret 没设置成功，去 Settings → Variables and Secrets 确认
- **日志查看**：`wrangler tail`（需要本地装 wrangler 并 `wrangler login`），或在 Dashboard 的 Worker 页面查看实时日志
- **`Exceeded CPU Time Limit`**：一般不会出现（两个文件也就几 MB，哈希计算很快），如果出现，考虑升级到 Workers 付费版（$5/月起，CPU 时间额度更高）

---

## 二、ImmortalWrt 客户端部署教程

### 第一步：上传脚本到路由器

用 scp、或者 LuCI 网页的文件管理上传都行，放在 `/root` 下：

```sh
chmod +x /root/update-geodata-client-cf.sh
```

### 第二步：安装依赖

```sh
opkg update
opkg install curl                       # 或 wget-ssl
opkg install ca-bundle ca-certificates   # HTTPS 证书校验必需
opkg install coreutils-sha256sum        # 完整性校验必需
```

### 第三步：编辑脚本配置

打开 `/root/update-geodata-client-cf.sh`，改这两行：

```sh
GEODATA_SERVER="https://geodata-sync.your-subdomain.workers.dev"   # 换成你自己的 Worker 地址
SERVICE_NAME="daed"                                                 # 换成你实际的代理服务名
```

### 第四步：手动跑一次，确认没问题

```sh
/root/update-geodata-client-cf.sh
logread | grep geodata-update
ls -la /usr/share/v2ray/
```

确认 `geoip.dat`、`geosite.dat` 已经生成，且服务已重启。

### 第五步：再跑一次，验证增量检测生效

```sh
/root/update-geodata-client-cf.sh
```

这次应该看到日志显示"均为最新，无需下载"。如果又重新下载了，说明两边计算出的 sha256 没对上，需要排查（比如 Worker 那边是不是刚好又跑了一次定时任务产生了新版本）。

### 第六步：加入定时任务

```sh
crontab -e
```

加一行，比如每周一凌晨 1 点检查一次（因为服务端每天早上 6 点才更新一次源数据，检查太频繁没有意义，一周一次足够，几乎不耗流量）：

```
0 1 * * 1 /root/update-geodata-client-cf.sh
```

字段含义：`分 时 日 月 周`，`周` 这一列 BusyBox crond 用 `0`/`7` 表示周日、`1` 表示周一，所以 `1` 就是每周一。

这一行按路由器系统本地时间执行——如果路由器时区已经是 `Asia/Shanghai`（GMT+8，可用 `date` 命令确认），上面这行就是最终结果，不需要再做任何换算。只有当路由器系统时区是 UTC 时才需要换算成 UTC 时间填写。

保存后重启 cron 服务：

```sh
/etc/init.d/cron restart
```

### 关于文件替换（不做备份）

脚本**不会**在替换前生成 `.bak` 备份，下载的临时文件通过 sha256 校验后直接 `mv` 覆盖旧文件，这样每次更新都不会在软路由本就有限的存储空间里多占一份文件。

安全性由两层保证：
1. 下载完成后先比对 checksums.txt 里的 sha256，校验不通过的文件会被直接丢弃、不会替换，旧文件保持不变
2. 只有校验通过、内容可信的文件才会执行替换，所以正常情况下不存在"替换后发现文件损坏"需要回滚的场景

如果确实怀疑当前文件有问题（比如上游 `v2ray-rules-dat` 本身发布了有缺陷的版本），可以：
- 手动触发 Cloudflare 端重新抓取：浏览器打开 `https://<domain>/sync?token=<ADMIN_TOKEN>`，确认拉到的是修复后的新版本
- 在路由器上手动删除本地文件后重新执行一次脚本，会被判定为"本地不存在，必然触发更新"重新下载：
  ```sh
  rm -f /usr/share/v2ray/geoip.dat /usr/share/v2ray/geosite.dat
  /root/update-geodata-client-cf.sh
  ```

---

## 安全性说明

- 路由器到 Worker 之间是标准 HTTPS 请求，流量特征和访问任意普通网站一致
- 建议这个"geodata 分发"用的域名/Worker 和你其他代理基础设施（比如 VPN/代理节点）保持独立，避免因为共用同一个域名或 IP 造成关联风险
- `/sync` 端点通过 Secret Token 保护，避免被随意探测或触发

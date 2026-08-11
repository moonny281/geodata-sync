#!/bin/sh
# =========================================================
# update-geodata-client-cf.sh
# 部署位置：ImmortalWrt 路由器（本地网络无法直连 GitHub）
# 功能：从 Cloudflare Worker（HTTPS，Cloudflare 自动签发证书）拉取
#       checksums.txt 判断是否有更新，仅在有变化时下载对应文件，
#       校验后原子替换并重启 daed
# =========================================================

set -eu

# ---------- 可调整配置 ----------
# 改成你实际绑定的自定义域名，或先用 Workers 默认的 *.workers.dev 域名测试
GEODATA_SERVER="https://geodata-sync.your-subdomain.workers.dev"
# ---------------------------------------------------

DEST_DIR="/usr/share/v2ray"
TMP_DIR="/tmp/geodata_update"
CHECKSUM_URL="$GEODATA_SERVER/checksums.txt"
GEOIP_URL="$GEODATA_SERVER/geoip.dat"
GEOSITE_URL="$GEODATA_SERVER/geosite.dat"
SERVICE_NAME="daed"        # 留空则只更新文件、不重启服务
RETRY_TIMES=3
RETRY_INTERVAL=5
LOG_TAG="geodata-update"

log() {
    logger -t "$LOG_TAG" "$1"
    echo "[$LOG_TAG] $1"
}

DOWNLOADER=""
if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
else
    log "错误：未找到 curl 或 wget，请先 opkg install curl 或 wget-ssl"
    exit 1
fi

# HTTPS 校验证书需要 CA 根证书包，OpenWrt/ImmortalWrt 精简固件常常没预装
if [ ! -f /etc/ssl/certs/ca-certificates.crt ] && [ ! -d /etc/ssl/certs ]; then
    log "警告：未检测到 CA 证书包，HTTPS 证书校验可能失败，请先执行: opkg update && opkg install ca-bundle ca-certificates"
fi

# 脚本用 sha256sum 做完整性校验，精简固件可能没有这个 applet
if ! command -v sha256sum >/dev/null 2>&1; then
    log "错误：未找到 sha256sum，请先执行: opkg update && opkg install coreutils-sha256sum"
    exit 1
fi

fetch() {
    # $1 = url  $2 = 输出路径  返回值表示成功与否
    url="$1"
    out="$2"
    i=1
    while [ "$i" -le "$RETRY_TIMES" ]; do
        if [ "$DOWNLOADER" = "curl" ]; then
            if curl -fsSL --connect-timeout 10 --max-time 60 -o "$out" "$url"; then
                return 0
            fi
        else
            if wget -q -T 10 -O "$out" "$url"; then
                return 0
            fi
        fi
        log "请求失败 (第 $i/$RETRY_TIMES 次): $url"
        i=$((i + 1))
        [ "$i" -le "$RETRY_TIMES" ] && sleep "$RETRY_INTERVAL"
    done
    return 1
}

mkdir -p "$DEST_DIR" "$TMP_DIR"

# 第一步：拉取远端 checksums.txt（体积很小），判断是否需要更新
REMOTE_CHECKSUMS="$TMP_DIR/checksums.txt"
if ! fetch "$CHECKSUM_URL" "$REMOTE_CHECKSUMS"; then
    log "无法获取 checksums.txt，本次更新中止（服务端不可达或证书异常）"
    rm -rf "$TMP_DIR"
    exit 1
fi

REMOTE_GEOIP_SHA=$(awk '$1=="geoip.dat"{print $2}' "$REMOTE_CHECKSUMS")
REMOTE_GEOSITE_SHA=$(awk '$1=="geosite.dat"{print $2}' "$REMOTE_CHECKSUMS")

if [ -z "$REMOTE_GEOIP_SHA" ] || [ -z "$REMOTE_GEOSITE_SHA" ]; then
    log "checksums.txt 格式异常，本次更新中止"
    rm -rf "$TMP_DIR"
    exit 1
fi

# 本地现有文件的 sha256（文件不存在则视为空，必然触发更新）
local_sha() {
    [ -f "$1" ] && sha256sum "$1" | awk '{print $1}' || echo ""
}

LOCAL_GEOIP_SHA=$(local_sha "$DEST_DIR/geoip.dat")
LOCAL_GEOSITE_SHA=$(local_sha "$DEST_DIR/geosite.dat")

NEED_GEOIP=0
NEED_GEOSITE=0
[ "$REMOTE_GEOIP_SHA" != "$LOCAL_GEOIP_SHA" ] && NEED_GEOIP=1
[ "$REMOTE_GEOSITE_SHA" != "$LOCAL_GEOSITE_SHA" ] && NEED_GEOSITE=1

if [ "$NEED_GEOIP" -eq 0 ] && [ "$NEED_GEOSITE" -eq 0 ]; then
    log "geoip.dat / geosite.dat 均为最新，无需下载"
    rm -rf "$TMP_DIR"
    exit 0
fi

CHANGED=0

update_one() {
    # $1 = url  $2 = 目标文件名  $3 = 期望的 sha256
    url="$1"
    name="$2"
    expect_sha="$3"
    tmp="$TMP_DIR/$name.tmp"
    dest="$DEST_DIR/$name"

    log "检测到 $name 有更新，开始下载"
    if ! fetch "$url" "$tmp"; then
        log "$name 下载失败，跳过本次更新"
        return
    fi

    actual_sha=$(sha256sum "$tmp" | awk '{print $1}')
    if [ "$actual_sha" != "$expect_sha" ]; then
        # 注意：${var:0:12} 是 bash 扩展语法，busybox ash/dash 不支持，统一用 cut 截取，避免脚本报语法错误
        expect_short=$(echo "$expect_sha" | cut -c1-12)
        actual_short=$(echo "$actual_sha" | cut -c1-12)
        log "$name 校验和不匹配（期望 ${expect_short}... 实际 ${actual_short}...），丢弃该文件"
        rm -f "$tmp"
        return
    fi

    # 不做备份：直接替换，省掉软路由上双倍占用的存储空间；
    # 校验和已经在上面核对过，替换的内容是可信的，无需保留旧文件用于回滚
    mv -f "$tmp" "$dest"
    log "$name 已更新并通过校验"
    CHANGED=1
}

[ "$NEED_GEOIP" -eq 1 ] && update_one "$GEOIP_URL" "geoip.dat" "$REMOTE_GEOIP_SHA"
[ "$NEED_GEOSITE" -eq 1 ] && update_one "$GEOSITE_URL" "geosite.dat" "$REMOTE_GEOSITE_SHA"

rm -rf "$TMP_DIR"

if [ "$CHANGED" -eq 1 ]; then
    if [ -n "$SERVICE_NAME" ]; then
        if [ -x "/etc/init.d/$SERVICE_NAME" ]; then
            log "正在重启服务：$SERVICE_NAME"
            /etc/init.d/"$SERVICE_NAME" restart
            log "服务 $SERVICE_NAME 已重启"
        else
            log "警告：未找到 /etc/init.d/$SERVICE_NAME，跳过重启"
        fi
    fi
else
    log "本次没有文件被成功替换"
fi

log "更新流程结束"

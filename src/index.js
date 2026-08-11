// =========================================================
// geodata-sync Worker
// 功能：
//   1. scheduled handler（Cron）：从 GitHub 下载最新 geoip.dat / geosite.dat，
//      计算 sha256，写入 R2，并生成 checksums.txt
//   2. fetch handler：对外提供 GET /geoip.dat /geosite.dat /checksums.txt 下载
// =========================================================

const SOURCES = {
  "geoip.dat":
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat",
  "geosite.dat":
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat",
};

const MIN_FILE_SIZE = 100 * 1024; // 100KB，用于过滤 GitHub 限流/错误响应
const ALLOWED_KEYS = new Set(["geoip.dat", "geosite.dat", "checksums.txt"]);

async function sha256Hex(buffer) {
  const digest = await crypto.subtle.digest("SHA-256", buffer);
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function syncOnce(env) {
  const summary = {};

  for (const [name, url] of Object.entries(SOURCES)) {
    let resp;
    try {
      resp = await fetch(url);
    } catch (err) {
      summary[name] = { ok: false, reason: `请求异常: ${err.message}` };
      continue;
    }

    if (!resp.ok) {
      summary[name] = { ok: false, reason: `HTTP ${resp.status}` };
      continue;
    }

    const buffer = await resp.arrayBuffer();
    if (buffer.byteLength < MIN_FILE_SIZE) {
      summary[name] = {
        ok: false,
        reason: `文件大小异常仅 ${buffer.byteLength} 字节`,
      };
      continue;
    }

    const hash = await sha256Hex(buffer);

    // 和已存储版本比对，没变化则跳过写入，节省 R2 写操作次数
    const existing = await env.GEODATA_BUCKET.head(name);
    const existingHash = existing?.customMetadata?.sha256;
    if (existingHash === hash) {
      summary[name] = { ok: true, updated: false, sha256: hash };
      continue;
    }

    await env.GEODATA_BUCKET.put(name, buffer, {
      httpMetadata: { contentType: "application/octet-stream" },
      customMetadata: { sha256: hash, updatedAt: new Date().toISOString() },
    });
    summary[name] = { ok: true, updated: true, sha256: hash };
  }

  // 重新生成 checksums.txt，格式：<文件名> <sha256>，客户端脚本按此解析
  const lines = [];
  for (const name of Object.keys(SOURCES)) {
    const head = await env.GEODATA_BUCKET.head(name);
    if (head?.customMetadata?.sha256) {
      lines.push(`${name} ${head.customMetadata.sha256}`);
    }
  }
  lines.push(`# updated_at ${new Date().toISOString()}`);

  await env.GEODATA_BUCKET.put("checksums.txt", lines.join("\n") + "\n", {
    httpMetadata: { contentType: "text/plain; charset=utf-8" },
  });

  return summary;
}

async function handleGet(request, env) {
  const url = new URL(request.url);
  const key = url.pathname.replace(/^\//, "");

  if (!ALLOWED_KEYS.has(key)) {
    return new Response("Not Found", { status: 404 });
  }

  const object = await env.GEODATA_BUCKET.get(key);
  if (!object) {
    return new Response("Not Found", { status: 404 });
  }

  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("etag", object.httpEtag);
  headers.set("Cache-Control", "public, max-age=1800");

  return new Response(object.body, { headers });
}

async function handleSync(request, env) {
  // 用 Secret Token 保护，避免任何人都能触发/探测这个端点
  const url = new URL(request.url);
  const token = url.searchParams.get("token");

  if (!env.ADMIN_TOKEN) {
    return new Response(
      "未配置 ADMIN_TOKEN，请先执行 wrangler secret put ADMIN_TOKEN",
      { status: 500 }
    );
  }
  if (token !== env.ADMIN_TOKEN) {
    return new Response("Unauthorized", { status: 401 });
  }

  const summary = await syncOnce(env);
  return new Response(JSON.stringify(summary, null, 2), {
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

export default {
  async fetch(request, env, ctx) {
    if (request.method !== "GET") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    const url = new URL(request.url);
    if (url.pathname === "/sync") {
      return handleSync(request, env);
    }

    return handleGet(request, env);
  },

  async scheduled(controller, env, ctx) {
    ctx.waitUntil(
      syncOnce(env).then((summary) => {
        console.log("同步完成:", JSON.stringify(summary));
      })
    );
  },
};

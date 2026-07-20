import { NextRequest, NextResponse } from "next/server";

/**
 * Same-origin proxy to FastAPI so the browser never needs CORS or a public API URL.
 * Runtime target (k8s): http://fast-api:8001
 * Local dev: http://127.0.0.1:8001 or http://192.168.1.11:30081
 */
function apiBase(): string {
  return (
    process.env.API_INTERNAL_URL?.replace(/\/$/, "") ||
    process.env.NEXT_PUBLIC_API_URL?.replace(/\/$/, "") ||
    "http://127.0.0.1:8001"
  );
}

async function proxy(req: NextRequest, path: string[]) {
  const targetPath = path.join("/");
  const url = new URL(req.url);
  const dest = `${apiBase()}/${targetPath}${url.search}`;

  let body: ArrayBuffer | undefined;
  if (req.method !== "GET" && req.method !== "HEAD") {
    body = await req.arrayBuffer();
  }

  const upstream = await fetch(dest, {
    method: req.method,
    headers: {
      Accept: req.headers.get("Accept") || "application/json",
      "Content-Type": req.headers.get("Content-Type") || "application/json",
    },
    body,
    cache: "no-store",
  });

  const text = await upstream.text();
  return new NextResponse(text, {
    status: upstream.status,
    headers: {
      "Content-Type":
        upstream.headers.get("Content-Type") || "application/json",
    },
  });
}

type Ctx = { params: Promise<{ path: string[] }> };

export async function GET(req: NextRequest, ctx: Ctx) {
  const { path } = await ctx.params;
  return proxy(req, path);
}

export async function POST(req: NextRequest, ctx: Ctx) {
  const { path } = await ctx.params;
  return proxy(req, path);
}

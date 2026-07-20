"use client";

import { useCallback, useEffect, useState } from "react";
import {
  fetchApiResponse,
  fetchHealth,
  getApiBaseUrl,
  type ApiResponse,
  type HealthResponse,
} from "@/lib/api";

type LoadState = "idle" | "loading" | "ok" | "error";

export default function ApiDashboard() {
  const [baseUrl, setBaseUrl] = useState(getApiBaseUrl());
  const [health, setHealth] = useState<HealthResponse | null>(null);
  const [apiData, setApiData] = useState<ApiResponse | null>(null);
  const [healthState, setHealthState] = useState<LoadState>("idle");
  const [apiState, setApiState] = useState<LoadState>("idle");
  const [error, setError] = useState<string | null>(null);

  const loadAll = useCallback(async () => {
    setError(null);
    setHealthState("loading");
    setApiState("loading");
    setHealth(null);
    setApiData(null);

    try {
      const h = await fetchHealth(baseUrl);
      setHealth(h);
      setHealthState("ok");
    } catch (e) {
      setHealthState("error");
      setError(e instanceof Error ? e.message : "Health request failed");
    }

    try {
      const a = await fetchApiResponse(baseUrl);
      setApiData(a);
      setApiState("ok");
    } catch (e) {
      setApiState("error");
      setError((prev) =>
        [prev, e instanceof Error ? e.message : "API request failed"]
          .filter(Boolean)
          .join(" · ")
      );
    }
  }, [baseUrl]);

  useEffect(() => {
    void loadAll();
  }, [loadAll]);

  return (
    <div className="mx-auto flex w-full max-w-3xl flex-col gap-8 px-4 py-12">
      <header className="space-y-2">
        <p className="text-sm font-medium uppercase tracking-wide text-emerald-600 dark:text-emerald-400">
          Monorepo · apps/web
        </p>
        <h1 className="text-3xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-50">
          FastAPI dashboard
        </h1>
        <p className="text-zinc-600 dark:text-zinc-400">
          Calls the k3s-deployed API{" "}
          <code className="rounded bg-zinc-100 px-1.5 py-0.5 text-sm dark:bg-zinc-800">
            /health
          </code>{" "}
          and{" "}
          <code className="rounded bg-zinc-100 px-1.5 py-0.5 text-sm dark:bg-zinc-800">
            /api/response
          </code>
          .
        </p>
      </header>

      <section className="rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm dark:border-zinc-800 dark:bg-zinc-950">
        <label className="mb-2 block text-sm font-medium text-zinc-700 dark:text-zinc-300">
          API base URL
        </label>
        <div className="flex flex-col gap-3 sm:flex-row">
          <input
            className="w-full flex-1 rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 outline-none ring-emerald-500 focus:ring-2 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100"
            value={baseUrl}
            onChange={(e) => setBaseUrl(e.target.value)}
            placeholder="http://192.168.1.11:30081"
            spellCheck={false}
          />
          <button
            type="button"
            onClick={() => void loadAll()}
            className="rounded-lg bg-emerald-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-emerald-500"
          >
            Refresh
          </button>
        </div>
        <p className="mt-2 text-xs text-zinc-500">
          Default <code className="text-zinc-700 dark:text-zinc-300">/backend</code> proxies to
          FastAPI via Next.js (k3s-friendly). Optional direct API:{" "}
          <code className="text-zinc-700 dark:text-zinc-300">NEXT_PUBLIC_API_URL</code>.
        </p>
      </section>

      {error && (
        <div className="rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950/40 dark:text-red-200">
          {error}
        </div>
      )}

      <div className="grid gap-4 md:grid-cols-2">
        <ResultCard
          title="GET /health"
          state={healthState}
          body={health ? JSON.stringify(health, null, 2) : null}
        />
        <ResultCard
          title="GET /api/response"
          state={apiState}
          body={apiData ? JSON.stringify(apiData, null, 2) : null}
        />
      </div>

      {apiData?.success && (
        <section className="rounded-2xl border border-emerald-200 bg-emerald-50 p-5 dark:border-emerald-900 dark:bg-emerald-950/30">
          <h2 className="text-lg font-medium text-emerald-900 dark:text-emerald-100">
            {apiData.data.greeting}
          </h2>
          <p className="mt-1 text-sm text-emerald-800 dark:text-emerald-200">
            {apiData.message} · {apiData.framework}
          </p>
          <ul className="mt-3 flex flex-wrap gap-2">
            {apiData.data.items.map((item) => (
              <li
                key={item}
                className="rounded-full bg-emerald-600/10 px-3 py-1 text-xs font-medium text-emerald-800 dark:text-emerald-200"
              >
                {item}
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}

function ResultCard({
  title,
  state,
  body,
}: {
  title: string;
  state: LoadState;
  body: string | null;
}) {
  const badge =
    state === "ok"
      ? "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/50 dark:text-emerald-200"
      : state === "error"
        ? "bg-red-100 text-red-800 dark:bg-red-900/50 dark:text-red-200"
        : state === "loading"
          ? "bg-amber-100 text-amber-800 dark:bg-amber-900/50 dark:text-amber-200"
          : "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300";

  return (
    <article className="rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm dark:border-zinc-800 dark:bg-zinc-950">
      <div className="mb-3 flex items-center justify-between gap-2">
        <h2 className="text-sm font-semibold text-zinc-900 dark:text-zinc-100">
          {title}
        </h2>
        <span className={`rounded-full px-2.5 py-0.5 text-xs font-medium ${badge}`}>
          {state}
        </span>
      </div>
      <pre className="max-h-64 overflow-auto rounded-lg bg-zinc-50 p-3 text-xs text-zinc-800 dark:bg-zinc-900 dark:text-zinc-200">
        {body ?? (state === "loading" ? "Loading…" : "—")}
      </pre>
    </article>
  );
}

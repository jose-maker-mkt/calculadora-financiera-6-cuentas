interface Env {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  GOOGLE_SHEETS_WEBHOOK_URL: string;
}

type Job = { id: number; payload: Record<string, unknown>; attempts: number };

export default {
  async scheduled(_event: ScheduledEvent, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(syncPendingJobs(env));
  },
};

async function syncPendingJobs(env: Env): Promise<void> {
  const base = env.SUPABASE_URL.replace(/\/$/, "");
  const headers = {
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    "Content-Type": "application/json",
  };
  const claim = await fetch(`${base}/rest/v1/rpc/claim_sheets_sync_jobs`, {
    method: "POST", headers, body: JSON.stringify({ p_batch_size: 40 }),
  });
  if (!claim.ok) throw new Error(`Could not claim sync jobs: ${claim.status}`);
  const jobs = await claim.json() as Job[];
  let next = 0;
  const workers = Array.from({ length: Math.min(5, jobs.length) }, async () => {
    while (next < jobs.length) {
      const job = jobs[next++];
      let error: string | null = null;
      try {
        if (!env.GOOGLE_SHEETS_WEBHOOK_URL) throw new Error("Sheets webhook not configured");
        const response = await fetch(env.GOOGLE_SHEETS_WEBHOOK_URL, {
          method: "POST",
          headers: { "Content-Type": "text/plain;charset=utf-8" },
          body: JSON.stringify(job.payload),
          redirect: "follow",
        });
        if (!response.ok) throw new Error(`Sheets returned ${response.status}`);
        const text = await response.text();
        if (text && text.length < 4096) {
          try {
            const result = JSON.parse(text) as { ok?: boolean; success?: boolean };
            if (result.ok === false || result.success === false) throw new Error("Sheets rejected the record");
          } catch (parseError) {
            if (parseError instanceof Error && parseError.message === "Sheets rejected the record") throw parseError;
          }
        }
      } catch (cause) {
        error = cause instanceof Error ? cause.message : "Sheets sync failed";
      }
      await fetch(`${base}/rest/v1/rpc/finish_sheets_sync_job`, {
        method: "POST", headers,
        body: JSON.stringify({ p_job_id: job.id, p_error: error }),
      });
    }
  });
  await Promise.all(workers);
}

interface Env {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
}

type RegistrationPayload = {
  action?: string;
  registrationId?: string;
  [key: string]: unknown;
};

export const onRequestPost: PagesFunction<Env> = async ({ request, env }) => {
  const origin = request.headers.get("Origin");
  if (origin && origin !== new URL(request.url).origin) {
    return json({ error: "origin_not_allowed" }, 403);
  }
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    return json({ error: "backend_not_configured" }, 503);
  }
  const declaredLength = Number(request.headers.get("Content-Length") || 0);
  if (declaredLength > 16_384) return json({ error: "payload_too_large" }, 413);

  let body: RegistrationPayload;
  try {
    body = await request.json() as RegistrationPayload;
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const base = env.SUPABASE_URL.replace(/\/$/, "");
  const headers = {
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    "Content-Type": "application/json",
  };

  if (body.action === "pdf_downloaded") {
    if (typeof body.registrationId !== "string") return json({ error: "invalid_registration" }, 400);
    const response = await fetch(`${base}/rest/v1/rpc/record_diagnosis_pdf_download`, {
      method: "POST", headers, body: JSON.stringify({ p_registration_id: body.registrationId }),
    });
    if (!response.ok) return json({ error: "event_not_saved" }, 502);
    return json({ ok: true });
  }

  if (body.action !== "register" || body.consent !== true) {
    return json({ error: "consent_required" }, 400);
  }
  const response = await fetch(`${base}/rest/v1/rpc/submit_financial_diagnosis`, {
    method: "POST",
    headers,
    body: JSON.stringify({ p_data: body }),
  });
  if (!response.ok) {
    return json({ error: "registration_not_saved" }, 502);
  }
  const result = await response.json() as { registrationId?: string };
  if (!result.registrationId) return json({ error: "registration_not_saved" }, 502);
  return json({ ok: true, registrationId: result.registrationId }, 201);
};

function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

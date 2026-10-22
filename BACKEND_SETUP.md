# Backend setup (Supabase + Google Sheets)

This branch introduces a server-side registration endpoint and a durable queue for copying registrations to the existing Google Sheet. The browser no longer needs to write registrations directly to Apps Script. Supabase remains the source of truth; a scheduled Cloudflare Worker retries Sheet sync jobs.

## Before activation

1. Create the Supabase project in the South America (São Paulo) region.
2. In Supabase SQL Editor, apply `supabase/migrations/202610220001_initial_backend.sql`.
3. In the Cloudflare Pages project, set these server-side variables for both Preview and Production:
   - `SUPABASE_URL`
   - `SUPABASE_SERVICE_ROLE_KEY` (secret; never put this in browser code or GitHub)
4. Deploy the Worker from the `workers/` directory and set:
   - `SUPABASE_URL`
   - `SUPABASE_SERVICE_ROLE_KEY` (secret)
   - `GOOGLE_SHEETS_WEBHOOK_URL` (the existing Apps Script web app URL)
5. Confirm the Pages deployment has the registration endpoint and the Worker cron is active before directing event attendees to it.

The function stores the registration and a Sheets outbox job in one database transaction. The Worker processes jobs in small batches, retries failures with increasing delays, and clears the queued copy once Sheets accepts it. A Sheets outage therefore does not lose a registration or hold up the visitor's screen.

## Data and consent

The migration stores contact details, income/currency, calculated monthly investment amount, level, exchange rate, and consent timestamp. Anonymous browser users receive no direct database read/write permissions. The existing consent is recorded as `educational-simulation-v1`; the sync payload does not authorize advisor follow-up (`shareWithNestor=false`).

Before launch, confirm the privacy notice and the event team's retention policy for personal and financial data. Do not paste service-role keys into chat or commit them to the repository.

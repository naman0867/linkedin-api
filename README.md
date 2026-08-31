# LinkedIn Profile API

An HTTP API that accepts a LinkedIn member profile URL and returns the profile as
structured JSON. Authentication and data retrieval are both reverse-engineered
against LinkedIn's private endpoints — no browser, no headless driver, no
official API, no third-party data provider.

**Live:** https://linkedin-profile-api-81m4.onrender.com/docs
**Demo key:** `my-long-random-key-9f3k2j`

```bash
curl -G https://linkedin-profile-api-81m4.onrender.com/v1/profile \
  -H "X-API-Key: my-long-random-key-9f3k2j" \
  --data-urlencode "url=https://www.linkedin.com/in/williamhgates/"
```

> **Free tier:** the first request may take ~60s while the instance wakes.
>
> **Please read [Current status](#current-status-linkedin-endpoint-migration) first.**
> LinkedIn retired the profile endpoint this API was built against *during* the
> assignment window. Authentication works and is verified; profile retrieval
> currently returns a typed `UPSTREAM_ERROR` because the upstream returns
> `410 Gone`. The investigation, evidence and migration path are documented below.

---

## Contents

- [Current status](#current-status-linkedin-endpoint-migration)
- [Scope and legal position](#scope-and-legal-position)
- [Approach](#approach)
- [Setup](#setup)
- [API documentation](#api-documentation)
- [Response schema](#response-schema)
- [Known limitations](#known-limitations)
- [Testing](#testing)
- [Deployment](#deployment)
- [What I would do next](#what-i-would-do-next)

---

## Current status: LinkedIn endpoint migration

I am documenting this prominently rather than burying it, because it is the most
interesting thing I found and because a reviewer testing the live URL will hit it
immediately.

### What happened

This API was built against `/voyager/api/identity/profiles/{id}/profileView`, the
aggregate endpoint that has served LinkedIn profile data for years. On **31 August
2026**, that endpoint returns `410 Gone` — not 403, not 404. `410` is the status a
server sends when a resource has been *deliberately and permanently removed*. This
is a deprecation, not a block on my session.

### Evidence

Verified with a valid, authenticated session (`/voyager/api/me` returns `200`
throughout, so the session itself is sound):

| Endpoint | Status |
|---|---|
| `identity/profiles/{id}/profileView` | **410 Gone** |
| `identity/profiles/{id}` | **410 Gone** |
| `me` | **200 OK** |
| `identity/dash/profiles?q=memberIdentity&memberIdentity={id}` | **200 OK** |
| `identity/dash/profiles?...&decorationId=...FullProfileWithEntities-{55..71}` | **302** (all 17 versions) |

Reproducible via the probe scripts committed in `scripts/`:

```bash
python scripts/probe_endpoints.py williamhgates   # endpoint sweep
python scripts/probe2.py williamhgates            # collection endpoints + queryId discovery
```

### What this means

LinkedIn has moved from the legacy aggregate model to the **dash** model. Instead
of one call returning a nested document with `positionView`, `educationView` and
so on, the new design returns a normalized `{data, included}` graph, and each
profile section is a separate collection endpoint keyed by the profile URN.

The base `dash/profiles` call succeeds and returns the `Profile` entity. The
section collections (`profilePositionGroups`, `profileEducations`,
`profileSkills`, …) are the remaining piece. Probing them was cut short by
LinkedIn soft rate limiting: after roughly 30 requests the profile endpoints began
returning `302` redirects while `/me` continued to return `200`. I stopped rather
than push through it — sustained probing against a rate limit is how an account
gets restricted, and that seemed a worse outcome than an incomplete map.

### What works today

- Programmatic authentication against `/uas/authenticate` — verified, returns a
  valid `li_at`
- Session validation (`/me` → `200`)
- The new base profile endpoint (`dash/profiles` → `200`)
- URL parsing, response schema, caching, throttling, typed errors, 19 passing tests
- Live HTTPS deployment

### What does not

- Full profile assembly. Requires mapping the dash collection endpoints, which is
  the concrete next task described in [What I would do next](#what-i-would-do-next).

I would rather submit an honest account of a live API migration than a scraper
copied from a two-year-old tutorial that silently returns nothing.

---

## Scope and legal position

Leading with this because it shaped the design.

LinkedIn's User Agreement prohibits scraping and automated data collection. This
project authenticates with a real member session, so it operates *inside* that
agreement rather than outside it. *hiQ Labs v. LinkedIn* is often cited as
establishing that scraping public data is lawful, but that ruling concerned the
Computer Fraud and Abuse Act and unauthenticated access to public pages; on remand
LinkedIn prevailed on breach of contract. Authenticated collection is a materially
weaker position than the headline summary suggests.

Profile data is also personal data. Under GDPR and India's DPDP Act, collecting and
storing it engages obligations around lawful basis, retention and subject access
that a production deployment would have to answer for.

Consequences baked into the implementation:

- Outbound requests are throttled and serialized (`MIN_REQUEST_INTERVAL=2.5`,
  `MAX_CONCURRENT_FETCHES=2`)
- Responses are cached for 24h, so repeat lookups never touch LinkedIn
- Nothing is persisted beyond the cache TTL
- No credential is read from anywhere but the environment

For production I would argue for a licensed provider (Proxycurl, Bright Data, or
LinkedIn's partner APIs) and keep the reverse-engineered path for development only.
The adapter boundary in `app/sources/` exists so that swap is a one-file change.

---

## Approach

### Why the private API rather than HTML parsing

LinkedIn's web app is a client-side application that talks to a private REST layer
at `/voyager/api/*`. Reading that layer directly is more robust than parsing
rendered HTML: responses are already structured, they don't change when the
front-end is restyled, and one call can return many sections. It is also what the
brief asked for — a purely reverse-engineered solution that hits LinkedIn
endpoints directly, with no browser involved.

### Authentication is reverse-engineered too

The service does not rely on cookies harvested from a browser session. It replays
LinkedIn's login form against `/uas/authenticate` directly. **No browser or
headless driver is used at any point in the pipeline.**

Three steps, and the ordering matters:

1. `GET /uas/authenticate` — seeds a `JSESSIONID` cookie. Posting straight to step
   2 fails, because the CSRF value in the body has to match a session LinkedIn has
   already issued.
2. `POST /uas/authenticate` — form-encoded `session_key` / `session_password`, plus
   the `JSESSIONID` value as a CSRF field.
3. Read `li_at` from the response cookie jar.

The response is JSON with a `login_result` discriminator rather than a plain status
code, so `200` does not by itself mean success — a challenge also returns `200`.

**The quoting asymmetry** is the detail that costs people hours. `JSESSIONID` is
stored *with* surrounding quotes. The login body wants it **with** quotes; the
`csrf-token` header on subsequent Voyager calls wants it **without**. A one-character
mismatch produces a `403` on every request, which reads exactly like an expired
session.

Cookies are still supported as a fallback (`LINKEDIN_LI_AT` / `LINKEDIN_JSESSIONID`)
for the case where a datacenter IP triggers a verification challenge.

### Architecture

```
      POST /v1/profile
             │
             ▼
   ┌──────────────────┐
   │ urls.py          │  parse + validate → public identifier
   └────────┬─────────┘
            ▼
   ┌──────────────────┐
   │ cache.py         │  Redis, or in-process fallback  ──► hit ──► respond
   └────────┬─────────┘
            ▼ miss
   ┌──────────────────┐
   │ session.py       │  owns the session; re-authenticates on expiry
   └────────┬─────────┘
            ▼
   ┌──────────────────┐
   │ sources/voyager  │  throttled, session-authenticated fetch
   └────────┬─────────┘
            ▼
   ┌──────────────────┐
   │ normalize.py     │  upstream shapes → the public schema
   └────────┬─────────┘
            ▼
        Profile JSON
```

Five decisions worth calling out:

**A source is an adapter, not the architecture.** `app/sources/` holds fetching
strategy behind a narrow interface. Adding a dash-collections source or a
commercial provider means adding a file, not restructuring the service. Given what
happened to `profileView`, this turned out to matter more than I expected when I
designed it.

**Fetching is separate from normalizing.** `voyager.py` knows about cookies and
HTTP; `normalize.py` knows about response shapes. This makes the mapping logic
unit-testable against fixtures with no network access — see `tests/test_normalize.py`.

**Sessions self-heal.** Cookie expiry was the biggest weakness of a cookies-only
design: the session dies hours after submission and the whole API looks broken.
`session.py` re-authenticates on the first `SESSION_EXPIRED` and retries once. It
gives up permanently after a challenge, because a verification prompt will not
clear on retry and repeated failed logins are how accounts get locked.

**Partial failure degrades one section, not the request.** Supplementary calls that
fail are recorded in `meta.unavailable_sections` rather than failing the response.
Every accessor in `normalize.py` is defensive for the same reason.

**Upstream failures are typed.** `403` → `SESSION_EXPIRED`; `429`/`999` →
`RATE_LIMITED` with `retryable: true`; `410` → `UPSTREAM_ERROR`; unknown identifier
→ `PROFILE_NOT_FOUND`. A caller can act on these. A generic `500` tells them nothing.
This design is why the current upstream removal surfaces as a clean, diagnostic
JSON error instead of a stack trace.

---

## Setup

### 1. Install

```bash
git clone https://github.com/naman0867/linkedin-api.git
cd linkedin-api
python -m venv .venv && source .venv/bin/activate    # Windows: .venv\Scripts\activate
pip install -r requirements.txt -r requirements-dev.txt
```

### 2. Configure

```bash
cp .env.example .env
```

Preferred — credentials, so the session self-heals:

```ini
API_KEYS=pick-something-long
LINKEDIN_EMAIL=you@example.com
LINKEDIN_PASSWORD=your-password
```

Fallback — cookies, if programmatic login hits a challenge. From a logged-in
browser: DevTools → Application → Cookies → `https://www.linkedin.com`.

```ini
LINKEDIN_LI_AT=AQEDAT...
LINKEDIN_JSESSIONID="ajax:1234567890123456789"
```

Keep the quotes on `JSESSIONID`. The client strips them where needed and re-adds
them where needed.

`.env` is gitignored. No credential is read from anywhere but the environment.

### 3. Run

```bash
uvicorn app.main:app --reload
```

http://localhost:8000/docs

---

## API documentation

Profile endpoints require an `X-API-Key` header matching an entry in `API_KEYS`.

### `GET /healthz`

No auth. Reports session state and cache backend.

```json
{
  "status": "ok",
  "linkedin_session_configured": true,
  "auth_mode": "credentials",
  "can_self_heal": true,
  "cache_backend": "memory"
}
```

`auth_mode` is `credentials`, `cookies` or `none`. `can_self_heal` indicates
whether re-authentication is available after session expiry.

### `POST /v1/profile`

```bash
curl -X POST https://linkedin-profile-api-81m4.onrender.com/v1/profile \
  -H "X-API-Key: my-long-random-key-9f3k2j" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://www.linkedin.com/in/williamhgates/"}'
```

| Field | Type | Default | Notes |
|---|---|---|---|
| `url` | string | required | Any member URL shape: bare, `www.`, country subdomain, with query params, or a `/details/...` sub-path |
| `refresh` | bool | `false` | Bypass the cache and force a live fetch |

### `GET /v1/profile`

Same operation as a GET, for browser and plain-curl testing.

```bash
curl -G https://linkedin-profile-api-81m4.onrender.com/v1/profile \
  -H "X-API-Key: my-long-random-key-9f3k2j" \
  --data-urlencode "url=https://www.linkedin.com/in/williamhgates/"
```

### Errors

One envelope for every failure:

```json
{ "error": { "code": "SESSION_EXPIRED", "message": "...", "retryable": false } }
```

| HTTP | `code` | Meaning |
|---|---|---|
| 400 | `INVALID_URL` | Not a member profile URL |
| 401 | `UNAUTHORIZED` | Missing or unknown `X-API-Key` |
| 404 | `PROFILE_NOT_FOUND` | No such profile, or not visible to the session account |
| 502 | `UPSTREAM_ERROR` | Unexpected upstream response — **currently returned for all profile fetches, see [Current status](#current-status-linkedin-endpoint-migration)** |
| 503 | `SESSION_EXPIRED` | LinkedIn rejected the session |
| 503 | `RATE_LIMITED` | Throttled upstream; `retryable: true` |
| 503 | `NO_SESSION` | No LinkedIn credentials configured |

---

## Response schema

Abridged; full schema at `/docs` and in `app/schemas.py`.

```json
{
  "public_identifier": "williamhgates",
  "profile_url": "https://www.linkedin.com/in/williamhgates",
  "urn": "urn:li:fs_profile:ACoAAA...",
  "basics": {
    "first_name": "Bill",
    "last_name": "Gates",
    "full_name": "Bill Gates",
    "headline": "Co-chair, Bill & Melinda Gates Foundation",
    "about": "...",
    "industry": "Philanthropy",
    "location": { "raw": "Seattle, Washington", "country": "United States" },
    "profile_picture": [
      { "url": "https://media.licdn.com/.../800.jpg", "width": 800, "height": 800 }
    ]
  },
  "experience": [
    {
      "title": "Co-chair",
      "company": { "name": "Bill & Melinda Gates Foundation", "linkedin_url": "..." },
      "start_date": { "year": 2000, "month": 1 },
      "end_date": null,
      "is_current": true
    }
  ],
  "education": [ ... ],
  "skills": [ { "name": "Philanthropy", "endorsement_count": 42 } ],
  "certifications": [ ... ],
  "languages": [ { "name": "English", "proficiency": "NATIVE_OR_BILINGUAL" } ],
  "projects": [ ... ],
  "honors": [ ... ],
  "volunteer": [ ... ],
  "meta": {
    "source": "voyager",
    "fetched_at": "2026-08-31T10:15:00Z",
    "cache_hit": false,
    "duration_ms": 1830,
    "unavailable_sections": []
  }
}
```

Three choices I'd defend:

**Dates are structs, not strings.** LinkedIn routinely gives a year with no month
and never gives a day. Serialising `{"year": 2019}` as `"2019-01-01"` invents
precision that was never there, and every consumer then has to guess whether
January was real. `{"year": 2019, "month": null, "day": null}` is honest.

**`meta.unavailable_sections` exists** so `"skills": []` is unambiguous. An empty
array otherwise conflates "this member listed no skills" with "we could not
retrieve them", and those warrant different handling.

**Images are arrays with dimensions.** LinkedIn serves several resolutions;
returning all of them lets the consumer choose rather than baking in my guess.
They are signed URLs that expire, which `expires_at` records.

---

## Known limitations

**The profile endpoint has been retired.** `profileView` returns `410 Gone` as of
31 August 2026. Full detail, evidence and migration path in
[Current status](#current-status-linkedin-endpoint-migration). This is the dominant
limitation and everything below is secondary to it.

**Rate limits are undocumented and enforced silently.** LinkedIn publishes no
thresholds. During endpoint probing, roughly 30 requests in a few minutes was
enough to trigger soft limiting: profile endpoints began returning `302` while
`/me` still returned `200`. There is no `Retry-After`, no error body, no signal
other than the redirect. Conservative defaults reduce but do not eliminate this.

**Visibility is account-scoped.** Voyager returns what the *authenticated member*
can see. Second- and third-degree connections show reduced data; some profiles are
private. The same URL can legitimately yield different output from different
backing accounts, and a low-connection account returns substantially less.

**Account provisioning is a hard constraint.** I attempted to use a separate
account for testing and found newly created accounts are gated behind identity
verification — government ID, multi-day review. This has an architectural
consequence: **throughput cannot be scaled by adding accounts.** A production
system needs licensed data access, not more sessions. This is not a detail; it
caps the whole approach.

**Programmatic login is IP-sensitive.** It succeeded from a residential
connection. Datacenter IPs — which includes every cloud host — frequently trigger
`CHALLENGE_REQUIRED`, which cannot be resolved without out-of-band input. This is
why cookie fallback exists.

**Session tokens are the real secret.** `li_at` is a bearer token: anyone holding
it can act as the account without the password and without triggering 2FA. It is
environment-only, never logged, never committed.

**Not exhaustive.** Recommendations, endorsement detail, contact info, patents and
course lists are not mapped. Contact info sits behind a separate endpoint that
`403`s for most non-connections.

**Single-session throughput.** One account, serialized requests, ~2.5s apart. Real
throughput would need a session pool and residential proxies — and per the
provisioning constraint above, that pool is not obtainable at scale.

**Cache invalidation is time-based only.** A profile edited within the TTL serves
stale until it expires or `refresh: true` is passed. LinkedIn provides no change
signal.

---

## Testing

```bash
pytest -q
```

19 tests, no network access required.

- **`test_urls.py`** — URL parsing across the shapes people actually paste: bare
  domains, country subdomains, tracking params, `/details/` sub-paths, uppercase
  schemes. Plus rejection of company URLs, feed URLs, and lookalike domains such
  as `linkedin.com.evil.test`.
- **`test_normalize.py`** — the mapping layer against recorded fixtures: image
  artifacts reassembled largest-first, open-ended positions marked current, skills
  deduplicated across two sources, and missing sections degrading rather than
  raising.
- **`test_session.py`** — re-authentication behaviour: one retry on expiry, and
  *exactly one* login attempt after a challenge, verifying the lockout guard.

Splitting fetch from transform is what makes this possible. The mapping is the part
most likely to break when LinkedIn changes a response, so it needs to be cheap to
test — which is also what will make the dash migration tractable.

---

## Deployment

Live on Render's free tier via the committed `render.yaml`. Point Render at the
repo as a Blueprint and set the environment variables in the dashboard.

```bash
docker build -t linkedin-profile-api .
docker run -p 8000:8000 --env-file .env linkedin-profile-api
```

Two notes on the free tier: instances sleep after 15 minutes and take ~60s to wake,
and free Key Value storage is in-memory only, so a warmed cache does not survive a
restart. Set `REDIS_URL` on a paid tier for a cache that persists.

---

## What I would do next

Concretely, in order:

**1. Map the dash collections.** The base `dash/profiles` call returns the
`Profile` entity and its URN. Each section is then its own endpoint —
`identity/dash/profilePositionGroups?q=viewee&profileUrn={urn}` and siblings for
educations, skills, certifications and languages. `scripts/probe2.py` already
probes these; it needs a clean run outside a rate limit window.

**2. Write a `dash` source adapter.** A sibling to `voyager.py` behind the same
interface. The response is a normalized `{data, included}` graph rather than nested
views, so `normalize.py` gains a second mapper — resolving `$type` discriminators
and URN references across the `included` array — rather than being rewritten.

**3. Add GraphQL as a third adapter.** LinkedIn is migrating toward
`/voyager/api/graphql` with `queryId` build hashes that rotate on deploy. Pinning
them means re-extracting after each rotation, so the durable version discovers
them at runtime from the page bundle. `probe2.py` contains the discovery regex.

**4. Harden against exactly this class of failure.** The 410 should have been
caught by a scheduled canary rather than by a manual fetch. A daily job hitting a
known profile, asserting non-empty core fields, and alerting on drift would turn a
silent breakage into a notification.

The architecture already anticipated this specific problem — the original
limitations section flagged `profileView` as legacy and named the GraphQL
migration as the risk. The adapter boundary is why the fix is additive rather than
a rewrite. What I would change is the monitoring: I designed for the failure but
had no way to detect it early.

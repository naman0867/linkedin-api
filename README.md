# LinkedIn Profile API

An HTTP API that accepts a LinkedIn member profile URL and returns the profile as
structured JSON.

```
POST /v1/profile   { "url": "https://www.linkedin.com/in/williamhgates/" }
```

Live: `https://<your-deployment>/docs` â€” interactive OpenAPI docs are generated
from the code, so they cannot drift from the implementation.

---

## Contents

- [Scope and legal position](#scope-and-legal-position)
- [Approach](#approach)
- [Setup](#setup)
- [API documentation](#api-documentation)
- [Response schema](#response-schema)
- [Known limitations](#known-limitations)
- [Testing](#testing)
- [Deployment](#deployment)

---

## Scope and legal position

Leading with this because it shaped every design decision below.

LinkedIn's User Agreement prohibits scraping and automated data collection. This
project authenticates with a real member session, which means it operates inside
that agreement rather than outside it. *hiQ Labs v. LinkedIn* is often cited as
establishing that scraping public data is lawful, but that ruling concerned the
Computer Fraud and Abuse Act and unauthenticated access to public pages; on
remand LinkedIn prevailed on breach of contract. Authenticated collection is a
materially weaker position than the headline summary of that case suggests.

Separately, profile data is personal data. Under GDPR and India's DPDP Act,
collecting and storing it engages obligations around lawful basis, retention and
subject access that a production deployment would have to answer for.

Practical consequences baked into this implementation:

- **Use a throwaway LinkedIn account.** Accounts used this way get restricted.
  Do not use one you care about.
- Outbound requests are throttled and serialized by default
  (`MIN_REQUEST_INTERVAL=2.5`, `MAX_CONCURRENT_FETCHES=2`).
- Responses are cached for 24h so repeated lookups never touch LinkedIn.
- Nothing is persisted beyond the cache TTL.

If this were going to production rather than being a hiring exercise, I would
argue for a licensed data provider (Proxycurl, Bright Data, or LinkedIn's own
partner APIs) and keep the scraping path only as a development fallback. The
adapter boundary in `app/sources/` exists precisely so that swap is a one-file
change.

---

## Approach

### Why the internal API rather than HTML parsing

LinkedIn's web app is a client-side application that talks to a private REST
layer at `/voyager/api/*`. Reading that layer directly is both more robust and
less work than parsing rendered HTML: the responses are already structured, they
do not change when the front-end is restyled, and a single `profileView` call
returns positions, education, certifications, languages, projects, honours and
volunteering together.

Authenticating is a matter of faithfully replaying what a logged-in browser
sends:

| Element | Value |
|---|---|
| Cookie `li_at` | the session token |
| Cookie `JSESSIONID` | a quoted value, e.g. `"ajax:1234567890123456789"` |
| Header `csrf-token` | the same JSESSIONID value **with quotes stripped** |
| Header `x-restli-protocol-version` | `2.0.0` |

The quote handling is the detail that trips people up. If `csrf-token` and the
`JSESSIONID` cookie disagree by so much as a quote character, every request
returns 403 â€” and it is easy to misread that as an expired session.

### Architecture

```
      POST /v1/profile
             â”‚
             â–¼
   â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
   â”‚ urls.py          â”‚  parse + validate â†’ public identifier
   â””â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
            â–¼
   â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
   â”‚ cache.py         â”‚  Redis, or in-process fallback  â”€â”€â–º hit â”€â”€â–º respond
   â””â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
            â–¼ miss
   â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
   â”‚ sources/voyager  â”‚  throttled, session-authenticated fetch
   â””â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
            â–¼
   â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
   â”‚ normalize.py     â”‚  Voyager's shapes â†’ the public schema
   â””â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
            â–¼
        Profile JSON
```

Four decisions worth calling out:

**A source is an adapter, not the architecture.** `app/sources/` holds the
fetching strategy behind a narrow interface. Adding a public-HTML fallback or a
commercial provider means adding a file, not restructuring the service.

**Fetching is separate from normalizing.** `voyager.py` knows about cookies and
HTTP; `normalize.py` knows about LinkedIn's response shapes. This is what makes
the mapping logic unit-testable against fixtures without any network access â€”
see `tests/test_normalize.py`.

**Partial failure degrades one section, not the request.** Skills are fetched
separately because `profileView` truncates them. If that supplementary call
fails, the profile still returns and `meta.unavailable_sections` records the
gap. Every accessor in `normalize.py` is defensive for the same reason: LinkedIn
changes these structures without notice, and a missing key should cost one field
rather than the response.

**Upstream failures are typed.** A 403 becomes `SESSION_EXPIRED`, a 999 becomes
`RATE_LIMITED` with `retryable: true`, an unknown identifier becomes
`PROFILE_NOT_FOUND`. A caller can act on these; a generic 500 tells them nothing.

---

## Setup

### 1. Install

```bash
git clone https://github.com/<you>/linkedin-profile-api.git
cd linkedin-profile-api
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

### 2. Getting your cookies

1. Log into LinkedIn in a browser, **using a burner account**.
2. Open DevTools â†’ Application â†’ Cookies â†’ `https://www.linkedin.com`.
3. Copy the values of `li_at` and `JSESSIONID`.
4. Keep the surrounding quotes on `JSESSIONID` â€” the client strips them where
   needed and re-adds them where needed.

### 3. Configure

```bash
cp .env.example .env
```

```ini
API_KEYS=pick-something-long
LINKEDIN_LI_AT=AQEDAT...
LINKEDIN_JSESSIONID="ajax:1234567890123456789"
```

`.env` is gitignored. No credential is ever read from anywhere but the
environment, so nothing secret reaches the repository.

### 4. Run

```bash
uvicorn app.main:app --reload
```

Then open http://localhost:8000/docs.

---

## API documentation

All profile endpoints require an `X-API-Key` header matching an entry in
`API_KEYS`.

### `GET /healthz`

No auth. Reports whether a LinkedIn session is configured and which cache
backend is active.

```json
{ "status": "ok", "linkedin_session_configured": true, "cache_backend": "redis" }
```

### `POST /v1/profile`

```bash
curl -X POST https://<host>/v1/profile \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://www.linkedin.com/in/williamhgates/"}'
```

| Field | Type | Default | Notes |
|---|---|---|---|
| `url` | string | required | Any member URL shape: bare, `www.`, country subdomain, with query params, or a `/details/...` sub-path |
| `refresh` | bool | `false` | Bypass the cache and force a live fetch |

### `GET /v1/profile`

The same operation as a GET, for browser and plain-curl testing.

```bash
curl -G https://<host>/v1/profile \
  -H "X-API-Key: $API_KEY" \
  --data-urlencode "url=https://www.linkedin.com/in/williamhgates/"
```

### Errors

Every error shares one envelope:

```json
{ "error": { "code": "SESSION_EXPIRED", "message": "...", "retryable": false } }
```

| HTTP | `code` | Meaning |
|---|---|---|
| 400 | `INVALID_URL` | Not a member profile URL |
| 401 | `UNAUTHORIZED` | Missing or unknown `X-API-Key` |
| 404 | `PROFILE_NOT_FOUND` | No such profile, or not visible to the session account |
| 503 | `SESSION_EXPIRED` | LinkedIn rejected the cookies â€” refresh them |
| 503 | `RATE_LIMITED` | Throttled upstream; `retryable: true`, back off |
| 503 | `NO_SESSION` | Deployment has no LinkedIn credentials configured |
| 502 | `UPSTREAM_ERROR` | Unexpected upstream response |

---

## Response schema

Abridged; the full schema is at `/docs` and in `app/schemas.py`.

```json
{
  "public_identifier": "williamhgates",
  "profile_url": "https://www.linkedin.com/in/williamhgates",
  "urn": "urn:li:fs_profile:ACoAAA...",
  "basics": {
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
    "fetched_at": "2026-08-27T10:15:00Z",
    "cache_hit": false,
    "duration_ms": 1830,
    "unavailable_sections": []
  }
}
```

Three schema choices I'd defend:

**Dates are structs, not strings.** LinkedIn routinely gives a year with no
month and never gives a day. Serialising `{"year": 2019}` as `"2019-01-01"`
invents precision that was never there, and every downstream consumer then has
to guess whether January was real. `{"year": 2019, "month": null, "day": null}`
is honest.

**`meta.unavailable_sections` exists** so that `"skills": []` is unambiguous. An
empty array otherwise conflates "this member listed no skills" with "we could
not retrieve them", and those warrant very different handling by a caller.

**Images are arrays with dimensions.** LinkedIn serves several resolutions;
returning all of them lets the consumer pick, rather than baking my guess in.
They are signed URLs that expire, which `expires_at` records.

---

## Known limitations

**Session fragility.** Cookies expire, and LinkedIn issues security challenges
that invalidate them early. There is no automated re-login â€” that would mean
handling credentials and 2FA, which is both more invasive and more fragile than
rotating a cookie by hand. Expiry surfaces as an explicit `SESSION_EXPIRED`
rather than a confusing 500.

**Visibility is account-scoped.** Voyager returns what the *authenticated
member* can see. Second- and third-degree connections show reduced data, and
some profiles are private. The API cannot return fields LinkedIn does not serve
to that session, so the same URL can legitimately yield different output from
different backing accounts.

**Rate limits are undocumented and enforced silently.** LinkedIn does not
publish thresholds. Sustained automated access leads to HTTP 999, challenge
pages, and eventually account restriction. The conservative defaults here reduce
but do not eliminate that risk.

**`profileView` is legacy.** LinkedIn is migrating to a GraphQL layer whose
`queryId` values are build hashes that rotate on deploy. Pinning them means
re-extracting after each rotation. I kept `profileView` because it is stable
today and does not require that maintenance; the adapter boundary is where a
GraphQL source would slot in when it stops working.

**Not exhaustive.** Recommendations, endorsement detail, contact info,
publications, patents and course lists are not mapped. Contact info in
particular sits behind a separate endpoint that 403s on most non-connections.

**Single-session throughput.** One account, serialized requests, ~2.5s apart.
Real throughput would need a pool of sessions and residential proxies. That is a
proxy-infrastructure problem more than a code problem, and it pushes further
into territory the legal section above is cautious about.

**Cache invalidation is time-based only.** A profile edited within the TTL
serves stale until it expires or `refresh: true` is passed. There is no change
signal from LinkedIn to do better.

---

## Testing

```bash
pytest -q
```

16 tests covering URL parsing across the shapes people actually paste, and the
normalization layer against recorded fixtures. The normalization tests run with
no network access, which is the point of splitting fetch from transform â€” the
mapping is the part most likely to break when LinkedIn changes a response, and
it is the part that needs to be cheap to test.

---

## Deployment

Any container host works. With Railway or Render, point at the repo and set the
environment variables from `.env.example` in the dashboard; both terminate TLS
and provide HTTPS by default.

```bash
docker build -t linkedin-profile-api .
docker run -p 8000:8000 --env-file .env linkedin-profile-api
```

Set `REDIS_URL` in production so the cache survives restarts. Without it the
service falls back to an in-process cache, which works but is cold on every
deploy â€” and a cold cache means more outbound requests to LinkedIn.


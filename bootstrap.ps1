# Writes every project file with correct content.
# Usage:  powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1

$ErrorActionPreference = 'Stop'

foreach ($d in @('app', 'app\sources', 'scripts', 'tests')) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

$content = @'
fastapi>=0.115.0
uvicorn[standard]>=0.30.0
httpx>=0.27.0
pydantic>=2.7.0
pydantic-settings>=2.3.0
selectolax>=0.3.21
redis>=5.0.0

'@
Set-Content -Path 'requirements.txt' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote requirements.txt'

$content = @'
pytest>=8.0.0
pytest-asyncio>=0.23.0

'@
Set-Content -Path 'requirements-dev.txt' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote requirements-dev.txt'

$content = @'
[pytest]
asyncio_mode = auto

'@
Set-Content -Path 'pytest.ini' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote pytest.ini'

$content = @'
.env
.env.*
!.env.example
__pycache__/
*.py[cod]
.venv/
venv/
.pytest_cache/
.mypy_cache/
*.log
cookies.json

# Raw upstream dumps (personal data, unredacted)
raw/

'@
Set-Content -Path '.gitignore' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote .gitignore'

$content = @'
# ---- Your API's own auth (clients must send this as X-API-Key) ----
API_KEYS=dev-local-key-change-me

# ---- LinkedIn session cookies (see README: "Getting your cookies") ----
# Grab these from a logged-in browser session. Use a BURNER account.
LINKEDIN_LI_AT=
LINKEDIN_JSESSIONID=

# ---- OR: programmatic login (no browser, session self-heals on expiry) ----
# Preferred for deployment. Cloud IPs often trigger a verification challenge;
# if so, fall back to the cookies above.
LINKEDIN_EMAIL=
LINKEDIN_PASSWORD=

# ---- Optional ----
# Outbound proxy for LinkedIn requests, e.g. http://user:pass@host:port
LINKEDIN_PROXY=
# Redis for caching. Falls back to in-process memory cache if unset.
REDIS_URL=
CACHE_TTL_SECONDS=86400
# Throttle: minimum seconds between two outbound LinkedIn requests
MIN_REQUEST_INTERVAL=2.5
MAX_CONCURRENT_FETCHES=2

'@
Set-Content -Path '.env.example' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote .env.example'

$content = @'
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

EXPOSE 8000
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]

'@
Set-Content -Path 'Dockerfile' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote Dockerfile'

$content = @'
services:
  - type: web
    name: linkedin-profile-api
    runtime: python
    plan: free
    buildCommand: pip install -r requirements.txt
    startCommand: uvicorn app.main:app --host 0.0.0.0 --port $PORT
    healthCheckPath: /healthz
    envVars:
      - key: PYTHON_VERSION
        value: "3.12.4"
      # Set these in the Render dashboard, never here.
      - key: API_KEYS
        sync: false
      - key: LINKEDIN_LI_AT
        sync: false
      - key: LINKEDIN_JSESSIONID
        sync: false

'@
Set-Content -Path 'render.yaml' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote render.yaml'

$content = @'
# LinkedIn Profile API

An HTTP API that accepts a LinkedIn member profile URL and returns the profile as
structured JSON.

```
POST /v1/profile   { "url": "https://www.linkedin.com/in/williamhgates/" }
```

Live: `https://<your-deployment>/docs` — interactive OpenAPI docs are generated
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
returns 403 — and it is easy to misread that as an expired session.

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
   │ sources/voyager  │  throttled, session-authenticated fetch
   └────────┬─────────┘
            ▼
   ┌──────────────────┐
   │ normalize.py     │  Voyager's shapes → the public schema
   └────────┬─────────┘
            ▼
        Profile JSON
```

Four decisions worth calling out:

**A source is an adapter, not the architecture.** `app/sources/` holds the
fetching strategy behind a narrow interface. Adding a public-HTML fallback or a
commercial provider means adding a file, not restructuring the service.

**Fetching is separate from normalizing.** `voyager.py` knows about cookies and
HTTP; `normalize.py` knows about LinkedIn's response shapes. This is what makes
the mapping logic unit-testable against fixtures without any network access —
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
2. Open DevTools → Application → Cookies → `https://www.linkedin.com`.
3. Copy the values of `li_at` and `JSESSIONID`.
4. Keep the surrounding quotes on `JSESSIONID` — the client strips them where
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
| 503 | `SESSION_EXPIRED` | LinkedIn rejected the cookies — refresh them |
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
that invalidate them early. There is no automated re-login — that would mean
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
no network access, which is the point of splitting fetch from transform — the
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
deploy — and a cold cache means more outbound requests to LinkedIn.

'@
Set-Content -Path 'README.md' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote README.md'

New-Item -ItemType File -Force -Path 'app\__init__.py' | Out-Null
Write-Host '  wrote app\__init__.py (empty package marker)'

$content = @'
from __future__ import annotations

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # Auth for *this* API. Comma-separated list of accepted client keys.
    api_keys: str = "dev-local-key-change-me"

    # LinkedIn session. Never commit these.
    linkedin_li_at: str = ""
    linkedin_jsessionid: str = ""
    linkedin_email: str = ""
    linkedin_password: str = ""
    linkedin_proxy: str | None = None

    # Caching
    redis_url: str | None = None
    cache_ttl_seconds: int = 86_400

    # Politeness / self-preservation
    min_request_interval: float = 2.5
    max_concurrent_fetches: int = 2
    request_timeout: float = 20.0

    user_agent: str = (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
    )

    @property
    def api_key_set(self) -> set[str]:
        return {k.strip() for k in self.api_keys.split(",") if k.strip()}

    @property
    def has_linkedin_session(self) -> bool:
        return bool(self.linkedin_li_at and self.linkedin_jsessionid)

    @property
    def has_linkedin_credentials(self) -> bool:
        return bool(self.linkedin_email and self.linkedin_password)


@lru_cache
def get_settings() -> Settings:
    return Settings()

'@
Set-Content -Path 'app\config.py' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote app\config.py'

$content = @'
from __future__ import annotations

import re
from urllib.parse import unquote, urlparse

_PROFILE_PATH = re.compile(r"^/(?:in|pub)/([^/?#]+)")
_VALID_IDENT = re.compile(r"^[\w\-%.]{1,120}$", re.UNICODE)


class InvalidProfileURL(ValueError):
    """Raised when the input is not a usable LinkedIn profile URL."""


def parse_public_identifier(raw: str) -> str:
    """Extract the public identifier (the '/in/<this>' slug) from a profile URL.

    Accepts the many shapes people actually paste:
      linkedin.com/in/naman
      https://www.linkedin.com/in/naman/
      https://in.linkedin.com/in/naman?trk=whatever
      https://www.linkedin.com/in/naman/details/experience/
    """
    if not raw or not isinstance(raw, str):
        raise InvalidProfileURL("A LinkedIn profile URL is required.")

    candidate = raw.strip()
    if not candidate:
        raise InvalidProfileURL("A LinkedIn profile URL is required.")

    if not candidate.lower().startswith(("http://", "https://")):
        candidate = "https://" + candidate

    parsed = urlparse(candidate)
    host = parsed.netloc.lower().split(":")[0]

    # LinkedIn serves country subdomains: in., uk., de., etc.
    if host != "linkedin.com" and not host.endswith(".linkedin.com"):
        raise InvalidProfileURL(f"'{host}' is not a LinkedIn domain.")

    match = _PROFILE_PATH.match(parsed.path)
    if not match:
        raise InvalidProfileURL(
            "Expected a member profile path like /in/<identifier>. "
            "Company, school and job URLs are not supported."
        )

    identifier = unquote(match.group(1)).strip()
    if not identifier or not _VALID_IDENT.match(identifier):
        raise InvalidProfileURL(f"Could not read a valid identifier from '{raw}'.")

    return identifier


def canonical_url(public_identifier: str) -> str:
    return f"https://www.linkedin.com/in/{public_identifier}"

'@
Set-Content -Path 'app\urls.py' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote app\urls.py'

$content = @'
from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Literal

from pydantic import BaseModel, Field


class Source(str, Enum):
    VOYAGER = "voyager"
    PUBLIC_HTML = "public_html"
    CACHE = "cache"


class PartialDate(BaseModel):
    """LinkedIn dates are frequently incomplete ('2019', 'Mar 2019', no day ever).

    Modelling this as a struct rather than a date string means a consumer never
    has to guess whether '2019-01-01' meant January or just 'sometime in 2019'.
    """

    year: int | None = None
    month: int | None = Field(default=None, ge=1, le=12)
    day: int | None = Field(default=None, ge=1, le=31)


class Image(BaseModel):
    url: str
    width: int | None = None
    height: int | None = None
    expires_at: datetime | None = Field(
        default=None,
        description="LinkedIn media URLs are signed and expire. Re-fetch rather than hotlink.",
    )


class Location(BaseModel):
    raw: str | None = None
    city: str | None = None
    country: str | None = None
    country_code: str | None = None


class Organization(BaseModel):
    name: str | None = None
    linkedin_url: str | None = None
    urn: str | None = None
    logo: Image | None = None


class Basics(BaseModel):
    first_name: str | None = None
    last_name: str | None = None
    full_name: str | None = None
    headline: str | None = None
    about: str | None = None
    industry: str | None = None
    location: Location = Field(default_factory=Location)
    is_student: bool | None = None
    profile_picture: list[Image] = Field(default_factory=list)
    background_image: list[Image] = Field(default_factory=list)


class Experience(BaseModel):
    title: str | None = None
    company: Organization = Field(default_factory=Organization)
    employment_type: str | None = None
    location: str | None = None
    description: str | None = None
    start_date: PartialDate = Field(default_factory=PartialDate)
    end_date: PartialDate | None = None
    is_current: bool = False


class Education(BaseModel):
    school: Organization = Field(default_factory=Organization)
    degree: str | None = None
    field_of_study: str | None = None
    grade: str | None = None
    activities: str | None = None
    description: str | None = None
    start_date: PartialDate = Field(default_factory=PartialDate)
    end_date: PartialDate | None = None


class Skill(BaseModel):
    name: str
    endorsement_count: int | None = None


class Certification(BaseModel):
    name: str | None = None
    authority: str | None = None
    license_number: str | None = None
    url: str | None = None
    issued_on: PartialDate | None = None
    expires_on: PartialDate | None = None


class Language(BaseModel):
    name: str
    proficiency: str | None = None


class Project(BaseModel):
    title: str | None = None
    description: str | None = None
    url: str | None = None
    start_date: PartialDate | None = None
    end_date: PartialDate | None = None


class Honor(BaseModel):
    title: str | None = None
    issuer: str | None = None
    description: str | None = None
    issued_on: PartialDate | None = None


class Volunteer(BaseModel):
    role: str | None = None
    organization: Organization = Field(default_factory=Organization)
    cause: str | None = None
    description: str | None = None
    start_date: PartialDate | None = None
    end_date: PartialDate | None = None


class Meta(BaseModel):
    source: Source
    fetched_at: datetime
    cache_hit: bool = False
    duration_ms: int | None = None
    unavailable_sections: list[str] = Field(
        default_factory=list,
        description="Sections the upstream refused or omitted, so an empty list is "
        "distinguishable from 'the member has none'.",
    )


class Profile(BaseModel):
    public_identifier: str
    profile_url: str
    urn: str | None = None
    basics: Basics = Field(default_factory=Basics)
    experience: list[Experience] = Field(default_factory=list)
    education: list[Education] = Field(default_factory=list)
    skills: list[Skill] = Field(default_factory=list)
    certifications: list[Certification] = Field(default_factory=list)
    languages: list[Language] = Field(default_factory=list)
    projects: list[Project] = Field(default_factory=list)
    honors: list[Honor] = Field(default_factory=list)
    volunteer: list[Volunteer] = Field(default_factory=list)
    meta: Meta


class ProfileRequest(BaseModel):
    url: str = Field(
        ...,
        description="A LinkedIn member profile URL.",
        examples=["https://www.linkedin.com/in/williamhgates/"],
    )
    refresh: bool = Field(
        default=False, description="Bypass the cache and force a live fetch."
    )


class ErrorBody(BaseModel):
    code: str
    message: str
    retryable: bool = False


class ErrorResponse(BaseModel):
    error: ErrorBody


class Health(BaseModel):
    status: Literal["ok", "degraded"]
    linkedin_session_configured: bool
    auth_mode: Literal["credentials", "cookies", "none"]
    can_self_heal: bool
    cache_backend: str

'@
Set-Content -Path 'app\schemas.py' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote app\schemas.py'

$content = @'
"""Cache abstraction with a Redis backend and an in-process fallback.

Caching is not a nice-to-have here. Every cache hit is an outbound request that
never touches LinkedIn, which is the main lever for keeping the session alive.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import Any, Protocol

log = logging.getLogger(__name__)


class Cache(Protocol):
    name: str

    async def get(self, key: str) -> dict[str, Any] | None: ...
    async def set(self, key: str, value: dict[str, Any], ttl: int) -> None: ...
    async def aclose(self) -> None: ...


class MemoryCache:
    name = "memory"

    def __init__(self, max_entries: int = 1024) -> None:
        self._store: dict[str, tuple[float, dict[str, Any]]] = {}
        self._max = max_entries
        self._lock = asyncio.Lock()

    async def get(self, key: str) -> dict[str, Any] | None:
        async with self._lock:
            entry = self._store.get(key)
            if not entry:
                return None
            expires_at, value = entry
            if expires_at < time.time():
                self._store.pop(key, None)
                return None
            return value

    async def set(self, key: str, value: dict[str, Any], ttl: int) -> None:
        async with self._lock:
            if len(self._store) >= self._max:
                oldest = min(self._store, key=lambda k: self._store[k][0])
                self._store.pop(oldest, None)
            self._store[key] = (time.time() + ttl, value)

    async def aclose(self) -> None:
        self._store.clear()


class RedisCache:
    name = "redis"

    def __init__(self, url: str) -> None:
        import redis.asyncio as redis

        self._redis = redis.from_url(url, decode_responses=True)

    async def get(self, key: str) -> dict[str, Any] | None:
        try:
            payload = await self._redis.get(key)
        except Exception as exc:  # a cache outage must not fail the request
            log.warning("redis get failed: %s", exc)
            return None
        if not payload:
            return None
        try:
            return json.loads(payload)
        except ValueError:
            return None

    async def set(self, key: str, value: dict[str, Any], ttl: int) -> None:
        try:
            await self._redis.set(key, json.dumps(value, default=str), ex=ttl)
        except Exception as exc:
            log.warning("redis set failed: %s", exc)

    async def aclose(self) -> None:
        await self._redis.aclose()


def build_cache(redis_url: str | None) -> Cache:
    if redis_url:
        try:
            return RedisCache(redis_url)
        except Exception as exc:
            log.warning("Redis unavailable (%s); falling back to memory cache.", exc)
    return MemoryCache()


def cache_key(public_identifier: str) -> str:
    return f"profile:v1:{public_identifier.lower()}"

'@
Set-Content -Path 'app\cache.py' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote app\cache.py'

$content = @'
"""Translate Voyager's response shapes into the schema in schemas.py.

Voyager returns a deeply nested, union-typed structure with keys like
`com.linkedin.common.VectorImage`. Every accessor here is defensive: LinkedIn
changes these shapes without notice and a missing key should degrade one field,
never fail the whole request.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from .schemas import (
    Basics,
    Certification,
    Education,
    Experience,
    Honor,
    Image,
    Language,
    Location,
    Meta,
    Organization,
    PartialDate,
    Profile,
    Project,
    Skill,
    Source,
    Volunteer,
)
from .urls import canonical_url


# --------------------------------------------------------------------- helpers


def _dig(obj: Any, *path: str) -> Any:
    for key in path:
        if not isinstance(obj, dict):
            return None
        obj = obj.get(key)
    return obj


def _elements(obj: Any, key: str) -> list[dict[str, Any]]:
    section = _dig(obj, key, "elements")
    return [e for e in section if isinstance(e, dict)] if isinstance(section, list) else []


def _date(node: Any) -> PartialDate | None:
    if not isinstance(node, dict):
        return None
    year, month, day = node.get("year"), node.get("month"), node.get("day")
    if year is None and month is None and day is None:
        return None
    return PartialDate(year=year, month=month, day=day)


def _images(node: Any) -> list[Image]:
    """Rebuild media URLs from LinkedIn's VectorImage artifacts.

    A VectorImage carries a `rootUrl` plus per-resolution `artifacts`, each with
    a `fileIdentifyingUrlPathSegment`. The full URL is the concatenation. These
    URLs are signed and expire, typically within weeks.
    """
    if not isinstance(node, dict):
        return []
    vector = node.get("com.linkedin.common.VectorImage")
    if not isinstance(vector, dict):
        vector = node
    root = vector.get("rootUrl")
    artifacts = vector.get("artifacts")
    if not root or not isinstance(artifacts, list):
        return []

    out: list[Image] = []
    for art in artifacts:
        if not isinstance(art, dict):
            continue
        segment = art.get("fileIdentifyingUrlPathSegment")
        if not segment:
            continue
        expiry = art.get("expiresAt")
        out.append(
            Image(
                url=f"{root}{segment}",
                width=art.get("width"),
                height=art.get("height"),
                expires_at=(
                    datetime.fromtimestamp(expiry / 1000, tz=timezone.utc)
                    if isinstance(expiry, (int, float))
                    else None
                ),
            )
        )
    return sorted(out, key=lambda i: i.width or 0, reverse=True)


def _org_from_mini(mini: Any, kind: str = "company") -> Organization:
    if not isinstance(mini, dict):
        return Organization()
    identifier = mini.get("universalName") or mini.get("publicIdentifier")
    return Organization(
        name=mini.get("name"),
        urn=mini.get("entityUrn") or mini.get("objectUrn"),
        linkedin_url=(
            f"https://www.linkedin.com/{kind}/{identifier}" if identifier else None
        ),
        logo=next(iter(_images(mini.get("logo"))), None),
    )


# ------------------------------------------------------------------- sections


def _basics(profile: dict[str, Any]) -> Basics:
    mini = profile.get("miniProfile") if isinstance(profile.get("miniProfile"), dict) else {}
    first = profile.get("firstName")
    last = profile.get("lastName")
    full = " ".join(p for p in (first, last) if p) or None

    return Basics(
        first_name=first,
        last_name=last,
        full_name=full,
        headline=profile.get("headline") or mini.get("occupation"),
        about=profile.get("summary"),
        industry=profile.get("industryName"),
        is_student=profile.get("student"),
        location=Location(
            raw=profile.get("geoLocationName") or profile.get("locationName"),
            city=profile.get("geoLocationName"),
            country=profile.get("geoCountryName"),
            country_code=(_dig(profile, "location", "basicLocation", "countryCode") or "").upper()
            or None,
        ),
        profile_picture=_images(mini.get("picture")),
        background_image=_images(mini.get("backgroundImage")),
    )


def _experience(raw: dict[str, Any]) -> list[Experience]:
    out: list[Experience] = []
    for item in _elements(raw, "positionView"):
        period = item.get("timePeriod") or {}
        end = _date(period.get("endDate"))
        company = _org_from_mini(_dig(item, "company", "miniCompany"))
        if not company.name:
            company.name = item.get("companyName")
        out.append(
            Experience(
                title=item.get("title"),
                company=company,
                employment_type=item.get("employmentType"),
                location=item.get("locationName") or item.get("geoLocationName"),
                description=item.get("description"),
                start_date=_date(period.get("startDate")) or PartialDate(),
                end_date=end,
                is_current=end is None,
            )
        )
    return out


def _education(raw: dict[str, Any]) -> list[Education]:
    out: list[Education] = []
    for item in _elements(raw, "educationView"):
        period = item.get("timePeriod") or {}
        school = _org_from_mini(_dig(item, "school"), kind="school")
        if not school.name:
            school.name = item.get("schoolName")
        out.append(
            Education(
                school=school,
                degree=item.get("degreeName"),
                field_of_study=item.get("fieldOfStudy"),
                grade=item.get("grade"),
                activities=item.get("activities"),
                description=item.get("description"),
                start_date=_date(period.get("startDate")) or PartialDate(),
                end_date=_date(period.get("endDate")),
            )
        )
    return out


def _certifications(raw: dict[str, Any]) -> list[Certification]:
    out: list[Certification] = []
    for item in _elements(raw, "certificationView"):
        period = item.get("timePeriod") or {}
        out.append(
            Certification(
                name=item.get("name"),
                authority=item.get("authority"),
                license_number=item.get("licenseNumber"),
                url=item.get("url"),
                issued_on=_date(period.get("startDate")),
                expires_on=_date(period.get("endDate")),
            )
        )
    return out


def _languages(raw: dict[str, Any]) -> list[Language]:
    return [
        Language(name=item["name"], proficiency=item.get("proficiency"))
        for item in _elements(raw, "languageView")
        if item.get("name")
    ]


def _projects(raw: dict[str, Any]) -> list[Project]:
    out: list[Project] = []
    for item in _elements(raw, "projectView"):
        period = item.get("timePeriod") or {}
        out.append(
            Project(
                title=item.get("title"),
                description=item.get("description"),
                url=item.get("url"),
                start_date=_date(period.get("startDate")),
                end_date=_date(period.get("endDate")),
            )
        )
    return out


def _honors(raw: dict[str, Any]) -> list[Honor]:
    out: list[Honor] = []
    for item in _elements(raw, "honorView"):
        out.append(
            Honor(
                title=item.get("title"),
                issuer=item.get("issuer"),
                description=item.get("description"),
                issued_on=_date(item.get("issueDate")),
            )
        )
    return out


def _volunteer(raw: dict[str, Any]) -> list[Volunteer]:
    out: list[Volunteer] = []
    for item in _elements(raw, "volunteerExperienceView"):
        period = item.get("timePeriod") or {}
        org = _org_from_mini(_dig(item, "company", "miniCompany"))
        if not org.name:
            org.name = item.get("companyName")
        out.append(
            Volunteer(
                role=item.get("role"),
                organization=org,
                cause=item.get("cause"),
                description=item.get("description"),
                start_date=_date(period.get("startDate")),
                end_date=_date(period.get("endDate")),
            )
        )
    return out


def _skills(raw: dict[str, Any], extra: list[dict[str, Any]]) -> list[Skill]:
    seen: dict[str, Skill] = {}
    for item in _elements(raw, "skillView") + [e for e in extra if isinstance(e, dict)]:
        name = item.get("name")
        if not name or name in seen:
            continue
        seen[name] = Skill(
            name=name,
            endorsement_count=item.get("endorsementCount")
            or _dig(item, "endorsedByViewer", "count"),
        )
    return list(seen.values())


# ---------------------------------------------------------------------- entry


def from_voyager(
    public_identifier: str,
    bundle: dict[str, Any],
    *,
    unavailable: list[str],
    duration_ms: int,
) -> Profile:
    raw = bundle.get("profile_view") or {}
    profile_node = raw.get("profile") if isinstance(raw.get("profile"), dict) else {}

    return Profile(
        public_identifier=public_identifier,
        profile_url=canonical_url(public_identifier),
        urn=profile_node.get("entityUrn"),
        basics=_basics(profile_node),
        experience=_experience(raw),
        education=_education(raw),
        skills=_skills(raw, bundle.get("skills") or []),
        certifications=_certifications(raw),
        languages=_languages(raw),
        projects=_projects(raw),
        honors=_honors(raw),
        volunteer=_volunteer(raw),
        meta=Meta(
            source=Source.VOYAGER,
            fetched_at=datetime.now(tz=timezone.utc),
            cache_hit=False,
            duration_ms=duration_ms,
            unavailable_sections=unavailable,
        ),
    )

'@
Set-Content -Path 'app\normalize.py' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote app\normalize.py'

$content = @'
"""Owns the LinkedIn session and keeps it alive.

Cookie expiry was the single biggest weakness of the cookies-only design: a
session dies hours after submission and the whole API looks broken. If account
credentials are configured, this layer re-authenticates on the first
SESSION_EXPIRED and retries the fetch once, so expiry becomes invisible.

Re-auth is attempted exactly once per failed fetch. Retrying a rejected login
repeatedly is how an account gets locked, and a lockout is far worse than one
failed request.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from .config import Settings
from .sources.auth import AuthError, Session, authenticate
from .sources.voyager import SessionExpired, VoyagerClient

log = logging.getLogger(__name__)


class SessionManager:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._client: VoyagerClient | None = None
        self._lock = asyncio.Lock()
        self._auth_failed_permanently = False

    # ------------------------------------------------------------------ build

    def _build_client(self, li_at: str, jsessionid: str) -> VoyagerClient:
        s = self._settings
        return VoyagerClient(
            li_at,
            jsessionid,
            user_agent=s.user_agent,
            timeout=s.request_timeout,
            proxy=s.linkedin_proxy,
            min_interval=s.min_request_interval,
            max_concurrency=s.max_concurrent_fetches,
        )

    async def _login(self) -> Session:
        s = self._settings
        return await authenticate(
            s.linkedin_email,
            s.linkedin_password,
            user_agent=s.user_agent,
            proxy=s.linkedin_proxy,
            timeout=s.request_timeout,
        )

    async def start(self) -> None:
        """Prefer supplied cookies; fall back to logging in."""
        s = self._settings
        if s.has_linkedin_session:
            self._client = self._build_client(s.linkedin_li_at, s.linkedin_jsessionid)
            log.info("Using LinkedIn cookies from configuration.")
            return

        if s.has_linkedin_credentials:
            try:
                session = await self._login()
            except AuthError as exc:
                log.warning("Startup login failed [%s]: %s", exc.code, exc)
                return
            self._client = self._build_client(session.li_at, session.jsessionid)
            return

        log.warning("No LinkedIn cookies or credentials configured.")

    async def _reauthenticate(self) -> bool:
        """Swap in a fresh client. Returns False if re-auth is not possible."""
        if self._auth_failed_permanently:
            return False
        if not self._settings.has_linkedin_credentials:
            return False

        async with self._lock:
            try:
                session = await self._login()
            except AuthError as exc:
                # A challenge or bad password will not resolve on retry, so stop
                # trying for the life of the process rather than hammering login.
                log.warning("Re-authentication failed [%s]: %s", exc.code, exc)
                self._auth_failed_permanently = True
                return False

            old = self._client
            self._client = self._build_client(session.li_at, session.jsessionid)
            if old:
                await old.aclose()
            log.info("Re-authenticated after session expiry.")
            return True

    # ----------------------------------------------------------------- public

    @property
    def available(self) -> bool:
        return self._client is not None

    @property
    def can_self_heal(self) -> bool:
        return (
            self._settings.has_linkedin_credentials
            and not self._auth_failed_permanently
        )

    async def fetch_all(self, public_identifier: str) -> tuple[dict[str, Any], list[str]]:
        if self._client is None:
            if not await self._reauthenticate():
                raise SessionExpired("No usable LinkedIn session is available.")
            assert self._client is not None

        try:
            return await self._client.fetch_all(public_identifier)
        except SessionExpired:
            if not await self._reauthenticate():
                raise
            return await self._client.fetch_all(public_identifier)

    async def aclose(self) -> None:
        if self._client:
            await self._client.aclose()
            self._client = None

'@
Set-Content -Path 'app\session.py' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote app\session.py'

$content = @'
from __future__ import annotations

import logging
import time
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import JSONResponse

from . import normalize
from .cache import build_cache, cache_key
from .config import Settings, get_settings
from .schemas import (
    ErrorResponse,
    Health,
    Profile,
    ProfileRequest,
    Source,
)
from .session import SessionManager
from .sources.voyager import VoyagerError
from .urls import InvalidProfileURL, parse_public_identifier

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("linkedin-profile-api")


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    app.state.cache = build_cache(settings.redis_url)
    app.state.session = SessionManager(settings)
    await app.state.session.start()

    if not app.state.session.available and not app.state.session.can_self_heal:
        log.warning("No LinkedIn session available; /v1/profile will return 503.")

    try:
        yield
    finally:
        await app.state.session.aclose()
        await app.state.cache.aclose()


app = FastAPI(
    title="LinkedIn Profile API",
    version="1.0.0",
    description=(
        "Accepts a LinkedIn member profile URL and returns the profile as "
        "structured JSON. See the repository README for scope, legal "
        "considerations and known limitations."
    ),
    lifespan=lifespan,
)


# ------------------------------------------------------------------------ auth


def require_api_key(
    settings: Settings = Depends(get_settings),
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> None:
    if x_api_key not in settings.api_key_set:
        raise HTTPException(
            status_code=401,
            detail={
                "code": "UNAUTHORIZED",
                "message": "Provide a valid X-API-Key header.",
                "retryable": False,
            },
        )


# ------------------------------------------------------------- error handling


@app.exception_handler(HTTPException)
async def http_exception_handler(_: Request, exc: HTTPException) -> JSONResponse:
    detail = exc.detail
    if not isinstance(detail, dict):
        detail = {"code": "ERROR", "message": str(detail), "retryable": False}
    return JSONResponse(status_code=exc.status_code, content={"error": detail})


@app.exception_handler(VoyagerError)
async def voyager_exception_handler(_: Request, exc: VoyagerError) -> JSONResponse:
    return JSONResponse(
        status_code=exc.http_status,
        content={
            "error": {
                "code": exc.code,
                "message": str(exc),
                "retryable": exc.retryable,
            }
        },
    )


# --------------------------------------------------------------------- routes


@app.get("/healthz", response_model=Health, tags=["meta"])
async def healthz(settings: Settings = Depends(get_settings)) -> Health:
    healthy = app.state.session.available
    return Health(
        status="ok" if healthy else "degraded",
        linkedin_session_configured=healthy,
        auth_mode=(
            "credentials" if settings.has_linkedin_credentials
            else "cookies" if settings.has_linkedin_session
            else "none"
        ),
        can_self_heal=app.state.session.can_self_heal,
        cache_backend=app.state.cache.name,
    )


async def _resolve(url: str, refresh: bool, settings: Settings) -> Profile:
    try:
        public_identifier = parse_public_identifier(url)
    except InvalidProfileURL as exc:
        raise HTTPException(
            status_code=400,
            detail={"code": "INVALID_URL", "message": str(exc), "retryable": False},
        ) from exc

    key = cache_key(public_identifier)

    if not refresh:
        cached = await app.state.cache.get(key)
        if cached:
            profile = Profile.model_validate(cached)
            profile.meta.cache_hit = True
            profile.meta.source = Source.CACHE
            return profile

    if not app.state.session.available and not app.state.session.can_self_heal:
        raise HTTPException(
            status_code=503,
            detail={
                "code": "NO_SESSION",
                "message": "No LinkedIn session is configured on this deployment.",
                "retryable": False,
            },
        )

    started = time.perf_counter()
    bundle, unavailable = await app.state.session.fetch_all(public_identifier)
    elapsed_ms = int((time.perf_counter() - started) * 1000)

    profile = normalize.from_voyager(
        public_identifier, bundle, unavailable=unavailable, duration_ms=elapsed_ms
    )
    await app.state.cache.set(
        key, profile.model_dump(mode="json"), settings.cache_ttl_seconds
    )
    return profile


@app.post(
    "/v1/profile",
    response_model=Profile,
    tags=["profile"],
    responses={
        400: {"model": ErrorResponse},
        401: {"model": ErrorResponse},
        404: {"model": ErrorResponse},
        503: {"model": ErrorResponse},
    },
)
async def post_profile(
    body: ProfileRequest,
    settings: Settings = Depends(get_settings),
    _: None = Depends(require_api_key),
) -> Profile:
    return await _resolve(body.url, body.refresh, settings)


@app.get("/v1/profile", response_model=Profile, tags=["profile"])
async def get_profile(
    url: str = Query(..., description="A LinkedIn member profile URL."),
    refresh: bool = Query(False),
    settings: Settings = Depends(get_settings),
    _: None = Depends(require_api_key),
) -> Profile:
    """Convenience GET so the API is testable from a browser or plain curl."""
    return await _resolve(url, refresh, settings)

'@
Set-Content -Path 'app\main.py' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote app\main.py'

New-Item -ItemType File -Force -Path 'app\sources\__init__.py' | Out-Null
Write-Host '  wrote app\sources\__init__.py (empty package marker)'

$content = @'
"""Programmatic authentication against LinkedIn's auth endpoint.

The browser's login form posts to /uas/authenticate. Replaying it needs three
steps, and the ordering matters:

  1. GET  /uas/authenticate  - seeds a JSESSIONID cookie. Skipping this and
     posting straight to step 2 fails, because the CSRF value in the body has
     to match a session LinkedIn has already issued.
  2. POST /uas/authenticate  - form-encoded session_key / session_password,
     plus the JSESSIONID value as a CSRF field. Note the body wants the value
     *with* its quotes, unlike the csrf-token header used elsewhere.
  3. Read li_at from the response cookie jar.

The response is JSON with a `login_result` discriminator rather than a plain
status code, so a 200 does not by itself mean the login succeeded - a challenge
also returns 200.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

import httpx

log = logging.getLogger(__name__)

AUTH_URL = "https://www.linkedin.com/uas/authenticate"


class AuthError(Exception):
    code = "AUTH_FAILED"
    retryable = False


class BadCredentials(AuthError):
    code = "BAD_CREDENTIALS"


class ChallengeRequired(AuthError):
    """LinkedIn wants an email PIN, CAPTCHA or 2FA code.

    Common when logging in from a datacenter IP, which includes essentially
    every cloud host. Cannot be solved without out-of-band input.
    """

    code = "CHALLENGE_REQUIRED"


@dataclass(frozen=True)
class Session:
    li_at: str
    jsessionid: str


async def authenticate(
    email: str,
    password: str,
    *,
    user_agent: str,
    proxy: str | None = None,
    timeout: float = 20.0,
) -> Session:
    """Log in and return fresh session cookies. Raises AuthError on failure."""
    if not email or not password:
        raise AuthError("Email and password are both required.")

    async with httpx.AsyncClient(
        timeout=timeout,
        follow_redirects=True,
        proxy=proxy or None,
        headers={
            "user-agent": user_agent,
            "accept-language": "en-US,en;q=0.9",
            "x-li-user-agent": "LIAuthLibrary:0.0.3 com.linkedin.android:4.1.881",
        },
    ) as client:
        # Step 1: seed the session so LinkedIn recognises our CSRF value.
        try:
            await client.get(AUTH_URL)
        except httpx.RequestError as exc:
            raise AuthError(f"Could not reach LinkedIn: {exc}") from exc

        jsessionid = client.cookies.get("JSESSIONID")
        if not jsessionid:
            raise AuthError(
                "LinkedIn did not issue a JSESSIONID. The login page shape has "
                "probably changed."
            )

        # Step 2: replay the form post.
        try:
            response = await client.post(
                AUTH_URL,
                data={
                    "session_key": email,
                    "session_password": password,
                    "JSESSIONID": jsessionid,
                    "loginCsrfParam": jsessionid.strip('"'),
                },
                headers={
                    "content-type": "application/x-www-form-urlencoded",
                    "x-isajaxform": "1",
                },
            )
        except httpx.RequestError as exc:
            raise AuthError(f"Login request failed: {exc}") from exc

        if response.status_code == 401:
            raise BadCredentials("LinkedIn rejected the email or password.")
        if response.status_code == 429:
            raise ChallengeRequired("Too many login attempts; LinkedIn is throttling.")
        if response.status_code != 200:
            raise AuthError(f"Login returned HTTP {response.status_code}.")

        try:
            payload = response.json()
        except ValueError:
            raise AuthError(
                "Login returned a non-JSON body, which usually means an "
                "interstitial challenge page."
            ) from None

        result = payload.get("login_result")
        if result and result != "PASS":
            # CHALLENGE, TWO_FACTOR_REQUIRED, and friends all land here.
            raise ChallengeRequired(
                f"LinkedIn requires additional verification (login_result={result}). "
                "Log in once from a browser on this network to clear it, then "
                "supply cookies directly."
            )

        # Step 3: harvest the authenticated cookies.
        li_at = client.cookies.get("li_at")
        if not li_at:
            raise AuthError("Login reported success but no li_at cookie was set.")

        final_jsessionid = client.cookies.get("JSESSIONID") or jsessionid
        log.info("Authenticated to LinkedIn programmatically.")
        return Session(li_at=li_at, jsessionid=final_jsessionid)

'@
Set-Content -Path 'app\sources\auth.py' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote app\sources\auth.py'

$content = @'
"""Client for LinkedIn's internal 'Voyager' API.

The linkedin.com web app talks to a private REST layer at /voyager/api/*.
Authenticating is a matter of replaying what the browser sends:

  * cookie `li_at`        - the session token
  * cookie `JSESSIONID`   - a quoted value like "ajax:1234567890123456789"
  * header `csrf-token`   - the JSESSIONID value with the quotes stripped
  * header `x-restli-protocol-version: 2.0.0`

If csrf-token and JSESSIONID disagree, every request 403s. That mismatch is the
single most common reason a working scraper suddenly stops working.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

import httpx

log = logging.getLogger(__name__)

VOYAGER_BASE = "https://www.linkedin.com/voyager/api"


class VoyagerError(Exception):
    code = "UPSTREAM_ERROR"
    retryable = False
    http_status = 502


class SessionExpired(VoyagerError):
    code = "SESSION_EXPIRED"
    http_status = 503


class Blocked(VoyagerError):
    code = "RATE_LIMITED"
    retryable = True
    http_status = 503


class ProfileNotFound(VoyagerError):
    code = "PROFILE_NOT_FOUND"
    http_status = 404


class VoyagerClient:
    def __init__(
        self,
        li_at: str,
        jsessionid: str,
        *,
        user_agent: str,
        timeout: float = 20.0,
        proxy: str | None = None,
        min_interval: float = 2.5,
        max_concurrency: int = 2,
    ) -> None:
        if not li_at or not jsessionid:
            raise ValueError("Both li_at and JSESSIONID cookies are required.")

        # LinkedIn stores JSESSIONID *with* surrounding quotes; the CSRF header
        # must carry the same value *without* them.
        quoted = jsessionid if jsessionid.startswith('"') else f'"{jsessionid}"'
        csrf = quoted.strip('"')

        self._client = httpx.AsyncClient(
            base_url=VOYAGER_BASE,
            timeout=timeout,
            follow_redirects=False,
            proxy=proxy or None,
            cookies={"li_at": li_at, "JSESSIONID": quoted},
            headers={
                "user-agent": user_agent,
                "csrf-token": csrf,
                "x-restli-protocol-version": "2.0.0",
                "x-li-lang": "en_US",
                "accept": "application/json",
                "accept-language": "en-US,en;q=0.9",
                "referer": "https://www.linkedin.com/feed/",
            },
        )
        self._gate = asyncio.Semaphore(max_concurrency)
        self._min_interval = min_interval
        self._last_call = 0.0
        self._pace_lock = asyncio.Lock()

    async def aclose(self) -> None:
        await self._client.aclose()

    # ---------------------------------------------------------------- internals

    async def _pace(self) -> None:
        """Serialize a minimum gap between outbound calls.

        Bursting is what gets accounts flagged. This is deliberately crude and
        deliberately conservative.
        """
        async with self._pace_lock:
            loop = asyncio.get_running_loop()
            elapsed = loop.time() - self._last_call
            if elapsed < self._min_interval:
                await asyncio.sleep(self._min_interval - elapsed)
            self._last_call = loop.time()

    @staticmethod
    def _raise_for_status(response: httpx.Response, context: str) -> None:
        status = response.status_code
        if status == 200:
            return
        if status in (301, 302, 303, 307, 308):
            # Voyager does not redirect for valid sessions. A redirect means we
            # were bounced to the login or challenge wall.
            raise SessionExpired(
                "LinkedIn redirected the request, which means the session is no "
                "longer authenticated (expired cookie or a security challenge)."
            )
        if status in (401, 403):
            raise SessionExpired(
                "LinkedIn rejected the session. Refresh li_at/JSESSIONID, and check "
                "the account has not been challenged or restricted."
            )
        if status == 404:
            raise ProfileNotFound(
                "No profile at that identifier, or it is not visible to this account."
            )
        if status in (429, 999):
            raise Blocked(
                f"LinkedIn throttled the request (HTTP {status}). Back off before retrying."
            )
        raise VoyagerError(f"{context} failed with HTTP {status}.")

    async def _get(
        self, path: str, params: dict[str, Any] | None = None, *, context: str
    ) -> dict[str, Any]:
        async with self._gate:
            await self._pace()
            try:
                response = await self._client.get(path, params=params)
            except httpx.RequestError as exc:
                raise VoyagerError(f"Network error during {context}: {exc}") from exc

        self._raise_for_status(response, context)
        try:
            return response.json()
        except ValueError as exc:
            raise VoyagerError(
                f"{context} returned a non-JSON body, usually an interstitial page."
            ) from exc

    # ------------------------------------------------------------------- public

    async def profile_view(self, public_identifier: str) -> dict[str, Any]:
        """The legacy aggregate endpoint.

        One round trip for positions, education, certifications, languages,
        projects, honors and volunteering. It truncates some collections, which
        is why skills are fetched separately below.
        """
        return await self._get(
            f"/identity/profiles/{public_identifier}/profileView",
            context="profileView",
        )

    async def skills(self, public_identifier: str, count: int = 100) -> list[dict[str, Any]]:
        payload = await self._get(
            f"/identity/profiles/{public_identifier}/skills",
            params={"count": count, "start": 0},
            context="skills",
        )
        return payload.get("elements", []) or []

    async def fetch_all(self, public_identifier: str) -> tuple[dict[str, Any], list[str]]:
        """Fetch everything, tolerating partial failure on optional sections.

        Returns (bundle, unavailable_section_names). The primary profileView call
        is allowed to raise; supplementary calls are not.
        """
        bundle: dict[str, Any] = {}
        unavailable: list[str] = []

        bundle["profile_view"] = await self.profile_view(public_identifier)

        try:
            bundle["skills"] = await self.skills(public_identifier)
        except VoyagerError as exc:
            log.warning("skills fetch failed for %s: %s", public_identifier, exc)
            bundle["skills"] = []
            unavailable.append("skills")

        return bundle, unavailable

'@
Set-Content -Path 'app\sources\voyager.py' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote app\sources\voyager.py'

$content = @'
#!/usr/bin/env python3
"""Fetch one profile and write both the raw and normalized output to disk.

This exists for two jobs:

  1. Verifying the mapping. `normalize.py` is written against documented Voyager
     shapes, but LinkedIn changes them. Diff raw vs normalized to find fields
     that came back empty and fix the accessor.

  2. Producing evidence. The normalized files under samples/ are committed as
     proof the API worked, which matters because a session cookie will very
     likely have expired by the time anyone reviews the repo.

Usage:
    python scripts/dump_profile.py williamhgates
    python scripts/dump_profile.py https://www.linkedin.com/in/williamhgates/

Writes:
    raw/<identifier>.raw.json          gitignored - may contain personal data
    samples/<identifier>.sample.json   committed - review manually before pushing
"""

from __future__ import annotations

import asyncio
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from app import normalize  # noqa: E402
from app.config import get_settings  # noqa: E402
from app.sources.voyager import VoyagerClient, VoyagerError  # noqa: E402
from app.urls import InvalidProfileURL, parse_public_identifier  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
RAW_DIR = ROOT / "raw"
SAMPLE_DIR = ROOT / "samples"


def _empty_paths(node, prefix=""):
    """Walk the normalized output and report fields that came back empty.

    Anything listed here is either genuinely absent from the profile or a
    mapping that needs fixing. Check the raw dump to tell which.
    """
    findings = []
    if isinstance(node, dict):
        for key, value in node.items():
            findings.extend(_empty_paths(value, f"{prefix}.{key}" if prefix else key))
    elif isinstance(node, list):
        if not node:
            findings.append(prefix)
    elif node is None:
        findings.append(prefix)
    return findings


async def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    try:
        identifier = parse_public_identifier(sys.argv[1])
    except InvalidProfileURL:
        identifier = sys.argv[1].strip()

    settings = get_settings()
    if not settings.has_linkedin_session:
        print("ERROR: LINKEDIN_LI_AT and LINKEDIN_JSESSIONID are not set in .env")
        return 1

    client = VoyagerClient(
        settings.linkedin_li_at,
        settings.linkedin_jsessionid,
        user_agent=settings.user_agent,
        timeout=settings.request_timeout,
        proxy=settings.linkedin_proxy,
        min_interval=settings.min_request_interval,
        max_concurrency=1,
    )

    try:
        print(f"fetching {identifier} ...")
        bundle, unavailable = await client.fetch_all(identifier)
    except VoyagerError as exc:
        print(f"FAILED [{exc.code}]: {exc}")
        return 1
    finally:
        await client.aclose()

    RAW_DIR.mkdir(exist_ok=True)
    SAMPLE_DIR.mkdir(exist_ok=True)

    raw_path = RAW_DIR / f"{identifier}.raw.json"
    raw_path.write_text(json.dumps(bundle, indent=2, ensure_ascii=False))

    profile = normalize.from_voyager(
        identifier, bundle, unavailable=unavailable, duration_ms=0
    )
    sample_path = SAMPLE_DIR / f"{identifier}.sample.json"
    sample_path.write_text(
        json.dumps(profile.model_dump(mode="json"), indent=2, ensure_ascii=False)
    )

    # ---------------------------------------------------------------- report
    basics = profile.basics
    print(f"\n  raw     -> {raw_path.relative_to(ROOT)}")
    print(f"  sample  -> {sample_path.relative_to(ROOT)}")
    print("\n  name        ", basics.full_name or "(EMPTY)")
    print("  headline    ", (basics.headline or "(EMPTY)")[:60])
    print("  location    ", basics.location.raw or "(EMPTY)")
    print("  about       ", f"{len(basics.about)} chars" if basics.about else "(EMPTY)")
    print("  picture     ", f"{len(basics.profile_picture)} sizes" if basics.profile_picture else "(EMPTY)")
    print("  experience  ", len(profile.experience))
    print("  education   ", len(profile.education))
    print("  skills      ", len(profile.skills))
    print("  certs       ", len(profile.certifications))
    print("  languages   ", len(profile.languages))

    empty = _empty_paths(profile.model_dump(mode="json"))
    interesting = [
        p for p in empty
        if not p.startswith("meta.") and p.count(".") < 3
    ]
    if interesting:
        print("\n  empty fields (check raw dump to see if this is a mapping bug):")
        for path in interesting:
            print(f"    - {path}")

    print(
        "\nBefore committing samples/, open the file and confirm you are happy "
        "publishing that person's data in a public repo."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))

'@
Set-Content -Path 'scripts\dump_profile.py' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote scripts\dump_profile.py'

New-Item -ItemType File -Force -Path 'tests\__init__.py' | Out-Null
Write-Host '  wrote tests\__init__.py (empty package marker)'

$content = @'
import pytest

from app.urls import InvalidProfileURL, parse_public_identifier


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("https://www.linkedin.com/in/naman/", "naman"),
        ("linkedin.com/in/naman", "naman"),
        ("https://in.linkedin.com/in/naman-b12345?trk=xyz", "naman-b12345"),
        ("https://www.linkedin.com/in/naman/details/experience/", "naman"),
        ("HTTPS://WWW.LINKEDIN.COM/in/Naman", "Naman"),
    ],
)
def test_valid_urls(raw, expected):
    assert parse_public_identifier(raw) == expected


@pytest.mark.parametrize(
    "raw",
    [
        "",
        "not a url",
        "https://example.com/in/naman",
        "https://www.linkedin.com/company/tross",
        "https://www.linkedin.com/feed/",
        "https://linkedin.com.evil.test/in/naman",
    ],
)
def test_rejected_urls(raw):
    with pytest.raises(InvalidProfileURL):
        parse_public_identifier(raw)

'@
Set-Content -Path 'tests\test_urls.py' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote tests\test_urls.py'

$content = @'
from app.normalize import from_voyager

FIXTURE = {
    "profile_view": {
        "profile": {
            "firstName": "Ada",
            "lastName": "Lovelace",
            "headline": "Analytical Engine Programmer",
            "summary": "First programmer.",
            "geoLocationName": "London",
            "geoCountryName": "United Kingdom",
            "industryName": "Computing",
            "entityUrn": "urn:li:fs_profile:ABC",
            "miniProfile": {
                "publicIdentifier": "adalovelace",
                "picture": {
                    "com.linkedin.common.VectorImage": {
                        "rootUrl": "https://media.example/",
                        "artifacts": [
                            {"width": 100, "height": 100, "fileIdentifyingUrlPathSegment": "s100.jpg"},
                            {"width": 400, "height": 400, "fileIdentifyingUrlPathSegment": "s400.jpg"},
                        ],
                    }
                },
            },
        },
        "positionView": {
            "elements": [
                {
                    "title": "Programmer",
                    "companyName": "Analytical Engine Co",
                    "timePeriod": {"startDate": {"month": 6, "year": 1843}},
                }
            ]
        },
        "educationView": {"elements": [{"schoolName": "Home Tutoring", "fieldOfStudy": "Mathematics"}]},
        "skillView": {"elements": [{"name": "Mathematics"}]},
        "languageView": {"elements": [{"name": "English", "proficiency": "NATIVE_OR_BILINGUAL"}]},
    },
    "skills": [{"name": "Algorithms"}, {"name": "Mathematics"}],
}


def test_maps_core_fields():
    profile = from_voyager("adalovelace", FIXTURE, unavailable=[], duration_ms=42)

    assert profile.basics.full_name == "Ada Lovelace"
    assert profile.basics.location.country == "United Kingdom"
    assert profile.profile_url == "https://www.linkedin.com/in/adalovelace"
    assert profile.meta.duration_ms == 42


def test_images_sorted_largest_first():
    profile = from_voyager("adalovelace", FIXTURE, unavailable=[], duration_ms=1)
    pictures = profile.basics.profile_picture

    assert pictures[0].url == "https://media.example/s400.jpg"
    assert pictures[0].width == 400


def test_open_ended_position_marked_current():
    profile = from_voyager("adalovelace", FIXTURE, unavailable=[], duration_ms=1)
    role = profile.experience[0]

    assert role.is_current is True
    assert role.start_date.year == 1843
    assert role.company.name == "Analytical Engine Co"


def test_skills_deduplicated_across_sources():
    profile = from_voyager("adalovelace", FIXTURE, unavailable=[], duration_ms=1)
    names = [s.name for s in profile.skills]

    assert names.count("Mathematics") == 1
    assert "Algorithms" in names


def test_missing_sections_do_not_raise():
    profile = from_voyager("ghost", {"profile_view": {}}, unavailable=["skills"], duration_ms=1)

    assert profile.experience == []
    assert profile.meta.unavailable_sections == ["skills"]

'@
Set-Content -Path 'tests\test_normalize.py' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote tests\test_normalize.py'

$content = @'
import pytest

from app.config import Settings
from app.session import SessionManager
from app.sources.auth import ChallengeRequired
from app.sources.voyager import SessionExpired


def _settings(**kw):
    base = dict(
        api_keys="k", linkedin_li_at="", linkedin_jsessionid="",
        linkedin_email="", linkedin_password="",
    )
    base.update(kw)
    return Settings(**base)


class FakeClient:
    def __init__(self, fail_times=0):
        self.fail_times = fail_times
        self.calls = 0
        self.closed = False

    async def fetch_all(self, identifier):
        self.calls += 1
        if self.calls <= self.fail_times:
            raise SessionExpired("expired")
        return ({"profile_view": {}}, [])

    async def aclose(self):
        self.closed = True


@pytest.mark.asyncio
async def test_expired_session_triggers_one_reauth_and_succeeds(monkeypatch):
    mgr = SessionManager(_settings(linkedin_email="a@b.c", linkedin_password="pw"))
    mgr._client = FakeClient(fail_times=1)
    logins = []

    def swap(li_at, jsessionid):
        return FakeClient(fail_times=0)

    async def fake_login():
        logins.append(1)
        return type("S", (), {"li_at": "x", "jsessionid": '"ajax:1"'})()

    monkeypatch.setattr(mgr, "_login", fake_login)
    monkeypatch.setattr(mgr, "_build_client", swap)

    bundle, unavailable = await mgr.fetch_all("someone")

    assert bundle == {"profile_view": {}}
    assert len(logins) == 1


@pytest.mark.asyncio
async def test_challenge_stops_further_login_attempts(monkeypatch):
    mgr = SessionManager(_settings(linkedin_email="a@b.c", linkedin_password="pw"))
    mgr._client = FakeClient(fail_times=99)
    attempts = []

    async def fake_login():
        attempts.append(1)
        raise ChallengeRequired("needs PIN")

    monkeypatch.setattr(mgr, "_login", fake_login)

    with pytest.raises(SessionExpired):
        await mgr.fetch_all("someone")
    with pytest.raises(SessionExpired):
        await mgr.fetch_all("someone")

    # Only one login attempt total: a challenge will not clear on retry, and
    # hammering login is how accounts get locked.
    assert len(attempts) == 1
    assert mgr.can_self_heal is False


@pytest.mark.asyncio
async def test_no_credentials_means_no_self_heal():
    mgr = SessionManager(_settings(linkedin_li_at="x", linkedin_jsessionid='"ajax:1"'))
    mgr._client = FakeClient(fail_times=99)

    with pytest.raises(SessionExpired):
        await mgr.fetch_all("someone")
    assert mgr.can_self_heal is False

'@
Set-Content -Path 'tests\test_session.py' -Value $content -Encoding UTF8 -NoNewline:$false
Write-Host '  wrote tests\test_session.py'

Write-Host ''
Write-Host 'Done. Next:' -ForegroundColor Green
Write-Host '  python -m venv .venv'
Write-Host '  .venv\Scripts\activate'
Write-Host '  pip install -r requirements.txt -r requirements-dev.txt'
Write-Host '  python -m pytest -q'
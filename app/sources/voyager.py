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


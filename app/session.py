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


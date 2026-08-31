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


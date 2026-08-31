#!/usr/bin/env python3
"""Probe Voyager endpoints to find which ones still respond.

LinkedIn retires endpoints without notice; profileView now returns 410 Gone.
This walks a list of candidates and reports the status of each, then tries to
discover current GraphQL queryIds from the profile page bundle.

Requests are spaced out deliberately. Do not lower the delay.

Usage:
    python scripts/probe_endpoints.py williamhgates
"""

from __future__ import annotations

import asyncio
import json
import pathlib
import re
import sys

import httpx

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from app.config import get_settings  # noqa: E402
from app.sources.auth import authenticate  # noqa: E402

DELAY = 3.0
VOYAGER = "https://www.linkedin.com/voyager/api"

# Accept headers change the response shape. The "normalized" variant returns a
# flat {data, included} graph; the default returns nested legacy structures.
ACCEPT_PLAIN = "application/json"
ACCEPT_NORM = "application/vnd.linkedin.normalized+json+2.1"


def candidates(pid: str) -> list[tuple[str, str, str]]:
    """(label, url, accept_header)"""
    out: list[tuple[str, str, str]] = [
        ("legacy profileView", f"{VOYAGER}/identity/profiles/{pid}/profileView", ACCEPT_PLAIN),
        ("legacy profile", f"{VOYAGER}/identity/profiles/{pid}", ACCEPT_PLAIN),
        ("me", f"{VOYAGER}/me", ACCEPT_PLAIN),
        (
            "dash bare",
            f"{VOYAGER}/identity/dash/profiles?q=memberIdentity&memberIdentity={pid}",
            ACCEPT_NORM,
        ),
    ]
    # Decoration IDs are versioned and the version rotates. Sweep a range.
    for version in range(55, 72):
        out.append(
            (
                f"dash deco FullProfileWithEntities-{version}",
                f"{VOYAGER}/identity/dash/profiles?q=memberIdentity"
                f"&memberIdentity={pid}"
                f"&decorationId=com.linkedin.voyager.dash.deco.identity.profile"
                f".FullProfileWithEntities-{version}",
                ACCEPT_NORM,
            )
        )
    return out


async def probe(client: httpx.AsyncClient, label: str, url: str, accept: str) -> dict | None:
    try:
        response = await client.get(url, headers={"accept": accept})
    except httpx.RequestError as exc:
        print(f"  {label:52s} network error: {exc}")
        return None

    status = response.status_code
    marker = "OK  " if status == 200 else "    "
    print(f"{marker}{label:52s} HTTP {status}")

    if status != 200:
        return None

    try:
        payload = response.json()
    except ValueError:
        print(f"      (non-JSON body, {len(response.content)} bytes)")
        return None

    top = list(payload.keys())[:8]
    print(f"      top-level keys: {top}")
    if "included" in payload and isinstance(payload["included"], list):
        types: dict[str, int] = {}
        for item in payload["included"]:
            if isinstance(item, dict):
                t = item.get("$type", "?").split(".")[-1]
                types[t] = types.get(t, 0) + 1
        print(f"      included types: {dict(sorted(types.items(), key=lambda kv: -kv[1])[:12])}")
    return payload


async def discover_query_ids(client: httpx.AsyncClient, pid: str) -> list[str]:
    """Scrape the profile page for GraphQL queryIds currently in use."""
    print("\n-- discovering GraphQL queryIds from page bundle --")
    try:
        response = await client.get(f"https://www.linkedin.com/in/{pid}/")
    except httpx.RequestError as exc:
        print(f"  page fetch failed: {exc}")
        return []

    print(f"  page HTTP {response.status_code}, {len(response.text)} chars")
    found = sorted(set(re.findall(r"voyager[A-Za-z]+\.[0-9a-f]{16,}", response.text)))
    if found:
        for q in found[:25]:
            print(f"    {q}")
    else:
        print("  none found inline (they may live in a separate JS bundle)")
    return found


async def main() -> int:
    pid = sys.argv[1] if len(sys.argv) > 1 else "williamhgates"
    settings = get_settings()

    if settings.has_linkedin_session:
        li_at, jsessionid = settings.linkedin_li_at, settings.linkedin_jsessionid
    elif settings.has_linkedin_credentials:
        print("logging in ...")
        session = await authenticate(
            settings.linkedin_email,
            settings.linkedin_password,
            user_agent=settings.user_agent,
        )
        li_at, jsessionid = session.li_at, session.jsessionid
    else:
        print("ERROR: no credentials in .env")
        return 1

    quoted = jsessionid if jsessionid.startswith('"') else f'"{jsessionid}"'
    csrf = quoted.strip('"')

    async with httpx.AsyncClient(
        timeout=25.0,
        follow_redirects=False,
        cookies={"li_at": li_at, "JSESSIONID": quoted},
        headers={
            "user-agent": settings.user_agent,
            "csrf-token": csrf,
            "x-restli-protocol-version": "2.0.0",
            "x-li-lang": "en_US",
            "accept-language": "en-US,en;q=0.9",
            "referer": "https://www.linkedin.com/feed/",
        },
    ) as client:
        print(f"\n-- probing endpoints for /in/{pid} --\n")
        working: list[tuple[str, str, dict]] = []

        for label, url, accept in candidates(pid):
            payload = await probe(client, label, url, accept)
            if payload is not None:
                working.append((label, url, payload))
            await asyncio.sleep(DELAY)

        query_ids = await discover_query_ids(client, pid)

    print("\n" + "=" * 60)
    if working:
        print(f"{len(working)} endpoint(s) responded 200:")
        for label, url, _ in working:
            print(f"  - {label}")
        out = pathlib.Path("raw")
        out.mkdir(exist_ok=True)
        for label, url, payload in working:
            safe = re.sub(r"[^a-zA-Z0-9_-]+", "_", label)
            path = out / f"probe_{safe}.json"
            path.write_text(json.dumps(payload, indent=2, ensure_ascii=False))
        print(f"\nFull payloads written to raw/probe_*.json")
    else:
        print("No endpoint returned 200.")

    if query_ids:
        print(f"\n{len(query_ids)} queryId(s) discovered - see list above.")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))

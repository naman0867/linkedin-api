#!/usr/bin/env python3
"""Round two: find where the profile *sections* live now.

probe_endpoints.py established that /identity/dash/profiles?q=memberIdentity
returns the base Profile but not the entity collections. In the dash model each
section is its own endpoint keyed by the profile URN, so this script:

  1. fetches the base profile and extracts its URN
  2. probes each candidate collection endpoint
  3. fetches the profile page (following redirects this time) and scrapes for
     live GraphQL queryIds

Usage:
    python scripts/probe2.py williamhgates
"""

from __future__ import annotations

import asyncio
import json
import pathlib
import re
import sys
import urllib.parse

import httpx

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from app.config import get_settings  # noqa: E402

DELAY = 2.5
VOYAGER = "https://www.linkedin.com/voyager/api"
ACCEPT_NORM = "application/vnd.linkedin.normalized+json+2.1"

COLLECTIONS = [
    "profilePositionGroups",
    "profilePositions",
    "profileEducations",
    "profileSkills",
    "profileCertifications",
    "profileLanguages",
    "profileProjects",
    "profileHonors",
    "profileVolunteerExperiences",
    "profileCourses",
    "profilePublications",
]


def summarize(payload: dict, depth: int = 0) -> None:
    data = payload.get("data")
    included = payload.get("included")
    if isinstance(data, dict):
        keys = [k for k in data.keys() if not k.startswith("$")][:10]
        print(f"      data keys: {keys}")
    if isinstance(included, list):
        types: dict[str, int] = {}
        for item in included:
            if isinstance(item, dict):
                t = str(item.get("$type", "?")).split(".")[-1]
                types[t] = types.get(t, 0) + 1
        print(f"      included ({len(included)}): {dict(sorted(types.items(), key=lambda kv: -kv[1])[:10])}")


async def get(client: httpx.AsyncClient, label: str, url: str) -> dict | None:
    try:
        r = await client.get(url, headers={"accept": ACCEPT_NORM})
    except httpx.RequestError as exc:
        print(f"    {label:34s} network error: {exc}")
        return None
    flag = "OK  " if r.status_code == 200 else "    "
    print(f"{flag}{label:34s} HTTP {r.status_code}")
    if r.status_code != 200:
        return None
    try:
        payload = r.json()
    except ValueError:
        print("      (non-JSON)")
        return None
    summarize(payload)
    return payload


def find_urn(payload: dict) -> str | None:
    """Pull the profile URN out of the base dash response."""
    for item in payload.get("included") or []:
        if isinstance(item, dict) and "Profile" in str(item.get("$type", "")):
            urn = item.get("entityUrn")
            if urn:
                return urn
    data = payload.get("data")
    if isinstance(data, dict):
        for key in ("*elements", "elements"):
            val = data.get(key)
            if isinstance(val, list) and val and isinstance(val[0], str):
                return val[0]
    return None


async def main() -> int:
    pid = sys.argv[1] if len(sys.argv) > 1 else "williamhgates"
    s = get_settings()
    if not s.has_linkedin_session:
        print("ERROR: needs LINKEDIN_LI_AT and LINKEDIN_JSESSIONID in .env")
        return 1

    quoted = s.linkedin_jsessionid
    if not quoted.startswith('"'):
        quoted = f'"{quoted}"'

    out = pathlib.Path("raw")
    out.mkdir(exist_ok=True)

    async with httpx.AsyncClient(
        timeout=25.0,
        follow_redirects=False,
        cookies={"li_at": s.linkedin_li_at, "JSESSIONID": quoted},
        headers={
            "user-agent": s.user_agent,
            "csrf-token": quoted.strip('"'),
            "x-restli-protocol-version": "2.0.0",
            "x-li-lang": "en_US",
            "accept-language": "en-US,en;q=0.9",
            "referer": "https://www.linkedin.com/feed/",
        },
    ) as client:
        print(f"\n-- base profile for /in/{pid} --\n")
        base = await get(
            client,
            "dash profiles (memberIdentity)",
            f"{VOYAGER}/identity/dash/profiles?q=memberIdentity&memberIdentity={pid}",
        )
        if not base:
            print("base profile failed; cannot continue")
            return 1
        (out / "base_profile.json").write_text(json.dumps(base, indent=2, ensure_ascii=False))

        urn = find_urn(base)
        print(f"\n  profile URN: {urn}")
        if not urn:
            print("  could not locate URN - inspect raw/base_profile.json")
            return 1

        encoded = urllib.parse.quote(urn, safe="")
        await asyncio.sleep(DELAY)

        print(f"\n-- collection endpoints --\n")
        working: list[str] = []
        for name in COLLECTIONS:
            payload = await get(
                client,
                name,
                f"{VOYAGER}/identity/dash/{name}?q=viewee&profileUrn={encoded}",
            )
            if payload:
                working.append(name)
                (out / f"coll_{name}.json").write_text(
                    json.dumps(payload, indent=2, ensure_ascii=False)
                )
            await asyncio.sleep(DELAY)

        print("\n-- GraphQL queryIds from page --\n")
        try:
            page = await client.get(f"https://www.linkedin.com/in/{pid}/")
            print(f"  page HTTP {page.status_code}, {len(page.text)} chars")
            ids = sorted(set(re.findall(r"voyager[A-Za-z]+\.[0-9a-f]{16,}", page.text)))
            for q in ids[:30]:
                print(f"    {q}")
            if ids:
                (out / "query_ids.txt").write_text("\n".join(ids))
            else:
                print("    none inline")
        except httpx.RequestError as exc:
            print(f"  page fetch failed: {exc}")

    print("\n" + "=" * 60)
    print(f"working collections ({len(working)}): {working}")
    print("payloads in raw/")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))

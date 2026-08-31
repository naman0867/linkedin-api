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
from app.session import SessionManager  # noqa: E402
from app.sources.voyager import VoyagerError  # noqa: E402
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
    if not (settings.has_linkedin_session or settings.has_linkedin_credentials):
        print("ERROR: LINKEDIN_LI_AT and LINKEDIN_JSESSIONID are not set in .env")
        return 1

    manager = SessionManager(settings)
    await manager.start()

    try:
        print(f"fetching {identifier} ...")
        bundle, unavailable = await manager.fetch_all(identifier)
    except VoyagerError as exc:
        print(f"FAILED [{exc.code}]: {exc}")
        return 1
    finally:
        await manager.aclose()

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


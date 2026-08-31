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


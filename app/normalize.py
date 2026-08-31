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


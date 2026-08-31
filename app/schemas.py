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


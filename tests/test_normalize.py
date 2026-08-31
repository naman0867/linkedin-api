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


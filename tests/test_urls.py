import pytest

from app.urls import InvalidProfileURL, parse_public_identifier


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("https://www.linkedin.com/in/naman/", "naman"),
        ("linkedin.com/in/naman", "naman"),
        ("https://in.linkedin.com/in/naman-b12345?trk=xyz", "naman-b12345"),
        ("https://www.linkedin.com/in/naman/details/experience/", "naman"),
        ("HTTPS://WWW.LINKEDIN.COM/in/Naman", "Naman"),
    ],
)
def test_valid_urls(raw, expected):
    assert parse_public_identifier(raw) == expected


@pytest.mark.parametrize(
    "raw",
    [
        "",
        "not a url",
        "https://example.com/in/naman",
        "https://www.linkedin.com/company/tross",
        "https://www.linkedin.com/feed/",
        "https://linkedin.com.evil.test/in/naman",
    ],
)
def test_rejected_urls(raw):
    with pytest.raises(InvalidProfileURL):
        parse_public_identifier(raw)


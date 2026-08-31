import pytest

from app.config import Settings
from app.session import SessionManager
from app.sources.auth import ChallengeRequired
from app.sources.voyager import SessionExpired


def _settings(**kw):
    base = dict(
        api_keys="k", linkedin_li_at="", linkedin_jsessionid="",
        linkedin_email="", linkedin_password="",
    )
    base.update(kw)
    return Settings(**base)


class FakeClient:
    def __init__(self, fail_times=0):
        self.fail_times = fail_times
        self.calls = 0
        self.closed = False

    async def fetch_all(self, identifier):
        self.calls += 1
        if self.calls <= self.fail_times:
            raise SessionExpired("expired")
        return ({"profile_view": {}}, [])

    async def aclose(self):
        self.closed = True


@pytest.mark.asyncio
async def test_expired_session_triggers_one_reauth_and_succeeds(monkeypatch):
    mgr = SessionManager(_settings(linkedin_email="a@b.c", linkedin_password="pw"))
    mgr._client = FakeClient(fail_times=1)
    logins = []

    def swap(li_at, jsessionid):
        return FakeClient(fail_times=0)

    async def fake_login():
        logins.append(1)
        return type("S", (), {"li_at": "x", "jsessionid": '"ajax:1"'})()

    monkeypatch.setattr(mgr, "_login", fake_login)
    monkeypatch.setattr(mgr, "_build_client", swap)

    bundle, unavailable = await mgr.fetch_all("someone")

    assert bundle == {"profile_view": {}}
    assert len(logins) == 1


@pytest.mark.asyncio
async def test_challenge_stops_further_login_attempts(monkeypatch):
    mgr = SessionManager(_settings(linkedin_email="a@b.c", linkedin_password="pw"))
    mgr._client = FakeClient(fail_times=99)
    attempts = []

    async def fake_login():
        attempts.append(1)
        raise ChallengeRequired("needs PIN")

    monkeypatch.setattr(mgr, "_login", fake_login)

    with pytest.raises(SessionExpired):
        await mgr.fetch_all("someone")
    with pytest.raises(SessionExpired):
        await mgr.fetch_all("someone")

    # Only one login attempt total: a challenge will not clear on retry, and
    # hammering login is how accounts get locked.
    assert len(attempts) == 1
    assert mgr.can_self_heal is False


@pytest.mark.asyncio
async def test_no_credentials_means_no_self_heal():
    mgr = SessionManager(_settings(linkedin_li_at="x", linkedin_jsessionid='"ajax:1"'))
    mgr._client = FakeClient(fail_times=99)

    with pytest.raises(SessionExpired):
        await mgr.fetch_all("someone")
    assert mgr.can_self_heal is False


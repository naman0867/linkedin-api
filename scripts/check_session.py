import httpx
from app.config import get_settings
s = get_settings()
q = s.linkedin_jsessionid
if not q.startswith('"'):
    q = '"' + q + '"'
r = httpx.get(
    "https://www.linkedin.com/voyager/api/me",
    cookies={"li_at": s.linkedin_li_at, "JSESSIONID": q},
    headers={
        "csrf-token": q.strip('"'),
        "x-restli-protocol-version": "2.0.0",
        "user-agent": s.user_agent,
    },
    follow_redirects=False,
)
print("HTTP", r.status_code)
from __future__ import annotations

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # Auth for *this* API. Comma-separated list of accepted client keys.
    api_keys: str = "dev-local-key-change-me"

    # LinkedIn session. Never commit these.
    linkedin_li_at: str = ""
    linkedin_jsessionid: str = ""
    linkedin_email: str = ""
    linkedin_password: str = ""
    linkedin_proxy: str | None = None

    # Caching
    redis_url: str | None = None
    cache_ttl_seconds: int = 86_400

    # Politeness / self-preservation
    min_request_interval: float = 2.5
    max_concurrent_fetches: int = 2
    request_timeout: float = 20.0

    user_agent: str = (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
    )

    @property
    def api_key_set(self) -> set[str]:
        return {k.strip() for k in self.api_keys.split(",") if k.strip()}

    @property
    def has_linkedin_session(self) -> bool:
        return bool(self.linkedin_li_at and self.linkedin_jsessionid)

    @property
    def has_linkedin_credentials(self) -> bool:
        return bool(self.linkedin_email and self.linkedin_password)


@lru_cache
def get_settings() -> Settings:
    return Settings()


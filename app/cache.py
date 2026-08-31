"""Cache abstraction with a Redis backend and an in-process fallback.

Caching is not a nice-to-have here. Every cache hit is an outbound request that
never touches LinkedIn, which is the main lever for keeping the session alive.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import Any, Protocol

log = logging.getLogger(__name__)


class Cache(Protocol):
    name: str

    async def get(self, key: str) -> dict[str, Any] | None: ...
    async def set(self, key: str, value: dict[str, Any], ttl: int) -> None: ...
    async def aclose(self) -> None: ...


class MemoryCache:
    name = "memory"

    def __init__(self, max_entries: int = 1024) -> None:
        self._store: dict[str, tuple[float, dict[str, Any]]] = {}
        self._max = max_entries
        self._lock = asyncio.Lock()

    async def get(self, key: str) -> dict[str, Any] | None:
        async with self._lock:
            entry = self._store.get(key)
            if not entry:
                return None
            expires_at, value = entry
            if expires_at < time.time():
                self._store.pop(key, None)
                return None
            return value

    async def set(self, key: str, value: dict[str, Any], ttl: int) -> None:
        async with self._lock:
            if len(self._store) >= self._max:
                oldest = min(self._store, key=lambda k: self._store[k][0])
                self._store.pop(oldest, None)
            self._store[key] = (time.time() + ttl, value)

    async def aclose(self) -> None:
        self._store.clear()


class RedisCache:
    name = "redis"

    def __init__(self, url: str) -> None:
        import redis.asyncio as redis

        self._redis = redis.from_url(url, decode_responses=True)

    async def get(self, key: str) -> dict[str, Any] | None:
        try:
            payload = await self._redis.get(key)
        except Exception as exc:  # a cache outage must not fail the request
            log.warning("redis get failed: %s", exc)
            return None
        if not payload:
            return None
        try:
            return json.loads(payload)
        except ValueError:
            return None

    async def set(self, key: str, value: dict[str, Any], ttl: int) -> None:
        try:
            await self._redis.set(key, json.dumps(value, default=str), ex=ttl)
        except Exception as exc:
            log.warning("redis set failed: %s", exc)

    async def aclose(self) -> None:
        await self._redis.aclose()


def build_cache(redis_url: str | None) -> Cache:
    if redis_url:
        try:
            return RedisCache(redis_url)
        except Exception as exc:
            log.warning("Redis unavailable (%s); falling back to memory cache.", exc)
    return MemoryCache()


def cache_key(public_identifier: str) -> str:
    return f"profile:v1:{public_identifier.lower()}"


"""
IP/proxy → ISO country code lookup with two-layer cache.
Layer 1: in-memory dict (fast, reset on restart)
Layer 2: ip_country_cache DB table (persistent across restarts)
External API: ip-api.com batch endpoint (free, no auth, 100 IPs/request)
"""

import logging
from datetime import datetime
from typing import Optional

import requests

logger = logging.getLogger(__name__)

# in-memory cache: ip_address -> ISO 2-letter country code
_ip_cache: dict[str, str] = {}

# proxy domain keywords -> country code (priority 1)
PROXY_COUNTRY_MAP: dict[str, str] = {
    "webshare": "US",
    "tunproxy": "VN",
}

IP_API_BATCH_URL = "http://ip-api.com/batch?fields=query,countryCode,status"
IP_API_BATCH_SIZE = 100


def country_from_proxy(proxy_host: Optional[str]) -> Optional[str]:
    if not proxy_host:
        return None
    lower = proxy_host.lower()
    for keyword, cc in PROXY_COUNTRY_MAP.items():
        if keyword in lower:
            return cc
    return None


def get_node_country(proxy_host: Optional[str], public_ip: Optional[str]) -> Optional[str]:
    """Return ISO country code: proxy keyword first, then cached IP lookup."""
    cc = country_from_proxy(proxy_host)
    if cc:
        return cc
    if public_ip and public_ip not in ("", "N/A"):
        return _ip_cache.get(public_ip)
    return None


def warm_ip_cache(db) -> None:
    """Load all rows from ip_country_cache DB table into the in-memory dict."""
    from app.models import IPCountryCache
    try:
        rows = db.query(IPCountryCache).all()
        for row in rows:
            _ip_cache[row.ip] = row.country_code
        logger.info("ip_country: warmed %d IPs from DB cache", len(rows))
    except Exception as exc:
        logger.warning("ip_country: warm_ip_cache error: %s", exc)


def refresh_ip_countries(db) -> None:
    """
    Background task: find IPs not yet cached, batch-fetch from ip-api.com,
    persist to DB and update in-memory dict.
    """
    from app.models import IPCountryCache, NodeStatus

    try:
        # collect distinct public_ip values from live node statuses
        rows = db.query(NodeStatus.public_ip).filter(
            NodeStatus.public_ip.isnot(None),
            NodeStatus.public_ip != "",
            NodeStatus.public_ip != "N/A",
        ).distinct().all()

        all_ips = {r.public_ip for r in rows}
        unknown_ips = [ip for ip in all_ips if ip not in _ip_cache]

        if not unknown_ips:
            return

        logger.info("ip_country: fetching %d unknown IPs", len(unknown_ips))

        # batch into chunks of IP_API_BATCH_SIZE
        fetched: dict[str, str] = {}
        for i in range(0, len(unknown_ips), IP_API_BATCH_SIZE):
            chunk = unknown_ips[i:i + IP_API_BATCH_SIZE]
            try:
                resp = requests.post(
                    IP_API_BATCH_URL,
                    json=[{"query": ip} for ip in chunk],
                    timeout=10,
                )
                if resp.status_code == 200:
                    for item in resp.json():
                        if item.get("status") == "success" and item.get("countryCode"):
                            fetched[item["query"]] = item["countryCode"]
            except Exception as exc:
                logger.warning("ip_country: batch fetch error: %s", exc)

        if not fetched:
            return

        # persist to DB and update in-memory cache
        now = datetime.utcnow()
        for ip, cc in fetched.items():
            _ip_cache[ip] = cc
            existing = db.query(IPCountryCache).filter(IPCountryCache.ip == ip).first()
            if existing:
                existing.country_code = cc
                existing.cached_at = now
            else:
                db.add(IPCountryCache(ip=ip, country_code=cc, cached_at=now))

        db.commit()
        logger.info("ip_country: cached %d new IPs", len(fetched))

    except Exception as exc:
        db.rollback()
        logger.error("ip_country: refresh_ip_countries error: %s", exc)

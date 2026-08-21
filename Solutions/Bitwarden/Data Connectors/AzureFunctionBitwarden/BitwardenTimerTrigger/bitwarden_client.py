"""
Bitwarden API client with OAuth2 client-credentials authentication,
token caching, retry logic, and continuation-token pagination.

Supports three deployment models:
  - Bitwarden Cloud US  (default)  – identity: https://identity.bitwarden.com
                                      api:      https://api.bitwarden.com
  - Bitwarden Cloud EU             – identity: https://identity.bitwarden.eu
                                      api:      https://api.bitwarden.eu
  - Self-hosted / on-premises      – identity: https://<your-domain>/identity
                                      api:      https://<your-domain>/api

For self-hosted servers set BITWARDEN_IDENTITY_URL and BITWARDEN_API_URL to
the appropriate base URLs.  The client appends ``/connect/token`` and
``/public/<resource>`` automatically.

Reference: https://bitwarden.com/help/public-api/
"""

import logging
import time
from datetime import datetime, timezone, timedelta
from typing import List, Optional

import requests


class BitwardenAuthError(Exception):
    """Raised when authentication against the Bitwarden identity endpoint fails."""


class BitwardenApiError(Exception):
    """Raised when a Bitwarden API call returns a non-retryable error."""


# Token expiry buffer: refresh the token this many seconds before it actually
# expires.  Bitwarden tokens have a 3600 s (1 h) TTL; we renew at 3540 s.
_TOKEN_EXPIRY_BUFFER_SECONDS = 60


class BitwardenClient:
    """
    Client for the Bitwarden Public API.

    Authentication: POST ``<identity_url>/connect/token`` with
    ``client_credentials`` grant using ``api.organization`` scope.
    The bearer token is cached and automatically refreshed before it expires.

    Data endpoints (all support continuation-token pagination):
    - ``GET <api_url>/public/events``   (also time-windowed)
    - ``GET <api_url>/public/members``
    - ``GET <api_url>/public/groups``

    Self-hosted usage
    -----------------
    Pass the full base URLs via config keys ``bitwarden_identity_url`` and
    ``bitwarden_api_url``.  For a server at ``https://bw.example.com``:

        bitwarden_identity_url = "https://bw.example.com/identity"
        bitwarden_api_url      = "https://bw.example.com/api"

    The client will call:
        POST https://bw.example.com/identity/connect/token
        GET  https://bw.example.com/api/public/events
    """

    _RETRYABLE_STATUS_CODES = {429, 500, 502, 503, 504}
    _DEFAULT_MAX_RETRIES = 3
    _DEFAULT_INITIAL_BACKOFF = 2
    _DEFAULT_MAX_BACKOFF = 60

    def __init__(self, config):
        self._identity_url: str = config.get(
            "bitwarden_identity_url", "https://identity.bitwarden.com"
        ).rstrip("/")
        self._api_url: str = config.get(
            "bitwarden_api_url", "https://api.bitwarden.com"
        ).rstrip("/")
        self._client_id: str = config.get("bitwarden_client_id")
        self._client_secret: str = config.get("bitwarden_client_secret")
        self._max_retries: int = config.get(
            "bitwarden_max_retries", self._DEFAULT_MAX_RETRIES
        )
        self._initial_backoff: int = config.get(
            "bitwarden_initial_backoff_seconds", self._DEFAULT_INITIAL_BACKOFF
        )
        self._max_backoff: int = config.get(
            "bitwarden_max_backoff_seconds", self._DEFAULT_MAX_BACKOFF
        )
        # Token cache
        self._access_token: Optional[str] = None
        self._token_expires_at: Optional[datetime] = None

    # ------------------------------------------------------------------
    # Authentication
    # ------------------------------------------------------------------

    def _is_token_valid(self) -> bool:
        """Return True when a cached token exists and has not (nearly) expired."""
        if not self._access_token or not self._token_expires_at:
            return False
        return datetime.now(timezone.utc) < self._token_expires_at

    def _authenticate(self) -> str:
        """Obtain (or refresh) a bearer token from ``<identity_url>/connect/token``.

        Bitwarden token response::

            {
              "access_token": "<TOKEN>",
              "expires_in":   3600,
              "token_type":   "Bearer"
            }

        The token is cached; ``_is_token_valid()`` gates calls so we only
        re-authenticate when necessary.
        """
        token_url = f"{self._identity_url}/connect/token"
        payload = {
            "grant_type": "client_credentials",
            "client_id": self._client_id,
            "client_secret": self._client_secret,
            "scope": "api.organization",
        }
        headers = {
            "Accept": "application/json",
            "Content-Type": "application/x-www-form-urlencoded",
        }

        logging.debug("Requesting Bitwarden access token from %s", token_url)

        try:
            response = requests.post(
                token_url, data=payload, headers=headers, timeout=30
            )
            response.raise_for_status()
        except requests.HTTPError as exc:
            raise BitwardenAuthError(
                f"Failed to obtain Bitwarden token ({exc.response.status_code}): "
                f"{exc.response.text}"
            ) from exc
        except requests.RequestException as exc:
            raise BitwardenAuthError(
                f"Network error during Bitwarden authentication: {exc}"
            ) from exc

        token_data = response.json()
        self._access_token = token_data.get("access_token")
        if not self._access_token:
            raise BitwardenAuthError(
                "Bitwarden token response did not contain 'access_token'."
            )

        expires_in: int = token_data.get("expires_in", 3600)
        self._token_expires_at = datetime.now(timezone.utc) + timedelta(
            seconds=max(0, expires_in - _TOKEN_EXPIRY_BUFFER_SECONDS)
        )

        logging.info(
            "Bitwarden access token obtained. Valid until ~%s UTC.",
            self._token_expires_at.strftime("%H:%M:%S"),
        )
        return self._access_token

    def _get_token(self) -> str:
        """Return a valid bearer token, re-authenticating when needed."""
        if not self._is_token_valid():
            self._authenticate()
        return self._access_token

    def _get_auth_headers(self) -> dict:
        return {
            "Authorization": f"Bearer {self._get_token()}",
            "Accept": "application/json",
        }

    # ------------------------------------------------------------------
    # HTTP helpers
    # ------------------------------------------------------------------

    def _get_with_retry(self, url: str, params: Optional[dict] = None) -> dict:
        """Execute a GET request with exponential back-off on retryable errors.

        Handles automatic re-authentication on 401 (e.g. clock skew or a
        token that was invalidated server-side after an API key rotation).
        """
        headers = self._get_auth_headers()
        reauthenticated = False

        for attempt in range(self._max_retries + 1):
            try:
                resp = requests.get(url, headers=headers, params=params, timeout=60)
            except requests.RequestException as exc:
                if attempt < self._max_retries:
                    self._backoff(attempt)
                    continue
                raise BitwardenApiError(
                    f"Network error calling {url}: {exc}"
                ) from exc

            if resp.status_code == 401 and not reauthenticated:
                logging.warning(
                    "Received 401 from Bitwarden API – forcing token refresh."
                )
                # Invalidate cached token and force a fresh auth request
                self._access_token = None
                self._token_expires_at = None
                headers = self._get_auth_headers()
                reauthenticated = True
                continue

            if resp.status_code in self._RETRYABLE_STATUS_CODES:
                if attempt < self._max_retries:
                    logging.warning(
                        "Retryable status %d from %s. Attempt %d/%d.",
                        resp.status_code, url, attempt + 1, self._max_retries,
                    )
                    self._backoff(attempt)
                    continue
                raise BitwardenApiError(
                    f"Bitwarden API returned {resp.status_code} after "
                    f"{self._max_retries} retries: {resp.text}"
                )

            if not resp.ok:
                raise BitwardenApiError(
                    f"Bitwarden API error {resp.status_code} for {url}: {resp.text}"
                )

            return resp.json()

        raise BitwardenApiError(f"Exhausted retries for {url}.")

    def _backoff(self, attempt: int) -> None:
        wait = min(self._initial_backoff * (2 ** attempt), self._max_backoff)
        logging.debug("Backing off for %ds before retry.", wait)
        time.sleep(wait)

    # ------------------------------------------------------------------
    # Paginated fetchers
    # ------------------------------------------------------------------

    def _fetch_all_pages(self, url: str, params: Optional[dict] = None) -> List[dict]:
        """Fetch all items from a continuation-token–paginated endpoint.

        The Bitwarden API returns a ``continuationToken`` field when more
        than 50 results are available.  Pass it back as a query parameter
        on subsequent requests::

            GET /public/events?continuationToken=<token_value>

        Ref: https://bitwarden.com/help/public-api/#continuation-token
        """
        params = dict(params or {})
        all_items: List[dict] = []
        page = 0

        while True:
            page += 1
            data = self._get_with_retry(url, params=params)
            items = data.get("data", [])
            all_items.extend(items)
            logging.debug(
                "Page %d: fetched %d items (total: %d)", page, len(items), len(all_items)
            )
            # continuationToken is returned at the top level of the response;
            # pass it as a query parameter for the next request.
            continuation_token = data.get("continuationToken")
            if not continuation_token:
                break
            params["continuationToken"] = continuation_token

        return all_items

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def get_events(
        self,
        start: datetime,
        end: datetime,
    ) -> List[dict]:
        """Fetch organization events between *start* and *end* (UTC).

        The events endpoint is time-windowed and supports continuation-token
        pagination within that window.

        :param start: Window start (UTC, timezone-aware).
        :param end:   Window end   (UTC, timezone-aware).
        :returns: List of event dicts.
        """
        url = f"{self._api_url}/public/events"
        params = {
            "start": start.strftime("%Y-%m-%dT%H:%M:%S.000000Z"),
            "end": end.strftime("%Y-%m-%dT%H:%M:%S.000000Z"),
        }
        logging.info(
            "Fetching Bitwarden events from %s to %s",
            params["start"],
            params["end"],
        )
        return self._fetch_all_pages(url, params)

    def get_members(self) -> List[dict]:
        """Fetch all organization members."""
        url = f"{self._api_url}/public/members"
        logging.info("Fetching Bitwarden members.")
        return self._fetch_all_pages(url)

    def get_groups(self) -> List[dict]:
        """Fetch all organization groups."""
        url = f"{self._api_url}/public/groups"
        logging.info("Fetching Bitwarden groups.")
        return self._fetch_all_pages(url)

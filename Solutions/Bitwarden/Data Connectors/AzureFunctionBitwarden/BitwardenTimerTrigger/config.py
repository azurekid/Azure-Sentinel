"""
Configuration management for the Bitwarden Function App connector.

All settings are read from environment variables.  The Bitwarden
client secret can optionally be sourced from Azure Key Vault using
the Managed Identity assigned to the Function App.

Supported Bitwarden deployment types
-------------------------------------
Cloud US (default)
    BITWARDEN_CLOUD_REGION=us  (or unset)
    Identity: https://identity.bitwarden.com
    API:      https://api.bitwarden.com

Cloud EU
    BITWARDEN_CLOUD_REGION=eu
    Identity: https://identity.bitwarden.eu
    API:      https://api.bitwarden.eu

Self-hosted / on-premises
    Set BITWARDEN_IDENTITY_URL and BITWARDEN_API_URL explicitly, e.g.
        BITWARDEN_IDENTITY_URL=https://bw.example.com/identity
        BITWARDEN_API_URL=https://bw.example.com/api
    Explicit values always override the cloud region default.

Reference: https://bitwarden.com/help/public-api/#endpoints
"""

import logging
import os
from typing import Optional

from azure.identity import ManagedIdentityCredential
from azure.keyvault.secrets import SecretClient
from dotenv import load_dotenv


class ConfigStore:
    """Lightweight key/value store for runtime configuration."""

    def __init__(self, **kwargs):
        self._config: dict = dict(kwargs)

    def get(self, key: str, default=None):
        return self._config.get(key, default)

    def __repr__(self) -> str:
        return f"ConfigStore(keys={list(self._config.keys())})"


# Environment variable names -----------------------------------------------
_ENV_BITWARDEN_CLIENT_ID = "BITWARDEN_CLIENT_ID"
_ENV_BITWARDEN_CLIENT_SECRET = "BITWARDEN_CLIENT_SECRET"
_ENV_BITWARDEN_CLOUD_REGION = "BITWARDEN_CLOUD_REGION"   # "us" | "eu"
_ENV_BITWARDEN_IDENTITY_URL = "BITWARDEN_IDENTITY_URL"   # overrides cloud region
_ENV_BITWARDEN_API_URL = "BITWARDEN_API_URL"             # overrides cloud region

_ENV_AZURE_DCE_ENDPOINT = "AZURE_DCE_ENDPOINT"
_ENV_AZURE_DCR_EVENTS_IMMUTABLEID = "AZURE_DCR_EVENTS_IMMUTABLEID"
_ENV_AZURE_DCR_MEMBERS_IMMUTABLEID = "AZURE_DCR_MEMBERS_IMMUTABLEID"
_ENV_AZURE_DCR_GROUPS_IMMUTABLEID = "AZURE_DCR_GROUPS_IMMUTABLEID"

_ENV_KEY_VAULT_URI = "KEY_VAULT_URI"
_ENV_KEY_VAULT_SECRET_NAME = "KEY_VAULT_SECRET_NAME"
_ENV_AZURE_CLIENT_ID = "AZURE_CLIENT_ID"

# Lookback window for events (minutes)
_ENV_EVENT_LOOKBACK_MINUTES = "BITWARDEN_EVENT_LOOKBACK_MINUTES"
_DEFAULT_EVENT_LOOKBACK_MINUTES = 5

# Cloud region → default endpoint mapping
_CLOUD_ENDPOINTS = {
    "us": {
        "identity_url": "https://identity.bitwarden.com",
        "api_url": "https://api.bitwarden.com",
    },
    "eu": {
        "identity_url": "https://identity.bitwarden.eu",
        "api_url": "https://api.bitwarden.eu",
    },
}


def _resolve_client_secret(
    credential: Optional[ManagedIdentityCredential],
    key_vault_uri: Optional[str],
    secret_name: Optional[str],
) -> str:
    """Return the Bitwarden client secret.

    Preference order:
    1. Key Vault (when KEY_VAULT_URI and KEY_VAULT_SECRET_NAME are set).
    2. BITWARDEN_CLIENT_SECRET environment variable.
    """
    if key_vault_uri and secret_name and credential:
        try:
            kv_client = SecretClient(vault_url=key_vault_uri, credential=credential)
            secret = kv_client.get_secret(secret_name)
            logging.debug("Bitwarden client secret retrieved from Key Vault.")
            return secret.value
        except Exception as exc:
            logging.error(
                "Failed to retrieve Bitwarden client secret from Key Vault: %s", exc
            )

    logging.warning(
        "Key Vault not configured or unreachable – "
        "falling back to %s environment variable.",
        _ENV_BITWARDEN_CLIENT_SECRET,
    )
    secret_env = os.getenv(_ENV_BITWARDEN_CLIENT_SECRET)
    if not secret_env:
        raise ValueError(
            f"Bitwarden client secret not found. "
            f"Set {_ENV_BITWARDEN_CLIENT_SECRET} or configure KEY_VAULT_URI / "
            f"KEY_VAULT_SECRET_NAME with a Managed Identity."
        )
    return secret_env


def _require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise ValueError(f"Required environment variable '{name}' is not set.")
    return value


def _parse_int_env(name: str, default: int) -> int:
    raw = os.getenv(name, str(default))
    try:
        return int(raw)
    except ValueError:
        raise ValueError(f"Environment variable '{name}' must be an integer, got: '{raw}'")


def _resolve_bitwarden_urls() -> tuple:
    """Determine the Bitwarden identity and API base URLs.

    Resolution order (first match wins):
    1. Explicit ``BITWARDEN_IDENTITY_URL`` / ``BITWARDEN_API_URL`` env vars
       → used as-is (supports self-hosted / on-premises servers).
    2. ``BITWARDEN_CLOUD_REGION`` env var (``us`` or ``eu``) → maps to the
       corresponding Bitwarden Cloud endpoints.
    3. Default: Bitwarden Cloud US.

    :returns: Tuple of (identity_url, api_url).
    """
    explicit_identity = os.getenv(_ENV_BITWARDEN_IDENTITY_URL)
    explicit_api = os.getenv(_ENV_BITWARDEN_API_URL)

    if explicit_identity and explicit_api:
        logging.info(
            "Using explicit Bitwarden URLs – identity: %s, api: %s",
            explicit_identity,
            explicit_api,
        )
        return explicit_identity.rstrip("/"), explicit_api.rstrip("/")

    if explicit_identity or explicit_api:
        raise ValueError(
            "Both BITWARDEN_IDENTITY_URL and BITWARDEN_API_URL must be set "
            "together for self-hosted deployments. Only one was provided."
        )

    region = (os.getenv(_ENV_BITWARDEN_CLOUD_REGION) or "us").lower().strip()
    if region not in _CLOUD_ENDPOINTS:
        raise ValueError(
            f"Unknown BITWARDEN_CLOUD_REGION '{region}'. "
            f"Valid values: {list(_CLOUD_ENDPOINTS.keys())}. "
            "For self-hosted servers, set BITWARDEN_IDENTITY_URL and BITWARDEN_API_URL instead."
        )

    endpoints = _CLOUD_ENDPOINTS[region]
    logging.info("Using Bitwarden Cloud %s endpoints.", region.upper())
    return endpoints["identity_url"], endpoints["api_url"]


def load_configuration(
    azure_credential: Optional[ManagedIdentityCredential] = None,
) -> ConfigStore:
    """Load and validate all configuration from environment variables.

    :param azure_credential: Azure credential to use for Key Vault lookups
                             and DCR uploads.  Defaults to
                             ``ManagedIdentityCredential`` when not supplied.
    :returns: Populated :class:`ConfigStore`.
    :raises ValueError: If any required configuration is missing.
    """
    load_dotenv()

    azure_client_id = os.getenv(_ENV_AZURE_CLIENT_ID)
    if azure_credential is None:
        azure_credential = (
            ManagedIdentityCredential(client_id=azure_client_id)
            if azure_client_id
            else ManagedIdentityCredential()
        )

    key_vault_uri = os.getenv(_ENV_KEY_VAULT_URI)
    secret_name = os.getenv(_ENV_KEY_VAULT_SECRET_NAME, "bitwarden-client-secret")

    client_secret = _resolve_client_secret(
        credential=azure_credential,
        key_vault_uri=key_vault_uri,
        secret_name=secret_name,
    )

    identity_url, api_url = _resolve_bitwarden_urls()

    config = ConfigStore(
        # Bitwarden API settings
        bitwarden_client_id=_require_env(_ENV_BITWARDEN_CLIENT_ID),
        bitwarden_client_secret=client_secret,
        bitwarden_identity_url=identity_url,
        bitwarden_api_url=api_url,
        # Azure Monitor / DCR settings
        azure_dce_endpoint=_require_env(_ENV_AZURE_DCE_ENDPOINT),
        azure_dcr_events_immutableid=_require_env(_ENV_AZURE_DCR_EVENTS_IMMUTABLEID),
        azure_dcr_members_immutableid=_require_env(
            _ENV_AZURE_DCR_MEMBERS_IMMUTABLEID
        ),
        azure_dcr_groups_immutableid=_require_env(_ENV_AZURE_DCR_GROUPS_IMMUTABLEID),
        azure_credential=azure_credential,
        # Operational settings
        event_lookback_minutes=_parse_int_env(
            _ENV_EVENT_LOOKBACK_MINUTES, _DEFAULT_EVENT_LOOKBACK_MINUTES
        ),
    )

    logging.debug("Configuration loaded: %s", config)
    return config

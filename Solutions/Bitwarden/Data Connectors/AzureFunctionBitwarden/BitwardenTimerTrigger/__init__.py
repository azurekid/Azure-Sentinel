"""
Bitwarden → Microsoft Sentinel data connector
Azure Function – Timer Trigger (every 5 minutes)

Pulls three data types from the Bitwarden Public API and ingests
them into Microsoft Sentinel via Azure Monitor Logs Ingestion API:

  • BitwardenEventLogs_CL  – organisation audit events (time-windowed)
  • BitwardenMembers_CL    – organisation member list (snapshot)
  • BitwardenGroups_CL     – organisation group list  (snapshot)
"""

import logging
import os
from datetime import datetime, timezone, timedelta

import azure.functions as func

from .bitwarden_client import BitwardenClient, BitwardenAuthError, BitwardenApiError
from .config import load_configuration
from .sentinel_uploader import SentinelUploader


def _normalise_events(raw_events: list, ingestion_time: datetime) -> list:
    """Map raw Bitwarden event fields to the BitwardenEventLogs_CL schema."""
    records = []
    for ev in raw_events:
        records.append(
            {
                "TimeGenerated": ev.get(
                    "date", ingestion_time.strftime("%Y-%m-%dT%H:%M:%S.000Z")
                ),
                "eventType": ev.get("type"),
                "itemId": ev.get("itemId"),
                "collectionId": ev.get("collectionId"),
                "groupId": ev.get("groupId"),
                "policyId": ev.get("policyId"),
                "memberId": ev.get("memberId"),
                "actingUserId": ev.get("actingUserId"),
                "installationId": ev.get("installationId"),
                "device": ev.get("device"),
                "ipAddress": ev.get("ipAddress"),
            }
        )
    return records


def _normalise_members(raw_members: list, ingestion_time: datetime) -> list:
    """Map raw Bitwarden member fields to the BitwardenMembers_CL schema."""
    ts = ingestion_time.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    return [
        {
            "TimeGenerated": ts,
            "memberId": m.get("id"),
            "userId": m.get("userId"),
            "email": m.get("email"),
            "name": m.get("name"),
        }
        for m in raw_members
    ]


def _normalise_groups(raw_groups: list, ingestion_time: datetime) -> list:
    """Map raw Bitwarden group fields to the BitwardenGroups_CL schema."""
    ts = ingestion_time.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    return [
        {
            "TimeGenerated": ts,
            "groupId": g.get("id"),
            "name": g.get("name"),
        }
        for g in raw_groups
    ]


def main(mytimer: func.TimerRequest) -> None:
    """Azure Function entry-point – called every 5 minutes by the timer trigger."""

    log_level = os.getenv("LOG_LEVEL", "INFO").upper()
    logging.basicConfig(level=getattr(logging, log_level, logging.INFO))

    now_utc = datetime.now(timezone.utc)
    logging.info(
        "Bitwarden connector started at %s (past_due=%s)",
        now_utc.isoformat(),
        mytimer.past_due,
    )

    if mytimer.past_due:
        logging.warning("Timer is past due – execution was delayed.")

    # ------------------------------------------------------------------
    # Load configuration
    # ------------------------------------------------------------------
    try:
        config = load_configuration()
    except ValueError as exc:
        logging.error("Configuration error: %s", exc)
        raise

    # ------------------------------------------------------------------
    # Determine event query window
    # ------------------------------------------------------------------
    lookback_minutes: int = config.get("event_lookback_minutes", 5)
    window_end = now_utc
    window_start = now_utc - timedelta(minutes=lookback_minutes)

    # ------------------------------------------------------------------
    # Fetch data from Bitwarden
    # ------------------------------------------------------------------
    bw_client = BitwardenClient(config)
    uploader = SentinelUploader(config)

    # -- Events ----------------------------------------------------------
    try:
        raw_events = bw_client.get_events(start=window_start, end=window_end)
        logging.info("Fetched %d Bitwarden events.", len(raw_events))
    except (BitwardenAuthError, BitwardenApiError) as exc:
        logging.error("Failed to fetch Bitwarden events: %s", exc)
        raw_events = []

    if raw_events:
        events_records = _normalise_events(raw_events, now_utc)
        try:
            uploader.upload_events(events_records)
        except RuntimeError as exc:
            logging.error("Error uploading events to Sentinel: %s", exc)

    # -- Members ---------------------------------------------------------
    try:
        raw_members = bw_client.get_members()
        logging.info("Fetched %d Bitwarden members.", len(raw_members))
    except (BitwardenAuthError, BitwardenApiError) as exc:
        logging.error("Failed to fetch Bitwarden members: %s", exc)
        raw_members = []

    if raw_members:
        members_records = _normalise_members(raw_members, now_utc)
        try:
            uploader.upload_members(members_records)
        except RuntimeError as exc:
            logging.error("Error uploading members to Sentinel: %s", exc)

    # -- Groups ----------------------------------------------------------
    try:
        raw_groups = bw_client.get_groups()
        logging.info("Fetched %d Bitwarden groups.", len(raw_groups))
    except (BitwardenAuthError, BitwardenApiError) as exc:
        logging.error("Failed to fetch Bitwarden groups: %s", exc)
        raw_groups = []

    if raw_groups:
        groups_records = _normalise_groups(raw_groups, now_utc)
        try:
            uploader.upload_groups(groups_records)
        except RuntimeError as exc:
            logging.error("Error uploading groups to Sentinel: %s", exc)

    # ------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------
    duration = (datetime.now(timezone.utc) - now_utc).total_seconds()
    logging.info(
        "Bitwarden connector finished in %.1fs. "
        "Events: %d, Members: %d, Groups: %d.",
        duration,
        len(raw_events),
        len(raw_members),
        len(raw_groups),
    )

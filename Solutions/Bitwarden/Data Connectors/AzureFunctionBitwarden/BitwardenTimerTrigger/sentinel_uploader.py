"""
Sentinel / Azure Monitor ingestion helper.

Uploads lists of records to custom Log Analytics tables via the
Logs Ingestion API (DCR-based ingestion).
"""

import logging
from typing import List

from azure.monitor.ingestion import LogsIngestionClient
from azure.core.exceptions import HttpResponseError


class SentinelUploader:
    """
    Wraps the Azure Monitor ``LogsIngestionClient`` and provides
    per-stream upload methods for the three Bitwarden tables.
    """

    def __init__(self, config):
        dce_endpoint: str = config.get("azure_dce_endpoint")
        credential = config.get("azure_credential")

        self._client = LogsIngestionClient(
            endpoint=dce_endpoint,
            credential=credential,
            logging_enable=(logging.root.level <= logging.DEBUG),
        )
        self._dcr_events_immutableid: str = config.get(
            "azure_dcr_events_immutableid"
        )
        self._dcr_members_immutableid: str = config.get(
            "azure_dcr_members_immutableid"
        )
        self._dcr_groups_immutableid: str = config.get(
            "azure_dcr_groups_immutableid"
        )

    # ------------------------------------------------------------------
    # Internal upload helper
    # ------------------------------------------------------------------

    def _upload(
        self,
        rule_id: str,
        stream_name: str,
        records: List[dict],
    ) -> None:
        """Upload *records* to *stream_name* on *rule_id*.

        The SDK handles automatic 1 MB chunking and gzip compression.
        """
        if not records:
            logging.info(
                "No records to upload for stream '%s' – skipping.", stream_name
            )
            return

        upload_errors = []

        def on_error(error):
            logging.error(
                "Chunk upload failed for stream '%s' (%d records): %s",
                stream_name,
                len(error.failed_logs),
                error.error,
            )
            upload_errors.append(error)

        logging.info(
            "Uploading %d records to stream '%s' (DCR: %s).",
            len(records),
            stream_name,
            rule_id,
        )

        self._client.upload(
            rule_id=rule_id,
            stream_name=stream_name,
            logs=records,
            on_error=on_error,
        )

        if upload_errors:
            total_failed = sum(len(e.failed_logs) for e in upload_errors)
            raise RuntimeError(
                f"Upload to '{stream_name}' partially failed: "
                f"{len(upload_errors)} chunk(s), {total_failed} record(s) lost."
            )

        logging.info(
            "Successfully uploaded %d records to '%s'.", len(records), stream_name
        )

    # ------------------------------------------------------------------
    # Public upload methods
    # ------------------------------------------------------------------

    def upload_events(self, records: List[dict]) -> None:
        """Upload Bitwarden event log records to ``BitwardenEventLogs_CL``."""
        self._upload(
            rule_id=self._dcr_events_immutableid,
            stream_name="Custom-BitwardenEventLogs_CL",
            records=records,
        )

    def upload_members(self, records: List[dict]) -> None:
        """Upload Bitwarden member records to ``BitwardenMembers_CL``."""
        self._upload(
            rule_id=self._dcr_members_immutableid,
            stream_name="Custom-BitwardenMembers_CL",
            records=records,
        )

    def upload_groups(self, records: List[dict]) -> None:
        """Upload Bitwarden group records to ``BitwardenGroups_CL``."""
        self._upload(
            rule_id=self._dcr_groups_immutableid,
            stream_name="Custom-BitwardenGroups_CL",
            records=records,
        )

# NextDNS Microsoft Sentinel Connector

This folder contains an OpenAI-style Microsoft Sentinel solution layout for the NextDNS codeless connector.

## What gets deployed

- Log Analytics tables:
  - NextDNS_CL for raw DNS query events
  - NextDNSAnalytics_CL for NextDNS analytics aggregates
- Data Collection Endpoint (DCE)
- Data Collection Rule (DCR) with two streams:
  - Custom-NextDNS_CL
  - Custom-NextDNSAnalytics_CL
- Sentinel connector definition (Customizable)
- RestApiPoller data connectors:
  - Logs endpoint: /logs
  - Analytics endpoints: /analytics/status, /analytics/domains, /analytics/reasons, /analytics/queryTypes, /analytics/devices
- Parser functions:
  - NextDNS_Parser
  - NextDNSAnalytics_Parser
- Scheduled analytics rules for SOC detections

## Folder structure

- Data/
  - Solution_NextDNS.json
- Data Connectors/NextDNS_CCP/
  - NextDNS_ConnectorDefinition.json
  - NextDNS_DCR.json
  - NextDNS_PollingConfig.json
  - NextDNSLogs_Table.json
  - NextDNSAnalytics_Table.json
- Parsers/
  - parser_NextDNSAliasFunction.json
  - parser_NextDNSAnalyticsAliasFunction.json
- Package/
  - mainTemplate.json
  - createUiDefinition.json
  - testParameters.json
- ReleaseNotes.md
- SolutionMetadata.json

Legacy and source helper files are still present:
- workspaceArtifacts.template.json
- NextDNSParser.kql
- NextDNSAnalyticsParser.kql
- ingestion-transform.kql
- nextdns-ccp.parameters.json

## Prerequisites

- Microsoft Sentinel enabled on the target workspace
- Permissions to deploy:
  - Microsoft.SecurityInsights/*
  - Microsoft.Insights/*
  - Microsoft.OperationalInsights/*
- NextDNS API key
- One or more NextDNS profile IDs

## Parameters

- workspaceName: Log Analytics workspace name
- profiles: Array of NextDNS profile IDs
- nextDnsApiKeySecretUri: Secure value used by APIKey auth in RestApiPoller

## Deployment

Deploy the package template at:
- MSPIMManager/Public/SecurityAlerts/SentinelCCP/NextDNS/Package/mainTemplate.json

With parameters from:
- MSPIMManager/Public/SecurityAlerts/SentinelCCP/NextDNS/Package/testParameters.json

Example command:

az deployment group create \
  --resource-group <resource-group> \
  --template-file MSPIMManager/Public/SecurityAlerts/SentinelCCP/NextDNS/Package/mainTemplate.json \
  --parameters workspace=<workspace-name> \
               workspace-location=<workspace-region> \
               profiles='["1d96ff","9387a4"]' \
               nextDnsApiKeySecretUri=<nextdns-api-key>

## Parser-first detection model

All scheduled rules are based on parser functions, not direct table queries.

- Rules based on NextDNS_Parser:
  - NextDNS blocked domain spike
  - NextDNS potential DNS tunneling
  - NextDNS newly observed domain burst
  - NextDNS malicious category blocked surge
- Rules based on NextDNSAnalytics_Parser:
  - NextDNS analytics blocked ratio spike by profile
  - NextDNS analytics malicious reason concentration

## Operational notes

- Analytics polling is hourly for aggregate endpoints.
- Logs polling is 5 minutes.
- The DCR analytics transform normalizes queries into queryCount and preserves name/status fields for parser logic.
- Connector definition includes API key guidance and a connection toggle in instruction steps.

## Security note

- Do not keep real secrets in template defaults.
- Store sensitive values in secure parameter inputs and protected secret stores.

## References

- NextDNS API: https://nextdns.github.io/api/
- Microsoft Sentinel codeless connector guidance: https://learn.microsoft.com/azure/sentinel/create-codeless-connector
- Microsoft.SecurityInsights ARM reference: https://learn.microsoft.com/azure/templates/microsoft.securityinsights/
- Log Analytics tables ARM reference: https://learn.microsoft.com/azure/templates/microsoft.operationalinsights/workspaces/tables

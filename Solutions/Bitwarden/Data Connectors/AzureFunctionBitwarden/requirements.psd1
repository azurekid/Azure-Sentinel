# This file enables managed dependencies in Azure Functions PowerShell worker.
# The runtime downloads these modules from the PowerShell Gallery automatically.
# https://learn.microsoft.com/azure/azure-functions/functions-reference-powershell#dependency-management
@{
    'Az.Accounts'  = '3.*'
    'Az.KeyVault'  = '6.*'
}

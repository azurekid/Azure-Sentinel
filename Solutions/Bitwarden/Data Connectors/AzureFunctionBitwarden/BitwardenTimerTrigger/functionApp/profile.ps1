# Azure Functions profile.ps1
#
# Executed on every cold start of the Function App.
# Authenticates to Azure using the User-Assigned Managed Identity so that
# Az module cmdlets (Get-AzKeyVaultSecret, Get-AzAccessToken) work without
# any stored credentials.

if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity
}

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Values = @()
)

@($Values) | ConvertTo-Json -Compress

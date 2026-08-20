<#
.SYNOPSIS
    Measures which subsystems the frame budget is actually going to, by ablation.

.DESCRIPTION
    Runs the game repeatedly over an IDENTICAL scripted route — same spawn, same
    camera, same movement, same seeds — once as a baseline and once per subsystem
    with that subsystem removed. The difference in frame time between a run and
    the baseline is that subsystem's real cost.

    Why ablation rather than just reading a profiler: a profiler tells you where
    time was spent, but attributing GPU time to a cause is unreliable (work
    overlaps, and cost lands on whoever issued the draw). "How much faster is it
    without X" is the question actually being asked, and an A/B run answers it
    directly. The profiler columns are still printed, because they say WHICH KIND
    of cost each subsystem carries — GPU, render submission, or GDScript — and
    that decides what a fix would even look like.

    Runs are WINDOWED on purpose: --headless has no real renderer, so GPU timings
    would all be zero and the whole exercise would measure nothing.

.PARAMETER Seconds
    Measurement window per run, after warm-up. Default 8.

.PARAMETER Warmup
    Discarded settling time per run. Default 10 — the streaming managers are
    still building chunks well past the first few seconds, and those builds cost
    tens of milliseconds each, so a short warm-up measures loading rather than
    playing.

.PARAMETER Ablations
    Which subsystems to test. Default is the full list.

.PARAMETER Static
    Measure standing still instead of walking. Steady-state draw cost only, with
    no continuous streaming. Useful as a second read: comparing the two says how
    much of the cost is streaming work versus simply drawing the scene.

.EXAMPLE
    powershell -File scripts/dev/run_perf.ps1

.EXAMPLE
    powershell -File scripts/dev/run_perf.ps1 -Ablations grass,trees,shadows -Seconds 6
#>
param(
    [double]$Seconds = 8.0,
    [double]$Warmup  = 10.0,
    [string[]]$Ablations = @('grass', 'trees', 'terrain', 'structures', 'props',
                             'npcs', 'rain', 'shadows', 'ssao', 'fog', 'sky', 'msaa'),
    [switch]$Static,
    [string]$Godot = "C:\Users\LukeD\Desktop\Godot\Godot_v4.7-stable_win64.exe"
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# Invoked via `powershell -File`, every argument arrives as a plain string, so
# `-Ablations grass,trees` binds as ONE element "grass,trees" rather than two.
# Left alone that silently collapses the whole sweep into a single run with
# everything removed at once - which still produces a plausible-looking table,
# just not the per-subsystem one that was asked for. Split explicitly.
$Ablations = @($Ablations | ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

if (-not (Test-Path $Godot)) {
    Write-Error "Godot not found at $Godot. Pass -Godot <path>."
}

# A running editor renders its own viewport and competes for the same GPU, which
# shows up as noise larger than most of the differences being measured.
$editors = @(Get-Process -Name "Godot*" -ErrorAction SilentlyContinue)
if ($editors.Count -gt 0) {
    Write-Host "WARNING: $($editors.Count) Godot process(es) already running." -ForegroundColor Yellow
    Write-Host "         Close the editor before trusting these numbers - it competes for the GPU." -ForegroundColor Yellow
    Write-Host ""
}

# The route. Identical for every run, which is what makes the runs comparable:
# fixed spawn, fixed camera, and walking so that chunk streaming stays active.
$route = @('--at=10,0.5,22', '--cam=45,-25,20')
if (-not $Static) { $route += '--drive=move_forward' }

function Invoke-PerfRun {
    param([string]$Label, [string]$Disable)

    $userArgs = @("--perf=$Seconds", "--perf-warmup=$Warmup", "--perf-label=$Label") + $route
    if ($Disable) { $userArgs += "--perf-disable=$Disable" }

    Write-Host ("  {0,-12} " -f $Label) -NoNewline
    $output = & $Godot --path $projectRoot -- @userArgs 2>&1 | Out-String

    # A failed ablation must not be silently averaged into the table as "no
    # effect" - that is indistinguishable from "this subsystem is free".
    if ($output -match 'PERF ABLATION FAILED|TARGET NOT FOUND') {
        Write-Host "ABLATION FAILED - see output" -ForegroundColor Red
        return $null
    }
    $line = ($output -split "`n" | Where-Object { $_ -match '^PERF\|' } | Select-Object -First 1)
    if (-not $line) {
        Write-Host "NO RESULT - run did not complete" -ForegroundColor Red
        return $null
    }

    $f = $line.Trim() -split '\|'
    $row = [PSCustomObject]@{
        Label      = $f[1]
        FrameMed   = [double]$f[2]
        FrameP95   = [double]$f[3]
        Gpu        = [double]$f[4]
        RenderCpu  = [double]$f[5]
        ScriptMed  = [double]$f[6]
        ScriptP95  = [double]$f[7]
        DrawVis    = [double]$f[8]
        DrawShadow = [double]$f[9]
        PrimVis    = [double]$f[10]
        PrimShadow = [double]$f[11]
    }
    Write-Host ("{0,8:N2} ms" -f $row.FrameMed) -ForegroundColor Green
    return $row
}

$mode = if ($Static) { "standing still" } else { "walking (streaming active)" }
Write-Host ""
Write-Host "Perf sweep - $mode, ${Seconds}s measured after ${Warmup}s warm-up" -ForegroundColor Cyan
Write-Host "Each run removes ONE subsystem; the difference from baseline is its cost."
Write-Host ""

$results = @()
$baseline = Invoke-PerfRun -Label 'baseline' -Disable $null
if (-not $baseline) { Write-Error "Baseline run failed; nothing to compare against." }
$results += $baseline

foreach ($a in $Ablations) {
    $row = Invoke-PerfRun -Label $a -Disable $a
    if ($row) { $results += $row }
}

Write-Host ""
Write-Host "=== COST BY SUBSYSTEM (sorted by frame time saved) ===" -ForegroundColor Cyan
Write-Host ""
Write-Host ("{0,-12} {1,9} {2,9} {3,8} {4,8} {5,9} {6,9}" -f `
    'removed', 'frame ms', 'saved', 'gpu ms', 'gpu-', 'script ms', 'script-')
Write-Host ("-" * 72)
Write-Host ("{0,-12} {1,9:N2} {2,9} {3,8:N2} {4,8} {5,9:N2} {6,9}" -f `
    'nothing', $baseline.FrameMed, '-', $baseline.Gpu, '-', $baseline.ScriptMed, '-')

$ranked = $results | Where-Object { $_.Label -ne 'baseline' } |
    Sort-Object { $baseline.FrameMed - $_.FrameMed } -Descending

foreach ($r in $ranked) {
    Write-Host ("{0,-12} {1,9:N2} {2,9:N2} {3,8:N2} {4,8:N2} {5,9:N2} {6,9:N2}" -f `
        $r.Label, $r.FrameMed, ($baseline.FrameMed - $r.FrameMed),
        $r.Gpu, ($baseline.Gpu - $r.Gpu),
        $r.ScriptMed, ($baseline.ScriptMed - $r.ScriptMed))
}

Write-Host ""
Write-Host "'saved' = ms per frame recovered by removing that subsystem." -ForegroundColor DarkGray
Write-Host "gpu- / script- split that saving into GPU work vs GDScript work," -ForegroundColor DarkGray
Write-Host "which is what decides whether a fix is a shader/draw change or a code change." -ForegroundColor DarkGray
Write-Host ""
Write-Host "=== STALLS (p95 frame time - felt as hitching, not low fps) ===" -ForegroundColor Cyan
Write-Host ""
Write-Host ("{0,-12} {1,9} {2,9}" -f 'removed', 'p95 ms', 'saved')
Write-Host ("-" * 34)
Write-Host ("{0,-12} {1,9:N2} {2,9}" -f 'nothing', $baseline.FrameP95, '-')
foreach ($r in ($results | Where-Object { $_.Label -ne 'baseline' } |
        Sort-Object { $baseline.FrameP95 - $_.FrameP95 } -Descending)) {
    Write-Host ("{0,-12} {1,9:N2} {2,9:N2}" -f `
        $r.Label, $r.FrameP95, ($baseline.FrameP95 - $r.FrameP95))
}
Write-Host ""

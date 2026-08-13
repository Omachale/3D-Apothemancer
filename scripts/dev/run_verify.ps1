<#
.SYNOPSIS
    Runs the headless verification suites so a broken script FAILS FAST
    instead of hanging forever.

.DESCRIPTION
    Every verify_*.gd exits through a single quit() as the last statement of
    _ready()/_init(). There is no watchdog and no error path. GDScript errors
    are fatal to the SCRIPT but not to the PROCESS: on a parse error _ready()
    never runs at all, so quit() is unreachable -- and headless Godot has no
    window, no input and no work queue, so it idles forever. It does not
    crash, does not time out, and does not exit non-zero. It just sits there.

    That trap was hit three times in one session (2026-08-12); one run was
    still alive twenty minutes later, holding up everything behind it, over a
    single un-inferable `:=`.

    Three things make it easy to trip, and this closes all three:

      1. PARSE-CHECK FIRST (--check-only). The codebase is strictly typed, so
         mistakes are usually PARSE errors rather than runtime ones -- the
         worst case, since the script never runs and so prints no partial log
         to diagnose from. --check-only catches those in ~2 seconds with a
         line number. It also catches a stale class cache (see 2), which
         surfaces as `Parse Error: Could not find type "Foo"`.

      2. REFRESH THE CLASS CACHE (-RescanClasses). A new `class_name` is not
         in .godot/global_script_class_cache.cfg until an EDITOR filesystem
         scan writes it, and `--headless <scene>` never does one. So the first
         headless run after adding any new class_name is GUARANTEED to
         parse-error, and therefore guaranteed to hang. Pass this after adding
         or renaming a class_name.

      3. TWO HARD BACKSTOPS. --quit-after bounds the process from inside;
         WaitForExit bounds it from outside and kills it. Belt and braces,
         because the whole point is that a hang must never again be possible.

    JUDGING A RUN. --quit-after force-quits with exit code 0, so a hung script
    would look like a silent PASS if only the exit code were checked. A run
    counts as passing only if it exits 0 AND prints its own success marker.

    PARSE CHECK CAVEAT. --check-only implies --script, and --script does NOT
    set up autoloads, so any script that reaches Game/Wind/Rain/Targeting/
    DevTools reports `Compile Error: Identifier not found: Game` even when it
    is perfectly valid. That specific class of error is therefore ignored,
    along with the cascade it causes. `Parse Error` is never ignored -- it is
    always real, and it is the one that causes the hang.

.EXAMPLE
    ./scripts/dev/run_verify.ps1
    ./scripts/dev/run_verify.ps1 -Suites tower,zone_layout
    ./scripts/dev/run_verify.ps1 -RescanClasses
#>
param(
    # Suite names to run (the verify_ prefix is optional). Default: all.
    [string[]]$Suites = @(),
    # Force an editor filesystem scan first, so newly added `class_name`
    # symbols resolve. Needed after adding or renaming one.
    [switch]$RescanClasses,
    # Frames before the internal backstop fires. Generous enough never to bite
    # a healthy run -- suites quit in the first frame or two, except
    # verify_terrain_manager which streams tiles over many frames.
    [int]$QuitAfter = 20000,
    # Wall-clock ceiling per Godot invocation. The outer backstop.
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'

$Godot = 'C:/Users/LukeD/Desktop/Godot/Godot_v4.7-stable_win64.exe'
$ProjectRoot = (Resolve-Path "$PSScriptRoot/../..").Path

if (-not (Test-Path $Godot)) {
    Write-Host "Godot not found at $Godot" -ForegroundColor Red
    exit 2
}

# Autoloads (project.godot). Scripts referencing these parse-check as
# "Identifier not found" purely because --script skips autoload setup.
$AutoloadNames = 'Game|Wind|Rain|Targeting|DevTools'

# Runs Godot with both streams captured to files. Start-Process is used
# rather than a plain call because PowerShell 5.1 wraps a native command's
# redirected stderr in ErrorRecords and flips $? to false even on success,
# which made an earlier version of this script report false failures.
function Invoke-Godot {
    param([string[]]$GodotArgs)

    # -ArgumentList joins an array with spaces and does NOT quote, so the
    # project path ("...\3D Apothemancer") would arrive as two arguments and
    # Godot would abort with "Invalid project path". Quote anything with
    # whitespace.
    $quoted = @()
    foreach ($a in $GodotArgs) {
        if ($a -match '\s') { $quoted += '"' + $a + '"' } else { $quoted += $a }
    }

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $Godot -ArgumentList $quoted -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        # Touching .Handle caches it, WITHOUT which .ExitCode comes back null
        # on a -PassThru process that was not started with -Wait. That null
        # then reads as "no exit code" and the run is misjudged.
        $null = $p.Handle

        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            Write-Host "  TIMED OUT after ${TimeoutSeconds}s -- killing PID $($p.Id)" -ForegroundColor Red
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            return @{ ExitCode = 124; Text = 'timed out'; TimedOut = $true }
        }

        $text = ''
        foreach ($f in @($outFile, $errFile)) {
            $c = Get-Content $f -Raw -ErrorAction SilentlyContinue
            if ($null -ne $c) { $text += $c }
        }
        return @{ ExitCode = $p.ExitCode; Text = $text; TimedOut = $false }
    }
    finally {
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

# True when --check-only output contains a problem that is genuinely the
# script's fault, as opposed to the autoload artifact described in the header.
function Test-RealParseFailure {
    param([string]$Text)

    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match 'Parse Error') { return $true }
        if ($line -match 'Compile Error') {
            # Ignore only the autoload-not-found case and its cascade.
            if ($line -match "Identifier not found: ($AutoloadNames)\b") { continue }
            if ($line -match 'Failed to compile depended scripts') { continue }
            return $true
        }
    }
    return $false
}

# How each suite runs. Scene-based suites (extends Node) need a wrapper scene
# because they reach autoloads, which --script does not set up. The two
# SceneTree-based suites have no such dependency and run directly.
$AllSuites = [ordered]@{
    'heightfield'     = @{ Script = 'res://scripts/dev/verify_heightfield.gd';     Scene = $null }
    'terrain_chunk'   = @{ Script = 'res://scripts/dev/verify_terrain_chunk.gd';   Scene = $null }
    'terrain_manager' = @{ Script = 'res://scripts/dev/verify_terrain_manager.gd'; Scene = 'res://scenes/dev/VerifyTerrainManager.tscn' }
    'zone_layout'     = @{ Script = 'res://scripts/dev/verify_zone_layout.gd';     Scene = 'res://scenes/dev/VerifyZoneLayout.tscn' }
    'tower'           = @{ Script = 'res://scripts/dev/verify_tower.gd';           Scene = 'res://scenes/dev/VerifyTower.tscn' }
    'atmosphere'      = @{ Script = 'res://scripts/dev/verify_atmosphere.gd';      Scene = 'res://scenes/dev/VerifyAtmosphere.tscn' }
    'health'          = @{ Script = 'res://scripts/dev/verify_health.gd';          Scene = 'res://scenes/dev/VerifyHealth.tscn' }
    'targeting'       = @{ Script = 'res://scripts/dev/verify_targeting.gd';       Scene = 'res://scenes/dev/VerifyTargeting.tscn' }
    'aim'             = @{ Script = 'res://scripts/dev/verify_aim.gd';             Scene = 'res://scenes/dev/VerifyAim.tscn' }
    'camera_pitch'    = @{ Script = 'res://scripts/dev/verify_camera_pitch.gd';    Scene = 'res://scenes/dev/VerifyCameraPitch.tscn' }
}

if ($Suites.Count -eq 0) {
    $selected = @($AllSuites.Keys)
} else {
    $selected = @()
    foreach ($s in $Suites) {
        $key = $s -replace '^verify_', ''
        if (-not $AllSuites.Contains($key)) {
            Write-Host "Unknown suite '$s'. Known: $($AllSuites.Keys -join ', ')" -ForegroundColor Red
            exit 2
        }
        $selected += $key
    }
}

if ($RescanClasses) {
    Write-Host '== Refreshing global class cache ==' -ForegroundColor Cyan
    $scan = Invoke-Godot @('--headless', '--path', $ProjectRoot, '--editor', '--quit')
    Write-Host '  cache rescan done'
    # Verified rather than assumed: --editor has been seen to leave a process
    # behind, and an unnoticed stray editor is exactly what this exists to
    # prevent. Only processes matching THIS invocation are touched -- the
    # user's own editor and running game must be left alone.
    Start-Sleep -Seconds 1
    $stray = @(Get-CimInstance Win32_Process -Filter "Name like '%Godot%'" |
        Where-Object { $_.CommandLine -like '*--editor*' -and $_.CommandLine -like '*--quit*' })
    foreach ($p in $stray) {
        Write-Host "  cleaning up stray editor PID $($p.ProcessId)" -ForegroundColor Yellow
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

$failed = @()
foreach ($name in $selected) {
    $suite = $AllSuites[$name]
    Write-Host ''
    Write-Host "== $name ==" -ForegroundColor Cyan

    # ---- 1. Parse check: cheap, and turns a hang into a line number. ----
    $check = Invoke-Godot @('--headless', '--path', $ProjectRoot, '--check-only', '--script', $suite.Script)
    if (Test-RealParseFailure -Text $check.Text) {
        Write-Host $check.Text.TrimEnd()
        Write-Host "PARSE FAILED ($name) -- not running it" -ForegroundColor Red
        $failed += $name
        continue
    }

    # ---- 2. Run, bounded by both backstops. ----
    if ($null -ne $suite.Scene) {
        $runArgs = @('--headless', '--path', $ProjectRoot, '--quit-after', "$QuitAfter", $suite.Scene)
    } else {
        $runArgs = @('--headless', '--path', $ProjectRoot, '--quit-after', "$QuitAfter", '--script', $suite.Script)
    }
    $run = Invoke-Godot $runArgs
    Write-Host $run.Text.TrimEnd()

    # ---- 3. Judge on BOTH exit code and the suite's own success marker. ----
    # Two marker styles are in use: "ALL <X> CHECKS PASSED" (heightfield,
    # terrain_chunk, terrain_manager, zone_layout, tower) and "VERIFY <X>:
    # PASS" (health, targeting, aim, camera_pitch). Accept either; a suite
    # printing neither is treated as never having finished.
    $passed = $run.Text -match '(?m)^\s*(ALL .*PASSED|VERIFY .*:\s*PASS)\s*$'
    if ($run.ExitCode -ne 0) {
        Write-Host "FAILED ($name): exit code $($run.ExitCode)" -ForegroundColor Red
        $failed += $name
    } elseif (-not $passed) {
        Write-Host "FAILED ($name): exit 0 but no success marker -- script likely never reached quit()" -ForegroundColor Red
        $failed += $name
    } else {
        Write-Host "OK ($name)" -ForegroundColor Green
    }
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host "$($failed.Count) SUITE(S) FAILED: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host "ALL $($selected.Count) SUITE(S) PASSED" -ForegroundColor Green
exit 0

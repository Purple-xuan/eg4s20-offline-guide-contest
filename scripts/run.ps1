param(
    [ValidateSet('check','synthesis','route','bitgen','rebuilt_bitgen')]
    [string]$Mode = 'check',
    [string]$TdExe = $env:TD_EXE
)
$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path $PSScriptRoot -Parent
if (-not $TdExe) {
    $found = Get-Command td_commands_prompt.exe -ErrorAction SilentlyContinue
    if ($found) { $TdExe = $found.Source }
    else { $TdExe = 'C:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/bin/td_commands_prompt.exe' }
}
if (-not (Test-Path -LiteralPath $TdExe)) { throw 'Pass -TdExe with the full path to td_commands_prompt.exe (TD 6.2.168116).' }
$env:SUBMISSION_MODE = $Mode
$outputDir = Join-Path $packageRoot "build/$Mode"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$logFile = Join-Path $outputDir 'console.log'
Push-Location $outputDir
try {
    $entryScript = (Join-Path $PSScriptRoot 'entry.tcl').Replace('\', '/')
    & $TdExe $entryScript *> $logFile
    $code = $LASTEXITCODE
    Get-Content -LiteralPath $logFile -Tail 15
    if ($code -ne 0 -or -not (Select-String -LiteralPath $logFile -SimpleMatch "SUBMISSION_PASS: $Mode" -Quiet)) {
        throw "TD failed; see $logFile"
    }
} finally { Pop-Location }

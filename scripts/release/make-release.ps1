# make-release.ps1 - capture + shrink the appliance image, driving WSL from Windows.
#
# The whole release path is Linux work (dd, loop devices, resize2fs), so this is
# a thin driver: it resolves paths and your SSH config into WSL, then runs
# capture-image.sh, check-image.sh and shrink-image.sh inside Ubuntu.
#
# Work happens on WSL's own filesystem, not /mnt/c - writing 32 GB through 9p is
# several times slower. Only the finished .img.gz is copied back to Windows.
#
#   .\make-release.ps1 -FromSsh x16raspi
#   .\make-release.ps1 -FromDevice /dev/sdb        # card in a reader, see below
#   .\make-release.ps1 -SkipCapture                # re-shrink an existing capture
#
# For -FromDevice, attach the reader to WSL first from an ADMIN PowerShell:
#   wmic diskdrive list brief                      # find the disk number
#   wsl --mount \\.\PHYSICALDRIVE2 --bare
#   wsl lsblk                                      # confirm which /dev/sdX it is
#
# Two Windows-isms this file works around, both learned the hard way:
#   * ASCII only. Windows PowerShell 5.1 reads .ps1 as ANSI, and an em-dash
#     decodes to a smart quote that silently terminates a string.
#   * Every WSL call passes a plain argv array - no `bash -lc "..."`. wsl.exe
#     re-parses its command line, so quotes, semicolons and backslashes in a
#     shell string get mangled before Linux ever sees them.
#
[CmdletBinding()]
param(
    [string]$FromSsh,
    [string]$FromDevice,
    [string]$Distro   = 'Ubuntu',
    # Every step needs root inside WSL - losetup, mount, dd, mkfs - so run as
    # root rather than leaning on sudo, which prompts and stalls the run.
    [string]$WslUser  = 'root',
    [string]$Name     = 'x16-appliance-r49',
    [string]$WorkDir,
    [string]$OutDir   = (Get-Location).Path,
    # 0 = ship DietPi's stock 128 MB FAT and skip the refit entirely. That is
    # the default because it is the configuration known to boot, and 128 MB
    # already holds thousands of .PRG files. Set a size only if you deliberately
    # want a bigger drop folder; it costs root-filesystem space on small cards.
    [int]$FatMB       = 0,
    # The name Windows shows for the card's drop drive. It is the owner's first
    # impression, and an unlabelled card reads as "Removable Disk (E:)".
    # Applied whether or not the FAT is refitted; '' skips labelling entirely.
    [string]$FatLabel = 'X16PI',
    [switch]$SkipCapture,
    [switch]$TransportGzip
)

$ErrorActionPreference = 'Stop'

if (-not $FromSsh -and -not $FromDevice -and -not $SkipCapture) {
    throw "Give -FromSsh <host> or -FromDevice /dev/sdX (or -SkipCapture to shrink an existing capture)."
}
if ($FromSsh -and $FromDevice) { throw "Pick one source, not both." }

function Invoke-Wsl {
    param([string]$Label, [string[]]$Argv)
    Write-Host ""
    Write-Host "== $Label ==" -ForegroundColor Cyan
    Write-Host "wsl: $($Argv -join ' ')" -ForegroundColor DarkGray
    & wsl.exe -d $Distro -u $WslUser -- @Argv
    if ($LASTEXITCODE -ne 0) { throw "$Label failed (exit $LASTEXITCODE)" }
}

function Convert-ToWslPath {
    param([string]$WindowsPath)
    # Deliberately not `wslpath`: wsl.exe re-parses its command line and strips
    # the backslashes out of a Windows path before wslpath sees it.
    # Assumes the default drvfs layout (C:\ -> /mnt/c), which is WSL's default.
    $full = [System.IO.Path]::GetFullPath($WindowsPath)
    if ($full -notmatch '^[A-Za-z]:') { throw "not a drive-letter path: $WindowsPath" }
    $drive = $full.Substring(0, 1).ToLower()
    $rest  = $full.Substring(2).Replace('\', '/')
    return "/mnt/$drive$rest"
}

# --- locate the repo and the work dir inside WSL -----------------------------
$repoWin = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$repo    = Convert-ToWslPath $repoWin

$wslHome = ((& wsl.exe -d $Distro -u $WslUser -- printenv HOME) -replace "`0", '').Trim()
if ($LASTEXITCODE -ne 0 -or -not $wslHome) { throw "Cannot reach WSL distro '$Distro'. Try: wsl -l -v" }
if (-not $WorkDir) { $WorkDir = "$wslHome/x16-release" }

Write-Host "repo (WSL):  $repo"
Write-Host "work dir:    $WorkDir  (inside WSL)"

# The FAT partition can only be resized offline, between capture and shrink -
# growing it moves the start of the mounted root, which no live system allows.
# So the capture lands under a -raw name and the refit produces the real one.
$img = "$WorkDir/$Name.img"
$raw = if ($FatMB -gt 0) { "$WorkDir/$Name-raw.img" } else { $img }
$gz  = "$img.gz"

# --- capture -----------------------------------------------------------------
if (-not $SkipCapture) {
    Invoke-Wsl -Label 'prepare work dir' -Argv @('mkdir', '-p', $WorkDir)
    Invoke-Wsl -Label 'free space'       -Argv @('df', '-h', $WorkDir)

    if ($FromDevice) {
        $srcArgs = @('--from-device', $FromDevice)
    }
    else {
        # Resolve the Windows SSH config so a host alias works from WSL too,
        # which has no ~/.ssh/config of its own. `ssh -G` prints the effective
        # settings for a host without connecting to it.
        $g = & ssh.exe -G $FromSsh 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $g) {
            throw "ssh -G $FromSsh failed - is the host in your ~/.ssh/config?"
        }
        $hostname = ($g | Where-Object { $_ -match '^hostname ' }     | Select-Object -First 1) -replace '^hostname ', ''
        $user     = ($g | Where-Object { $_ -match '^user ' }         | Select-Object -First 1) -replace '^user ', ''
        $port     = ($g | Where-Object { $_ -match '^port ' }         | Select-Object -First 1) -replace '^port ', ''
        $idfile   = ($g | Where-Object { $_ -match '^identityfile ' } | Select-Object -First 1) -replace '^identityfile ', ''

        $srcArgs = @('--from-ssh', "$user@$hostname", '--ssh-port', $port)
        if ($idfile) { $idfile = $idfile -replace '^~', $env:USERPROFILE }
        if ($idfile -and (Test-Path $idfile)) {
            # capture-image.sh copies the key to a 0600 temp file first: /mnt/c
            # is mounted 0777 and ssh rejects a key that permissive.
            $srcArgs += @('--ssh-key', (Convert-ToWslPath $idfile))
        }
        else {
            Write-Host "no usable key for $FromSsh - ssh will prompt for the password (DietPi: root/dietpi)" -ForegroundColor Yellow
        }
        Write-Host "source:      $user@$hostname port $port"
    }

    if ($TransportGzip) { $srcArgs += '--transport-gzip' }

    $argv = @('bash', "$repo/scripts/release/capture-image.sh") + $srcArgs + @('-o', $raw, '-y', '--force')
    Invoke-Wsl -Label 'capture card' -Argv $argv
}

# --- refit the FAT partition -------------------------------------------------
if ($FatMB -gt 0) {
    $refit = @('bash', "$repo/scripts/release/refit-fat.sh", '--fat-mb', "$FatMB", '-o', $img)
    if ($FatLabel) { $refit += @('--label', $FatLabel) }
    $refit += $raw
    Invoke-Wsl -Label "refit FAT to $FatMB MB" -Argv $refit
    Invoke-Wsl -Label 'drop the raw capture' -Argv @('rm', '-f', $raw)
}

# --- name the drop drive -----------------------------------------------------
# Runs after any refit (which mkfs's a fresh FAT and would drop the label), and
# unconditionally otherwise, because the refit is off by default and used to be
# the only thing that ever set a label.
if ($FatLabel) {
    Invoke-Wsl -Label "label the FAT drive '$FatLabel'" `
               -Argv @('bash', "$repo/scripts/release/set-fat-label.sh", '--label', $FatLabel, $img)
}

# --- check + shrink ----------------------------------------------------------
Invoke-Wsl -Label 'shrink (ship-readiness checks run first)' `
           -Argv @('bash', "$repo/scripts/release/shrink-image.sh", $img)

# --- bring the artifact back to Windows --------------------------------------
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$outWsl = Convert-ToWslPath $OutDir
Invoke-Wsl -Label 'copy artifact to Windows' -Argv @('cp', '-v', $gz, "$outWsl/")
Invoke-Wsl -Label 'free the WSL copy'        -Argv @('rm', '-f', $gz)

$final = Join-Path $OutDir "$Name.img.gz"
Write-Host ""
Write-Host "Done: $final" -ForegroundColor Green
if (Test-Path $final) {
    $mb = "{0:N0} MB" -f ((Get-Item $final).Length / 1MB)
    Write-Host "  size: $mb"
}
Write-Host "  Gate 5: flash it to a BLANK card, boot a second Pi, re-pass Gate 3," -ForegroundColor Yellow
Write-Host "          and check 'df -h /' shows the root expanded to that card." -ForegroundColor Yellow

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServerRoot
)

$ErrorActionPreference = "Stop"
$target = [IO.Path]::GetFullPath($ServerRoot)
if (-not (Test-Path -LiteralPath $target -PathType Container)) {
    throw "The game-server configuration root does not exist: $target"
}

function Ensure-ConfigurationJunction {
    param([string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $fullPath) {
        $item = Get-Item -LiteralPath $fullPath -Force
        $resolvedTarget = @($item.Target) | Select-Object -First 1
        if ($item.LinkType -ne "Junction" -or [IO.Path]::GetFullPath([string]$resolvedTarget) -ne $target) {
            throw "Refusing to replace an unexpected AMP configuration path: $fullPath"
        }
        return
    }
    [void](New-Item -ItemType Junction -Path $fullPath -Target $target)
}

# The WC2 MetaConfig path is explicitly anchored below the application root.
# Keeping only that junction avoids inheriting a stale instance-root junction
# from a previous template revision.
Ensure-ConfigurationJunction -Path (Join-Path $PSScriptRoot "runtime-config")

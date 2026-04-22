<#
.SYNOPSIS
    Apply per-pair retention to a destination tree. The only destructive
    module in ServerSync.
#>

function Invoke-Retention {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$DestinationRoot,

        [Parameter(Mandatory)]
        [Object]$Policy,

        [scriptblock]$LogCallback
    )

    if (-not (Test-Path -Path $DestinationRoot -PathType Container)) {
        return  # nothing to do
    }

    $subfolders = Get-ChildItem -Path $DestinationRoot -Directory -Force

    switch ($Policy.Mode) {
        'files'   { Invoke-RetentionFilesMode   -Subfolders $subfolders -Policy $Policy -LogCallback $LogCallback }
        'folders' { Invoke-RetentionFoldersMode -Subfolders $subfolders -Policy $Policy -LogCallback $LogCallback }
        default   { throw "Unknown retention mode: $($Policy.Mode)" }
    }
}

function Invoke-RetentionFilesMode {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Object[]]$Subfolders,
        [Object]$Policy,
        [scriptblock]$LogCallback
    )

    foreach ($sub in $Subfolders) {
        foreach ($ext in $Policy.Extensions) {
            $normalizedExt = $ext
            if (-not $normalizedExt.StartsWith('.')) { $normalizedExt = ".$normalizedExt" }

            $files = Get-ChildItem -Path $sub.FullName -File -Force |
                Where-Object { $_.Extension -ieq $normalizedExt } |
                Sort-Object LastWriteTime -Descending

            $toDelete = $files | Select-Object -Skip $Policy.Count
            foreach ($f in $toDelete) {
                if ($PSCmdlet.ShouldProcess($f.FullName, 'Delete (retention)')) {
                    Remove-Item -LiteralPath $f.FullName -Force
                    if ($LogCallback) {
                        & $LogCallback "retention: deleted $($f.FullName)"
                    }
                }
            }
        }
    }
}

function Invoke-RetentionFoldersMode {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Object[]]$Subfolders,
        [Object]$Policy,
        [scriptblock]$LogCallback
    )

    foreach ($sub in $Subfolders) {
        $childFolders = Get-ChildItem -Path $sub.FullName -Directory -Force |
            Sort-Object LastWriteTime -Descending

        $toDelete = $childFolders | Select-Object -Skip $Policy.Count
        foreach ($d in $toDelete) {
            if ($PSCmdlet.ShouldProcess($d.FullName, 'Delete folder recursively (retention)')) {
                Remove-Item -LiteralPath $d.FullName -Recurse -Force
                if ($LogCallback) {
                    & $LogCallback "retention: deleted folder $($d.FullName)"
                }
            }
        }
    }
}

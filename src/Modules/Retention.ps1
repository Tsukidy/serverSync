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

    if (-not (Test-Path -LiteralPath $DestinationRoot -PathType Container)) {
        return  # nothing to do
    }

    # Resolve to canonical full path so containment checks are reliable.
    $canonicalRoot = (Resolve-Path -LiteralPath $DestinationRoot).ProviderPath

    # If the destination root itself is a reparse point (junction/symlink),
    # refuse: we cannot guarantee containment when the root may resolve
    # outside its apparent location.
    $rootItem = Get-Item -LiteralPath $canonicalRoot -Force
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        $msg = "retention: refusing to operate on reparse-point destination root: $canonicalRoot"
        if ($LogCallback) { & $LogCallback $msg }
        else { Write-Warning $msg }
        return
    }

    $subfolders = Get-ChildItem -LiteralPath $canonicalRoot -Directory -Force |
        Where-Object {
            # Skip subfolders that are reparse points - retention should not
            # follow links that may escape the destination tree.
            -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
        }

    switch ($Policy.Mode) {
        'files'   { Invoke-RetentionFilesMode   -Subfolders $subfolders -Policy $Policy -CanonicalRoot $canonicalRoot -LogCallback $LogCallback }
        'folders' { Invoke-RetentionFoldersMode -Subfolders $subfolders -Policy $Policy -CanonicalRoot $canonicalRoot -LogCallback $LogCallback }
        default   { throw "Unknown retention mode: $($Policy.Mode)" }
    }
}

function Invoke-RetentionFilesMode {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Object[]]$Subfolders,
        [Object]$Policy,
        [Parameter(Mandatory)][string]$CanonicalRoot,
        [scriptblock]$LogCallback
    )

    foreach ($sub in $Subfolders) {
        foreach ($ext in $Policy.Extensions) {
            $normalizedExt = $ext
            if (-not $normalizedExt.StartsWith('.')) { $normalizedExt = ".$normalizedExt" }

            $files = Get-ChildItem -LiteralPath $sub.FullName -File -Force |
                Where-Object { $_.Extension -ieq $normalizedExt } |
                Sort-Object LastWriteTime -Descending

            $toDelete = $files | Select-Object -Skip $Policy.Count
            foreach ($f in $toDelete) {
                # Containment guard: only delete if the file is under the canonical root.
                if (-not (Test-PathContainedIn -Candidate $f.FullName -Root $CanonicalRoot)) {
                    if ($LogCallback) { & $LogCallback "retention: refused (outside destination root): $($f.FullName)" }
                    continue
                }
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
        [Parameter(Mandatory)][string]$CanonicalRoot,
        [scriptblock]$LogCallback
    )

    foreach ($sub in $Subfolders) {
        $childFolders = Get-ChildItem -LiteralPath $sub.FullName -Directory -Force |
            Sort-Object LastWriteTime -Descending

        $toDelete = $childFolders | Select-Object -Skip $Policy.Count
        foreach ($d in $toDelete) {
            # Refuse to recurse into reparse points - they may target locations
            # outside the destination tree.
            if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                if ($LogCallback) { & $LogCallback "retention: refused (reparse point): $($d.FullName)" }
                continue
            }
            # Containment guard: only delete if the folder is under the canonical root.
            if (-not (Test-PathContainedIn -Candidate $d.FullName -Root $CanonicalRoot)) {
                if ($LogCallback) { & $LogCallback "retention: refused (outside destination root): $($d.FullName)" }
                continue
            }
            if ($PSCmdlet.ShouldProcess($d.FullName, 'Delete folder recursively (retention)')) {
                Remove-Item -LiteralPath $d.FullName -Recurse -Force
                if ($LogCallback) {
                    & $LogCallback "retention: deleted folder $($d.FullName)"
                }
            }
        }
    }
}

function Test-PathContainedIn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$Root
    )
    # Both must be canonical paths. Use ProviderPath form throughout.
    $candidateFull = (Resolve-Path -LiteralPath $Candidate -ErrorAction SilentlyContinue)
    if (-not $candidateFull) { return $false }
    $candidateStr = $candidateFull.ProviderPath
    # Normalize trailing separator on Root so 'D:\Backup' doesn't match 'D:\BackupOther\...'.
    $rootWithSep = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    return $candidateStr.StartsWith($rootWithSep, [StringComparison]::OrdinalIgnoreCase) -or
           $candidateStr.Equals($Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)
}

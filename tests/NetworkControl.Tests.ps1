BeforeAll {
    $script:ModulePath = [IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Modules', 'NetworkControl.ps1')
    . $script:ModulePath

    # Stub Windows-only cmdlets so Pester can mock them on non-Windows
    if (-not (Get-Command Enable-NetAdapter -ErrorAction SilentlyContinue)) {
        function global:Enable-NetAdapter { param($Name, [switch]$Confirm) }
    }
    if (-not (Get-Command Disable-NetAdapter -ErrorAction SilentlyContinue)) {
        function global:Disable-NetAdapter { param($Name, [switch]$Confirm) }
    }
    if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) {
        function global:Get-NetAdapter { param($Name) }
    }
}

Describe 'NetworkControl - enable/disable' -Tag 'Unit' {
    It 'Enable-ServerSyncNics calls Enable-NetAdapter for each name' {
        Mock Enable-NetAdapter { } -ParameterFilter { $Name }

        Enable-ServerSyncNics -Names @('Ethernet','Ethernet 2')

        Should -Invoke Enable-NetAdapter -Times 1 -ParameterFilter { $Name -eq 'Ethernet' }
        Should -Invoke Enable-NetAdapter -Times 1 -ParameterFilter { $Name -eq 'Ethernet 2' }
    }

    It 'Disable-ServerSyncNics calls Disable-NetAdapter for each name' {
        Mock Disable-NetAdapter { } -ParameterFilter { $Name }
        Disable-ServerSyncNics -Names @('Ethernet')
        Should -Invoke Disable-NetAdapter -Times 1
    }

    It 'Test-AllNicsDisabled returns $true when all report Status "Disabled"' {
        Mock Get-NetAdapter { [PSCustomObject]@{ Name=$Name; Status='Disabled' } } -ParameterFilter { $Name }
        (Test-AllNicsDisabled -Names @('Ethernet','Ethernet 2')) | Should -Be $true
    }

    It 'Test-AllNicsDisabled returns $false when one is still Up' {
        Mock Get-NetAdapter {
            if ($Name -eq 'Ethernet') { [PSCustomObject]@{ Name=$Name; Status='Disabled' } }
            else { [PSCustomObject]@{ Name=$Name; Status='Up' } }
        } -ParameterFilter { $Name }
        (Test-AllNicsDisabled -Names @('Ethernet','Ethernet 2')) | Should -Be $false
    }

    It 'Test-AllNicsDisabled returns $false when an adapter does not exist (typo or rename)' {
        # Critical: a typo in config used to silently pass verification.
        Mock Get-NetAdapter {
            if ($Name -eq 'Ethernet') { [PSCustomObject]@{ Name=$Name; Status='Disabled' } }
            else { $null }   # the missing adapter case
        } -ParameterFilter { $Name }
        (Test-AllNicsDisabled -Names @('Ethernet','EthernetX-typo')) | Should -Be $false
    }
}

Describe 'NetworkControl - readiness' -Tag 'Unit' {
    It 'Wait-NetworkReady returns $true when ping succeeds' {
        Mock Test-Connection { $true }
        (Wait-NetworkReady -TargetHost '192.168.1.1' -TimeoutSeconds 1) | Should -Be $true
    }

    It 'Wait-NetworkReady returns $false after timeout when ping never succeeds' {
        Mock Test-Connection { $false }
        (Wait-NetworkReady -TargetHost '192.168.1.1' -TimeoutSeconds 2) | Should -Be $false
    }
}

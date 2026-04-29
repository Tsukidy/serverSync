BeforeAll {
    $script:ModulePath = [IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Modules', 'SyncOperations.ps1')
    . $script:ModulePath
}

Describe 'SyncOperations - robocopy exit code interpretation' -Tag 'Unit' {
    It 'treats 0-3 as success' {
        foreach ($code in 0..3) {
            $r = ConvertFrom-RobocopyExitCode -ExitCode $code
            $r.Success | Should -Be $true
            $r.HasWarnings | Should -Be $false
        }
    }

    It 'treats 4-7 as success with warnings' {
        foreach ($code in 4..7) {
            $r = ConvertFrom-RobocopyExitCode -ExitCode $code
            $r.Success | Should -Be $true
            $r.HasWarnings | Should -Be $true
        }
    }

    It 'treats 8-16 as failure' {
        foreach ($code in 8..16) {
            $r = ConvertFrom-RobocopyExitCode -ExitCode $code
            $r.Success | Should -Be $false
        }
    }

    It 'returns a human-readable description' {
        (ConvertFrom-RobocopyExitCode -ExitCode 0).Description | Should -Match 'no'
        (ConvertFrom-RobocopyExitCode -ExitCode 1).Description | Should -Match 'copied'
        (ConvertFrom-RobocopyExitCode -ExitCode 8).Description | Should -Not -Match 'success'
    }
}

Describe 'SyncOperations - argument building' -Tag 'Unit' {
    It 'Build-RobocopyArgs uses the spec flags' {
        $args = Build-RobocopyArgs -Source '\\src\s' -Destination 'D:\d' `
            -Threads 6 -Retries 3 -RetryWaitSeconds 10 -LogFile 'C:\l.log'
        $argString = $args -join ' '
        $argString | Should -Match '/E'
        $argString | Should -Match '/Z'
        $argString | Should -Match '/COPY:DAT'
        $argString | Should -Match '/XO'
        $argString | Should -Match '/R:3'
        $argString | Should -Match '/W:10'
        $argString | Should -Match '/MT:6'
        $argString | Should -Match '/NP'
        $argString | Should -Match '/LOG\+:C:\\l\.log'
    }

    It 'Build-RobocopyArgs includes extra_flags verbatim' {
        $args = Build-RobocopyArgs -Source '\\s\s' -Destination 'D:\d' `
            -Threads 4 -Retries 1 -RetryWaitSeconds 5 -LogFile 'C:\l.log' `
            -ExtraFlags @('/COMPRESS','/IPG:50')
        $argString = $args -join ' '
        $argString | Should -Match '/COMPRESS'
        $argString | Should -Match '/IPG:50'
    }

    It 'Build-RobocopyArgs puts source and destination first' {
        $args = Build-RobocopyArgs -Source '\\src\s' -Destination 'D:\d' `
            -Threads 6 -Retries 3 -RetryWaitSeconds 10 -LogFile 'C:\l.log'
        $args[0] | Should -Be '\\src\s'
        $args[1] | Should -Be 'D:\d'
    }
}

Describe 'SyncOperations - mirror mode' -Tag 'Unit' {
    It 'Build-RobocopyArgs -Mirror includes /MIR' {
        $args = Build-RobocopyArgs -Source '\\src\s' -Destination 'D:\d' `
            -Threads 6 -Retries 3 -RetryWaitSeconds 10 -LogFile 'C:\l.log' -Mirror
        ($args -join ' ') | Should -Match '/MIR'
    }

    It 'Build-RobocopyArgs -Mirror omits /E (redundant with /MIR)' {
        $args = Build-RobocopyArgs -Source '\\src\s' -Destination 'D:\d' `
            -Threads 6 -Retries 3 -RetryWaitSeconds 10 -LogFile 'C:\l.log' -Mirror
        # /E should not appear as a standalone arg (would be wrong; /MIR includes it)
        $args | Should -Not -Contain '/E'
    }

    It 'Build-RobocopyArgs -Mirror omits /XO' {
        $args = Build-RobocopyArgs -Source '\\src\s' -Destination 'D:\d' `
            -Threads 6 -Retries 3 -RetryWaitSeconds 10 -LogFile 'C:\l.log' -Mirror
        $args | Should -Not -Contain '/XO'
    }

    It 'Build-RobocopyArgs without -Mirror keeps /E and /XO and omits /MIR' {
        $args = Build-RobocopyArgs -Source '\\src\s' -Destination 'D:\d' `
            -Threads 6 -Retries 3 -RetryWaitSeconds 10 -LogFile 'C:\l.log'
        $args | Should -Contain '/E'
        $args | Should -Contain '/XO'
        $args | Should -Not -Contain '/MIR'
    }

    It 'Build-RobocopyArgs -Mirror still includes the standard non-copy-mode flags' {
        $args = Build-RobocopyArgs -Source '\\src\s' -Destination 'D:\d' `
            -Threads 6 -Retries 3 -RetryWaitSeconds 10 -LogFile 'C:\l.log' -Mirror
        $argString = $args -join ' '
        $argString | Should -Match '/Z'
        $argString | Should -Match '/COPY:DAT'
        $argString | Should -Match '/R:3'
        $argString | Should -Match '/W:10'
        $argString | Should -Match '/MT:6'
        $argString | Should -Match '/NP'
        $argString | Should -Match '/LOG\+:'
    }
}

Describe 'SyncOperations - Test-RobocopyFlag allowlist' -Tag 'Unit' {
    It 'allows benign flags like /COMPRESS' {
        Test-RobocopyFlag -Flag '/COMPRESS' | Should -Be $true
    }

    It 'allows prefixed flags like /IPG:50' {
        Test-RobocopyFlag -Flag '/IPG:50' | Should -Be $true
        Test-RobocopyFlag -Flag '/MAXAGE:30' | Should -Be $true
    }

    It 'is case-insensitive' {
        Test-RobocopyFlag -Flag '/compress' | Should -Be $true
        Test-RobocopyFlag -Flag '/ipg:50' | Should -Be $true
    }

    It 'rejects /MIR (mirror is opt-in via retention.mode)' {
        Test-RobocopyFlag -Flag '/MIR' | Should -Be $false
    }

    It 'rejects /PURGE' {
        Test-RobocopyFlag -Flag '/PURGE' | Should -Be $false
    }

    It 'rejects /MOVE and /MOV' {
        Test-RobocopyFlag -Flag '/MOVE' | Should -Be $false
        Test-RobocopyFlag -Flag '/MOV' | Should -Be $false
    }

    It 'rejects /LOG and /LOG+ (log redirection could overwrite files)' {
        Test-RobocopyFlag -Flag '/LOG:C:\evil.log' | Should -Be $false
        Test-RobocopyFlag -Flag '/LOG+:C:\evil.log' | Should -Be $false
    }

    It 'rejects /JOB and /SAVE' {
        Test-RobocopyFlag -Flag '/JOB:foo' | Should -Be $false
        Test-RobocopyFlag -Flag '/SAVE:bar' | Should -Be $false
    }

    It 'rejects core flags we set ourselves' {
        Test-RobocopyFlag -Flag '/E' | Should -Be $false
        Test-RobocopyFlag -Flag '/XO' | Should -Be $false
        Test-RobocopyFlag -Flag '/COPY:DATSO' | Should -Be $false
    }

    It 'rejects flags not starting with /' {
        Test-RobocopyFlag -Flag 'COMPRESS' | Should -Be $false
        Test-RobocopyFlag -Flag '\\evil' | Should -Be $false
    }

    It 'rejects empty / whitespace input' {
        Test-RobocopyFlag -Flag '' | Should -Be $false
        Test-RobocopyFlag -Flag '   ' | Should -Be $false
    }
}

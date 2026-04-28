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

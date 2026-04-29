BeforeAll {
    $script:ModulePath = [IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Modules', 'Logging.ps1')
    . $script:ModulePath
}

Describe 'Logging - file logger' -Tag 'Unit' {
    BeforeEach {
        $script:TmpDir = Join-Path ([IO.Path]::GetTempPath()) ("logging-test-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TmpDir | Out-Null
    }
    AfterEach {
        if (Test-Path $script:TmpDir) { Remove-Item -Recurse -Force $script:TmpDir }
    }

    It 'New-ServerSyncLogger returns a logger object with path' {
        $logger = New-ServerSyncLogger -LogDirectory $script:TmpDir -Prefix 'sync'
        $logger.LogPath | Should -Not -BeNullOrEmpty
        $logger.LogPath | Should -Match 'sync-\d{4}-\d{2}-\d{2}'
    }

    It 'Write-ServerSyncLog appends a timestamped line' {
        $logger = New-ServerSyncLogger -LogDirectory $script:TmpDir -Prefix 'sync'
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message 'hello'
        $content = Get-Content -Raw $logger.LogPath
        $content | Should -Match 'INFO'
        $content | Should -Match 'hello'
        $content | Should -Match '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
    }

    It 'Write-ServerSyncLog supports multiple levels' {
        $logger = New-ServerSyncLogger -LogDirectory $script:TmpDir -Prefix 'sync'
        Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message 'bang'
        Write-ServerSyncLog -Logger $logger -Level 'WARN'  -Message 'hmm'
        $content = Get-Content -Raw $logger.LogPath
        $content | Should -Match 'ERROR.*bang'
        $content | Should -Match 'WARN.*hmm'
    }

    It 'Remove-OldLogFiles deletes files older than retention' {
        $old = New-Item -ItemType File -Path (Join-Path $script:TmpDir 'old.log')
        $old.LastWriteTime = (Get-Date).AddDays(-100)
        $new = New-Item -ItemType File -Path (Join-Path $script:TmpDir 'new.log')
        Remove-OldLogFiles -LogDirectory $script:TmpDir -RetentionDays 90
        Test-Path $old.FullName | Should -Be $false
        Test-Path $new.FullName | Should -Be $true
    }
}

Describe 'Logging - email' -Tag 'Unit' {
    It 'Send-ServerSyncEmail returns early when email.enabled is false' {
        $emailConfig = [PSCustomObject]@{ enabled=$false }
        # Should not throw and should not call Send-MailMessage
        { Send-ServerSyncEmail -Config $emailConfig -Subject 'x' -Body 'y' -Credential $null } |
            Should -Not -Throw
    }

    It 'Send-ServerSyncEmail returns early when send_on is "failure" and no failures' {
        $emailConfig = [PSCustomObject]@{ enabled=$true; send_on='failure' }
        { Send-ServerSyncEmail -Config $emailConfig -Subject 'x' -Body 'y' -Credential $null -HasFailures $false } |
            Should -Not -Throw
    }

    It 'Test-ShouldSendEmail matches send_on logic' {
        (Test-ShouldSendEmail -SendOn 'always'  -HasFailures $true)  | Should -Be $true
        (Test-ShouldSendEmail -SendOn 'always'  -HasFailures $false) | Should -Be $true
        (Test-ShouldSendEmail -SendOn 'failure' -HasFailures $true)  | Should -Be $true
        (Test-ShouldSendEmail -SendOn 'failure' -HasFailures $false) | Should -Be $false
        (Test-ShouldSendEmail -SendOn 'never'   -HasFailures $true)  | Should -Be $false
    }
}

Describe 'Logging - log injection defense' -Tag 'Unit' {
    BeforeEach {
        $script:TmpDir = Join-Path ([IO.Path]::GetTempPath()) ("logging-inject-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TmpDir | Out-Null
    }
    AfterEach {
        if (Test-Path $script:TmpDir) { Remove-Item -Recurse -Force $script:TmpDir }
    }

    It 'ConvertTo-LogSafeText escapes CR LF and NUL' {
        ConvertTo-LogSafeText -Text "hello`nworld"   | Should -Be 'hello\nworld'
        ConvertTo-LogSafeText -Text "hello`r`nworld" | Should -Be 'hello\r\nworld'
        ConvertTo-LogSafeText -Text "hello`0world"   | Should -Be 'hello\0world'
    }

    It 'ConvertTo-LogSafeText passes through normal text unchanged' {
        ConvertTo-LogSafeText -Text 'normal message' | Should -Be 'normal message'
        ConvertTo-LogSafeText -Text ''               | Should -Be ''
    }

    It 'Write-ServerSyncLog refuses to write a forged log line via injected newline' {
        $logger = New-ServerSyncLogger -LogDirectory $script:TmpDir -Prefix 'inject'
        # Attacker-controlled pair name that tries to inject a forged "All OK" line.
        $injected = "Pair1`r`n2026-04-22T02:00:00+00:00 [INFO] All pairs OK"
        Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message $injected

        $content = Get-Content -Raw $logger.LogPath
        # The escaped \r\n sequence should appear as literal text in the log.
        $content | Should -Match '\\r\\n'
        # The exact attack path - a fresh INFO line at the start of a line -
        # must not exist. With escaping in place, the whole injected payload
        # remains on the single ERROR line.
        $lines = Get-Content -Path $logger.LogPath
        ($lines | Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\S* \[INFO\] All pairs OK$' }).Count | Should -Be 0
        # And the file should contain only one logged line, not two.
        ($lines | Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}T' }).Count | Should -Be 1
    }
}

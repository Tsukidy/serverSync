BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'src' 'Modules' 'Retention.ps1'
    . $script:ModulePath
}

Describe 'Retention - files mode' -Tag 'Unit' {
    BeforeEach {
        $script:TmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("retention-test-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TmpRoot | Out-Null
    }

    AfterEach {
        if (Test-Path $script:TmpRoot) {
            Remove-Item -Recurse -Force $script:TmpRoot
        }
    }

    It 'keeps the N newest matching files in each immediate subfolder' {
        $sub = Join-Path $script:TmpRoot 'MachineA'
        New-Item -ItemType Directory -Path $sub | Out-Null
        1..5 | ForEach-Object {
            $f = New-Item -ItemType File -Path (Join-Path $sub "backup-$_.TIB")
            $f.LastWriteTime = (Get-Date).AddDays(-$_)
        }

        $policy = [PSCustomObject]@{ Mode='files'; Count=2; Extensions=@('.TIB') }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy

        $remaining = Get-ChildItem $sub -Filter '*.TIB' | Sort-Object LastWriteTime -Descending
        $remaining.Count | Should -Be 2
        $remaining.Name | Should -Be @('backup-1.TIB','backup-2.TIB')
    }

    It 'never touches files whose extension is not in the list' {
        $sub = Join-Path $script:TmpRoot 'MachineA'
        New-Item -ItemType Directory -Path $sub | Out-Null
        foreach ($ext in '.TIB','.log','.txt') {
            1..3 | ForEach-Object {
                $f = New-Item -ItemType File -Path (Join-Path $sub "file-$_$ext")
                $f.LastWriteTime = (Get-Date).AddDays(-$_)
            }
        }

        $policy = [PSCustomObject]@{ Mode='files'; Count=1; Extensions=@('.TIB') }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy

        (Get-ChildItem $sub -Filter '*.TIB').Count | Should -Be 1
        (Get-ChildItem $sub -Filter '*.log').Count | Should -Be 3
        (Get-ChildItem $sub -Filter '*.txt').Count | Should -Be 3
    }

    It 'applies retention independently in each subfolder' {
        foreach ($machine in 'MachineA','MachineB') {
            $sub = Join-Path $script:TmpRoot $machine
            New-Item -ItemType Directory -Path $sub | Out-Null
            1..4 | ForEach-Object {
                $f = New-Item -ItemType File -Path (Join-Path $sub "b-$_.TIB")
                $f.LastWriteTime = (Get-Date).AddDays(-$_)
            }
        }

        $policy = [PSCustomObject]@{ Mode='files'; Count=2; Extensions=@('.TIB') }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy

        (Get-ChildItem (Join-Path $script:TmpRoot 'MachineA') -Filter '*.TIB').Count | Should -Be 2
        (Get-ChildItem (Join-Path $script:TmpRoot 'MachineB') -Filter '*.TIB').Count | Should -Be 2
    }

    It 'tracks multiple extensions independently' {
        $sub = Join-Path $script:TmpRoot 'MachineA'
        New-Item -ItemType Directory -Path $sub | Out-Null
        foreach ($ext in '.vbk','.vbm') {
            1..4 | ForEach-Object {
                $f = New-Item -ItemType File -Path (Join-Path $sub "file-$_$ext")
                $f.LastWriteTime = (Get-Date).AddDays(-$_)
            }
        }

        $policy = [PSCustomObject]@{ Mode='files'; Count=2; Extensions=@('.vbk','.vbm') }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy

        (Get-ChildItem $sub -Filter '*.vbk').Count | Should -Be 2
        (Get-ChildItem $sub -Filter '*.vbm').Count | Should -Be 2
    }

    It 'matches extensions case-insensitively' {
        $sub = Join-Path $script:TmpRoot 'MachineA'
        New-Item -ItemType Directory -Path $sub | Out-Null
        foreach ($name in 'a.TIB','b.tib','c.Tib','d.TIB','e.TIB') {
            $f = New-Item -ItemType File -Path (Join-Path $sub $name)
            Start-Sleep -Milliseconds 5  # ensure distinct LastWriteTime
        }

        $policy = [PSCustomObject]@{ Mode='files'; Count=3; Extensions=@('.TIB') }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy

        (Get-ChildItem $sub).Count | Should -Be 3
    }
}

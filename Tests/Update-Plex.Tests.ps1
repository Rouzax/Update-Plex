<#
    Tests for the pure logic in Update-Plex.ps1: version parsing, the update
    decision (never a downgrade), the downloads URL and picking the installer
    from the plex.tv response. Dot-sourcing the script defines the functions
    without contacting Plex or plex.tv.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Update-Plex.ps1')

    # Shape of https://plex.tv/api/downloads/5.json (trimmed).
    $script:Response = [pscustomobject]@{
        computer = [pscustomobject]@{
            Windows = [pscustomobject]@{
                id           = 'windows'
                version      = '1.43.6.11212-fa660d0cd'
                release_date = 1795392000
                items_added  = "(Music) Read the record label from NFO files (PM-3800)`nUpdated Web to 4.162.1"
                items_fixed  = '(Transcoder) A crash with audio-only media (PM-6226)'
                releases     = @(
                    [pscustomobject]@{ build = 'windows-x86'; distro = 'windows'; url = 'https://downloads.plex.tv/x86.exe'; checksum = 'AAAA' }
                    [pscustomobject]@{ build = 'windows-x86_64'; distro = 'windows'; url = 'https://downloads.plex.tv/plex-media-server-new/1.43.6.11212-fa660d0cd/windows/PlexMediaServer-1.43.6.11212-fa660d0cd-x86_64.exe'; checksum = '302C7F700B5BC597F50D8FD7D967E25DD2628BB5' }
                )
            }
        }
    }
}

Describe 'ConvertTo-ComparableVersion' {

    It 'reads a plex.tv version with its build hash' {
        ConvertTo-ComparableVersion -Raw '1.43.6.11212-fa660d0cd' | Should -Be ([version]'1.43.6.11212')
    }

    It 'reads the four-part version the installed program reports' {
        ConvertTo-ComparableVersion -Raw '1.43.6.11100' | Should -Be ([version]'1.43.6.11100')
    }

    It 'pads short versions and ignores a v prefix' {
        ConvertTo-ComparableVersion -Raw 'v1.43' | Should -Be ([version]'1.43.0.0')
    }

    It 'returns nothing for text that is not a version' {
        ConvertTo-ComparableVersion -Raw 'unknown' | Should -BeNullOrEmpty
        ConvertTo-ComparableVersion -Raw '' | Should -BeNullOrEmpty
    }
}

Describe 'Compare-PlexVersion' {

    It 'sees a newer build of the same release' {
        Compare-PlexVersion -Installed '1.43.6.11100' -Latest '1.43.6.11212-fa660d0cd' | Should -Be 'Newer'
    }

    It 'treats the installed numbers and the plex.tv string as the same version' {
        Compare-PlexVersion -Installed '1.43.6.11212' -Latest '1.43.6.11212-fa660d0cd' | Should -Be 'Same'
    }

    It 'sees that the public channel can trail the installed beta' {
        Compare-PlexVersion -Installed '1.43.6.11100' -Latest '1.43.5.11079-b3b13e506' | Should -Be 'Older'
    }

    It 'compares numerically, not as text' {
        Compare-PlexVersion -Installed '1.9.0.0' -Latest '1.10.0.0' | Should -Be 'Newer'
    }

    It 'reports Unknown when a version cannot be read' {
        Compare-PlexVersion -Installed '' -Latest '1.43.6.11212' | Should -Be 'Unknown'
    }
}

Describe 'Get-UpdateDecision' {

    It 'installs a newer release' {
        (Get-UpdateDecision -Installed '1.43.6.11100' -Latest '1.43.6.11212-fa660d0cd').Action | Should -Be 'Install'
    }

    It 'skips the same version, and reinstalls it with -Force' {
        (Get-UpdateDecision -Installed '1.43.6.11212' -Latest '1.43.6.11212-fa660d0cd').Action | Should -Be 'Skip'
        (Get-UpdateDecision -Installed '1.43.6.11212' -Latest '1.43.6.11212-fa660d0cd' -ForceInstall).Action | Should -Be 'Install'
    }

    It 'never downgrades, not even with -Force' {
        $d = Get-UpdateDecision -Installed '1.43.6.11100' -Latest '1.43.5.11079-b3b13e506' -ForceInstall
        $d.Action | Should -Be 'Skip'
        $d.Reason | Should -Match 'never downgrading'
    }

    It 'never installs when the installed version cannot be read' {
        (Get-UpdateDecision -Installed '' -Latest '1.43.6.11212' -ForceInstall).Action | Should -Be 'Skip'
    }
}

Describe 'Get-DownloadsUri' {

    It 'asks for the Plex Pass channel only with a token' {
        Get-DownloadsUri -Channel Beta -HasToken $true | Should -Be 'https://plex.tv/api/downloads/5.json?channel=plexpass'
        Get-DownloadsUri -Channel Beta -HasToken $false | Should -Be 'https://plex.tv/api/downloads/5.json'
        Get-DownloadsUri -Channel Public -HasToken $true | Should -Be 'https://plex.tv/api/downloads/5.json'
    }

    It 'never puts the token in the URL' {
        Get-DownloadsUri -Channel Beta -HasToken $true | Should -Not -Match 'token'
    }
}

Describe 'Select-PlexRelease' {

    It 'picks the 64-bit Windows installer and its checksum' {
        $r = Select-PlexRelease -Response $script:Response
        $r.Version | Should -Be '1.43.6.11212-fa660d0cd'
        $r.Url | Should -Match 'x86_64\.exe$'
        $r.Sha1 | Should -Be '302c7f700b5bc597f50d8fd7d967e25dd2628bb5'
        $r.Released | Should -BeOfType [datetime]
    }

    It 'returns nothing when there is no 64-bit build' {
        $resp = [pscustomobject]@{ computer = [pscustomobject]@{ Windows = [pscustomobject]@{ version = '1.0'; releases = @([pscustomobject]@{ build = 'windows-x86'; url = 'u'; checksum = 'c' }) } } }
        Select-PlexRelease -Response $resp | Should -BeNullOrEmpty
    }

    It 'returns nothing for a response without Windows' {
        Select-PlexRelease -Response ([pscustomobject]@{ computer = [pscustomobject]@{ Linux = @{} } }) | Should -BeNullOrEmpty
    }

    It 'carries the release notes, one item per line' {
        $r = Select-PlexRelease -Response $script:Response
        $r.Added | Should -Be @('(Music) Read the record label from NFO files', 'Updated Web to 4.162.1')
        $r.Fixed | Should -Be @('(Transcoder) A crash with audio-only media')
    }

    It 'gives empty lists when the response has no release notes' {
        $resp = [pscustomobject]@{ computer = [pscustomobject]@{ Windows = [pscustomobject]@{ version = '1.0'; releases = @([pscustomobject]@{ build = 'windows-x86_64'; url = 'u'; checksum = 'c' }) } } }
        $r = Select-PlexRelease -Response $resp
        @($r.Added).Count | Should -Be 0
        @($r.Fixed).Count | Should -Be 0
    }
}

Describe 'ConvertTo-ReleaseNoteList' {

    It 'splits on line breaks, drops blank lines and the ticket number' {
        $list = ConvertTo-ReleaseNoteList -Text "(DVR) First fix (PM-5538)`r`n`n  Second item  `nThird (PM-12)"
        $list | Should -Be @('(DVR) First fix', 'Second item', 'Third')
    }

    It 'keeps a parenthesis that is not a ticket number' {
        ConvertTo-ReleaseNoteList -Text 'Faster scans (large libraries)' | Should -Be 'Faster scans (large libraries)'
    }

    It 'returns an empty list for empty text' {
        $list = ConvertTo-ReleaseNoteList -Text ''
        $list.Count | Should -Be 0
    }
}

Describe 'Format-ReleaseNote' {

    It 'lists added and fixed items under their headings' {
        $html = Format-ReleaseNote -Added @('New thing') -Fixed @('Old bug') -MaxLength 1000
        $html | Should -Be '<br><br><b>Added</b><br>&#8226; New thing<br><br><b>Fixed</b><br>&#8226; Old bug'
    }

    It 'leaves out an empty section' {
        Format-ReleaseNote -Fixed @('Old bug') -MaxLength 1000 | Should -Not -Match 'Added'
    }

    It 'escapes text so it cannot break the HTML' {
        Format-ReleaseNote -Added @('Use <b> & co') -MaxLength 1000 | Should -Match 'Use &lt;b&gt; &amp; co'
    }

    It 'stops at a whole item and counts the rest' {
        $items = 1..40 | ForEach-Object { "Release note number $_ with some words in it" }
        $html = Format-ReleaseNote -Added $items -MaxLength 400
        $html.Length | Should -BeLessOrEqual 400
        $html | Should -Match '&#8230; and (\d+) more in the release notes$'
        $shown = ([regex]::Matches($html, '&#8226;')).Count
        [int]($html -replace '.*and (\d+) more.*', '$1') | Should -Be (40 - $shown)
    }

    It 'returns nothing when there are no notes or no room' {
        Format-ReleaseNote -MaxLength 1000 | Should -Be ''
        Format-ReleaseNote -Added @('Something long enough not to fit') -MaxLength 10 | Should -Be ''
    }
}

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$lockPath = Join-Path $repositoryRoot 'eng\portable-ssh-config-source-lock.json'
$attributesPath = Join-Path $repositoryRoot '.gitattributes'

function Assert-Equal {
    param(
        $Actual,
        $Expected,
        [string] $Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-SetEqual {
    param(
        [string[]] $Actual,
        [string[]] $Expected,
        [string] $Message
    )

    $difference = @(Compare-Object -ReferenceObject @($Expected | Sort-Object) `
        -DifferenceObject @($Actual | Sort-Object))
    if ($difference.Count -ne 0) {
        throw "$Message Actual: $($Actual -join ', '); expected: $($Expected -join ', ')."
    }
}

if (-not (Test-Path $lockPath -PathType Leaf)) {
    throw "Source lock '$lockPath' is missing."
}

$lock = Get-Content $lockPath -Raw | ConvertFrom-Json
Assert-SetEqual @($lock.PSObject.Properties.Name) `
    @('schemaVersion', 'source', 'change', 'outputs') `
    'The source lock has unexpected top-level fields.'
Assert-Equal $lock.schemaVersion 1 'Unexpected source-lock schema.'
Assert-Equal $lock.source.repository 'PowerShell/openssh-portable' `
    'Unexpected source repository.'
Assert-Equal $lock.source.revision 'b8c08ef9da9450a94a9c5ef717d96a7bd83f3332' `
    'Unexpected source revision.'
Assert-Equal $lock.source.tree '34944561ca69ce2d2356ea04b14a1d150f9c668a' `
    'Unexpected source tree.'
Assert-Equal $lock.source.tag 'v10.0.0.0' 'Unexpected source tag.'
Assert-Equal $lock.change.scope 'ssh-client-only' 'Unexpected patch scope.'
Assert-Equal $lock.change.portableGlobalConfig '../../etc/ssh/ssh_config' `
    'Unexpected portable configuration path.'
Assert-Equal $lock.outputs.workflowIncluded $false `
    'A workflow must not be included in the source-only candidate.'
Assert-Equal $lock.outputs.artifactsProduced $false `
    'The source-only candidate must not claim artifacts.'

$expectedSourceFiles = [ordered]@{
    'ssh.c' = 'ea94d25106cf600e6ec1c39974ecc9047471244b'
    'contrib/win32/openssh/OpenSSH-build.ps1' = '22c6794a84deccefb39fb18ce042743556f6c9ad'
    'contrib/win32/openssh/OpenSSHBuildHelper.psm1' = '61a7c4502e135ef56e4de68c1280b3dfc83ead52'
    'contrib/win32/openssh/ssh.vcxproj' = '82c9c12d3600d7f435241b6c1e6214bcf072bd6f'
}
Assert-SetEqual @($lock.source.files.PSObject.Properties.Name) `
    @($expectedSourceFiles.Keys) 'Unexpected source file set.'
foreach ($entry in $expectedSourceFiles.GetEnumerator()) {
    Assert-Equal $lock.source.files.PSObject.Properties[$entry.Key].Value `
        $entry.Value "Unexpected blob for '$($entry.Key)'."
}

$patchPath = Join-Path $repositoryRoot $lock.change.patch.Replace('/', '\')
if (-not (Test-Path $patchPath -PathType Leaf)) {
    throw "Patch '$patchPath' is missing."
}

$patchBytes = [IO.File]::ReadAllBytes($patchPath)
if ($patchBytes.Length -eq 0 -or $patchBytes[-1] -ne 10) {
    throw 'The patch must end with an LF newline.'
}
if ($patchBytes -contains 13) {
    throw 'The patch must use LF line endings only.'
}

$patchHash = (Get-FileHash $patchPath -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-Equal $patchHash $lock.change.sha256 'The patch digest does not match the lock.'

$patchText = [Text.Encoding]::UTF8.GetString($patchBytes)
$targetMatches = [regex]::Matches(
    $patchText,
    '(?m)^diff --git a/(?<old>.+) b/(?<new>.+)$'
)
$targets = @()
foreach ($match in $targetMatches) {
    Assert-Equal $match.Groups['old'].Value $match.Groups['new'].Value `
        'A patch target changes path.'
    $targets += $match.Groups['old'].Value
}
Assert-SetEqual $targets @($expectedSourceFiles.Keys) 'Unexpected patch target set.'

$numstat = @(& git -C $repositoryRoot apply --numstat -- $patchPath 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Git rejected the unified diff: $($numstat -join [Environment]::NewLine)"
}
$numstatTargets = @($numstat | ForEach-Object {
    $parts = $_ -split "`t"
    if ($parts.Count -ne 3) {
        throw "Unexpected git apply --numstat output: '$_'."
    }
    $parts[2]
})
Assert-SetEqual $numstatTargets @($expectedSourceFiles.Keys) `
    'Git parsed an unexpected patch target set.'

$requiredPatchFragments = @(
    '#include "misc_internal.h"',
    'systemwide_config_file(void)',
    'is_absolute_path(SSH_PORTABLE_GLOBAL_CONFIG)',
    'realpath(joined, resolved)',
    'return _PATH_HOST_CONFIG_FILE;',
    'read_config_file(systemwide_config_file(), pw,',
    'SSHCONF_CHECKPERM',
    '[string]$PortableGlobalConfig = ""',
    '$cmdMsg += "/p:PortableGlobalConfig=$PortableGlobalConfig"',
    '<ItemDefinitionGroup Condition="''$(PortableGlobalConfig)'' != ''''">',
    'SSH_PORTABLE_GLOBAL_CONFIG=&quot;$(PortableGlobalConfig)&quot;'
)
foreach ($fragment in $requiredPatchFragments) {
    if (-not $patchText.Contains($fragment)) {
        throw "Patch contract fragment is missing: $fragment"
    }
}

$addedLines = @($patchText.Replace("`r", '').Split("`n") | Where-Object {
    $_.StartsWith('+') -and -not $_.StartsWith('+++')
}) -join "`n"
foreach ($forbiddenAddition in @(
    'actions/',
    'uses:',
    'upload-artifact',
    'download-artifact',
    'builtin-baseline',
    'vcpkg.json',
    'Start-OpenSSHPackage',
    'Compress-Archive'
)) {
    if ($addedLines.Contains($forbiddenAddition)) {
        throw "The source-only patch adds forbidden producer logic: $forbiddenAddition"
    }
}

$workflowDirectory = Join-Path $repositoryRoot '.github\workflows'
if (Test-Path $workflowDirectory) {
    throw 'The source-only candidate must not contain a workflow directory.'
}

$attributes = Get-Content $attributesPath -Raw
if ($attributes.Trim() -ne '*.patch text eol=lf -whitespace') {
    throw 'The patch line-ending policy is missing or ambiguous.'
}

Write-Host "Validated source-only portable config candidate: $($targets.Count) pinned source files, no workflow, no artifacts."

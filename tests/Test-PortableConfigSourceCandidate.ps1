[CmdletBinding(PositionalBinding = $false)]
param(
    [string] $SourceRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$lockRelativePath = 'eng/portable-ssh-config-source-lock.json'
$lockPath = Join-Path $repositoryRoot $lockRelativePath.Replace('/', '\')
$attributesPath = Join-Path $repositoryRoot '.gitattributes'
$readmePath = Join-Path $repositoryRoot 'README.md'
$gitPath = (Get-Command git -ErrorAction Stop).Source

function Assert-Equal {
    param(
        $Actual,
        $Expected,
        [string] $Message
    )

    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param(
        [bool] $Condition,
        [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-SetEqual {
    param(
        [string[]] $Actual,
        [string[]] $Expected,
        [string] $Message
    )

    if (@($Actual).Count -ne @($Expected).Count) {
        throw "$Message Actual: $($Actual -join ', '); expected: $($Expected -join ', ')."
    }
    $difference = @(Compare-Object -CaseSensitive `
        -ReferenceObject @($Expected | Sort-Object) `
        -DifferenceObject @($Actual | Sort-Object))
    if ($difference.Count -ne 0) {
        throw "$Message Actual: $($Actual -join ', '); expected: $($Expected -join ', ')."
    }
}

function Assert-Contains {
    param(
        [string] $Text,
        [string] $Fragment,
        [string] $Message
    )

    if (-not $Text.Contains($Fragment)) {
        throw "$Message Missing '$Fragment'."
    }
}

function Invoke-Git {
    param(
        [string] $Root,
        [string[]] $Arguments
    )

    $output = @(& $gitPath -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed:`n$($output -join [Environment]::NewLine)"
    }
    return $output
}

function Get-GitSingleLine {
    param(
        [string] $Root,
        [string[]] $Arguments
    )

    $output = @(Invoke-Git -Root $Root -Arguments $Arguments)
    if ($output.Count -ne 1) {
        throw "Expected one line from git $($Arguments -join ' '), got $($output.Count)."
    }
    return ([string]$output[0]).Trim()
}

function Get-GitBlobSha256 {
    param(
        [string] $Root,
        [string] $ObjectId
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $gitPath
    $startInfo.Arguments = "-C `"$Root`" cat-file blob $ObjectId"
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $null = $process.Start()
    $content = New-Object System.IO.MemoryStream
    try {
        $process.StandardOutput.BaseStream.CopyTo($content)
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "git cat-file failed for '$ObjectId': $errorText"
        }

        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            return (($sha256.ComputeHash($content.ToArray()) | ForEach-Object {
                $_.ToString('x2')
            }) -join '')
        }
        finally {
            $sha256.Dispose()
        }
    }
    finally {
        $content.Dispose()
        $process.Dispose()
    }
}

function Get-CanonicalWorktreeIdentity {
    param(
        [string] $Root,
        [string] $RelativePath
    )

    $fullPath = Join-Path $Root $RelativePath.Replace('/', '\')
    if (-not (Test-Path $fullPath -PathType Leaf)) {
        throw "Source file '$RelativePath' is missing."
    }
    $blob = Get-GitSingleLine -Root $Root -Arguments @(
        'hash-object',
        '-w',
        '--filters',
        "--path=$RelativePath",
        $fullPath
    )
    return [pscustomobject]@{
        gitBlob = $blob
        sha256 = Get-GitBlobSha256 -Root $Root -ObjectId $blob
    }
}

function Assert-Image {
    param(
        [string] $Root,
        $Files,
        [ValidateSet('preimage', 'postimage')]
        [string] $Image,
        [switch] $VerifyHead
    )

    foreach ($file in $Files.PSObject.Properties) {
        $relativePath = $file.Name
        $expected = $file.Value.PSObject.Properties[$Image].Value
        if ($VerifyHead) {
            $headBlob = Get-GitSingleLine -Root $Root -Arguments @(
                'rev-parse',
                "HEAD:$relativePath"
            )
            Assert-Equal $headBlob $expected.gitBlob `
                "Unexpected HEAD blob for '$relativePath'."
            Assert-Equal (Get-GitBlobSha256 -Root $Root -ObjectId $headBlob) `
                $expected.sha256 "Unexpected HEAD SHA-256 for '$relativePath'."
        }

        $actual = Get-CanonicalWorktreeIdentity -Root $Root `
            -RelativePath $relativePath
        Assert-Equal $actual.gitBlob $expected.gitBlob `
            "Unexpected worktree blob for '$relativePath'."
        Assert-Equal $actual.sha256 $expected.sha256 `
            "Unexpected worktree SHA-256 for '$relativePath'."
    }
}

function Assert-PatchLockPair {
    param(
        [string[]] $ChangedPaths,
        [string] $Context,
        [string] $PatchRelativePath
    )

    $patchChanged = @($ChangedPaths | Where-Object {
        $_ -ceq $PatchRelativePath
    }).Count -eq 1
    $lockChanged = @($ChangedPaths | Where-Object {
        $_ -ceq $lockRelativePath
    }).Count -eq 1
    if ($patchChanged -xor $lockChanged) {
        throw "$Context must change the patch and source lock together."
    }
}

function Resolve-PropertyScenario {
    param(
        [AllowNull()]
        [string] $EnvironmentValue,
        [AllowNull()]
        [string] $PropertySheetValue,
        [bool] $GlobalIsSet,
        [AllowNull()]
        [string] $GlobalValue
    )

    $value = $EnvironmentValue
    if ($null -ne $PropertySheetValue) {
        $value = $PropertySheetValue
    }

    # The unconditional project assignment overrides imported values. MSBuild
    # preserves an explicit global /p property instead of this local value.
    if ($GlobalIsSet) {
        $value = $GlobalValue
    }
    else {
        $value = 'false'
    }

    return [pscustomobject]@{
        value = $value
        valid = ($value -ceq 'true' -or $value -ceq 'false')
        enabled = ($value -ceq 'true')
    }
}

function Assert-PropertyScenario {
    param(
        [string] $Name,
        [AllowNull()]
        [string] $EnvironmentValue,
        [AllowNull()]
        [string] $PropertySheetValue,
        [bool] $GlobalIsSet,
        [AllowNull()]
        [string] $GlobalValue,
        [string] $ExpectedValue,
        [bool] $ExpectedValid,
        [bool] $ExpectedEnabled
    )

    $result = Resolve-PropertyScenario -EnvironmentValue $EnvironmentValue `
        -PropertySheetValue $PropertySheetValue -GlobalIsSet $GlobalIsSet `
        -GlobalValue $GlobalValue
    Assert-Equal $result.value $ExpectedValue "$Name resolved an unexpected value."
    Assert-Equal $result.valid $ExpectedValid "$Name validity is incorrect."
    Assert-Equal $result.enabled $ExpectedEnabled "$Name enablement is incorrect."
}

function Assert-AppliedSemantics {
    param(
        [string] $Root,
        $Files
    )

    $sshPath = Join-Path $Root 'ssh.c'
    $wrapperPath = Join-Path $Root 'contrib\win32\openssh\OpenSSH-build.ps1'
    $helperPath = Join-Path $Root 'contrib\win32\openssh\OpenSSHBuildHelper.psm1'
    $projectPath = Join-Path $Root 'contrib\win32\openssh\ssh.vcxproj'
    $solutionPath = Join-Path $Root 'contrib\win32\openssh\Win32-OpenSSH.sln'

    $ssh = Get-Content $sshPath -Raw
    $wrapper = Get-Content $wrapperPath -Raw
    $helper = Get-Content $helperPath -Raw
    $solution = Get-Content $solutionPath -Raw

    foreach ($fragment in @(
        ('#define PORTABLE_EXECUTABLE_DIRECTORY_SUFFIX' + "`t" + '"/usr/bin"'),
        ('#define PORTABLE_SYSTEM_CONFIG_SUFFIX' + "`t`t" + '"/etc/ssh/ssh_config"'),
        'if (realpath(__progdir, executable_dir) == NULL)',
        'executable_dir_len <= suffix_len',
        'executable_dir[executable_dir_len - suffix_len] = ''\0'';',
        'r < 0 || (size_t)r >= sizeof(config_path)',
        'return _PATH_HOST_CONFIG_FILE;',
        'read_config_file(systemwide_config_file(), pw,',
        'SSHCONF_CHECKPERM'
    )) {
        Assert-Contains $ssh $fragment 'The applied C contract is incomplete.'
    }
    Assert-True (-not $ssh.Contains('../../')) `
        'The applied C source contains traversal tokens.'

    $portableBlock = [regex]::Match(
        $ssh,
        '(?s)#ifdef SSH_PORTABLE_GLOBAL_CONFIG(?<enabled>.*?)#else\s+return _PATH_HOST_CONFIG_FILE;\s+#endif'
    )
    Assert-True $portableBlock.Success `
        'The explicit portable-only C block is missing.'
    Assert-True ($portableBlock.Groups['enabled'].Value.Contains('fatal(')) `
        'Portable error handling is not in the explicit opt-in block.'
    $functionBlock = [regex]::Match(
        $ssh,
        '(?s)systemwide_config_file\(void\)\s*\{(?<body>.*?)\}\s*#endif'
    )
    Assert-True $functionBlock.Success 'The system config function is missing.'
    Assert-Equal ([regex]::Matches(
        $functionBlock.Groups['body'].Value,
        '\bfatal\('
    ).Count) ([regex]::Matches(
        $portableBlock.Groups['enabled'].Value,
        '\bfatal\('
    ).Count) 'Fatal handling escaped the explicit portable block.'

    foreach ($scriptPath in @($wrapperPath, $helperPath)) {
        $tokens = $null
        $parseErrors = $null
        [Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null
        if ($parseErrors.Count -ne 0) {
            throw "PowerShell parser rejected '$scriptPath': $($parseErrors.Message -join '; ')"
        }
    }

    foreach ($fragment in @(
        '[CmdletBinding(PositionalBinding = $false)]',
        '[switch]$UsePortableGlobalConfig',
        '$portableGlobalConfig = $UsePortableGlobalConfig.IsPresent',
        '-UsePortableGlobalConfig:$portableGlobalConfig'
    )) {
        Assert-Contains $wrapper $fragment 'The build wrapper Boolean contract is incomplete.'
    }
    $buildHeader = [regex]::Match(
        $helper,
        '(?s)function Start-OpenSSHBuild\s*\{\s*(?<header>\[CmdletBinding\(SupportsShouldProcess=\$false, PositionalBinding=\$false\)\]\s*param\s*\(.*?\))\s*\$script:BuildLogFile'
    )
    Assert-True $buildHeader.Success `
        'Non-positional binding is not attached to Start-OpenSSHBuild.'
    Assert-Contains $buildHeader.Groups['header'].Value `
        '[switch]$UsePortableGlobalConfig' `
        'The Boolean switch is not a Start-OpenSSHBuild parameter.'
    foreach ($fragment in @(
        '$portableGlobalConfig = $UsePortableGlobalConfig.IsPresent.ToString().ToLowerInvariant()',
        '"/p:UsePortableGlobalConfig=${portableGlobalConfig}"'
    )) {
        Assert-Contains $helper $fragment 'The build helper Boolean contract is incomplete.'
    }
    Assert-True (-not [regex]::IsMatch(
        $wrapper + $helper,
        '(?m)\[string\]\s*\$UsePortableGlobalConfig'
    )) 'The Boolean opt-in is exposed as a string.'
    Assert-Equal ("/p:UsePortableGlobalConfig=$($false.ToString().ToLowerInvariant())") `
        '/p:UsePortableGlobalConfig=false' 'The wrapper default command line is not explicit false.'
    Assert-Equal ("/p:UsePortableGlobalConfig=$($true.ToString().ToLowerInvariant())") `
        '/p:UsePortableGlobalConfig=true' 'The wrapper opt-in command line is not explicit true.'

    $project = New-Object xml
    $project.PreserveWhitespace = $true
    $project.Load($projectPath)
    $namespace = New-Object System.Xml.XmlNamespaceManager($project.NameTable)
    $namespace.AddNamespace('m', $project.DocumentElement.NamespaceURI)

    $propertyNodes = @($project.SelectNodes(
        '//m:UsePortableGlobalConfig',
        $namespace
    ))
    Assert-Equal $propertyNodes.Count 1 `
        'The project must define exactly one local Boolean default.'
    Assert-Equal $propertyNodes[0].InnerText 'false' `
        'The project local default must be false.'
    Assert-Equal $propertyNodes[0].ParentNode.GetAttribute('Condition') '' `
        'The local false default must override ambient and imported values.'
    $propertySheetGroups = @($project.SelectNodes(
        '//m:ImportGroup[@Label="PropertySheets"]',
        $namespace
    ))
    $precedingPropertySheetGroups = @($propertyNodes[0].SelectNodes(
        'preceding::m:ImportGroup[@Label="PropertySheets"]',
        $namespace
    ))
    Assert-True ($propertySheetGroups.Count -gt 0) `
        'The project has no imported property sheets to test.'
    Assert-Equal $precedingPropertySheetGroups.Count $propertySheetGroups.Count `
        'The local false default must follow every imported property sheet.'

    $macroNodes = @($project.SelectNodes(
        '//m:PreprocessorDefinitions[contains(text(), "SSH_PORTABLE_GLOBAL_CONFIG")]',
        $namespace
    ))
    Assert-Equal $macroNodes.Count 1 `
        'The portable macro must be defined exactly once and only for ssh.exe.'
    Assert-Equal $macroNodes[0].InnerText `
        'SSH_PORTABLE_GLOBAL_CONFIG=1;%(PreprocessorDefinitions)' `
        'The portable macro must be a Boolean flag, not a path.'
    $enableCondition = $macroNodes[0].ParentNode.ParentNode.GetAttribute('Condition')
    Assert-Equal $enableCondition `
        '$([System.String]::CompareOrdinal(''$(UsePortableGlobalConfig)'', ''true'')) == 0' `
        'The macro must require exact lowercase true.'

    $validationTarget = $project.SelectSingleNode(
        '//m:Target[@Name="ValidateUsePortableGlobalConfig"]',
        $namespace
    )
    Assert-True ($null -ne $validationTarget) `
        'The project Boolean validation target is missing.'
    Assert-Equal $validationTarget.GetAttribute('BeforeTargets') 'PrepareForBuild' `
        'Boolean validation must run before build preparation.'
    Assert-Equal $validationTarget.GetAttribute('Condition') `
        '$([System.String]::CompareOrdinal(''$(UsePortableGlobalConfig)'', ''true'')) != 0 and $([System.String]::CompareOrdinal(''$(UsePortableGlobalConfig)'', ''false'')) != 0' `
        'The project must reject every non-exact Boolean value.'
    Assert-Equal $validationTarget.SelectSingleNode('m:Error', $namespace).GetAttribute('Text') `
        'UsePortableGlobalConfig must be exactly ''true'' or ''false''.' `
        'The direct-build validation error is ambiguous.'
    Assert-Contains $solution '"ssh", "ssh.vcxproj"' `
        'The direct solution-build test cannot locate the ssh project.'

    Assert-PropertyScenario -Name 'default direct solution build' `
        -GlobalIsSet $false -ExpectedValue 'false' `
        -ExpectedValid $true -ExpectedEnabled $false
    Assert-PropertyScenario -Name 'ambient environment true' `
        -EnvironmentValue 'true' -GlobalIsSet $false -ExpectedValue 'false' `
        -ExpectedValid $true -ExpectedEnabled $false
    Assert-PropertyScenario -Name 'imported props true' `
        -PropertySheetValue 'true' -GlobalIsSet $false -ExpectedValue 'false' `
        -ExpectedValid $true -ExpectedEnabled $false
    Assert-PropertyScenario -Name 'ambient invalid value' `
        -EnvironmentValue 'enabled' -GlobalIsSet $false -ExpectedValue 'false' `
        -ExpectedValid $true -ExpectedEnabled $false
    Assert-PropertyScenario -Name 'direct global false' `
        -GlobalIsSet $true -GlobalValue 'false' -ExpectedValue 'false' `
        -ExpectedValid $true -ExpectedEnabled $false
    Assert-PropertyScenario -Name 'direct global true' `
        -GlobalIsSet $true -GlobalValue 'true' -ExpectedValue 'true' `
        -ExpectedValid $true -ExpectedEnabled $true
    foreach ($invalidValue in @('', 'True', 'TRUE', 'False', '1', 'yes', 'enabled')) {
        Assert-PropertyScenario -Name "invalid direct global '$invalidValue'" `
            -GlobalIsSet $true -GlobalValue $invalidValue `
            -ExpectedValue $invalidValue -ExpectedValid $false `
            -ExpectedEnabled $false
    }

    $sourceDiff = @(Invoke-Git -Root $Root -Arguments @(
        'diff',
        '--unified=0',
        '--',
        $Files.PSObject.Properties.Name
    )) -join "`n"
    $addedSource = @($sourceDiff.Split("`n") | Where-Object {
        $_.StartsWith('+') -and -not $_.StartsWith('+++')
    }) -join "`n"
    Assert-True (-not [regex]::IsMatch($addedSource, '\.\.[\\/]')) `
        'The applied source adds path traversal.'
}

if (-not (Test-Path $lockPath -PathType Leaf)) {
    throw "Source lock '$lockPath' is missing."
}

$lock = Get-Content $lockPath -Raw | ConvertFrom-Json
Assert-SetEqual @($lock.PSObject.Properties.Name) `
    @('schemaVersion', 'source', 'change', 'outputs') `
    'The source lock has unexpected top-level fields.'
Assert-Equal $lock.schemaVersion 2 'Unexpected source-lock schema.'
Assert-Equal $lock.source.repository 'PowerShell/openssh-portable' `
    'Unexpected source repository.'
Assert-Equal $lock.source.revision 'b8c08ef9da9450a94a9c5ef717d96a7bd83f3332' `
    'Unexpected source revision.'
Assert-Equal $lock.source.tree '34944561ca69ce2d2356ea04b14a1d150f9c668a' `
    'Unexpected source tree.'
Assert-Equal $lock.source.tag 'v10.0.0.0' 'Unexpected source tag.'
Assert-Equal $lock.change.scope 'ssh-client-only' 'Unexpected patch scope.'
Assert-Equal $lock.change.optInProperty 'UsePortableGlobalConfig' `
    'Unexpected opt-in property.'
Assert-Equal ($lock.change.allowedValues -join ',') 'false,true' `
    'The opt-in must allow only exact lowercase false and true.'
Assert-Equal $lock.change.expectedExecutableDirectory 'usr/bin' `
    'Unexpected portable executable directory.'
Assert-Equal $lock.change.bundleRelativeConfig 'etc/ssh/ssh_config' `
    'Unexpected bundle-relative configuration path.'
Assert-Equal $lock.outputs.workflowIncluded $false `
    'A workflow must not be included in the source-only candidate.'
Assert-Equal $lock.outputs.artifactsProduced $false `
    'The source-only candidate must not claim artifacts.'

$expectedPaths = @(
    'ssh.c',
    'contrib/win32/openssh/OpenSSH-build.ps1',
    'contrib/win32/openssh/OpenSSHBuildHelper.psm1',
    'contrib/win32/openssh/ssh.vcxproj'
)
Assert-SetEqual @($lock.change.files.PSObject.Properties.Name) $expectedPaths `
    'Unexpected source image set.'
foreach ($file in $lock.change.files.PSObject.Properties) {
    foreach ($image in @('preimage', 'postimage')) {
        $identity = $file.Value.PSObject.Properties[$image].Value
        Assert-True ($identity.gitBlob -cmatch '^[0-9a-f]{40}$') `
            "Invalid $image Git blob for '$($file.Name)'."
        Assert-True ($identity.sha256 -cmatch '^[0-9a-f]{64}$') `
            "Invalid $image SHA-256 for '$($file.Name)'."
    }
    Assert-True (
        $file.Value.preimage.gitBlob -cne $file.Value.postimage.gitBlob
    ) "The patch does not change '$($file.Name)'."
}

$patchRelativePath = $lock.change.patch
$patchPath = Join-Path $repositoryRoot $patchRelativePath.Replace('/', '\')
if (-not (Test-Path $patchPath -PathType Leaf)) {
    throw "Patch '$patchPath' is missing."
}

$patchBytes = [IO.File]::ReadAllBytes($patchPath)
Assert-True ($patchBytes.Length -gt 0 -and $patchBytes[-1] -eq 10) `
    'The patch must end with an LF newline.'
Assert-True (-not ($patchBytes -contains 13)) `
    'The patch must use LF line endings only.'
$patchHash = (Get-FileHash $patchPath -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-Equal $patchHash $lock.change.sha256 `
    'The patch digest does not match the lock.'

$patchText = [Text.Encoding]::UTF8.GetString($patchBytes)
foreach ($record in @(
    '(?m)^GIT binary patch$',
    '(?m)^Binary files ',
    '(?m)^(old|new) mode ',
    '(?m)^(new file|deleted file) mode ',
    '(?m)^(dis)?similarity index ',
    '(?m)^(rename|copy) (from|to) ',
    '(?m)^diff --(cc|combined) '
)) {
    Assert-True (-not [regex]::IsMatch($patchText, $record)) `
        "The patch contains a forbidden binary, mode, rename, or copy record: $record"
}

$targetMatches = [regex]::Matches(
    $patchText,
    '(?m)^diff --git a/(?<old>.+) b/(?<new>.+)$'
)
Assert-Equal $targetMatches.Count $expectedPaths.Count `
    'The patch has an unexpected target count.'
$targets = @()
for ($index = 0; $index -lt $targetMatches.Count; $index++) {
    $targetMatch = $targetMatches[$index]
    $oldPath = $targetMatch.Groups['old'].Value
    $newPath = $targetMatch.Groups['new'].Value
    Assert-Equal $oldPath $newPath 'A patch target changes path.'
    $targets += $oldPath

    $sectionEnd = if ($index + 1 -lt $targetMatches.Count) {
        $targetMatches[$index + 1].Index
    }
    else {
        $patchText.Length
    }
    $section = $patchText.Substring(
        $targetMatch.Index,
        $sectionEnd - $targetMatch.Index
    )
    $indexRecord = [regex]::Match(
        $section,
        '(?m)^index (?<pre>[0-9a-f]{40})\.\.(?<post>[0-9a-f]{40}) 100644$'
    )
    Assert-True $indexRecord.Success `
        "The patch lacks a full regular-file index record for '$oldPath'."
    $lockedFile = $lock.change.files.PSObject.Properties[$oldPath].Value
    Assert-Equal $indexRecord.Groups['pre'].Value `
        $lockedFile.preimage.gitBlob "Patch preimage mismatch for '$oldPath'."
    Assert-Equal $indexRecord.Groups['post'].Value `
        $lockedFile.postimage.gitBlob "Patch postimage mismatch for '$oldPath'."

    $meaningfulAddedLines = @($section.Split("`n") | Where-Object {
        $_.StartsWith('+') -and
        -not $_.StartsWith('+++') -and
        $_.Substring(1).Trim().Length -gt 0 -and
        $_.Substring(1).Trim() -notmatch '^(/\*|\*|//|<!--|-->)'
    })
    Assert-True ($meaningfulAddedLines.Count -gt 0) `
        "Patch changes to '$oldPath' are comments or whitespace only."
}
Assert-SetEqual $targets $expectedPaths 'Unexpected patch target set.'

$numstat = @(Invoke-Git -Root $repositoryRoot -Arguments @(
    'apply',
    '--numstat',
    '--',
    $patchPath
))
$numstatTargets = @($numstat | ForEach-Object {
    $parts = $_ -split "`t"
    if ($parts.Count -ne 3) {
        throw "Unexpected git apply --numstat output: '$_'."
    }
    $parts[2]
})
Assert-SetEqual $numstatTargets $expectedPaths `
    'Git parsed an unexpected patch target set.'
$summary = @(Invoke-Git -Root $repositoryRoot -Arguments @(
    'apply',
    '--summary',
    '--',
    $patchPath
))
Assert-Equal $summary.Count 0 `
    'The patch contains file creation, deletion, mode, rename, or copy metadata.'

$workingPair = @(Invoke-Git -Root $repositoryRoot -Arguments @(
    'diff',
    '--name-only',
    'HEAD',
    '--',
    $patchRelativePath,
    $lockRelativePath
))
Assert-PatchLockPair -ChangedPaths $workingPair -Context 'Working changes' `
    -PatchRelativePath $patchRelativePath
$headPair = @(Invoke-Git -Root $repositoryRoot -Arguments @(
    'diff-tree',
    '--no-commit-id',
    '--name-only',
    '-r',
    'HEAD',
    '--',
    $patchRelativePath,
    $lockRelativePath
))
Assert-PatchLockPair -ChangedPaths $headPair -Context 'HEAD commit' `
    -PatchRelativePath $patchRelativePath

$attributes = Get-Content $attributesPath -Raw
Assert-Equal $attributes.Trim() '*.patch text eol=lf -whitespace' `
    'The patch line-ending policy is missing or ambiguous.'
Assert-True (-not (Test-Path (Join-Path $repositoryRoot '.github\workflows'))) `
    'The source-only candidate must not contain a workflow directory.'

$readme = Get-Content $readmePath -Raw
foreach ($fragment in @(
    'writable, reparseable, or otherwise untrusted bundle root',
    'configuration file ACL check does not establish bundle',
    '`sftp` can inherit this behavior when they launch `ssh.exe`'
)) {
    Assert-Contains $readme $fragment 'The portable trust boundary is incomplete.'
}

if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    Write-Host 'Validated offline source policy; exact application requires -SourceRoot.'
    return
}

$resolvedSourceRoot = (Resolve-Path $SourceRoot).Path
$sourceTopLevel = Get-GitSingleLine -Root $resolvedSourceRoot `
    -Arguments @('rev-parse', '--show-toplevel')
Assert-Equal ([IO.Path]::GetFullPath($sourceTopLevel).TrimEnd('\')) `
    ([IO.Path]::GetFullPath($resolvedSourceRoot).TrimEnd('\')) `
    'The supplied source root is not its Git worktree root.'
Assert-Equal (Get-GitSingleLine -Root $resolvedSourceRoot `
    -Arguments @('rev-parse', 'HEAD')) $lock.source.revision `
    'The supplied source revision is not locked.'
Assert-Equal (Get-GitSingleLine -Root $resolvedSourceRoot `
    -Arguments @('rev-parse', 'HEAD^{tree}')) $lock.source.tree `
    'The supplied source tree is not locked.'
$initialStatus = @(Invoke-Git -Root $resolvedSourceRoot `
    -Arguments @('status', '--porcelain'))
Assert-Equal $initialStatus.Count 0 'The supplied source root is not clean.'
Assert-Image -Root $resolvedSourceRoot -Files $lock.change.files `
    -Image preimage -VerifyHead

$applied = $false
try {
    $null = Invoke-Git -Root $resolvedSourceRoot -Arguments @(
        'apply',
        '--check',
        '--whitespace=nowarn',
        '--',
        $patchPath
    )
    $null = Invoke-Git -Root $resolvedSourceRoot -Arguments @(
        'apply',
        '--whitespace=nowarn',
        '--',
        $patchPath
    )
    $applied = $true

    $changedPaths = @(Invoke-Git -Root $resolvedSourceRoot -Arguments @(
        'diff',
        '--name-only'
    ))
    Assert-SetEqual $changedPaths $expectedPaths `
        'Applying the patch changed an unexpected file set.'
    $appliedSummary = @(Invoke-Git -Root $resolvedSourceRoot -Arguments @(
        'diff',
        '--summary'
    ))
    Assert-Equal $appliedSummary.Count 0 `
        'Applying the patch changed modes or paths.'
    Assert-Image -Root $resolvedSourceRoot -Files $lock.change.files `
        -Image postimage
    Assert-AppliedSemantics -Root $resolvedSourceRoot -Files $lock.change.files

    $null = Invoke-Git -Root $resolvedSourceRoot -Arguments @(
        'apply',
        '--reverse',
        '--check',
        '--whitespace=nowarn',
        '--',
        $patchPath
    )
    $null = Invoke-Git -Root $resolvedSourceRoot -Arguments @(
        'apply',
        '--reverse',
        '--whitespace=nowarn',
        '--',
        $patchPath
    )
    $applied = $false
}
finally {
    if ($applied) {
        $null = Invoke-Git -Root $resolvedSourceRoot -Arguments @(
            'apply',
            '--reverse',
            '--whitespace=nowarn',
            '--',
            $patchPath
        )
    }
}

$finalStatus = @(Invoke-Git -Root $resolvedSourceRoot `
    -Arguments @('status', '--porcelain'))
Assert-Equal $finalStatus.Count 0 `
    'Reverse application did not restore the clean source root.'
Assert-Image -Root $resolvedSourceRoot -Files $lock.change.files `
    -Image preimage -VerifyHead

Write-Host 'Validated exact source preimages, apply, postimages, semantics, and reverse apply.'

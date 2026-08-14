[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string] $BuildDirectory,

    [Parameter(Mandatory)]
    [ValidateSet('Portable', 'ProgramData')]
    [string] $GlobalConfigMode,

    [ValidateScript({
        $_ -match '^[A-Za-z0-9_.][A-Za-z0-9_./-]*$' -and -not [IO.Path]::IsPathRooted($_)
    })]
    [string] $PortableGlobalConfig = '../../etc/ssh/ssh_config'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$sourceSsh = Join-Path $BuildDirectory 'ssh.exe'
$sourceCrypto = Join-Path $BuildDirectory 'libcrypto.dll'
foreach ($path in @($sourceSsh, $sourceCrypto)) {
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "Required config-test binary '$path' is missing."
    }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$systemSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$administratorsSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$authenticatedUsersSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-11')

function Save-FileState {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path $Path -PathType Leaf)) {
        return [pscustomobject]@{ Exists = $false; Bytes = $null; Acl = $null }
    }
    return [pscustomobject]@{
        Exists = $true
        Bytes = [System.IO.File]::ReadAllBytes($Path)
        Acl = Get-Acl -Path $Path
    }
}

function Restore-FileState {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][pscustomobject] $State
    )

    if (-not $State.Exists) {
        Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
        return
    }
    $null = New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force
    [System.IO.File]::WriteAllBytes($Path, $State.Bytes)
    Set-Acl -Path $Path -AclObject $State.Acl
}

function Set-SecureConfigAcl {
    param([Parameter(Mandatory)][string] $Path)

    $acl = [System.Security.AccessControl.FileSecurity]::new()
    $acl.SetOwner($currentUserSid)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($identity in @($currentUserSid, $systemSid, $administratorsSid)) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $null = $acl.AddAccessRule($rule)
    }
    Set-Acl -Path $Path -AclObject $acl
}

function Set-InsecureConfigAcl {
    param([Parameter(Mandatory)][string] $Path)

    $acl = Get-Acl -Path $Path
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $authenticatedUsersSid,
        [System.Security.AccessControl.FileSystemRights]::Modify,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $null = $acl.AddAccessRule($rule)
    Set-Acl -Path $Path -AclObject $acl
}

function Write-Config {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string[]] $Lines
    )

    $null = New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force
    [System.IO.File]::WriteAllLines($Path, $Lines, $utf8NoBom)
    Set-SecureConfigAcl -Path $Path
}

function Invoke-Ssh {
    param(
        [Parameter(Mandatory)][string[]] $ArgumentList,
        [string] $WorkingDirectory = ''
    )

    if ($WorkingDirectory) {
        Push-Location $WorkingDirectory
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $script:SshPath @ArgumentList 2>&1 | ForEach-Object { $_.ToString() })
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = $output
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($WorkingDirectory) {
            Pop-Location
        }
    }
}

function Assert-ResolvedOption {
    param(
        [Parameter(Mandatory)][string[]] $ArgumentList,
        [Parameter(Mandatory)][string] $Option,
        [Parameter(Mandatory)][string] $Expected,
        [string] $WorkingDirectory = ''
    )

    $result = Invoke-Ssh -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory
    if ($result.ExitCode -ne 0) {
        throw "ssh $($ArgumentList -join ' ') failed with exit code $($result.ExitCode).`n$($result.Output -join [Environment]::NewLine)"
    }
    $match = @($result.Output | Where-Object { $_ -match "^$([Regex]::Escape($Option))\s+(.+)$" })
    if ($match.Count -ne 1) {
        throw "Expected one '$Option' setting from ssh $($ArgumentList -join ' '), found $($match.Count)."
    }
    $actual = ([regex]::Match($match[0], "^$([Regex]::Escape($Option))\s+(.+)$")).Groups[1].Value
    if ($actual -ne $Expected) {
        throw "ssh $($ArgumentList -join ' ') resolved '$Option' to '$actual'; expected '$Expected'."
    }
}

function Assert-ConfigFailure {
    param(
        [Parameter(Mandatory)][string[]] $ArgumentList,
        [Parameter(Mandatory)][string] $ExpectedPattern
    )

    $result = Invoke-Ssh -ArgumentList $ArgumentList
    if ($result.ExitCode -eq 0) {
        throw "ssh $($ArgumentList -join ' ') unexpectedly accepted an invalid configuration."
    }
    if (($result.Output -join [Environment]::NewLine) -notmatch $ExpectedPattern) {
        throw "ssh $($ArgumentList -join ' ') failed without expected diagnostic '$ExpectedPattern'.`n$($result.Output -join [Environment]::NewLine)"
    }
}

function Convert-ToSshPath {
    param([Parameter(Mandatory)][string] $Path)
    return ([System.IO.Path]::GetFullPath($Path)).Replace('\', '/')
}

$tempBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$testRoot = Join-Path $tempBase "openssh-config-$GlobalConfigMode-$PID"
$treeRoot = Join-Path $testRoot "relocated tree with spaces-$([char]0x03A9)"
$binDirectory = Join-Path $treeRoot 'usr\bin'
$script:SshPath = Join-Path $binDirectory 'ssh.exe'
$portableConfigPath = [System.IO.Path]::GetFullPath(
    (Join-Path $binDirectory $PortableGlobalConfig.Replace('/', '\'))
)
$expectedPortableConfigPath = Join-Path $treeRoot 'etc\ssh\ssh_config'
if (-not $portableConfigPath.Equals(
    $expectedPortableConfigPath,
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw "Portable config '$PortableGlobalConfig' resolves to '$portableConfigPath', not '$expectedPortableConfigPath'."
}

$profileSshDirectory = Join-Path $env:USERPROFILE '.ssh'
$userConfigPath = Join-Path $profileSshDirectory 'config'
$programDataSshDirectory = Join-Path $env:ProgramData 'ssh'
$programDataConfigPath = Join-Path $programDataSshDirectory 'ssh_config'
$userConfigState = Save-FileState -Path $userConfigPath
$programDataConfigState = Save-FileState -Path $programDataConfigPath
$profileSshDirectoryExisted = Test-Path $profileSshDirectory -PathType Container
$programDataSshDirectoryExisted = Test-Path $programDataSshDirectory -PathType Container
$environmentNames = @(
    'ProgramData',
    'OPENSSH_GLOBAL_CONFIG',
    'SSH_CONFIG',
    'SSH_PORTABLE_GLOBAL_CONFIG'
)
$savedEnvironment = @{}
foreach ($name in $environmentNames) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

try {
    $null = New-Item -ItemType Directory -Path $binDirectory -Force
    Copy-Item -Path $sourceSsh -Destination $script:SshPath -Force
    Copy-Item -Path $sourceCrypto -Destination (Join-Path $binDirectory 'libcrypto.dll') -Force

    $includeConfigPath = Join-Path $treeRoot 'included configs\global include.conf'
    $overrideConfigPath = Join-Path $testRoot 'explicit override.conf'
    $hostileConfigPath = Join-Path $testRoot 'hostile-environment.conf'
    $hostileCwd = Join-Path $testRoot 'hostile-current-directory'
    $hostileProgramData = Join-Path $testRoot 'hostile-program-data'
    $hostileProgramDataConfig = Join-Path $hostileProgramData 'ssh\ssh_config'

    Write-Config -Path $includeConfigPath -Lines @(
        'Host included-global'
        '    Port 2204'
    )
    Write-Config -Path $overrideConfigPath -Lines @(
        'Host portable-global'
        '    Port 4401'
    )
    Write-Config -Path $hostileConfigPath -Lines @(
        'Host portable-global'
        '    Port 6630'
    )
    Write-Config -Path $userConfigPath -Lines @(
        'Host portable-precedence'
        '    Port 3301'
    )
    Write-Config -Path $portableConfigPath -Lines @(
        "Include `"$(Convert-ToSshPath $includeConfigPath)`""
        'Host portable-global'
        '    Port 2201'
        'Host portable-precedence'
        '    Port 2202'
    )
    Write-Config -Path $programDataConfigPath -Lines @(
        "Include `"$(Convert-ToSshPath $includeConfigPath)`""
        'Host default-global'
        '    Port 2210'
        'Host portable-global'
        '    Port 6610'
        'Host portable-precedence'
        '    Port 6611'
    )
    Write-Config -Path $hostileProgramDataConfig -Lines @(
        'Host portable-global'
        '    Port 6631'
    )
    $null = New-Item -ItemType Directory -Path $hostileCwd -Force
    Write-Config -Path (Join-Path $hostileCwd 'ssh_config') -Lines @(
        'Host portable-global'
        '    Port 6620'
    )

    if ($GlobalConfigMode -eq 'Portable') {
        $activeConfigPath = $portableConfigPath
        $activeConfigLines = @(
            "Include `"$(Convert-ToSshPath $includeConfigPath)`""
            'Host portable-global'
            '    Port 2201'
            'Host portable-precedence'
            '    Port 2202'
        )
        Assert-ResolvedOption -ArgumentList @('-G', 'portable-global') -Option 'port' -Expected '2201'
    }
    else {
        $activeConfigPath = $programDataConfigPath
        $activeConfigLines = @(
            "Include `"$(Convert-ToSshPath $includeConfigPath)`""
            'Host default-global'
            '    Port 2210'
            'Host portable-global'
            '    Port 6610'
            'Host portable-precedence'
            '    Port 6611'
        )
        Assert-ResolvedOption -ArgumentList @('-G', 'default-global') -Option 'port' -Expected '2210'
        Assert-ResolvedOption -ArgumentList @('-G', 'portable-global') -Option 'port' -Expected '6610'
    }

    Assert-ResolvedOption -ArgumentList @('-G', 'included-global') -Option 'port' -Expected '2204'
    Assert-ResolvedOption -ArgumentList @('-G', 'portable-precedence') -Option 'port' -Expected '3301'
    Assert-ResolvedOption -ArgumentList @('-F', $overrideConfigPath, '-G', 'portable-global') -Option 'port' -Expected '4401'

    Remove-Item -Path $activeConfigPath -Force
    Assert-ResolvedOption -ArgumentList @('-G', 'missing-global') -Option 'port' -Expected '22'
    Write-Config -Path $activeConfigPath -Lines $activeConfigLines

    Write-Config -Path $activeConfigPath -Lines @('NotARealOpenSSHOption yes')
    Assert-ConfigFailure -ArgumentList @('-G', 'malformed-global') -ExpectedPattern 'Bad configuration option|bad configuration options'

    Write-Config -Path $activeConfigPath -Lines @(
        'Host legacy-policy'
        '    HostKeyAlgorithms +ssh-dss-cert-v01@openssh.com,ssh-dss'
    )
    Assert-ConfigFailure -ArgumentList @('-G', 'legacy-policy') -ExpectedPattern 'ssh-dss'

    Write-Config -Path $activeConfigPath -Lines $activeConfigLines
    Set-InsecureConfigAcl -Path $activeConfigPath
    Assert-ConfigFailure -ArgumentList @('-G', 'portable-global') -ExpectedPattern 'Bad owner or permissions'
    Write-Config -Path $activeConfigPath -Lines $activeConfigLines

    [Environment]::SetEnvironmentVariable('OPENSSH_GLOBAL_CONFIG', $hostileConfigPath, 'Process')
    [Environment]::SetEnvironmentVariable('SSH_CONFIG', $hostileConfigPath, 'Process')
    [Environment]::SetEnvironmentVariable('SSH_PORTABLE_GLOBAL_CONFIG', $hostileConfigPath, 'Process')
    if ($GlobalConfigMode -eq 'Portable') {
        [Environment]::SetEnvironmentVariable('ProgramData', $hostileProgramData, 'Process')
        Assert-ResolvedOption -ArgumentList @('-G', 'portable-global') -Option 'port' -Expected '2201' -WorkingDirectory $hostileCwd
    }
    else {
        Assert-ResolvedOption -ArgumentList @('-G', 'portable-global') -Option 'port' -Expected '6610' -WorkingDirectory $hostileCwd
    }

    Write-Host "Passed $GlobalConfigMode global configuration tests: discovery, relocation, Unicode/spaces, precedence, -F, Include, strict errors, ACLs, and hostile CWD/environment."
}
finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
    Restore-FileState -Path $userConfigPath -State $userConfigState
    Restore-FileState -Path $programDataConfigPath -State $programDataConfigState
    if (-not $profileSshDirectoryExisted -and
        (Test-Path $profileSshDirectory -PathType Container) -and
        -not (Get-ChildItem -Path $profileSshDirectory -Force)) {
        Remove-Item -Path $profileSshDirectory -Force
    }
    if (-not $programDataSshDirectoryExisted -and
        (Test-Path $programDataSshDirectory -PathType Container) -and
        -not (Get-ChildItem -Path $programDataSshDirectory -Force)) {
        Remove-Item -Path $programDataSshDirectory -Force
    }
    Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

As of Nov 1st 2016, active development on "Windows for OpenSSH" is being done in https://github.com/PowerShell/openssh-portable.

This repo (https://github.com/PowerShell/Win32-OpenSSH) is being maintained to keep track of releases and issues
and because it contains the [wiki](https://github.com/PowerShell/Win32-OpenSSH/wiki)
which has instructions for [building](https://github.com/PowerShell/Win32-OpenSSH/wiki/Building-OpenSSH-for-Windows-(using-LibreSSL-crypto)).

## Source-only portable client configuration proposal

This draft records an architecture-neutral source patch needed by a future
native ARM64 Git for Windows client. The `-UsePortableGlobalConfig` switch is
the only opt-in. It always passes the MSBuild property as exact lowercase
`false` by default or `true` when present; direct builds reject every other
value, including alternate casing.

Portable mode accepts no caller-supplied path. It requires `ssh.exe` to run
from the fixed `usr/bin` bundle location and selects only the hardcoded
bundle-relative `etc/ssh/ssh_config` file. No traversal component is accepted
from a caller.

The default remains `%ProgramData%\ssh\ssh_config` when the property is absent.
The override is compile-time-only, applies only to `ssh.exe`, canonicalizes
from the executable directory, and retains the existing Windows secure-file
permission check. A writable, reparseable, or otherwise untrusted bundle root
is unsafe: the configuration file ACL check does not establish bundle
provenance or authenticate ancestor directories and reparse targets. `scp` and
`sftp` can inherit this behavior when they launch `ssh.exe`, so the entire
portable directory must come from an admitted, access-controlled source.

Only explicit portable mode makes an invalid executable layout, directory
resolution failure, or path truncation fatal. The default ProgramData path
does not enter the portable resolver, and an absent configuration file retains
the normal non-fatal OpenSSH behavior.

This repository intentionally includes no workflow, dependency bootstrap,
package producer, or binary artifact for the proposal. Runtime, SDK, compiler,
linker, dependency-package, native process, loaded-module, and ABI provenance
remain external admission gates. The source record must not be interpreted as
an ARM64 build or behavior claim.

The immutable source identity, all four preimage and postimage blob IDs and
SHA-256 values, and the patch digest are recorded in
`eng/portable-ssh-config-source-lock.json`. The offline policy check requires
only the current repository and Git, but does not claim that the patch applies:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-PortableConfigSourceCandidate.ps1
```

Exact application is proven separately against a clean checkout of the locked
source. This check verifies every preimage, performs real `git apply --check`
and apply operations, validates every postimage and source contract, then
reverse-applies and proves that the source tree is clean again:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-PortableConfigSourceCandidate.ps1 -SourceRoot <exact-source-root>
```

Native validation stays blocked until an independently admitted bootstrap can
build the pinned source on genuine Windows ARM64. That later gate must cover
default x64 behavior, executable-relative ARM64 configuration, OS and process
architecture, imported and loaded modules, and dependency ABI provenance
before any package or artifact is produced.

### Release History

| Date | Version | Release with source |
|---|---|---|
| 7/26/2018 | 7.7.2.0 | https://github.com/PowerShell/openssh-portable/releases/tag/v7.7.2.0 |
| 1/11/2019 | 7.9.0.0 | https://github.com/PowerShell/openssh-portable/releases/tag/v7.9.0.0 |
| 6/23/2019 | 8.0.0.0 | https://github.com/PowerShell/openssh-portable/releases/tag/v8.0.0.0 |
| 12/17/2019 | 8.1.0.0 | https://github.com/PowerShell/openssh-portable/releases/tag/v8.1.0.0 |
| 05/26/2021 | 8.6.0.0 | https://github.com/PowerShell/openssh-portable/releases/tag/v8.6.0.0 |
| 03/17/2022 | 8.9.0.0 | https://github.com/PowerShell/openssh-portable/releases/tag/v8.9.0.0 |
| 03/22/2022 | 8.9.1.0 | https://github.com/PowerShell/openssh-portable/releases/tag/V8.9.1.0 |
| 12/13/2022 | 9.1.0.0 | https://github.com/PowerShell/openssh-portable/releases/tag/v9.1.0.0 |
| 02/21/2023 | 9.2.0.0 | https://github.com/PowerShell/openssh-portable/releases/tag/v9.2.0.0 |
| 04/17/2023 | 9.2.2.0 | https://github.com/PowerShell/openssh-portable/releases/tag/v9.2.2.0 |
| 10/10/2023 | 9.4.0.0 | https://github.com/PowerShell/openssh-portable/releases/tag/v9.4.0.0 |
| 12/18/2023 | 9.5.0.0 | https://github.com/PowerShell/openssh-portable/releases/tag/v9.5.0.0 |
| 10/08/2024 | 9.8.0.0 | https://github.com/PowerShell/openssh-portable/releases/tag/v9.8.0.0 |
| 10/10/2024 | 9.8.1.0 | https://github.com/PowerShell/openssh-portable/releases/tag/v9.8.1.0 |
| 04/08/2025 | 9.8.2.0 | https://github.com/PowerShell/openssh-portable/releases/tag/v9.8.2.0 |
| 04/18/2025 | 9.8.3.0 | https://github.com/PowerShell/openssh-portable/releases/tag/v9.8.3.0 |
| 10/27/2025 | 10.0.0.0 | https://github.com/PowerShell/openssh-portable/releases/tag/v10.0.0.0 |

## Code of Conduct

Please see our [Code of Conduct](.github/CODE_OF_CONDUCT.md) before participating in this project.

## Security Policy

For any security issues, please see our [Security Policy](.github/SECURITY.md).

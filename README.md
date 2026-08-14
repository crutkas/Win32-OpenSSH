As of Nov 1st 2016, active development on "Windows for OpenSSH" is being done in https://github.com/PowerShell/openssh-portable.

This repo (https://github.com/PowerShell/Win32-OpenSSH) is being maintained to keep track of releases and issues
and because it contains the [wiki](https://github.com/PowerShell/Win32-OpenSSH/wiki)
which has instructions for [building](https://github.com/PowerShell/Win32-OpenSSH/wiki/Building-OpenSSH-for-Windows-(using-LibreSSL-crypto)).

### ARM64 client artifact

The `ARM64 client artifact` workflow rebuilds the `v10.0.0.0` source tag on a native
Windows ARM64 runner, runs the upstream unit tests and client integration smoke
tests, verifies every packaged PE has machine type `0xAA64`, and publishes a
client-only payload laid out for Git for Windows.

The artifact manifest records the exact OpenSSH source commit, vcpkg baseline,
workflow commit, per-file SHA-256 hashes, and the disposition of all 11 existing
Git for Windows OpenSSH paths. Ten paths receive native replacements.
`usr/lib/ssh/ssh-keysign.exe` is removed because Win32 OpenSSH does not build it
and does not support host-based authentication. Server daemons, service scripts,
server configuration, and shell-host files are excluded from the artifact.

#### Portable client global configuration

The Windows `ssh` project has an opt-in build property for a package-relative
global client configuration:

```powershell
OpenSSH-build.ps1 -PortableGlobalConfig ../../etc/ssh/ssh_config
```

Without this property, all architectures retain the standard
`%ProgramData%\ssh\ssh_config` behavior. With it, `ssh.exe` resolves the
configured relative path from its own executable directory, canonicalizes it,
and applies the existing Windows secure-file ACL validation. The ARM64 client
artifact uses `../../etc/ssh/ssh_config`, which maps
`usr/bin/ssh.exe` to `etc/ssh/ssh_config` in a relocated Git installation. The
manifest records this contract but deliberately does not include the
configuration file; the downstream Git package owns that policy file.

This is client-only and build-time-only. It adds no runtime environment
variable, registry setting, current-directory search, or server/`sshd` path.
User `~/.ssh/config` remains higher precedence, `-F` still replaces both normal
config files, and Include, tilde expansion, Windows profile paths, missing-file
handling, and malformed-file failures continue through the normal OpenSSH
parser. A writable package tree introduces no new trust boundary because its
owner can already replace `ssh.exe`; when elevated or installed for multiple
users, the existing ACL check rejects a global config writable by an
untrusted identity.

Git for Windows' current global config contains unsupported
`ssh-dss`/`ssh-dss-cert-v01@openssh.com` additions. The native client remains
strict and rejects these names; it does not conditionally or silently ignore
unknown algorithms. The downstream package must remove only those unsupported
tokens from the affected comma-separated algorithm-list directives, preserving
the list modifier and every supported token. A directive whose resulting list
is empty must be removed rather than replaced with a broader policy.

To make the native client the default downstream:

1. Build and consume this artifact, keep the existing ten replacements and
   `ssh-keysign.exe` removal, and install the transformed policy as
   `etc/ssh/ssh_config`.
2. Verify the installed `usr/bin/ssh.exe` and `etc/ssh/ssh_config` retain the
   relative layout and secure Windows ACLs; no wrapper or environment override
   is required.
3. Remove the integration opt-in only after the transformed config passes the
   package's x64/native compatibility tests. The x64 package itself need not
   adopt the build property.

The workflow tests the portable ARM64 build from a relocated Unicode/space path
and a default x64 build against ProgramData. It covers user and `-F`
precedence, Include, missing and malformed files, strict legacy-algorithm
rejection, insecure ACLs, and hostile current-directory/environment inputs,
then runs the existing unit, client, PTY, and Git-over-SSH matrix.

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

# build-aseprite

Builds [Aseprite](https://github.com/aseprite/aseprite) from its official source on Windows, as a portable copy or an installer.

> Aseprite's [EULA](https://github.com/aseprite/aseprite/blob/main/EULA.txt) lets you compile it for your own personal use but forbids distributing copies, including installers made by this script. Share the script, not what it builds. To support the developers, [buy Aseprite](https://www.aseprite.org/).

## Usage

Double-click `build-aseprite.cmd`, or run:

```powershell
.\build-aseprite.ps1                    # portable copy in .\Aseprite
.\build-aseprite.ps1 -RunInstaller      # build an installer and run it
.\build-aseprite.ps1 -SilentInstall     # update an installed copy
.\build-aseprite.ps1 -InstallPrereqs    # install missing tools first
.\build-aseprite.ps1 -ListVersions      # available and installed versions
```

Run it again to update. Only what changed is downloaded and recompiled.

## Requirements

- Windows 10/11, 64-bit
- Visual Studio 2022 or newer (or Build Tools) with **Desktop development with C++**
- Git, CMake and Ninja (the ones bundled with Visual Studio work)
- Inno Setup 6.3+ for installers
- About 2 GB of free disk space

`-InstallPrereqs` installs anything missing with winget.

## Options

| Option | Description |
|---|---|
| `-Version` | `latest` (default), `latest-beta`, a tag (`v1.3.14`), a branch (`main`, `beta`), a commit, or `local` |
| `-BuildType` | `Release` (default), `RelWithDebInfo`, `Debug` |
| `-Arch` | `x64` (default) or `x86` |
| `-SourceMode` | `Git` (default) or `Zip` (release source zip, no Git needed) |
| `-WorkDir`, `-SourceDir`, `-InstallDir` | Where files go |
| `-SkiaDir` | Use your own Skia build |
| `-VsVersion` | Pick a Visual Studio version |
| `-Jobs` | Limit parallel compiles |
| `-Translations` | Include translations |
| `-Portable` | Keep the portable copy's settings next to its exe |
| `-NoUpdateCheck` | Disable the update check and news |
| `-Tests` | Build and run unit tests |
| `-CMakeArgs` | Extra CMake arguments |
| `-Clean` | Full rebuild |
| `-NoInstall` | Skip the portable copy |
| `-Installer` | Build an installer in `dist\` |
| `-RunInstaller`, `-SilentInstall` | Build the installer and run it |
| `-InstallPrereqs` | Install missing tools |
| `-FullHistory` | Full git history |
| `-Force` | Discard local source changes |
| `-ShowBuildOutput` | Show all build output |
| `-Run` | Launch Aseprite when done |

`Get-Help .\build-aseprite.ps1 -Full` describes each option.

## Troubleshooting

- Each run writes a log to `logs\`.
- Compiler out of memory: use `-Jobs 4`.
- Errors after updating Visual Studio: use `-Clean`.
- Use a short work folder path, such as `C:\asebuild`.

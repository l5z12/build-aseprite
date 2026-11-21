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

<!-- options:start -->
| Option | Description |
|---|---|
| `-Version` | latest (default), latest-beta, a tag such as v1.3.14, a branch (main, beta), a commit SHA, or local to build `-SourceDir` as-is. |
| `-BuildType` | Release (default), RelWithDebInfo (includes a .pdb) or Debug. |
| `-Arch` | x64 (default) or x86. |
| `-SourceMode` | Git (default) or Zip (official release source zip; tags only, no Git needed). |
| `-WorkDir` | Folder for source, dependencies, build files and logs. Default: script folder. |
| `-SourceDir` | Git checkout location. Default: `<WorkDir>\src`. |
| `-InstallDir` | Portable copy location. Default: `<WorkDir>\Aseprite`. With `-Installer`, a portable copy is only made when this is given. |
| `-SkiaDir` | Use an existing Skia build instead of downloading one. |
| `-VsVersion` | Visual Studio to use: latest (default), 2019, 2022, 2026 or a major version. |
| `-Jobs` | Parallel compile jobs (default: automatic). Lower it if the compiler runs out of memory. |
| `-Translations` | Include community translations. |
| `-Portable` | Store the portable copy's settings next to its exe instead of `%APPDATA%\Aseprite`. |
| `-NoUpdateCheck` | Disable the update check and the news on the Home tab. |
| `-Tests` | Also build and run the unit tests. |
| `-CMakeArgs` | Extra CMake arguments, e.g. `-CMakeArgs '-DENABLE_PSD=ON'`. |
| `-Clean` | Full rebuild. |
| `-NoInstall` | Don't make the portable copy. |
| `-Installer` | Build an installer in `dist\` with shortcuts, optional file associations and an uninstaller. Requires Inno Setup 6.3 or newer. |
| `-RunInstaller` | Build the installer and launch it. |
| `-SilentInstall` | Build the installer and run it unattended, keeping earlier install options. |
| `-InstallPrereqs` | Install missing tools with winget (Git, CMake, Ninja, Visual Studio Build Tools, and Inno Setup when needed). |
| `-FullHistory` | Fetch full git history instead of a shallow checkout. |
| `-Force` | Discard local source changes; allow a portable folder the script didn't create. |
| `-Run` | Launch Aseprite when done. |
| `-ShowBuildOutput` | Show all tool output instead of progress bars. |
| `-ListVersions` | Show available and installed versions, then exit. |
<!-- options:end -->

## Troubleshooting

- Each run writes a log to `logs\`.
- Compiler out of memory: use `-Jobs 4`.
- Errors after updating Visual Studio: use `-Clean`.
- Use a short work folder path, such as `C:\asebuild`.

## License

This script is [MIT licensed](LICENSE). Aseprite itself is covered by its own [EULA](https://github.com/aseprite/aseprite/blob/main/EULA.txt).

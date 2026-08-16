@echo off
REM ==========================================================================
REM  Build the Mesen Gauntlet Edition: native core, single-file UI, release ZIP.
REM
REM  Requirements:
REM    - Visual Studio 2022 (or the standalone Build Tools) with the C++ workload
REM    - .NET 8 SDK
REM
REM  Optional environment overrides:
REM    MSBUILD_PATH      Full path to MSBuild.exe. Located via vswhere if unset.
REM    WIN_SDK_VERSION   Windows SDK version to target. Default: 10.0.19041.0
REM    WINDOWS_KITS_DIR  Windows Kits root, e.g. "C:\Program Files (x86)\Windows Kits\10".
REM                      Only needed when the SDK is installed outside the default
REM                      location and MSBuild cannot resolve it on its own.
REM ==========================================================================
setlocal enabledelayedexpansion

REM Always run from this script's own directory, regardless of how it is invoked.
pushd "%~dp0"

if not defined WIN_SDK_VERSION set "WIN_SDK_VERSION=10.0.19041.0"

REM ---- Locate MSBuild ------------------------------------------------------
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not defined MSBUILD_PATH if exist "%VSWHERE%" (
    for /f "usebackq tokens=*" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe`) do set "MSBUILD_PATH=%%I"
)
if not defined MSBUILD_PATH (
    echo Error: Could not locate MSBuild.exe.
    echo Install Visual Studio 2022 with the C++ workload, or set MSBUILD_PATH.
    goto :handle_error
)

REM ---- Optional Windows SDK overrides --------------------------------------
set "SDK_ARGS="
if defined WINDOWS_KITS_DIR set SDK_ARGS=-p:WindowsSdkDir="%WINDOWS_KITS_DIR%\" -p:UniversalCRTSdkDir="%WINDOWS_KITS_DIR%\" -p:UCRTContentRoot="%WINDOWS_KITS_DIR%\"

echo ==========================================
echo Step 1: Building native MesenCore.dll...
echo ==========================================
echo Using MSBuild: %MSBUILD_PATH%
"%MSBUILD_PATH%" InteropDLL\InteropDLL.vcxproj -p:Configuration=Release -p:Platform=x64 -p:WindowsTargetPlatformVersion=%WIN_SDK_VERSION% %SDK_ARGS% -p:SolutionDir="%~dp0\"
if %ERRORLEVEL% neq 0 (
    echo Error: Failed to build native InteropDLL.
    goto :handle_error
)

echo ==========================================
echo Step 2: Publishing UI standalone executable...
echo ==========================================
dotnet publish UI/UI.csproj -c Release -r win-x64 -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true --self-contained true -p:SolutionDir="%~dp0\"
if %ERRORLEVEL% neq 0 (
    echo Error: Failed to publish UI.
    goto :handle_error
)

echo ==========================================
echo Step 3: Packaging Challenge release ZIP...
echo ==========================================
set "PUBLISH_DIR=%~dp0bin\win-x64\Release\win-x64\publish"

REM Ship the current player guide next to the exe (canonical copy lives in Challenge\README.txt).
copy /y "%~dp0Challenge\README.txt" "%PUBLISH_DIR%\README.txt" >nul
if %ERRORLEVEL% neq 0 (
    echo Error: Could not copy Challenge\README.txt into the publish folder.
    goto :handle_error
)

REM Read the version from Challenge\version.txt (the single source of truth). Comment lines
REM start with '#' and have no '=', so only the "version=" line matches.
set "CHALLENGE_VERSION="
for /f "usebackq tokens=1,* delims==" %%A in ("%~dp0Challenge\version.txt") do (
    if /i "%%A"=="version" set "CHALLENGE_VERSION=%%B"
)
if not defined CHALLENGE_VERSION (
    echo Error: Could not read "version=" from Challenge\version.txt
    goto :handle_error
)

set "ZIP_PATH=%PUBLISH_DIR%\Mesen_Challenge_Version_%CHALLENGE_VERSION%.zip"
if exist "%ZIP_PATH%" del /q "%ZIP_PATH%"

REM Wait 3 seconds using ping (works in non-interactive shells) to allow antivirus scanners to finish scanning Mesen.exe
ping -n 4 127.0.0.1 >nul

REM Bundle just Mesen.exe + README.txt at the ZIP root (matches the expected package layout).
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Compress-Archive -Path '%PUBLISH_DIR%\Mesen.exe','%PUBLISH_DIR%\README.txt' -DestinationPath '%ZIP_PATH%' -Force -ErrorAction Stop } catch { Write-Error $_; exit 1 }"
if %ERRORLEVEL% neq 0 (
    echo Error: Failed to create the Challenge release ZIP.
    goto :handle_error
)

echo ==========================================
echo Build completed successfully!
echo standalone executable path:
echo %PUBLISH_DIR%\Mesen.exe
echo release package:
echo %ZIP_PATH%
echo ==========================================
popd

echo %cmdcmdline% | findstr /i /c:"/c" >nul
if not errorlevel 1 pause
exit /b 0

:handle_error
set "ERR=%ERRORLEVEL%"
popd
echo %cmdcmdline% | findstr /i /c:"/c" >nul
if not errorlevel 1 pause
exit /b %ERR%

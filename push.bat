@echo off
setlocal
cd /d "%~dp0"

echo.
echo   ImGui overlay - push to GitHub (token auth)
echo   -----------------------------------------------
echo   STEP 1  Create a Personal Access Token (classic), scope: repo
echo           https://github.com/settings/tokens/new?scopes=repo^&description=imgui-overlay
echo           -^> Generate token -^> copy the ghp_... string
echo   STEP 2  Repo https://github.com/leontappro1/imgui-overlay-demo must exist.
echo           Only the FIRST push needs it empty; later pushes just update it.
echo.
echo   GitHub no longer accepts passwords. Use the TOKEN, not your password.
echo   Token input is HIDDEN. Never paste a token into a screenshot or chat.
echo.
set "GHUSER=leontappro1"
set /p "GHUSER=GitHub username [%GHUSER%]: "
set "GHTOKEN="
for /f "delims=" %%T in ('powershell -NoProfile -Command "$s=Read-Host 'Paste token (hidden)' -AsSecureString; [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))" 2^>nul') do set "GHTOKEN=%%T"
if "%GHTOKEN%"=="" (
  echo Hidden input unavailable - visible fallback, do not share your screen.
  set /p "GHTOKEN=Paste token (visible): "
)
if "%GHTOKEN%"=="" (echo Cancelled. & exit /b 1)

git remote remove origin >nul 2>&1
git remote add origin https://github.com/%GHUSER%/imgui-overlay-demo.git

rem This PortableGit has credential.helper=manager in its system config,
rem but the helper binary is missing. Disable the system config for the push
rem and pass the token in the URL. The token is NOT saved into .git/config.
set GIT_CONFIG_NOSYSTEM=1

echo.
echo Pushing...
git push "https://%GHUSER%:%GHTOKEN%@github.com/%GHUSER%/imgui-overlay-demo.git" main
if errorlevel 1 (
  echo.
  echo PUSH FAILED. Check:
  echo   - token starts with ghp_ and has the "repo" scope, not expired
  echo   - repo https://github.com/%GHUSER%/imgui-overlay-demo exists and is reachable
  echo   - if you pasted your account password instead of a token, rerun this file
) else (
  git remote set-url origin https://github.com/%GHUSER%/imgui-overlay-demo.git >nul 2>&1
  git fetch origin >nul 2>&1
  git branch --set-upstream-to=origin/main main >nul 2>&1
  echo.
  echo DONE. Token was not stored in git config. Push starts CI automatically.
  echo   https://github.com/%GHUSER%/imgui-overlay-demo/actions
  echo Wait for green jobs, then download from Artifacts:
  echo   imgui-overlay-ios-simulator-ipa          (simulator only)
  echo   imgui-overlay-ios-device-unsigned-ipa   (sign in ESign, install on iPhone)
)
echo.
pause

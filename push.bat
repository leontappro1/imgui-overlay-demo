@echo off
setlocal
cd /d "%~dp0"

echo.
echo   ImGui overlay - push to GitHub (token auth)
echo   -----------------------------------------------
echo   STEP 1  Create a Personal Access Token (classic), scope: repo
echo           https://github.com/settings/tokens/new?scopes=repo^&description=imgui-overlay
echo           -^> Generate token -^> copy the ghp_... string
echo   STEP 2  Repo must exist and be EMPTY: https://github.com/new
echo           name: imgui-overlay-demo  (no README, no .gitignore, no license)
echo.
echo   GitHub no longer accepts passwords. Use the TOKEN, not your password.
echo   (the token is visible while typing - don't share your screen)
echo.
set "GHUSER=leontappro1"
set /p "GHUSER=GitHub username [%GHUSER%]: "
set /p "GHTOKEN=Paste token (ghp_...): "
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
  echo   - repo https://github.com/%GHUSER%/imgui-overlay-demo exists and is EMPTY
  echo   - if you pasted your account password instead of a token, rerun this file
) else (
  git remote set-url origin https://github.com/%GHUSER%/imgui-overlay-demo.git >nul 2>&1
  git fetch origin >nul 2>&1
  git branch --set-upstream-to=origin/main main >nul 2>&1
  echo.
  echo DONE. Token was not stored in git config. Now open:
  echo   https://github.com/%GHUSER%/imgui-overlay-demo/actions
  echo Choose "Build iOS overlay" -^> Run workflow -^> download artifact.
)
echo.
pause

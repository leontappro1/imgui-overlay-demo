@echo off
setlocal
cd /d "%~dp0"

echo.
echo   ImGui overlay - push to GitHub
echo   -----------------------------------------------
echo   BEFORE RUNNING: create an EMPTY repo at https://github.com/new
echo   name: imgui-overlay-demo   (no README, no .gitignore, no license)
echo.
set /p GHUSER=GitHub username: 
if "%GHUSER%"=="" (echo Cancelled. & exit /b 1)

git remote remove origin >nul 2>&1
git remote add origin https://github.com/%GHUSER%/imgui-overlay-demo.git

echo.
echo Pushing... (a browser login window may pop up)
git push -u origin main
if errorlevel 1 (
  echo.
  echo PUSH FAILED. Check that the repo exists and is EMPTY:
  echo   https://github.com/new  ^| name: imgui-overlay-demo
  echo If you were asked to log in, retry this file once.
) else (
  echo.
  echo DONE. Now open:
  echo   https://github.com/%GHUSER%/imgui-overlay-demo/actions
  echo Choose "Build iOS overlay" -^> Run workflow -^> download artifact.
)
echo.
pause

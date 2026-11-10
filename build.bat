@echo off
setlocal
set ROOT=%~dp0
set IMG=%ROOT%third_party\imgui
if not exist "%ROOT%build" mkdir "%ROOT%build"

g++ -std=c++17 -O2 -mwindows -static -static-libgcc -static-libstdc++ ^
  -I"%IMG%" -I"%IMG%\backends" -I"%ROOT%shared" ^
  "%ROOT%src\main.cpp" "%ROOT%shared\ui.cpp" ^
  "%IMG%\imgui.cpp" "%IMG%\imgui_draw.cpp" "%IMG%\imgui_tables.cpp" ^
  "%IMG%\imgui_widgets.cpp" "%IMG%\imgui_demo.cpp" ^
  "%IMG%\backends\imgui_impl_win32.cpp" ^
  "%IMG%\backends\imgui_impl_opengl3.cpp" ^
  -o "%ROOT%build\imgui_overlay.exe" ^
  -lopengl32 -lgdi32 -luser32 -limm32 -ldwmapi -lshell32

if errorlevel 1 (echo BUILD FAILED & exit /b 1)
echo OK -^> %ROOT%build\imgui_overlay.exe

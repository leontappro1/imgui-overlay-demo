#!/usr/bin/env bash
# Git Bash / MSYS2. Produces build/imgui_overlay.exe (fully static, no DLLs needed).
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

IMG=third_party/imgui
mkdir -p build

g++ -std=c++17 -O2 -mwindows -static -static-libgcc -static-libstdc++ \
  -I"$IMG" -I"$IMG/backends" -Ishared \
  src/main.cpp shared/ui.cpp \
  "$IMG/imgui.cpp" "$IMG/imgui_draw.cpp" "$IMG/imgui_tables.cpp" \
  "$IMG/imgui_widgets.cpp" "$IMG/imgui_demo.cpp" \
  "$IMG/backends/imgui_impl_win32.cpp" \
  "$IMG/backends/imgui_impl_opengl3.cpp" \
  -o build/imgui_overlay.exe \
  -lopengl32 -lgdi32 -luser32 -limm32 -ldwmapi -lshell32

echo "OK -> $ROOT/build/imgui_overlay.exe"

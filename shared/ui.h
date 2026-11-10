#pragma once
// Platform-neutral UI. Shared verbatim by the Win32 demo and the iOS demo.
// Only the two backend files differ between platforms; this file does not.

#include "imgui.h"

namespace overlay
{
    struct Toggle
    {
        const char* label;
        bool* value;
    };

    struct PlatformHooks
    {
        const char* platform_line;   // e.g. "Win32 / OpenGL 3.0 / MinGW-w64"
        const char* hotkeys_line;    // e.g. "INSERT click-through | F12 quit"
        const char* backend_name;    // e.g. "Win32 + OpenGL3"
        const char* compiler_name;   // e.g. "MinGW-w64 GCC"
        const char* window_note;     // short text in the Window tab

        Toggle toggles[3];
        int toggle_count = 0;

        void (*on_toggle)(void*) = nullptr;  // called after any toggle changes
        void* user_data = nullptr;
    };

    // Draw one frame of the menu. dt is seconds since the previous frame.
    void DrawUI(const PlatformHooks& hooks, float dt);

    void AddLog(const char* fmt, ...);
    void ToggleDemo();
    void ToggleMenu();
    bool IsMenuVisible();
    float GetFPS();
}

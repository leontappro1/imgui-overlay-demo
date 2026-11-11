// ImGui overlay sandbox - Win32 + OpenGL 3.0
// A self-contained Dear ImGui overlay for YOUR OWN application / prototype.
// The menu itself lives in ../shared/ui.cpp and is shared verbatim with the iOS build.
// Dear ImGui v1.92.0 (MIT). No game binaries, no injection, no hooks.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <GL/gl.h>

#include <cwchar>
#include <cstdio>

#include "imgui.h"
#include "backends/imgui_impl_win32.h"
#include "backends/imgui_impl_opengl3.h"
#include "ui.h"

// ---------------------------------------------------------------- WGL helpers
typedef HGLRC(WINAPI* PFNWGLCREATECONTEXTATTRIBSARB)(HDC, HGLRC, const int*);
typedef BOOL(WINAPI* PFNWGLSWAPINTERVALEXT)(int);

#define WGL_CONTEXT_MAJOR_VERSION_ARB 0x2091
#define WGL_CONTEXT_MINOR_VERSION_ARB 0x2092

static HGLRC g_glrc = nullptr;
static PFNWGLSWAPINTERVALEXT g_swapInterval = nullptr;

static HGLRC CreateGLContext(HDC hdc)
{
    PIXELFORMATDESCRIPTOR pfd = {};
    pfd.nSize = sizeof(PIXELFORMATDESCRIPTOR);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.cStencilBits = 8;
    pfd.iLayerType = PFD_MAIN_PLANE;

    int pf = ChoosePixelFormat(hdc, &pfd);
    if (pf == 0) return nullptr;
    if (!SetPixelFormat(hdc, pf, &pfd)) return nullptr;

    // A legacy context is required first: only after making one current can we
    // query the ARB entry point that creates a modern OpenGL context.
    HGLRC bootstrap = wglCreateContext(hdc);
    if (!bootstrap) return nullptr;
    wglMakeCurrent(hdc, bootstrap);

    auto createAttribs = (PFNWGLCREATECONTEXTATTRIBSARB)
        wglGetProcAddress("wglCreateContextAttribsARB");
    g_swapInterval = (PFNWGLSWAPINTERVALEXT)wglGetProcAddress("wglSwapIntervalEXT");

    HGLRC modern = nullptr;
    if (createAttribs)
    {
        const int attribs[] = { WGL_CONTEXT_MAJOR_VERSION_ARB, 3,
                                WGL_CONTEXT_MINOR_VERSION_ARB, 0, 0 };
        modern = createAttribs(hdc, nullptr, attribs);
    }

    wglMakeCurrent(nullptr, nullptr);
    wglDeleteContext(bootstrap);

    HGLRC rc = modern ? modern : wglCreateContext(hdc);
    if (rc) wglMakeCurrent(hdc, rc);
    return rc;
}

// ---------------------------------------------------------------- platform glue
static bool g_topmost = true;
static bool g_clickThrough = false;
static bool g_vsync = true;
static bool g_hudMode = false;   // --hud: transparent fullscreen HUD overlay

static void ApplyWindowStyles(HWND hwnd)
{
    LONG ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    ex &= ~WS_EX_TRANSPARENT;
    if (g_hudMode)
    {
        // WS_EX_LAYERED + colour key is what makes the HUD window see-through.
        ex |= WS_EX_LAYERED;
    }
    else
    {
        ex &= ~WS_EX_LAYERED;
    }
    if (g_clickThrough) ex |= WS_EX_TRANSPARENT;
    SetWindowLongPtr(hwnd, GWL_EXSTYLE, ex);
    SetWindowPos(hwnd, g_topmost ? HWND_TOPMOST : HWND_NOTOPMOST,
                 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

static void OnToggle(void* userData)
{
    HWND hwnd = (HWND)userData;
    ApplyWindowStyles(hwnd);
    if (g_swapInterval) g_swapInterval(g_vsync ? 1 : 0);
}

static overlay::PlatformHooks MakeHooks(HWND hwnd)
{
    overlay::PlatformHooks h = {};
    h.platform_line = "Win32 / OpenGL 3.0 / MinGW-w64";
    h.hotkeys_line  = g_hudMode
        ? "INSERT click-through  |  F1 demo  |  F2 hide  |  F12 quit  (global hotkeys)"
        : "INSERT click-through  |  F1 demo  |  F2 hide  |  F12 quit";
    h.backend_name  = "Win32 + OpenGL3";
    h.compiler_name = "MinGW-w64 GCC";
    h.window_note   = g_hudMode
        ? "HUD mode: a transparent fullscreen window drawn on top of the desktop. "
          "It runs in its own process and only paints pixels - it never reads or "
          "touches another application's memory."
        : "Click-through uses WS_EX_TRANSPARENT | WS_EX_LAYERED, "
          "the same mechanism every desktop overlay uses. "
          "Turn it off to interact with the widgets again.";
    h.toggles[0] = { "always on top", &g_topmost };
    h.toggles[1] = { "click-through", &g_clickThrough };
    h.toggles[2] = { "vsync", &g_vsync };
    h.toggle_count = 3;
    h.on_toggle = OnToggle;
    h.user_data = hwnd;
    return h;
}

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND, UINT, WPARAM, LPARAM);

// ---------------------------------------------------------------- HUD overlay
// A compact always-on-top readout drawn in the corner of a fully transparent
// window. It lives in its own process and never touches another application:
// it only draws on top of the desktop.
static void DrawHUD()
{
    ImGuiIO& io = ImGui::GetIO();

    ImGui::SetNextWindowPos(ImVec2(24, 24), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowBgAlpha(0.85f);
    const ImGuiWindowFlags flags = ImGuiWindowFlags_NoTitleBar
                                 | ImGuiWindowFlags_NoResize
                                 | ImGuiWindowFlags_NoMove
                                 | ImGuiWindowFlags_NoSavedSettings
                                 | ImGuiWindowFlags_NoScrollbar
                                 | ImGuiWindowFlags_NoInputs;

    ImGui::Begin("##hud", nullptr, flags);
    {
        SYSTEMTIME st;
        GetLocalTime(&st);
        const float fps = overlay::GetFPS();

        ImGui::TextColored(ImVec4(0.20f, 0.85f, 0.95f, 1.0f), "ImGui HUD");
        ImGui::Separator();
        ImGui::Text("fps      %.1f   (%.2f ms)", fps,
                    1000.0f / (fps > 0.01f ? fps : 1.0f));
        ImGui::Text("uptime   %llu s",
                    (unsigned long long)(GetTickCount64() / 1000ULL));
        ImGui::Text("time     %02d:%02d:%02d", st.wHour, st.wMinute, st.wSecond);
        ImGui::Text("cursor   %.0f, %.0f", io.MousePos.x, io.MousePos.y);
        ImGui::Text("screen   %.0f x %.0f", io.DisplaySize.x, io.DisplaySize.y);
        ImGui::TextDisabled("INSERT click-through | F2 menu | F12 quit");
    }
    ImGui::End();
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (ImGui_ImplWin32_WndProcHandler(hwnd, msg, wp, lp)) return true;

    switch (msg)
    {
    case WM_SIZE:
        if (g_glrc && LOWORD(lp) > 0 && HIWORD(lp) > 0)
            glViewport(0, 0, LOWORD(lp), HIWORD(lp));
        return 0;

    case WM_HOTKEY:
        // Global hotkeys: the overlay window does not need keyboard focus.
        switch (wp)
        {
        case 1:
            g_clickThrough = !g_clickThrough;
            ApplyWindowStyles(hwnd);
            overlay::AddLog("click-through: %s", g_clickThrough ? "ON" : "OFF");
            return 0;
        case 2: overlay::ToggleDemo();  return 0;
        case 3: overlay::ToggleMenu();  return 0;
        case 4: PostQuitMessage(0);     return 0;
        }
        return 0;

    case WM_KEYDOWN:
        // In HUD mode the global hotkeys already handle these; handling them
        // twice would toggle the menu on and straight back off.
        if (g_hudMode) return 0;
        if (wp == VK_F12) { PostQuitMessage(0); return 0; }
        if (wp == VK_INSERT)
        {
            g_clickThrough = !g_clickThrough;
            ApplyWindowStyles(hwnd);
            overlay::AddLog("click-through: %s", g_clickThrough ? "ON" : "OFF");
            return 0;
        }
        if (wp == VK_F1) { overlay::ToggleDemo(); return 0; }
        if (wp == VK_F2) { overlay::ToggleMenu(); return 0; }
        return 0;

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

// ---------------------------------------------------------------- entry point
int WINAPI WinMain(HINSTANCE hInst, HINSTANCE, LPSTR, int)
{
    g_hudMode = (wcsstr(GetCommandLineW(), L"--hud") != nullptr);

    ImGui_ImplWin32_EnableDpiAwareness();

    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(WNDCLASSEXW);
    wc.style = CS_OWNDC;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.lpszClassName = L"ImGuiOverlaySandbox";
    if (!RegisterClassExW(&wc)) return 1;

    HWND hwnd = nullptr;
    if (g_hudMode)
    {
        // Fullscreen, borderless, tool window: an external HUD that floats
        // above everything else on the desktop.
        const int vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
        const int vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        const int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        const int vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW,
                               wc.lpszClassName, L"ImGui HUD overlay",
                               WS_POPUP, vx, vy, vw, vh,
                               nullptr, nullptr, hInst, nullptr);
        if (hwnd)
        {
            // Colour key: every black pixel of the framebuffer becomes
            // transparent, so only the HUD itself stays visible.
            SetLayeredWindowAttributes(hwnd, RGB(0, 0, 0), 0, LWA_COLORKEY);
            g_clickThrough = true;
        }
    }
    if (!hwnd)
    {
        hwnd = CreateWindowExW(0, wc.lpszClassName, L"ImGui overlay sandbox",
                               WS_OVERLAPPEDWINDOW, 120, 120, 900, 640,
                               nullptr, nullptr, hInst, nullptr);
    }
    if (!hwnd) return 1;

    HDC hdc = GetDC(hwnd);
    g_glrc = CreateGLContext(hdc);
    if (!g_glrc) { MessageBoxW(nullptr, L"Failed to create an OpenGL context", L"Error", MB_OK); return 1; }
    if (g_swapInterval) g_swapInterval(1);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr;                 // no files written next to the exe
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    ImGui::StyleColorsDark();

    ImGui_ImplWin32_Init(hwnd);
    ImGui_ImplOpenGL3_Init("#version 130");

    overlay::PlatformHooks hooks = MakeHooks(hwnd);
    ApplyWindowStyles(hwnd);
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);

    if (g_hudMode)
    {
        // The overlay window does not hold the keyboard focus, so the hotkeys
        // are registered globally.
        struct { int id; UINT key; const char* what; } hotkeys[] = {
            { 1, VK_INSERT, "INSERT" },
            { 2, VK_F1,     "F1" },
            { 3, VK_F2,     "F2" },
            { 4, VK_F12,    "F12" },
        };
        for (auto& hk : hotkeys)
            if (!RegisterHotKey(hwnd, hk.id, MOD_NOREPEAT, hk.key))
                overlay::AddLog("hotkey %s could not be registered", hk.what);
    }

    overlay::AddLog("overlay initialised (Win32%s)", g_hudMode ? ", HUD mode" : "");
    overlay::AddLog("OpenGL %s", (const char*)glGetString(GL_VERSION));

    DWORD last = GetTickCount();
    MSG msg = {};
    bool running = true;

    while (running)
    {
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE))
        {
            if (msg.message == WM_QUIT) { running = false; break; }
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if (!running) break;

        DWORD now = GetTickCount();
        float dt = (now - last) / 1000.0f;
        last = now;
        if (dt < 0.0f) dt = 0.0f;
        if (dt > 0.25f) dt = 0.25f;

        ImGui_ImplOpenGL3_NewFrame();
        ImGui_ImplWin32_NewFrame();
        ImGui::NewFrame();

        overlay::DrawUI(hooks, dt);
        if (g_hudMode) DrawHUD();

        ImGui::Render();
        RECT rect;
        GetClientRect(hwnd, &rect);
        glViewport(0, 0, rect.right, rect.bottom);
        if (g_hudMode)
            glClearColor(0.0f, 0.0f, 0.0f, 0.0f);   // colour key -> transparent
        else
            glClearColor(0.055f, 0.065f, 0.085f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
        SwapBuffers(hdc);
    }

    ImGui_ImplOpenGL3_Shutdown();
    ImGui_ImplWin32_Shutdown();
    ImGui::DestroyContext();

    wglMakeCurrent(nullptr, nullptr);
    wglDeleteContext(g_glrc);
    ReleaseDC(hwnd, hdc);
    DestroyWindow(hwnd);
    UnregisterClassW(wc.lpszClassName, hInst);
    return 0;
}

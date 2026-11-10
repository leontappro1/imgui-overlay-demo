// ImGui overlay sandbox - Win32 + OpenGL 3.0
// A self-contained Dear ImGui overlay for YOUR OWN application / prototype.
// The menu itself lives in ../shared/ui.cpp and is shared verbatim with the iOS build.
// Dear ImGui v1.92.0 (MIT). No game binaries, no injection, no hooks.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <GL/gl.h>

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

static void ApplyWindowStyles(HWND hwnd)
{
    LONG ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    ex &= ~(WS_EX_TRANSPARENT | WS_EX_LAYERED);
    if (g_clickThrough) ex |= (WS_EX_TRANSPARENT | WS_EX_LAYERED);
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
    h.hotkeys_line  = "INSERT click-through  |  F1 demo  |  F2 hide  |  F12 quit";
    h.backend_name  = "Win32 + OpenGL3";
    h.compiler_name = "MinGW-w64 GCC";
    h.window_note   = "Click-through uses WS_EX_TRANSPARENT | WS_EX_LAYERED, "
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

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (ImGui_ImplWin32_WndProcHandler(hwnd, msg, wp, lp)) return true;

    switch (msg)
    {
    case WM_SIZE:
        if (g_glrc && LOWORD(lp) > 0 && HIWORD(lp) > 0)
            glViewport(0, 0, LOWORD(lp), HIWORD(lp));
        return 0;

    case WM_KEYDOWN:
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
    ImGui_ImplWin32_EnableDpiAwareness();

    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(WNDCLASSEXW);
    wc.style = CS_OWNDC;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.lpszClassName = L"ImGuiOverlaySandbox";
    if (!RegisterClassExW(&wc)) return 1;

    HWND hwnd = CreateWindowExW(0, wc.lpszClassName, L"ImGui overlay sandbox",
                                WS_OVERLAPPEDWINDOW, 120, 120, 900, 640,
                                nullptr, nullptr, hInst, nullptr);
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

    overlay::AddLog("overlay initialised (Win32)");
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

        ImGui::Render();
        RECT rect;
        GetClientRect(hwnd, &rect);
        glViewport(0, 0, rect.right, rect.bottom);
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

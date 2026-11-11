// Platform-neutral UI, shared by the Win32 and iOS builds.
// Dear ImGui v1.92.0 (MIT).

#include "ui.h"

#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <string>
#include <vector>

namespace overlay
{
    struct State
    {
        bool showDemo = false;
        bool showMenu = true;
        bool enabled = true;
        int preset = 0;
        float value = 0.65f;
        float col[4] = { 0.20f, 0.75f, 0.95f, 1.0f };
        int frames = 0;
        float fps = 0.0f;
        float fpsTimer = 0.0f;
        float time = 0.0f;
        float fpsHistory[120] = {};
        int fpsHistoryIdx = 0;
        std::vector<std::string> log;
    };

    static State g;

    void AddLog(const char* fmt, ...)
    {
        char buf[256];
        va_list args;
        va_start(args, fmt);
        vsnprintf(buf, sizeof(buf), fmt, args);
        va_end(args);
        g.log.push_back(buf);
        if (g.log.size() > 60) g.log.erase(g.log.begin());
    }

    void ToggleDemo() { g.showDemo = !g.showDemo; }
    void ToggleMenu() { g.showMenu = !g.showMenu; }
    bool IsMenuVisible() { return g.showMenu; }
    float GetFPS() { return g.fps; }

    void DrawUI(const PlatformHooks& hooks, float dt)
    {
        ImGuiIO& io = ImGui::GetIO();

        g.time += dt;
        g.frames++;
        g.fpsTimer += dt;
        if (g.fpsTimer >= 0.10f)
        {
            g.fps = 1.0f / (dt > 0.0001f ? dt : 0.0001f);
            g.fpsHistory[g.fpsHistoryIdx] = g.fps;
            g.fpsHistoryIdx = (g.fpsHistoryIdx + 1) % IM_ARRAYSIZE(g.fpsHistory);
            g.fpsTimer = 0.0f;
        }

        if (g.showDemo) ImGui::ShowDemoWindow(&g.showDemo);
        if (!g.showMenu) return;

        const float pad = io.DisplaySize.x < 600.0f ? 12.0f : 24.0f;
        ImGui::SetNextWindowPos(ImVec2(pad, pad), ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowSize(ImVec2(460, 0), ImGuiCond_FirstUseEver);

        ImGui::Begin("ImGui // overlay sandbox", nullptr,
                     ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoCollapse);

        ImGui::TextColored(ImVec4(0.20f, 0.85f, 0.95f, 1.0f), "Dear ImGui 1.92.0");
        ImGui::SameLine();
        ImGui::TextDisabled("| %s", hooks.platform_line ? hooks.platform_line : "standalone");
        ImGui::Separator();

        ImGui::Text("FPS %.1f  (%.2f ms)   frames %d", g.fps,
                    1000.0f / (g.fps > 0.01f ? g.fps : 1.0f), g.frames);
        if (hooks.hotkeys_line)
        {
            ImGui::PushTextWrapPos(0.0f);
            ImGui::TextDisabled("%s", hooks.hotkeys_line);
            ImGui::PopTextWrapPos();
        }
        ImGui::Spacing();

        if (ImGui::BeginTabBar("tabs"))
        {
            if (ImGui::BeginTabItem("HUD"))
            {
                ImGui::Checkbox("Enabled", &g.enabled);
                ImGui::SameLine(140);
                ImGui::TextDisabled(g.enabled ? "running" : "paused");

                ImGui::SliderFloat("value", &g.value, 0.0f, 1.0f);
                ImGui::ColorEdit4("accent", g.col);

                const char* presets[] = { "default", "minimal", "verbose" };
                ImGui::Combo("preset", &g.preset, presets, IM_ARRAYSIZE(presets));

                float pulse = 0.5f + 0.5f * std::sin(g.time * 1.7f);
                ImGui::ProgressBar(pulse, ImVec2(-1, 0), "tick");
                ImGui::PlotLines("fps history", g.fpsHistory, IM_ARRAYSIZE(g.fpsHistory),
                                 g.fpsHistoryIdx, nullptr, 0.0f, 240.0f, ImVec2(-1, 48));

                if (ImGui::Button("add log line", ImVec2(130, 0)))
                    AddLog("frame %d, value %.2f, preset %d", g.frames, g.value, g.preset);
                ImGui::SameLine();
                if (ImGui::Button("clear", ImVec2(80, 0))) g.log.clear();

                ImGui::BeginChild("log", ImVec2(-1, 110), ImGuiChildFlags_Borders);
                for (const auto& line : g.log) ImGui::TextUnformatted(line.c_str());
                // Two ImGui contexts (app + PiP) share this log, so keep it
                // pinned to the newest line. PiP diagnostics are useless if
                // they are appended below the visible part of the child.
                ImGui::SetScrollHereY(1.0f);
                ImGui::EndChild();
                ImGui::EndTabItem();
            }

            if (ImGui::BeginTabItem("Window"))
            {
                for (int i = 0; i < hooks.toggle_count; i++)
                {
                    if (hooks.toggles[i].label && hooks.toggles[i].value)
                    {
                        if (ImGui::Checkbox(hooks.toggles[i].label, hooks.toggles[i].value)
                            && hooks.on_toggle)
                            hooks.on_toggle(hooks.user_data);
                    }
                }
                if (hooks.window_note)
                {
                    ImGui::Separator();
                    ImGui::PushTextWrapPos(0.0f);
                    ImGui::TextWrapped("%s", hooks.window_note);
                    ImGui::PopTextWrapPos();
                }
                ImGui::EndTabItem();
            }

            if (ImGui::BeginTabItem("About"))
            {
                ImGui::PushTextWrapPos(0.0f);
                ImGui::TextWrapped(
                    "This is a standalone overlay running in its OWN process. "
                    "Swap the platform/render backends and this exact UI code "
                    "runs on Windows, Android (GLES3/Vulkan) or iOS (Metal).");
                ImGui::PopTextWrapPos();
                ImGui::Spacing();
                ImGui::TextDisabled("backend:  %s", hooks.backend_name ? hooks.backend_name : "-");
                ImGui::TextDisabled("display:  %.0f x %.0f", io.DisplaySize.x, io.DisplaySize.y);
                ImGui::TextDisabled("compiler: %s", hooks.compiler_name ? hooks.compiler_name : "-");
                ImGui::EndTabItem();
            }
            ImGui::EndTabBar();
        }

        ImGui::End();
    }
}

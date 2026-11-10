# ImGui overlay sandbox

Рабочий, уже собранный пример оверлея на **Dear ImGui 1.92.0**: своё окно, свой процесс,
свой рендер. Win32 + OpenGL 3.0, компилируется MinGW-w64 без внешних зависимостей
(GLFW / SDL / vcpkg не нужны).

## Запуск

```
build/imgui_overlay.exe
```

| Клавиша | Действие |
|---|---|
| `INSERT` | click-through (окно поверх всех, клики проходят насквозь) |
| `F1` | окно-демо ImGui со всеми виджетами |
| `F2` | скрыть / показать меню |
| `F12` | выход |

`INSERT` удобен для проверки того, как оверлей ведёт себя поверх другого приложения.
Чтобы снова кликать по меню — нажми `INSERT` ещё раз.

## Пересборка

```bash
bash build.sh          # Git Bash / MSYS2
```
или `build.bat` из обычного `cmd`. Нужен только `g++` (MinGW-w64) в PATH.
Исходники ImGui лежат в `third_party/imgui/` — интернет при сборке не нужен.

## Структура

```
src/main.cpp                   Windows-обвязка: Win32 + WGL + OpenGL3
shared/ui.cpp, ui.h            ОБЩЕЕ меню (Win32 и iOS компилируют один файл)
third_party/imgui/             ядро Dear ImGui (MIT)
third_party/imgui/backends/    imgui_impl_win32 + imgui_impl_opengl3
build/imgui_overlay.exe        готовый бинарник
build.sh / build.bat           одна команда на сборку
ios/                           самодостаточный iOS / Xcode / Metal проект
```

## Что вообще нужно, чтобы завелся ImGui

Не «дамп» и не «вшитый файл». ImGui — это **библиотека, которая рисует интерфейс
в твоём цикле кадра**. Ей без разницы, игра это или блокнот. Нужны 4 вещи:

| Что | Здесь | Android | iOS |
|---|---|---|---|
| Ядро | `imgui.cpp` + draw/tables/widgets | то же | то же |
| Платформа (окно + ввод) | `imgui_impl_win32.cpp` | `imgui_impl_android.cpp` | UIKit + `imgui_impl_metal`, тачи маппятся в `main.mm` |
| Рендер | `imgui_impl_opengl3.cpp` | `imgui_impl_opengl3.cpp` (GLES3) или Vulkan | `imgui_impl_metal.mm` |
| Цикл кадра | `NewFrame → свой UI → Render → RenderDrawData` | в `android_app` / GLSurfaceView | `-[MTKViewDelegate drawInMTKView:]` |

В ImGui 1.92 отдельного `imgui_impl_ios` уже нет — iOS использует Metal-бэкенд и
самостоятельный маппинг тачей, как в официальном `example_apple_metal`.

Сам UI (`ImGui::Begin`, `SliderFloat`, `Checkbox`...) **переносится без изменений** —
он лежит в `shared/ui.cpp` и буквально один файл компилируется и в Windows-демо,
и в iOS-проекте. Это и есть ответ на «как это сделано»: `DrawUI()` рисует меню,
а обвязка платформы дёргает три вызова на кадр и очищает экран.

Чтобы окно стало по-настоящему прозрачным (а не тёмным, как здесь), на Windows
берут `WS_EX_LAYERED` + premultiplied alpha / DWM, на Android — прозрачную
GLSurfaceView поверх основного вью, на iOS — `MTKView` с `opaque = NO`.

## Про «дамп» и «вшить» — коротко и по факту

- **IPA ≠ APK.** IPA — пакет iOS, APK — Android. Мод-меню под Standoff 2 почти
  всегда делают под Android, т.е. нужен APK (`lib/arm64-v8a`), а не IPA.
- IPA из App Store **зашифрован FairPlay**. Так называемый «decrypted IPA» — это
  просто образ уже расшифрованного в памяти приложения, снятый с запущенного
  процесса. Для своего собственного приложения это нормальная практика отладки;
  с чужим онлайн-клиентом я этим не занимаюсь.
- Старую версию 1.1.0 официально не достать: магазины отдают только текущую
  сборку, а сервер давным-давно не принимает клиент той версии. Даже идеально
  «вшитый» билд 1.1.0 просто не залогинится.
- «Просто вшить» не работает ещё и потому, что после любой модификации ломается
  подпись, а дальше включаются проверка целостности, античит и серверная
  валидация. Плюс сторонние «готовые IPA/APK» с форумов — перепакованные файлы
  с неизвестным содержимым.

Поэтому помогать с модификацией клиента онлайн-игры и обходом античита не буду:
это бан аккаунта и испорченные матчи другим людям. А вот поднять ImGui в **своём**
приложении, сделать дебаг-HUD для своего движка или разобрать по косточкам этот
пример — всегда пожалуйста.

## iOS-вариант готов

`ios/` — самодостаточный проект: UIKit + `MTKView` + Metal, прозрачный оверлей
поверх обычного `UIView`, тач-ввод, CMake → Xcode. Меню то же самое
(`ios/shared/ui.cpp` — копия `shared/ui.cpp`). Подробности, команды сборки и
**конкретный путь к легальному `.ipa`** — в `ios/README.md`:

```bash
cd ios && ./build_ios.sh simulator && open build-simulator/ImGuiOverlayIOS.xcodeproj
# .ipa: DEV_TEAM=ABCDE12345 ./build_ipa.sh
```

Локально `.ipa` на Windows не собрать (Xcode только на macOS, WSL не помогает —
это Linux, а не macOS). Но **с Windows собрать можно через CI**: в
`.github/workflows/ios-build.yml` лежит воркфлоу для macOS-раннера GitHub Actions,
который собирает проект и выкладывает архив артефактом. Пуш → Actions →
Run workflow → скачать. Без Mac и без Apple-аккаунта для симуляторной сборки.
Подробности и таблица вариантов — в `ios/README.md`.

## Куда дальше

- Хочешь Android-вариант: тот же `DrawUI()`, бэкенды `imgui_impl_android` +
  GLES3, сборка через Android Studio + NDK / CMake.
- Хочешь оверлей поверх другого desktop-приложения: добавь к этому примеру
  прозрачность и привязку к чужому HWND.

Dear ImGui: https://github.com/ocornut/imgui (MIT license)

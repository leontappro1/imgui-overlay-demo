# ImGui overlay — iOS / Metal

Папка **самодостаточная**: скопируй `ios/` на Mac целиком, больше ничего тащить не надо.
Внутри уже лежит ядро Dear ImGui 1.92.0, Metal-бэкенд и общий код меню.

Это **своё приложение со своим бандлом**. Меню берётся из `shared/ui.cpp` — ровно тот же
файл, что компилируется в Windows-демо. Меняется только обвязка.

## Что нужно

| | |
|---|---|
| Машина | Mac с Xcode 14+ и CMake 3.20+ (`brew install cmake`) |
| Аккаунт | для симулятора — не нужен вообще; для девайса — бесплатный Apple ID хватает (подпись на 7 дней) |
| Team ID | `Xcode → Settings → Accounts → выбери команду → Team ID`. Нужен только для девайса / `.ipa` |
| Языки | C++17 + Objective-C++ (.mm), ARC включён в CMake |

Windows не соберёт `.ipa` локально — Xcode и iOS SDK есть только на macOS. Но
**собрать с Windows можно**, см. следующий раздел.

## У меня Windows — как собрать без Mac

**WSL не поможет, и вот почему.** Встроенный линукс — это ядро Linux под Windows,
а не macOS. `xcodebuild`, iOS SDK, iOS-фреймворки (UIKit, MetalKit) и `codesign`
поставляются только Apple, только в составе Xcode, только под macOS — и по лицензии
только на технике Apple. Никаким кросс-компилятором, clang'ом из WSL или CMake
тулчейном их не заменить. Виртуалка с macOS на PC — тоже мимо лицензии, не советую.

WSL при этом **полезен для своего**: проверять общий C++-код (`shared/ui.cpp`),
гонять Linux-сборку ImGui, clang-format, статический анализ. Но не для `.ipa`.

**Рабочий обход — macOS-раннер в GitHub Actions.** В репозитории уже лежит
`.github/workflows/ios-build.yml`: он поднимает `macos-15`, собирает проект и
выкладывает готовый архив артефактом. Ты только пушишь с Windows и скачиваешь.

Репозиторий уже проинициализирован локально (ветка `main`, коммиты готовы), так что
**просто запусти `push.bat` двойным кликом**, введи логин и токен.

⚠️ GitHub с 2021 года **не принимает пароль**, нужен Personal Access Token:
`https://github.com/settings/tokens/new?scopes=repo` → classic, галочка `repo` →
Generate token → скопировать `ghp_...`. Это его и вставляй, не пароль аккаунта.

В этой сборке PortableGit прописан `credential.helper=manager`, но самого
`git-credential-manager` нет — поэтому браузерный логин не открывается и git падает
с `Invalid username or token`. `push.bat` обходит это: отключает системный конфиг
через `GIT_CONFIG_NOSYSTEM=1` и передаёт токен прямо в URL пуша. Токен **не**
сохраняется в `.git/config` (сразу после пуша `remote` перезаписывается без него).

Если пушить вручную, та же логика одной командой:

```bash
GIT_CONFIG_NOSYSTEM=1 git push "https://USER:TOKEN@github.com/USER/imgui-overlay-demo.git" main
```

Дальше: **репозиторий → Actions → Build iOS overlay → Run workflow** → после
сборки скачиваешь артефакт `imgui-overlay-ios-simulator-ipa`. Внутри
`ImGuiOverlayIOS-simulator.ipa`.

| Путь | Нужен Mac | Нужен аккаунт | Что получишь |
|---|---|---|---|
| Actions, job `simulator` | нет | **нет вообще** | неподписанный симуляторный `.ipa`: проверить, что проект реально собирается, посмотреть структуру `Payload/*.app` |
| Actions, job `device` (галочка `signed_device`) | нет | платный Apple Developer + p12 + профиль | подписанный `.ipa`, ставится на зарегистрированный девайс |
| Локальный Mac + `build_ipa.sh` | да | бесплатный Apple ID | `.ipa` с подписью на 7 дней |
| WSL / кросс-сборка на Windows | — | — | невозможно, см. выше |

⚠️ Симуляторный `.ipa` — это срез под `iphonesimulator` без подписи. На телефон
его **не поставить**, он для проверки сборки и содержимого бандла. Для девайса
нужны подпись и профиль: включи `signed_device` и добавь секреты
`IOS_CERT_P12_BASE64`, `IOS_CERT_PASSWORD`, `IOS_PROVISION_BASE64`, `IOS_TEAM_ID`
и переменную `IOS_BUNDLE_ID` (список есть в шапке воркфлоу).

Тот же симуляторный билд можно сделать и локально на любом Mac без аккаунта:

```bash
cd ios && ./build_sim.sh     # -> ios/out/ImGuiOverlayIOS-simulator.ipa
```

## Быстрый старт (симулятор, без аккаунта)

```bash
cd ios
chmod +x build_ios.sh build_ipa.sh
./build_ios.sh simulator
open build-simulator/ImGuiOverlayIOS.xcodeproj
```

В Xcode: выбери любой iPhone-симулятор → `Cmd+R`. Увидишь тёмную подложку
«your app content here» и ImGui-меню поверх неё — `MTKView` с `opaque = NO`,
то есть настоящий оверлей, а не просто окно.

Касание = левая кнопка мыши (маппинг в `main.mm`), слайдеры и кнопки работают
пальцем. Вкладка **Window** переключает `opaque background` — видно разницу.

## Где взять `.ipa` — конкретно

`.ipa` — это просто zip-архив твоего собственного `.app`. Берётся из Xcode:

**Вариант A, через UI (проще):**
1. `./build_ios.sh device`
2. `open build-device/ImGuiOverlayIOS.xcodeproj`
3. В `Signing & Capabilities` выбери свою Team, поменяй Bundle ID на уникальный
   (не `com.example.*`).
4. `Product → Archive` → откроется Organizer → `Distribute App` →
   `Development` (или `Ad Hoc`) → `Export` → выбираешь папку.
5. В той папке лежит `ImGuiOverlayIOS.ipa`. Всё, это и есть искомый файл.

**Вариант B, из терминала:**

```bash
DEV_TEAM=ABCDE12345 ./build_ipa.sh
# -> build/ipa/ImGuiOverlayIOS.ipa
```

`ExportOptions.plist` с `method = development`; скрипт подставит твой Team ID.
Поставить на зарегистрированный девайс: `Xcode → Window → Devices and Simulators → +`
или `Apple Configurator 2`.

| method | Кому | Нужен платный аккаунт |
|---|---|---|
| `development` | только зарегистрированные девайсы | нет |
| `ad-hoc` | до 100 девайсов | да |
| `app-store` | App Store / TestFlight | да |

**Важно:** так получается IPA **своего** приложения. Чужую игру из App Store так
не вытащить — там FairPlay-шифрование, а «дамп» снимается с запущенного процесса
на девайсе. Я этим не занимаюсь: модификация онлайн-клиента = бан, проверка
подписи, античит, серверная валидация, да и старая версия 1.1.0 всё равно на
сервер не зайдёт. Подробнее в корневом `README.md`.

## Нюанс ImGui 1.92, который стоит знать

Отдельного `imgui_impl_ios.h/.mm` в этой версии **уже нет**. Официальный пример
`examples/example_apple_metal` делает так:

- платформа: голый **UIKit** (`UIViewController` + `UIWindow`), без `imgui_impl_osx`;
- ввод: самостоятельный маппинг `touchesBegan/Moved/Ended` → `io.AddMousePosEvent`
  + `io.AddMouseButtonEvent` (в `main.mm`);
- рендер: `imgui_impl_metal` — один и тот же файл для iOS и macOS.

`imgui_impl_osx.*` лежит в `third_party/imgui/backends/` только для справки,
**в сборку не входит** (он macOS-only). Папка `ref/` — оригинальный пример
из репозитория ImGui, тоже не компилируется, просто чтобы было с чем сравнить.

## Структура

```
ios/
├── main.mm                      UIKit + MTKView + Metal + touch mapping
├── shared/ui.cpp, ui.h          ОБЩЕЕ меню (то же, что на Windows)
├── third_party/imgui/           ядро ImGui 1.92.0
│   └── backends/imgui_impl_metal.*   ← единственный бэкенд рендера
├── Info.plist                   bundle id / ориентации / launch screen
├── CMakeLists.txt               генератор Xcode, фреймворки, signing
├── ExportOptions.plist          для экспорта .ipa
├── build_ios.sh                 cmake -G Xcode (simulator | device)
├── build_ipa.sh                 archive + exportArchive -> .ipa
└── ref/                         официальный пример для сравнения
```

## Что поменять под себя

- Меню — `shared/ui.cpp` (правь один файл, обе платформы подхватят).
- Прозрачность/подложка — `loadView` и `ApplyViewSettings()` в `main.mm`.
- Шрифт под пальцы — `style.FontSizeBase = 17.0f` + `ScaleAllSizes(1.15f)`.
- Bundle ID и Team — `-DBUNDLE_ID=... -DDEV_TEAM=...` или в Xcode.

Dear ImGui: https://github.com/ocornut/imgui (MIT)

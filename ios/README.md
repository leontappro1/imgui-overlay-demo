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
сборки внизу страницы запуска появится блок **Artifacts**, и там уже **два** архива:

| Артефакт | Внутри | Куда |
|---|---|---|
| `imgui-overlay-ios-simulator-ipa` | `ImGuiOverlayIOS-simulator.ipa` | только в симулятор Xcode |
| `imgui-overlay-ios-device-unsigned-ipa` | `ImGuiOverlayIOS-device-unsigned.ipa` | **на iPhone через ESign / Sideloadly / AltStore** |

Скачивать надо будучи залогиненным в GitHub: у артефактов своя авторизация, по
голой ссылке из API без токена будет `401`. Архив — это zip, внутри лежит сам
`.ipa`; распакуй внешний zip, а **внутренний `.ipa` не распаковывай** — ESign ест
именно `.ipa`.

| Путь | Нужен Mac | Нужен аккаунт | Что получишь |
|---|---|---|---|
| Actions, job `simulator` | нет | **нет вообще** | неподписанный симуляторный `.ipa`: проверить, что проект реально собирается, посмотреть структуру `Payload/*.app` |
| Actions, job `device_unsigned` | нет | **нет на этапе сборки** | неподписанный `arm64 / iphoneos` `.ipa` — его и подписываешь в ESign |
| Actions, job `device` (галочка `signed_device`) | нет | платный Apple Developer + p12 + профиль | уже подписанный `.ipa` |
| Локальный Mac + `build_ipa.sh` | да | бесплатный Apple ID | `.ipa` с подписью на 7 дней |
| WSL / кросс-сборка на Windows | — | — | невозможно, см. выше |

⚠️ **Симуляторный `.ipa` на телефон не ставится никак.** У его Mach-O в
`LC_BUILD_VERSION` платформа `iOSSimulator`, а не `iOS`. Подпись добавляет только
`_CodeSignature` и `embedded.mobileprovision` — ни архитектуру, ни платформу
бинарника она не меняет. ESign тут бессилен. Нужен именно `device_unsigned`:
`arm64`, SDK `iphoneos`.

Оба билда можно сделать и локально на любом Mac без аккаунта:

```bash
cd ios && ./build_sim.sh               # -> ios/out/ImGuiOverlayIOS-simulator.ipa
cd ios && ./build_device_unsigned.sh   # -> ios/out-dev/ImGuiOverlayIOS-device-unsigned.ipa
```

## Скачать и поставить на iPhone через ESign

По шагам, от пуша до иконки на домашнем экране.

**1. Взять правильный `.ipa`.** После пуша `push.bat` открой
`https://github.com/<твой-логин>/imgui-overlay-demo/actions`, дождись зелёной
джобы `Device .ipa (unsigned, for ESign / Sideloadly)` и скачай артефакт
`imgui-overlay-ios-device-unsigned-ipa`. Распакуй внешний zip (на телефоне это
«Файлы» → тап по архиву) — получится `ImGuiOverlayIOS-device-unsigned.ipa`.
**Не** бери `...-simulator-ipa`.

**2. Что должно быть в ESign заранее.** ESign не подписывает «из ниоткуда»: ему
нужны сертификат и профиль. В `ESign → Импорт / Настройки` загрузи:

- `.p12` — Apple Development-сертификат вместе с приватным ключом, и пароль к нему;
- `.mobileprovision` — профиль с подходящим `application-identifier` / bundle id.

Бесплатный Apple ID даёт Development-сертификат на 7 дней и профиль, привязанный
к UDID конкретного устройства; обычно их получают через Sideloadly / AltStore на
ПК, платный аккаунт — через developer.apple.com. Без этих двух файлов ESign
покажет ошибку подписи, и это не проблема собранного `.ipa`.

**3. Подписать.**

1. `ESign → Файлы / Загрузки` → найти `.ipa` → меню `⋯` → **Подписать / Sign**.
2. Выбрать сертификат и профиль. Bundle ID можно заменить на уникальный
   (`com.твоёимя.overlay`) — ESign перепишет `CFBundleIdentifier` в `Info.plist`;
   главное, чтобы он совпадал с профилем (или чтобы профиль был wildcard `*`).
3. Дождаться `Signed successfully`, появится `..._signed.ipa`.

**4. Установить.** Открыть подписанный файл → **Install** → иконка на домашнем
экране. Если iOS пишет «Untrusted Developer»: `Настройки → Основные → VPN и
управление устройством → [твой сертификат] → Доверять`.

**5. Переподпись.** Бесплатная подпись живёт 7 дней, потом приложение перестанет
запускаться — повтори шаг 3 (у ESign есть автоподпись по расписанию). Платный
аккаунт даёт год.

Альтернативы: Sideloadly / AltStore с ПК или `ios/build_ipa.sh` на Mac (сразу
подписанный `.ipa` через Xcode). Все они работают с тем же device-артефактом.

Если джоба `device_unsigned` красная — не пугайся, `simulator` при этом остаётся
зелёной (в воркфлоу стоит `continue-on-error`). Скачай артефакт
`ios-device-build-log` или глянь ошибки в Annotations рана и скинь мне текст.

⚠️ Это по-прежнему **твоё отдельное приложение**: оверлей рисуется внутри
собственного `MTKView`, доступа к чужому процессу у него нет (песочница iOS).
Никакого отношения к чужой игре этот `.ipa` не имеет.

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
├── build_ipa.sh                 archive + exportArchive -> подписанный .ipa
├── build_sim.sh                 CI: неподписанный simulator .ipa
├── build_device_unsigned.sh     CI: неподписанный arm64/iphoneos .ipa для ESign
└── ref/                         официальный пример для сравнения
```

Скрипты `build_sim.sh` / `build_device_unsigned.sh` ничего не подписывают
(`CODE_SIGNING_ALLOWED=NO`), поэтому ранятся и без Apple-аккаунта. Разница ровно
в `-DCMAKE_OSX_SYSROOT` и `-sdk`: `iphonesimulator` против `iphoneos`.

## Что поменять под себя

- Меню — `shared/ui.cpp` (правь один файл, обе платформы подхватят).
- Прозрачность/подложка — `loadView` и `ApplyViewSettings()` в `main.mm`.
- Шрифт под пальцы — `style.FontSizeBase = 17.0f` + `ScaleAllSizes(1.15f)`.
- Bundle ID и Team — `-DBUNDLE_ID=... -DDEV_TEAM=...` или в Xcode.

Dear ImGui: https://github.com/ocornut/imgui (MIT)

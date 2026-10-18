# GadgetForge — prompt-to-ESP32 studio for macOS

A native macOS app (SwiftUI, macOS 15+, Intel & Apple Silicon) that turns a
plain-language prompt into an ESP32-S3 device design:

1. **Prompt** — describe the device ("battery-powered ESP32-S3 temperature logger with OLED and two buttons").
2. **Design** — Gemini generates a parts list, ESP32-S3 pin assignments, and wiring plan. The app validates pins locally (reserved USB/flash pins, strapping pins, ADC2/Wi-Fi conflicts, duplicates, unassigned pins).
3. **Enclosure** — parametric tray + lid auto-sized to the parts, with a 3D SceneKit preview. Exports a binary **STL** for your 3D printer.
4. **Simulate** — exports a Wokwi `diagram.json` wired from your pin map. Paste it into a new ESP32-S3 project at wokwi.com and press Play.
5. **PCB** — one-click 2-layer auto-router (Manhattan maze, 0.35 mm traces, vias, DRC with clearance checks and unrouted-net reporting). Exports a **Gerber ZIP** (top/bottom copper, silkscreen, outline, Excellon drills) ready to upload to PCBWay.
6. **Build files** — BOM CSV, Arduino firmware stub with your pin defines, and PCBWay ordering notes.

## Build it (on your Intel MacBook, macOS 15)

1. Copy this folder to the Mac. Open `GadgetForge.xcodeproj` in Xcode 16+.
2. In the project editor → Signing & Capabilities, select your Apple ID team (free tier is fine for running locally).
3. Build & run (⌘R). On Intel it builds x86_64 automatically.
4. Open Settings in the app, paste a Gemini API key (free at aistudio.google.com), hit Save. The key lives only in your login keychain.

No backend, no paid APIs, no telemetry.

## CI build (GitHub Actions)

Every push to `main` builds an Intel (x86_64) Release build on a macOS 15
runner and publishes it under Releases as `GadgetForge-mac-intel.zip`.
The CI build is **ad-hoc signed** (no Apple Developer certificate in CI):
on first launch, right-click the app → Open.

For a Developer ID signed/notarized build, add your certificate as repo
secrets and update `.github/workflows/build-macos.yml`.

## Honest limits (v1)

- The AI drafts the design; **you verify it**. The pin validator catches common ESP32-S3 mistakes but it is not a substitute for checking datasheets.
- Wokwi simulation covers common parts (OLED, DHT22, buttons, LEDs, buzzer, servo, ultrasonic, RTC). Exotic parts simulate as "not available" — wire a stand-in.
- The enclosure is a simple tray + lid sized to the parts, not a precision-fit case with display cutouts. Good for a first print; refine in CAD after.
- The auto-router handles low-speed module carrier boards. It is not a replacement for careful review: always open the Gerbers in a viewer (e.g. gerblook.org) before ordering, and use KiCad for anything dense, high-speed, or analog-sensitive.

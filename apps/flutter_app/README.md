# Voice Assistant: Flutter app

Client for Android, iOS, Windows, macOS, Linux and the web.

```
lib/
  main.dart, app.dart        Entry point and MaterialApp.router
  core/                      Config, Dio API client, secure token storage, theme, router, shared widgets
  domain/                    Entities, repository interfaces, voice session state machine + transport contract
  data/                      JSON mappers and API-backed repository implementations
  providers/                 Dependency wiring, auth, preferences, theme, provider catalog
  features/
    auth/                    Sign-in and registration
    shell/                   Responsive frame: sidebar (wide) / drawer (narrow), keyboard shortcuts
    chat/                    Conversation list + chat (application/ controllers, presentation/ widgets)
    voice/                   Full-screen voice mode, orb visualisation, voice settings
    settings/                Appearance, voice, account, server status
test/                        Unit, controller and widget tests (fakes in test/support/)
```

Material widgets come from `package:material_ui` (Flutter 3.47+ split Material
out of the framework; `package:flutter/material.dart` is deprecated).

```powershell
flutter pub get
flutter run -d chrome                     # backend expected at http://localhost:8000
flutter run --dart-define=API_BASE_URL=https://api.example.com
flutter analyze
flutter test
```

See [../../docs/setup.md](../../docs/setup.md) for platform builds.

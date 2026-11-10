# Kniha jázd – Drive Log Cloud

Flutter mobile app for simple vehicle mileage logging. The project follows an offline-first approach: trips and GPS points are intended to be stored on the phone, while cloud backup will remain optional.

## Current features

- Slovak calendar from the beginning of the current year;
- selected-day detail view;
- editing of route, time, mileage, and trip type;
- monthly fuel-consumption estimate based on the configured average consumption;
- Android detection of the “in vehicle” state; after one-time approval in Settings, it starts GPS tracking only for driving;
- GPS tracking while the app is running, including permission and location-quality checks and a 20-minute traffic-jam stop tolerance;
- local SQLite storage for trips and vehicle settings, retained after the app is closed or restarted;
- an empty trip log ready for real journeys.

## Verification

```powershell
flutter analyze
flutter test
flutter run -d <id-zariadenia>
```

## Next step

Add optional cloud backup and Excel export, then complete a dedicated Android service for tracking after the app has been closed. The full plan is in [TASKS.md](TASKS.md).

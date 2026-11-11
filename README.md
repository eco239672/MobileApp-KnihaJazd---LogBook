# Kniha jázd – Drive Log Cloud

Flutter mobile app for simple vehicle mileage logging. The project follows an
offline-first approach: trips and vehicle settings are stored on the phone,
while cloud backup remains optional.

## Current features

- Slovak calendar from the beginning of the current year;
- selected-day detail view;
- editing of route, time, mileage, and trip type;
- monthly fuel-consumption estimate based on the configured average consumption;
- Android detection of the “in vehicle” state;
- automatic Android GPS tracking in a foreground service, including a persistent
  notification, location-quality checks, a 20-minute traffic-jam stop
  tolerance, and recovery of an interrupted tracking process;
- local SQLite storage for trips and vehicle settings, retained after the app is closed or restarted;
- Google account sign-in and on-demand Firestore cloud synchronization for
  trips and vehicle settings (requires a configured Android SHA-1 fingerprint
  and Firestore Security Rules);
- an empty trip log ready for real journeys.
- Excel export with a yearly overview and one worksheet for every recorded month.

## Verification

```powershell
flutter analyze
flutter test
flutter run -d <id-zariadenia>
flutter build apk --debug
```

## Firebase data layout

Each signed-in user can access only their own data:

```text
users/{uid}/jazdy/{cloudTripId}
users/{uid}/profil/vozidlo
```

The app keeps the SQLite database on the phone as the primary offline store.
When a signed-in user saves a trip or vehicle settings, it also attempts a
cloud sync. A manual sync button is available in Settings.

## Next step

Test automatic tracking on a physical Android device during real driving,
including phone calls, music playback, poor GPS coverage, and an interrupted
internet connection. The broader roadmap is in [TASKS.md](TASKS.md).

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
- electronic trip log data (Slovak rules from 1 January 2026): vehicle VIN,
  registration number, name and type, category, default driver and odometer at
  the start of record keeping; per trip a yearly sequence number, driver,
  purpose, and odometer before and after (computed from the starting odometer;
  a real odometer reading entered for a trip resets the running total);
- addresses instead of GPS coordinates: the phone's free Android Geocoder fills
  them in when internet is available (coordinates stay in the trip as proof);
  favourite places (Home, Work…) within 150 m replace the address with a name;
- optional car recognition via Bluetooth: if the car's Bluetooth device is
  selected, a GPS trip without a connection to it is saved as private.

## Trip-logic simulation (no phone needed)

`android/app/src/test/.../ZaznamJazdyTest.kt` drives the pure-Kotlin trip logic
(`ZaznamJazdy`) through fixed scenarios and 500 random trips between real
Slovak municipalities (`android/app/src/test/resources/obce_sk.csv`, data from
OpenStreetMap): waiting before departure, traffic lights, jams, tunnels,
inaccurate GPS points, false “left the vehicle” events and Android stopping the
tracking service mid-trip. The log is written to `build/simulacia-jazdy.txt`.

```powershell
cd android
.\gradlew.bat :app:testDebugUnitTest
```

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

The app keeps the SQLite database on the phone as the primary, permanent store
(trips are kept for years, e.g. for tax records). Firestore is the backup and the
way to share data between devices; its own offline cache is disabled.

Synchronization (when signed in):

- runs on app start, when the app returns to the foreground, after every change
  and every 10 minutes while the app is open; a manual button is in Settings;
- downloads only documents changed since the last download (`aktualizovane`,
  server time, with a 5-minute overlap), then uploads only local changes
  (`odoslane = 0` in SQLite);
- conflicts: the newer edit wins (`upravene`, device time in ms);
- deleting a trip keeps a tombstone (`vymazane: true`) in Firestore so other
  devices delete it too; locally the row is removed once the deletion is uploaded;
- without a connection, changes stay marked in SQLite and are sent later.

## Next step

Test automatic tracking on a physical Android device during real driving,
including phone calls, music playback, poor GPS coverage, and an interrupted
internet connection. The broader roadmap is in [TASKS.md](TASKS.md).

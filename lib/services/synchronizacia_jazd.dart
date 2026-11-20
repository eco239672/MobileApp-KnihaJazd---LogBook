import '../models/synchronizacia.dart';
import 'cloudova_synchronizacia.dart';
import 'lokalne_ulozisko.dart';

/// Dorovnanie jázd a nastavení vozidla medzi telefónom (SQLite) a cloudom.
///
/// Najprv stiahne zmeny z cloudu (novšia úprava vyhráva), potom odošle to,
/// čo sa zmenilo v telefóne. Do cloudu ide len to, čo sa zmenilo.
class SynchronizaciaJazd {
  SynchronizaciaJazd({required this.ulozisko, required this.cloud});

  final LokalneUlozisko ulozisko;
  final CloudovaSynchronizacia cloud;

  // Synchronizáciu môže vyvolať viac vecí naraz (štart, zmena, časovač,
  // tlačidlo). Reťazením bežia po jednej, inak by sa zmeny odoslali dvakrát.
  Future<void> _posledna = Future.value();

  /// Spustí synchronizáciu po skončení predchádzajúcej. Vráti true, ak sa
  /// v telefóne niečo zmenilo podľa cloudu (treba znova načítať údaje).
  Future<bool> synchronizovat() {
    final dalsia = _posledna.then((_) => _synchronizovatTeraz());
    // Chyba jednej synchronizácie nesmie zablokovať ďalšie v poradí.
    _posledna = dalsia.then<void>((_) {}, onError: (Object _) {});
    return dalsia;
  }

  Future<bool> _synchronizovatTeraz() async {
    final stiahnute = await cloud.stiahnutJazdy(
      odMillis: await ulozisko.nacitatCasStiahnutia(),
    );
    var zmenene = await ulozisko.aplikovatJazdyZCloudu(stiahnute.jazdy);
    final najnovsi = stiahnute.najnovsiCasMillis;
    if (najnovsi != null) await ulozisko.ulozitCasStiahnutia(najnovsi);

    final vzdialeneNastavenia = await cloud.stiahnutNastavenia();
    if (vzdialeneNastavenia != null &&
        await ulozisko.aplikovatNastaveniaZCloudu(vzdialeneNastavenia)) {
      zmenene = true;
    }

    final neodoslaneJazdy = await ulozisko.nacitatNeodoslaneJazdy();
    if (neodoslaneJazdy.isNotEmpty) {
      await cloud.odoslatJazdy(neodoslaneJazdy);
      await ulozisko.oznacitOdoslane(neodoslaneJazdy);
    }
    final ZmenaNastaveni? neodoslaneNastavenia = await ulozisko
        .nacitatNeodoslaneNastavenia();
    if (neodoslaneNastavenia != null) {
      await cloud.odoslatNastavenia(neodoslaneNastavenia);
      await ulozisko.oznacitNastaveniaOdoslane(neodoslaneNastavenia.upravene);
    }
    return zmenene;
  }
}

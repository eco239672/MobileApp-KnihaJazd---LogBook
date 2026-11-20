import '../models/jazda.dart';
import '../models/nastavenia_vozidla.dart';
import 'doplnenie_adries.dart';
import 'gps_tracking_service.dart';

/// Z dokončeného GPS záznamu vytvorí jazdu do knihy jázd.
///
/// Odkiaľ/kam sú najprv súradnice (zostanú v jazde ako dôkaz miesta); obľúbené
/// miesto sa dosadí hneď, adresa sa doplní neskôr, keď bude internet.
/// [identifikator] z natívnej služby zaručí, že sa ten istý záznam pri
/// opakovanom prenose neuloží dvakrát.
Jazda jazdaZGps(
  DokoncenaGpsJazda gps, {
  String? identifikator,
  List<OblubeneMiesto> oblubeneMiesta = const [],
}) {
  String cas(DateTime datum) =>
      '${datum.hour.toString().padLeft(2, '0')}:${datum.minute.toString().padLeft(2, '0')}';
  final odkial = formatovatSuradnice(
    gps.zaciatok.latitude,
    gps.zaciatok.longitude,
  );
  final kam = formatovatSuradnice(gps.koniec.latitude, gps.koniec.longitude);
  // Ak je nastavené Bluetooth auta a telefón k nemu počas jazdy nebol
  // pripojený, išlo pravdepodobne o iné vozidlo (autobus, cudzie auto).
  final ineVozidlo = gps.autoBluetooth == false;
  return DoplnenieAdries.pouzitOblubeneMiesta(
    Jazda(
      datum: gps.zaciatok.cas,
      odkial: odkial,
      kam: kam,
      odkialSuradnice: odkial,
      kamSuradnice: kam,
      zaciatok: cas(gps.zaciatok.cas),
      koniec: cas(gps.koniec.cas),
      kilometre: gps.prejdeneMetre / 1000,
      typ: ineVozidlo ? TypJazdy.sukromna : TypJazdy.sluzobna,
      autoBluetooth: gps.autoBluetooth,
      cloudId: identifikator == null ? null : 'gps-$identifikator',
    ),
    oblubeneMiesta,
  );
}

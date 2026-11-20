import '../models/jazda.dart';
import '../models/nastavenia_vozidla.dart';

/// Zistí adresu k súradniciam (v aplikácii Geocoder telefónu, v testoch
/// náhrada). Vráti null, ak sa adresa teraz nedá zistiť (napr. bez internetu),
/// a prázdny text, ak pre toto miesto žiadna adresa neexistuje.
typedef ZistitAdresu = Future<String?> Function(double latitude, double longitude);

/// Nahradí súradnice v „odkiaľ/kam“ názvom obľúbeného miesta alebo adresou.
///
/// Mení len miesta, ktoré sú ešte v súradniciach: adresu, ktorú používateľ
/// prepísal ručne, nikdy neprepíše. Súradnice zostanú v jazde ako dôkaz.
class DoplnenieAdries {
  DoplnenieAdries({required this.zistitAdresu});

  final ZistitAdresu zistitAdresu;

  /// Obľúbené miesta sa dosadia hneď (bez internetu), napr. pri uložení jazdy.
  static Jazda pouzitOblubeneMiesta(
    Jazda jazda,
    List<OblubeneMiesto> oblubeneMiesta,
  ) {
    if (oblubeneMiesta.isEmpty) return jazda;
    String? nazov(String? suradnice) {
      final bod = precitatSuradnice(suradnice);
      if (bod == null) return null;
      return OblubeneMiesto.najblizsie(
        oblubeneMiesta,
        bod.latitude,
        bod.longitude,
      )?.nazov;
    }

    final odkial = jazda.odkialJeSuradnica ? nazov(jazda.odkialSuradnice) : null;
    final kam = jazda.kamJeSuradnica ? nazov(jazda.kamSuradnice) : null;
    if (odkial == null && kam == null) return jazda;
    return jazda.copyWith(odkial: odkial, kam: kam);
  }

  /// Doplní adresy jazdám, ktoré ich ešte nemajú. Vráti len zmenené jazdy.
  ///
  /// [maxPoziadaviek] obmedzuje počet dopytov na adresu za jedno spustenie,
  /// aby prvé doplnenie stoviek starších jázd nezaťažilo telefón naraz.
  Future<List<Jazda>> doplnit(
    Iterable<Jazda> jazdy,
    List<OblubeneMiesto> oblubeneMiesta, {
    int maxPoziadaviek = 40,
  }) async {
    final zmenene = <Jazda>[];
    final pamat = <String, String?>{};
    var poziadavky = 0;
    var bezInternetu = false;

    Future<String?> adresa(String? suradnice) async {
      final bod = precitatSuradnice(suradnice);
      if (bod == null) return null;
      final oblubene = OblubeneMiesto.najblizsie(
        oblubeneMiesta,
        bod.latitude,
        bod.longitude,
      );
      if (oblubene != null) return oblubene.nazov;
      // Tie isté súradnice (napr. domov) sa nepýtajú opakovane.
      final kluc = formatovatSuradnice(bod.latitude, bod.longitude);
      if (pamat.containsKey(kluc)) return pamat[kluc];
      if (bezInternetu || poziadavky >= maxPoziadaviek) return null;
      poziadavky++;
      final vysledok = (await zistitAdresu(
        bod.latitude,
        bod.longitude,
      ))?.trim();
      // Zlyhanie väčšinou znamená, že nie je internet: ďalšie jazdy skúsime
      // až pri ďalšom spustení. Miesto bez adresy ostane v súradniciach.
      if (vysledok == null) bezInternetu = true;
      final najdena = vysledok == null || vysledok.isEmpty ? null : vysledok;
      pamat[kluc] = najdena;
      return najdena;
    }

    // Najnovšie jazdy prvé, aby sa adresy objavili najprv tam, kde ich
    // používateľ práve pozerá.
    final zoradene = [...jazdy]..sort((a, b) => porovnatJazdy(b, a));
    for (final jazda in zoradene) {
      if (!jazda.odkialJeSuradnica && !jazda.kamJeSuradnica) continue;
      final odkial = jazda.odkialJeSuradnica
          ? await adresa(jazda.odkialSuradnice)
          : null;
      final kam = jazda.kamJeSuradnica ? await adresa(jazda.kamSuradnice) : null;
      if (odkial == null && kam == null) continue;
      zmenene.add(jazda.copyWith(odkial: odkial, kam: kam));
    }
    return zmenene;
  }
}

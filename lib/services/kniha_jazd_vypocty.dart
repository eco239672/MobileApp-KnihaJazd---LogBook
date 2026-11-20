import '../models/jazda.dart';
import '../models/nastavenia_vozidla.dart';

/// Jedna jazda s údajmi, ktoré sa počítajú z celej knihy jázd: poradové
/// číslo v roku, vodič a stav tachometra pred jazdou a po nej.
class RiadokKnihyJazd {
  const RiadokKnihyJazd({
    required this.jazda,
    required this.poradoveCislo,
    required this.vodic,
    required this.tachometerPred,
    required this.tachometerPo,
  });

  final Jazda jazda;

  /// Poradové číslo jazdy v kalendárnom roku (1, 2, 3…).
  final int poradoveCislo;
  final String vodic;

  /// null, ak nie je zadaný počiatočný stav tachometra.
  final double? tachometerPred;
  final double? tachometerPo;

  /// Kilometre podľa tachometra; ak ho používateľ pri jazde zadal ručne,
  /// môžu sa mierne líšiť od GPS (rozdiel sa vyrovná v tejto jazde).
  double get kilometre {
    final pred = tachometerPred;
    final po = tachometerPo;
    if (jazda.tachometerPo != null && pred != null && po != null) {
      return po - pred;
    }
    return jazda.kilometre;
  }
}

/// Zoradí jazdy a dopočíta poradové čísla, vodiča a stav tachometra.
///
/// Tachometer sa počíta od [NastaveniaVozidla.pociatocnyTachometer] pripočítaním
/// kilometrov každej jazdy. Ak používateľ pri niektorej jazde zadá skutočný
/// stav tachometra, ďalšie jazdy pokračujú od neho.
List<RiadokKnihyJazd> zostavitKnihuJazd(
  Iterable<Jazda> jazdy,
  NastaveniaVozidla nastavenia,
) {
  final zoradene = [...jazdy]..sort(porovnatJazdy);
  final riadky = <RiadokKnihyJazd>[];
  double? tachometer = nastavenia.pociatocnyTachometer;
  int? rok;
  var cislo = 0;
  for (final jazda in zoradene) {
    if (jazda.datum.year != rok) {
      rok = jazda.datum.year;
      cislo = 0;
    }
    cislo++;
    final pred = tachometer;
    final zadanyPo = jazda.tachometerPo;
    final po = zadanyPo ?? (pred == null ? null : pred + jazda.kilometre);
    tachometer = po;
    riadky.add(
      RiadokKnihyJazd(
        jazda: jazda,
        poradoveCislo: cislo,
        vodic: jazda.vodic.trim().isNotEmpty
            ? jazda.vodic.trim()
            : nastavenia.vodic.trim(),
        // Ak tachometer ešte nebol známy a používateľ zadal stav po jazde,
        // stav pred jazdou dopočítame z kilometrov.
        tachometerPred: pred ?? (zadanyPo == null ? null : zadanyPo - jazda.kilometre),
        tachometerPo: po,
      ),
    );
  }
  return riadky;
}

/// Stav tachometra na konci každého roka (koniec zdaňovacieho obdobia).
Map<int, double> stavTachometraNaKonciRokov(List<RiadokKnihyJazd> riadky) {
  final vysledok = <int, double>{};
  for (final riadok in riadky) {
    final po = riadok.tachometerPo;
    if (po != null) vysledok[riadok.jazda.datum.year] = po;
  }
  return vysledok;
}

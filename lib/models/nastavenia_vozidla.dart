import 'dart:convert';

import 'jazda.dart';

/// Značka pre [NastaveniaVozidla.copyWith]: hodnota sa nemení.
const Object _nezmenene = Object();

class NastaveniaVozidla {
  const NastaveniaVozidla({
    this.spz = '',
    this.priemernaSpotreba,
    this.cenaBenzinu,
    this.cenaNafty,
    this.vin = '',
    this.znackaTyp = '',
    this.kategoria = 'M1',
    this.vodic = '',
    this.pociatocnyTachometer,
    this.oblubeneMiesta = const [],
    this.bluetoothAuta,
    this.bluetoothAutaNazov,
  });

  final String spz;
  final double? priemernaSpotreba;
  final double? cenaBenzinu;
  final double? cenaNafty;

  /// Identifikačné číslo vozidla (VIN) – povinný údaj elektronickej knihy jázd.
  final String vin;

  /// Názov a typ vozidla, napr. „Škoda Octavia 2.0 TDI“.
  final String znackaTyp;

  /// Kategória vozidla podľa osvedčenia o evidencii (osobné auto = M1).
  final String kategoria;

  /// Predvolený vodič; použije sa pri jazdách bez vlastného vodiča.
  final String vodic;

  /// Stav tachometra v deň začatia evidencie (pred prvou jazdou v aplikácii).
  final double? pociatocnyTachometer;

  /// Pomenované miesta (Domov, Práca…), ktoré sa zapíšu namiesto adresy.
  final List<OblubeneMiesto> oblubeneMiesta;

  /// Bluetooth adresa auta. Ak je zadaná, jazda bez pripojenia k autu sa
  /// zaznamená ako súkromná (napr. autobus, cudzie auto).
  final String? bluetoothAuta;
  final String? bluetoothAutaNazov;

  NastaveniaVozidla copyWith({
    String? spz,
    Object? priemernaSpotreba = _nezmenene,
    Object? cenaBenzinu = _nezmenene,
    Object? cenaNafty = _nezmenene,
    String? vin,
    String? znackaTyp,
    String? kategoria,
    String? vodic,
    Object? pociatocnyTachometer = _nezmenene,
    List<OblubeneMiesto>? oblubeneMiesta,
    Object? bluetoothAuta = _nezmenene,
    Object? bluetoothAutaNazov = _nezmenene,
  }) {
    T? hodnota<T>(Object? nova, T? stara) =>
        identical(nova, _nezmenene) ? stara : nova as T?;
    return NastaveniaVozidla(
      spz: spz ?? this.spz,
      priemernaSpotreba: hodnota<double>(
        priemernaSpotreba,
        this.priemernaSpotreba,
      ),
      cenaBenzinu: hodnota<double>(cenaBenzinu, this.cenaBenzinu),
      cenaNafty: hodnota<double>(cenaNafty, this.cenaNafty),
      vin: vin ?? this.vin,
      znackaTyp: znackaTyp ?? this.znackaTyp,
      kategoria: kategoria ?? this.kategoria,
      vodic: vodic ?? this.vodic,
      pociatocnyTachometer: hodnota<double>(
        pociatocnyTachometer,
        this.pociatocnyTachometer,
      ),
      oblubeneMiesta: oblubeneMiesta ?? this.oblubeneMiesta,
      bluetoothAuta: hodnota<String>(bluetoothAuta, this.bluetoothAuta),
      bluetoothAutaNazov: hodnota<String>(
        bluetoothAutaNazov,
        this.bluetoothAutaNazov,
      ),
    );
  }
}

/// Pomenované miesto, napr. „Domov“. Jazda, ktorá začne alebo skončí do
/// [polomerMetre] od neho, dostane namiesto adresy jeho názov.
class OblubeneMiesto {
  const OblubeneMiesto({
    required this.nazov,
    required this.latitude,
    required this.longitude,
    this.polomerMetre = predvolenyPolomer,
  });

  static const predvolenyPolomer = 150.0;

  final String nazov;
  final double latitude;
  final double longitude;
  final double polomerMetre;

  double vzdialenostOd(double latitude, double longitude) =>
      vzdialenostMetre(this.latitude, this.longitude, latitude, longitude);

  Map<String, Object> naMapu() => {
    'nazov': nazov,
    'latitude': latitude,
    'longitude': longitude,
    'polomerMetre': polomerMetre,
  };

  /// Neplatný záznam (napr. poškodený v cloude) vráti null.
  static OblubeneMiesto? zMapy(Object? mapa) {
    if (mapa is! Map) return null;
    final nazov = mapa['nazov'];
    final latitude = mapa['latitude'];
    final longitude = mapa['longitude'];
    final polomer = mapa['polomerMetre'];
    if (nazov is! String || nazov.trim().isEmpty) return null;
    if (latitude is! num || longitude is! num) return null;
    return OblubeneMiesto(
      nazov: nazov.trim(),
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
      polomerMetre: polomer is num && polomer > 0
          ? polomer.toDouble()
          : predvolenyPolomer,
    );
  }

  static String naJson(List<OblubeneMiesto> miesta) =>
      jsonEncode([for (final miesto in miesta) miesto.naMapu()]);

  static List<OblubeneMiesto> zJson(String? text) {
    if (text == null || text.trim().isEmpty) return const [];
    try {
      return zoZoznamu(jsonDecode(text));
    } on FormatException {
      return const [];
    }
  }

  static List<OblubeneMiesto> zoZoznamu(Object? zoznam) {
    if (zoznam is! List) return const [];
    return [
      for (final polozka in zoznam) ?zMapy(polozka),
    ];
  }

  /// Najbližšie obľúbené miesto, v ktorého polomere bod leží; inak null.
  static OblubeneMiesto? najblizsie(
    Iterable<OblubeneMiesto> miesta,
    double latitude,
    double longitude,
  ) {
    OblubeneMiesto? najlepsie;
    var najmensia = double.infinity;
    for (final miesto in miesta) {
      final vzdialenost = miesto.vzdialenostOd(latitude, longitude);
      if (vzdialenost <= miesto.polomerMetre && vzdialenost < najmensia) {
        najmensia = vzdialenost;
        najlepsie = miesto;
      }
    }
    return najlepsie;
  }
}

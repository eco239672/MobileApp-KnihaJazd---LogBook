import 'dart:math' as math;

enum TypJazdy {
  sluzobna('Služobná'),
  sukromna('Súkromná');

  const TypJazdy(this.nazov);

  final String nazov;
}

/// Značka pre [Jazda.copyWith]: hodnota sa nemení (na rozdiel od null = vymazať).
const Object _nezmenene = Object();

class Jazda {
  const Jazda({
    this.id,
    this.cloudId,
    required this.datum,
    required this.odkial,
    required this.kam,
    required this.zaciatok,
    required this.koniec,
    required this.kilometre,
    required this.typ,
    this.ucel = '',
    this.vodic = '',
    this.odkialSuradnice,
    this.kamSuradnice,
    this.tachometerPo,
    this.autoBluetooth,
  });

  final int? id;

  /// Stabilný identifikátor záznamu používaný pri synchronizácii do cloudu.
  final String? cloudId;
  final DateTime datum;

  /// Miesto začiatku: adresa, názov obľúbeného miesta, alebo (kým sa adresa
  /// nezistí) súradnice v tvare „48.15100, 17.87650“.
  final String odkial;
  final String kam;
  final String zaciatok;
  final String koniec;
  final double kilometre;
  final TypJazdy typ;

  /// Konkrétny účel jazdy (napr. „Stretnutie so zákazníkom XY“).
  final String ucel;

  /// Meno vodiča; prázdne = predvolený vodič z nastavení vozidla.
  final String vodic;

  /// GPS súradnice začiatku a konca (len pri jazdách z GPS) ako dôkaz miesta.
  final String? odkialSuradnice;
  final String? kamSuradnice;

  /// Skutočný stav tachometra po jazde, ak ho používateľ zadal. Od neho sa
  /// počíta stav tachometra ďalších jázd (vyrovná rozdiel medzi GPS a autom).
  final double? tachometerPo;

  /// Bol počas jazdy telefón pripojený k Bluetooth auta? null = nesleduje sa.
  final bool? autoBluetooth;

  /// Miesto začiatku je ešte len v súradniciach (adresa sa doplní neskôr).
  bool get odkialJeSuradnica =>
      odkialSuradnice != null && odkial == odkialSuradnice;
  bool get kamJeSuradnica => kamSuradnice != null && kam == kamSuradnice;

  /// Služobná jazda bez vyplneného účelu (pre daňové účely nestačí).
  bool get chybaUcel => typ == TypJazdy.sluzobna && ucel.trim().isEmpty;

  Jazda copyWith({
    int? id,
    String? cloudId,
    DateTime? datum,
    String? odkial,
    String? kam,
    String? zaciatok,
    String? koniec,
    double? kilometre,
    TypJazdy? typ,
    String? ucel,
    String? vodic,
    Object? odkialSuradnice = _nezmenene,
    Object? kamSuradnice = _nezmenene,
    Object? tachometerPo = _nezmenene,
    Object? autoBluetooth = _nezmenene,
  }) {
    return Jazda(
      id: id ?? this.id,
      cloudId: cloudId ?? this.cloudId,
      datum: datum ?? this.datum,
      odkial: odkial ?? this.odkial,
      kam: kam ?? this.kam,
      zaciatok: zaciatok ?? this.zaciatok,
      koniec: koniec ?? this.koniec,
      kilometre: kilometre ?? this.kilometre,
      typ: typ ?? this.typ,
      ucel: ucel ?? this.ucel,
      vodic: vodic ?? this.vodic,
      odkialSuradnice: identical(odkialSuradnice, _nezmenene)
          ? this.odkialSuradnice
          : odkialSuradnice as String?,
      kamSuradnice: identical(kamSuradnice, _nezmenene)
          ? this.kamSuradnice
          : kamSuradnice as String?,
      tachometerPo: identical(tachometerPo, _nezmenene)
          ? this.tachometerPo
          : tachometerPo as double?,
      autoBluetooth: identical(autoBluetooth, _nezmenene)
          ? this.autoBluetooth
          : autoBluetooth as bool?,
    );
  }
}

class JazdaDna {
  const JazdaDna({required this.indexVZozname, required this.jazda});

  final int indexVZozname;
  final Jazda jazda;

  JazdaDna copyWith({required Jazda jazda}) {
    return JazdaDna(indexVZozname: indexVZozname, jazda: jazda);
  }
}

/// Minúty od polnoci z času „HH:MM“ (aj „8:05“). Neplatný čas = 0.
int minutyZCasu(String cas) {
  final casti = cas.trim().split(':');
  if (casti.length != 2) return 0;
  return (int.tryParse(casti[0]) ?? 0) * 60 + (int.tryParse(casti[1]) ?? 0);
}

/// Poradie jázd: podľa dňa a v rámci dňa podľa času začiatku.
int porovnatJazdy(Jazda a, Jazda b) {
  final denA = DateTime(a.datum.year, a.datum.month, a.datum.day);
  final denB = DateTime(b.datum.year, b.datum.month, b.datum.day);
  final den = denA.compareTo(denB);
  if (den != 0) return den;
  return minutyZCasu(a.zaciatok).compareTo(minutyZCasu(b.zaciatok));
}

/// Súradnice v tvare, v akom sa ukladajú pri jazde: „48.15100, 17.87650“.
String formatovatSuradnice(double latitude, double longitude) =>
    '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';

/// Opak [formatovatSuradnice]; pri neplatnom texte vráti null.
({double latitude, double longitude})? precitatSuradnice(String? text) {
  if (text == null) return null;
  final casti = text.split(',');
  if (casti.length != 2) return null;
  final latitude = double.tryParse(casti[0].trim());
  final longitude = double.tryParse(casti[1].trim());
  if (latitude == null || longitude == null) return null;
  if (latitude.abs() > 90 || longitude.abs() > 180) return null;
  return (latitude: latitude, longitude: longitude);
}

/// Vzdialenosť dvoch bodov na Zemi v metroch (haversine).
double vzdialenostMetre(
  double latitude1,
  double longitude1,
  double latitude2,
  double longitude2,
) {
  const polomerZeme = 6371008.8;
  double radiany(double stupne) => stupne * math.pi / 180;
  final dLat = radiany(latitude2 - latitude1);
  final dLon = radiany(longitude2 - longitude1);
  final h =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(radiany(latitude1)) *
          math.cos(radiany(latitude2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * polomerZeme * math.asin(math.sqrt(h.clamp(0.0, 1.0)));
}

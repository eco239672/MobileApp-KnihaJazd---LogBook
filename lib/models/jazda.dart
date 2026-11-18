enum TypJazdy {
  sluzobna('Služobná'),
  sukromna('Súkromná');

  const TypJazdy(this.nazov);

  final String nazov;
}

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
  });

  final int? id;

  /// Stabilný identifikátor záznamu používaný pri synchronizácii do cloudu.
  final String? cloudId;
  final DateTime datum;
  final String odkial;
  final String kam;
  final String zaciatok;
  final String koniec;
  final double kilometre;
  final TypJazdy typ;

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

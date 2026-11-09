enum TypJazdy {
  sluzobna('Služobná'),
  sukromna('Súkromná');

  const TypJazdy(this.nazov);

  final String nazov;
}

class Jazda {
  const Jazda({
    required this.datum,
    required this.odkial,
    required this.kam,
    required this.zaciatok,
    required this.koniec,
    required this.kilometre,
    required this.typ,
  });

  final DateTime datum;
  final String odkial;
  final String kam;
  final String zaciatok;
  final String koniec;
  final double kilometre;
  final TypJazdy typ;

  Jazda copyWith({
    DateTime? datum,
    String? odkial,
    String? kam,
    String? zaciatok,
    String? koniec,
    double? kilometre,
    TypJazdy? typ,
  }) {
    return Jazda(
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

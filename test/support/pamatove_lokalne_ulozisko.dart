import 'package:kniha_jazd/models/jazda.dart';
import 'package:kniha_jazd/models/nastavenia_vozidla.dart';
import 'package:kniha_jazd/models/synchronizacia.dart';
import 'package:kniha_jazd/services/lokalne_ulozisko.dart';

/// Jednoduchá implementácia používaná len v testoch.
class PamatoveLokalneUlozisko implements LokalneUlozisko {
  final List<_PamatovaJazda> _jazdy = [];
  NastaveniaVozidla _nastavenia = const NastaveniaVozidla();
  int? _nastaveniaUpravene;
  var _nastaveniaOdoslane = true;
  int? _casStiahnutia;
  var _dalsieId = 1;
  var _hodiny = 0;

  // Monotónny „čas“, aby každá zmena mala novšiu značku aj v rýchlom teste.
  int _teraz() {
    final teraz = DateTime.now().millisecondsSinceEpoch;
    _hodiny = teraz > _hodiny ? teraz : _hodiny + 1;
    return _hodiny;
  }

  @override
  Future<UlozeneUdaje> nacitat() async => UlozeneUdaje(
    jazdy: List.unmodifiable(
      _jazdy.where((z) => !z.vymazana).map((z) => z.jazda),
    ),
    nastavenia: _nastavenia,
  );

  @override
  Future<Jazda> ulozitJazdu(Jazda jazda) async {
    var index = jazda.id == null
        ? -1
        : _jazdy.indexWhere((z) => z.jazda.id == jazda.id);
    if (index < 0 && jazda.cloudId != null) {
      index = _jazdy.indexWhere((z) => z.jazda.cloudId == jazda.cloudId);
    }
    final ulozena = jazda.copyWith(
      id: index >= 0 ? _jazdy[index].jazda.id : (jazda.id ?? _dalsieId++),
      cloudId:
          jazda.cloudId ?? 'pamat-${DateTime.now().microsecondsSinceEpoch}',
    );
    final zaznam = _PamatovaJazda(ulozena, upravene: _teraz());
    if (index < 0) {
      _jazdy.add(zaznam);
    } else {
      _jazdy[index] = zaznam;
    }
    return ulozena;
  }

  @override
  Future<void> vymazatJazdy(Iterable<Jazda> jazdy) async {
    final ids = jazdy.map((jazda) => jazda.id).whereType<int>().toSet();
    for (var i = 0; i < _jazdy.length; i++) {
      if (ids.contains(_jazdy[i].jazda.id)) {
        _jazdy[i] = _PamatovaJazda(
          _jazdy[i].jazda,
          upravene: _teraz(),
          vymazana: true,
        );
      }
    }
  }

  @override
  Future<void> ulozitNastavenia(NastaveniaVozidla nastavenia) async {
    _nastavenia = nastavenia;
    _nastaveniaUpravene = _teraz();
    _nastaveniaOdoslane = false;
  }

  @override
  Future<void> zavriet() async {}

  @override
  Future<List<ZmenaJazdy>> nacitatNeodoslaneJazdy() async => [
    for (final z in _jazdy.where((z) => !z.odoslana))
      ZmenaJazdy(
        cloudId: z.jazda.cloudId!,
        upravene: z.upravene,
        vymazana: z.vymazana,
        jazda: z.vymazana ? null : z.jazda,
      ),
  ];

  @override
  Future<void> oznacitOdoslane(Iterable<ZmenaJazdy> zmeny) async {
    for (final zmena in zmeny) {
      final index = _jazdy.indexWhere(
        (z) => z.jazda.cloudId == zmena.cloudId && z.upravene == zmena.upravene,
      );
      if (index < 0) continue;
      if (_jazdy[index].vymazana) {
        _jazdy.removeAt(index);
      } else {
        _jazdy[index].odoslana = true;
      }
    }
  }

  @override
  Future<bool> aplikovatJazdyZCloudu(Iterable<ZmenaJazdy> zmeny) async {
    var zmenene = false;
    for (final zmena in zmeny) {
      final index = _jazdy.indexWhere((z) => z.jazda.cloudId == zmena.cloudId);
      if (index >= 0 && _jazdy[index].upravene >= zmena.upravene) continue;
      final jazda = zmena.jazda;
      if (zmena.vymazana || jazda == null) {
        if (index >= 0) {
          _jazdy.removeAt(index);
          zmenene = true;
        }
        continue;
      }
      final zaznam = _PamatovaJazda(
        jazda.copyWith(
          id: index >= 0 ? _jazdy[index].jazda.id : _dalsieId++,
          cloudId: zmena.cloudId,
        ),
        upravene: zmena.upravene,
      )..odoslana = true;
      if (index >= 0) {
        _jazdy[index] = zaznam;
      } else {
        _jazdy.add(zaznam);
      }
      zmenene = true;
    }
    return zmenene;
  }

  @override
  Future<ZmenaNastaveni?> nacitatNeodoslaneNastavenia() async =>
      _nastaveniaOdoslane || _nastaveniaUpravene == null
      ? null
      : ZmenaNastaveni(
          nastavenia: _nastavenia,
          upravene: _nastaveniaUpravene!,
        );

  @override
  Future<void> oznacitNastaveniaOdoslane(int upravene) async {
    if (_nastaveniaUpravene == upravene) _nastaveniaOdoslane = true;
  }

  @override
  Future<bool> aplikovatNastaveniaZCloudu(ZmenaNastaveni zmena) async {
    final miestne = _nastaveniaUpravene;
    if (miestne != null && miestne >= zmena.upravene) return false;
    _nastavenia = zmena.nastavenia;
    _nastaveniaUpravene = zmena.upravene;
    _nastaveniaOdoslane = true;
    return true;
  }

  @override
  Future<int?> nacitatCasStiahnutia() async => _casStiahnutia;

  @override
  Future<void> ulozitCasStiahnutia(int casMillis) async {
    _casStiahnutia = casMillis;
  }
}

class _PamatovaJazda {
  _PamatovaJazda(this.jazda, {required this.upravene, this.vymazana = false});

  final Jazda jazda;
  final int upravene;
  final bool vymazana;
  var odoslana = false;
}

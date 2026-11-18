import 'dart:math';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../models/jazda.dart';
import '../models/nastavenia_vozidla.dart';
import '../models/synchronizacia.dart';

abstract interface class LokalneUlozisko {
  Future<UlozeneUdaje> nacitat();
  Future<Jazda> ulozitJazdu(Jazda jazda);

  /// Jazdy sa skryjú hneď, ale v databáze ostanú ako „vymazané“, kým sa
  /// zmazanie neodošle do cloudu (inak by sa z cloudu vrátili späť).
  Future<void> vymazatJazdy(Iterable<Jazda> jazdy);
  Future<void> ulozitNastavenia(NastaveniaVozidla nastavenia);
  Future<void> zavriet();

  // --- synchronizácia s cloudom ---

  /// Jazdy (aj vymazané) zmenené od posledného úspešného odoslania.
  Future<List<ZmenaJazdy>> nacitatNeodoslaneJazdy();

  /// Označí zmeny ako odoslané. Ak sa jazda medzitým znova upravila, zostane
  /// neodoslaná. Vymazané jazdy sa po odoslaní z telefónu odstránia úplne.
  Future<void> oznacitOdoslane(Iterable<ZmenaJazdy> zmeny);

  /// Zapíše zmeny z cloudu; novšia úprava vyhráva. Vráti true, ak sa niečo zmenilo.
  Future<bool> aplikovatJazdyZCloudu(Iterable<ZmenaJazdy> zmeny);

  Future<ZmenaNastaveni?> nacitatNeodoslaneNastavenia();
  Future<void> oznacitNastaveniaOdoslane(int upravene);
  Future<bool> aplikovatNastaveniaZCloudu(ZmenaNastaveni zmena);

  /// Serverový čas, od ktorého sa majú nabudúce sťahovať zmeny z cloudu.
  Future<int?> nacitatCasStiahnutia();
  Future<void> ulozitCasStiahnutia(int casMillis);
}

class UlozeneUdaje {
  const UlozeneUdaje({required this.jazdy, required this.nastavenia});

  final List<Jazda> jazdy;
  final NastaveniaVozidla nastavenia;
}

/// Trvalé úložisko v súbore SQLite v súkromnom priestore aplikácie telefónu.
class SqliteLokalneUlozisko implements LokalneUlozisko {
  SqliteLokalneUlozisko({this.databazovaCesta});

  static const _nazovDatabazy = 'kniha_jazd.db';
  final String? databazovaCesta;
  Database? _databaza;

  Future<Database> get _db async {
    final existujuca = _databaza;
    if (existujuca != null) return existujuca;

    final ciel =
        databazovaCesta ?? path.join(await getDatabasesPath(), _nazovDatabazy);
    final databaza = await openDatabase(
      ciel,
      version: 5,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE jazdy(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            cloud_id TEXT NOT NULL,
            datum TEXT NOT NULL,
            odkial TEXT NOT NULL,
            kam TEXT NOT NULL,
            zaciatok TEXT NOT NULL,
            koniec TEXT NOT NULL,
            kilometre REAL NOT NULL,
            typ TEXT NOT NULL,
            upravene INTEGER NOT NULL DEFAULT 0,
            odoslane INTEGER NOT NULL DEFAULT 0,
            vymazane INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await _vytvoritUnikatnyCloudId(db);
        await _vytvoritMeta(db);
        await db.execute('''
          CREATE TABLE nastavenia_vozidla(
            id INTEGER PRIMARY KEY CHECK (id = 1),
            spz TEXT NOT NULL,
            priemerna_spotreba REAL,
            cena_benzinu REAL,
            cena_nafty REAL,
            upravene INTEGER NOT NULL DEFAULT 0,
            odoslane INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
      onUpgrade: (db, staraVerzia, _) async {
        if (staraVerzia < 2) {
          await db.execute(
            'ALTER TABLE nastavenia_vozidla ADD COLUMN cena_benzinu REAL',
          );
          await db.execute(
            'ALTER TABLE nastavenia_vozidla ADD COLUMN cena_nafty REAL',
          );
          await db.execute('''
            UPDATE nastavenia_vozidla
            SET cena_benzinu = cena_paliva, cena_nafty = cena_paliva
            WHERE cena_paliva IS NOT NULL
          ''');
        }
        if (staraVerzia < 3) {
          await db.execute('ALTER TABLE jazdy ADD COLUMN cloud_id TEXT');
          final jazdy = await db.query('jazdy', columns: ['id']);
          for (final jazda in jazdy) {
            final id = jazda['id']! as int;
            await db.update(
              'jazdy',
              {'cloud_id': 'povodna-jazda-$id'},
              where: 'id = ?',
              whereArgs: [id],
            );
          }
        }
        if (staraVerzia < 4) {
          // Súbežná synchronizácia mohla ten istý cloudový záznam uložiť
          // viackrát. Ponecháme najstarší riadok a duplicitám zabránime indexom.
          await db.execute('''
            DELETE FROM jazdy
            WHERE cloud_id IS NOT NULL
              AND id NOT IN (
                SELECT MIN(id) FROM jazdy
                WHERE cloud_id IS NOT NULL
                GROUP BY cloud_id
              )
          ''');
          await _vytvoritUnikatnyCloudId(db);
        }
        if (staraVerzia < 5) {
          // Príznaky pre synchronizáciu. Existujúce jazdy a nastavenia sa pri
          // najbližšej synchronizácii odošlú (odoslane = 0).
          for (final stlpec in [
            'upravene INTEGER NOT NULL DEFAULT 0',
            'odoslane INTEGER NOT NULL DEFAULT 0',
            'vymazane INTEGER NOT NULL DEFAULT 0',
          ]) {
            await db.execute('ALTER TABLE jazdy ADD COLUMN $stlpec');
          }
          await db.execute(
            'ALTER TABLE nastavenia_vozidla ADD COLUMN upravene INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE nastavenia_vozidla ADD COLUMN odoslane INTEGER NOT NULL DEFAULT 0',
          );
          await _vytvoritMeta(db);
        }
      },
    );
    _databaza = databaza;
    return databaza;
  }

  static Future<void> _vytvoritUnikatnyCloudId(Database db) => db.execute(
    'CREATE UNIQUE INDEX IF NOT EXISTS jazdy_cloud_id ON jazdy(cloud_id)',
  );

  static Future<void> _vytvoritMeta(Database db) => db.execute(
    'CREATE TABLE IF NOT EXISTS meta(kluc TEXT PRIMARY KEY, hodnota TEXT)',
  );

  static int _teraz() => DateTime.now().millisecondsSinceEpoch;

  @override
  Future<UlozeneUdaje> nacitat() async {
    final db = await _db;
    final vysledky = await Future.wait([
      db.query(
        'jazdy',
        where: 'vymazane = 0',
        orderBy: 'datum DESC, zaciatok ASC',
      ),
      db.query('nastavenia_vozidla', where: 'id = ?', whereArgs: [1]),
    ]);
    final jazdy = vysledky[0].map(_jazdaZMapy).toList();
    final riadkyNastaveni = vysledky[1];
    final nastavenia = riadkyNastaveni.isEmpty
        ? const NastaveniaVozidla()
        : _nastaveniaZMapy(riadkyNastaveni.single);
    return UlozeneUdaje(jazdy: jazdy, nastavenia: nastavenia);
  }

  @override
  Future<Jazda> ulozitJazdu(Jazda jazda) async {
    final db = await _db;
    final sCloudId = jazda.cloudId ?? _novyCloudId();
    final sCloudJazda = jazda.copyWith(cloudId: sCloudId);
    final hodnoty = {
      ..._jazdaDoMapy(sCloudJazda),
      'upravene': _teraz(),
      'odoslane': 0,
      'vymazane': 0,
    };
    var id = jazda.id;
    if (id == null && jazda.cloudId != null) {
      // Ten istý záznam (z cloudu alebo z GPS na pozadí) už môže byť uložený.
      final existujuce = await db.query(
        'jazdy',
        columns: ['id'],
        where: 'cloud_id = ?',
        whereArgs: [jazda.cloudId],
        limit: 1,
      );
      if (existujuce.isNotEmpty) id = existujuce.single['id']! as int;
    }
    if (id == null) {
      final noveId = await db.insert('jazdy', hodnoty);
      return sCloudJazda.copyWith(id: noveId);
    }
    await db.update('jazdy', hodnoty, where: 'id = ?', whereArgs: [id]);
    return sCloudJazda.copyWith(id: id);
  }

  @override
  Future<void> vymazatJazdy(Iterable<Jazda> jazdy) async {
    final ids = jazdy.map((jazda) => jazda.id).whereType<int>().toList();
    if (ids.isEmpty) return;
    final db = await _db;
    final teraz = _teraz();
    await db.transaction((transakcia) async {
      for (final id in ids) {
        await transakcia.update(
          'jazdy',
          {'vymazane': 1, 'odoslane': 0, 'upravene': teraz},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    });
  }

  @override
  Future<void> ulozitNastavenia(NastaveniaVozidla nastavenia) async {
    final db = await _db;
    await db.insert('nastavenia_vozidla', {
      'id': 1,
      'spz': nastavenia.spz,
      'priemerna_spotreba': nastavenia.priemernaSpotreba,
      'cena_benzinu': nastavenia.cenaBenzinu,
      'cena_nafty': nastavenia.cenaNafty,
      'upravene': _teraz(),
      'odoslane': 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<List<ZmenaJazdy>> nacitatNeodoslaneJazdy() async {
    final db = await _db;
    final riadky = await db.query(
      'jazdy',
      where: 'odoslane = 0 AND cloud_id IS NOT NULL',
    );
    return [
      for (final riadok in riadky)
        ZmenaJazdy(
          cloudId: riadok['cloud_id']! as String,
          upravene: riadok['upravene']! as int,
          vymazana: riadok['vymazane'] == 1,
          jazda: riadok['vymazane'] == 1 ? null : _jazdaZMapy(riadok),
        ),
    ];
  }

  @override
  Future<void> oznacitOdoslane(Iterable<ZmenaJazdy> zmeny) async {
    final db = await _db;
    await db.transaction((transakcia) async {
      for (final zmena in zmeny) {
        // Podmienka na „upravene“: ak sa jazda medzitým zmenila, ostane na odoslanie.
        if (zmena.vymazana) {
          await transakcia.delete(
            'jazdy',
            where: 'cloud_id = ? AND upravene = ? AND vymazane = 1',
            whereArgs: [zmena.cloudId, zmena.upravene],
          );
        } else {
          await transakcia.update(
            'jazdy',
            {'odoslane': 1},
            where: 'cloud_id = ? AND upravene = ?',
            whereArgs: [zmena.cloudId, zmena.upravene],
          );
        }
      }
    });
  }

  @override
  Future<bool> aplikovatJazdyZCloudu(Iterable<ZmenaJazdy> zmeny) async {
    final db = await _db;
    var zmenene = false;
    await db.transaction((transakcia) async {
      for (final zmena in zmeny) {
        final miestne = await transakcia.query(
          'jazdy',
          columns: ['id', 'upravene'],
          where: 'cloud_id = ?',
          whereArgs: [zmena.cloudId],
          limit: 1,
        );
        final miestnaUprava = miestne.isEmpty
            ? null
            : miestne.single['upravene']! as int;
        // Telefón má rovnakú alebo novšiu verziu: nechávame ju (prípadne sa odošle).
        if (miestnaUprava != null && miestnaUprava >= zmena.upravene) continue;

        final jazda = zmena.jazda;
        if (zmena.vymazana || jazda == null) {
          if (miestne.isNotEmpty) {
            await transakcia.delete(
              'jazdy',
              where: 'cloud_id = ?',
              whereArgs: [zmena.cloudId],
            );
            zmenene = true;
          }
          continue;
        }

        final hodnoty = {
          ..._jazdaDoMapy(jazda.copyWith(cloudId: zmena.cloudId)),
          'upravene': zmena.upravene,
          'odoslane': 1,
          'vymazane': 0,
        };
        if (miestne.isEmpty) {
          await transakcia.insert('jazdy', hodnoty);
        } else {
          await transakcia.update(
            'jazdy',
            hodnoty,
            where: 'cloud_id = ?',
            whereArgs: [zmena.cloudId],
          );
        }
        zmenene = true;
      }
    });
    return zmenene;
  }

  @override
  Future<ZmenaNastaveni?> nacitatNeodoslaneNastavenia() async {
    final db = await _db;
    final riadky = await db.query(
      'nastavenia_vozidla',
      where: 'id = 1 AND odoslane = 0',
    );
    if (riadky.isEmpty) return null;
    return ZmenaNastaveni(
      nastavenia: _nastaveniaZMapy(riadky.single),
      upravene: riadky.single['upravene']! as int,
    );
  }

  @override
  Future<void> oznacitNastaveniaOdoslane(int upravene) async {
    final db = await _db;
    await db.update(
      'nastavenia_vozidla',
      {'odoslane': 1},
      where: 'id = 1 AND upravene = ?',
      whereArgs: [upravene],
    );
  }

  @override
  Future<bool> aplikovatNastaveniaZCloudu(ZmenaNastaveni zmena) async {
    final db = await _db;
    final miestne = await db.query(
      'nastavenia_vozidla',
      columns: ['upravene'],
      where: 'id = 1',
    );
    if (miestne.isNotEmpty &&
        (miestne.single['upravene']! as int) >= zmena.upravene) {
      return false;
    }
    final nastavenia = zmena.nastavenia;
    await db.insert('nastavenia_vozidla', {
      'id': 1,
      'spz': nastavenia.spz,
      'priemerna_spotreba': nastavenia.priemernaSpotreba,
      'cena_benzinu': nastavenia.cenaBenzinu,
      'cena_nafty': nastavenia.cenaNafty,
      'upravene': zmena.upravene,
      'odoslane': 1,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return true;
  }

  @override
  Future<int?> nacitatCasStiahnutia() async {
    final db = await _db;
    final riadky = await db.query(
      'meta',
      where: 'kluc = ?',
      whereArgs: ['cas_stiahnutia'],
    );
    if (riadky.isEmpty) return null;
    return int.tryParse(riadky.single['hodnota']! as String);
  }

  @override
  Future<void> ulozitCasStiahnutia(int casMillis) async {
    final db = await _db;
    await db.insert('meta', {
      'kluc': 'cas_stiahnutia',
      'hodnota': '$casMillis',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> zavriet() async {
    await _databaza?.close();
    _databaza = null;
  }

  Map<String, Object?> _jazdaDoMapy(Jazda jazda) => {
    'cloud_id': jazda.cloudId,
    'datum': jazda.datum.toIso8601String(),
    'odkial': jazda.odkial,
    'kam': jazda.kam,
    'zaciatok': jazda.zaciatok,
    'koniec': jazda.koniec,
    'kilometre': jazda.kilometre,
    'typ': jazda.typ.name,
  };

  Jazda _jazdaZMapy(Map<String, Object?> mapa) => Jazda(
    id: mapa['id'] as int,
    cloudId: mapa['cloud_id'] as String?,
    datum: DateTime.parse(mapa['datum']! as String),
    odkial: mapa['odkial']! as String,
    kam: mapa['kam']! as String,
    zaciatok: mapa['zaciatok']! as String,
    koniec: mapa['koniec']! as String,
    kilometre: (mapa['kilometre']! as num).toDouble(),
    typ: TypJazdy.values.byName(mapa['typ']! as String),
  );

  NastaveniaVozidla _nastaveniaZMapy(Map<String, Object?> mapa) =>
      NastaveniaVozidla(
        spz: mapa['spz']! as String,
        priemernaSpotreba: (mapa['priemerna_spotreba'] as num?)?.toDouble(),
        cenaBenzinu: (mapa['cena_benzinu'] as num?)?.toDouble(),
        cenaNafty: (mapa['cena_nafty'] as num?)?.toDouble(),
      );

  String _novyCloudId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
}

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

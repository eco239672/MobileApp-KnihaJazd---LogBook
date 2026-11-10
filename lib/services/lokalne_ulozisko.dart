import 'dart:math';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../models/jazda.dart';
import '../models/nastavenia_vozidla.dart';

abstract interface class LokalneUlozisko {
  Future<UlozeneUdaje> nacitat();
  Future<Jazda> ulozitJazdu(Jazda jazda);
  Future<void> vymazatJazdy(Iterable<Jazda> jazdy);
  Future<void> ulozitNastavenia(NastaveniaVozidla nastavenia);
  Future<void> zavriet();
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
      version: 3,
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
            typ TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE nastavenia_vozidla(
            id INTEGER PRIMARY KEY CHECK (id = 1),
            spz TEXT NOT NULL,
            priemerna_spotreba REAL,
            cena_benzinu REAL,
            cena_nafty REAL
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
      },
    );
    _databaza = databaza;
    return databaza;
  }

  @override
  Future<UlozeneUdaje> nacitat() async {
    final db = await _db;
    final vysledky = await Future.wait([
      db.query('jazdy', orderBy: 'datum DESC, zaciatok ASC'),
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
    final hodnoty = _jazdaDoMapy(sCloudJazda);
    final id = jazda.id;
    if (id == null) {
      final noveId = await db.insert('jazdy', hodnoty);
      return sCloudJazda.copyWith(id: noveId);
    }
    await db.update('jazdy', hodnoty, where: 'id = ?', whereArgs: [id]);
    return sCloudJazda;
  }

  @override
  Future<void> vymazatJazdy(Iterable<Jazda> jazdy) async {
    final ids = jazdy.map((jazda) => jazda.id).whereType<int>().toList();
    if (ids.isEmpty) return;
    final db = await _db;
    await db.transaction((transakcia) async {
      for (final id in ids) {
        await transakcia.delete('jazdy', where: 'id = ?', whereArgs: [id]);
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

/// Jednoduchá implementácia používaná len vo widget testoch.
class PamatoveLokalneUlozisko implements LokalneUlozisko {
  final List<Jazda> _jazdy = [];
  NastaveniaVozidla _nastavenia = const NastaveniaVozidla();
  var _dalsieId = 1;

  @override
  Future<UlozeneUdaje> nacitat() async =>
      UlozeneUdaje(jazdy: List.unmodifiable(_jazdy), nastavenia: _nastavenia);

  @override
  Future<Jazda> ulozitJazdu(Jazda jazda) async {
    final ulozena = jazda.id == null
        ? jazda.copyWith(
            id: _dalsieId++,
            cloudId:
                jazda.cloudId ??
                'pamat-${DateTime.now().microsecondsSinceEpoch}',
          )
        : jazda;
    final index = _jazdy.indexWhere((polozka) => polozka.id == ulozena.id);
    if (index < 0) {
      _jazdy.add(ulozena);
    } else {
      _jazdy[index] = ulozena;
    }
    return ulozena;
  }

  @override
  Future<void> vymazatJazdy(Iterable<Jazda> jazdy) async {
    final ids = jazdy.map((jazda) => jazda.id).whereType<int>().toSet();
    _jazdy.removeWhere((jazda) => ids.contains(jazda.id));
  }

  @override
  Future<void> ulozitNastavenia(NastaveniaVozidla nastavenia) async {
    _nastavenia = nastavenia;
  }

  @override
  Future<void> zavriet() async {}
}

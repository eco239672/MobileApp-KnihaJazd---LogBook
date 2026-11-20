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
      version: 6,
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
            vymazane INTEGER NOT NULL DEFAULT 0,
            ucel TEXT NOT NULL DEFAULT '',
            vodic TEXT NOT NULL DEFAULT '',
            odkial_suradnice TEXT,
            kam_suradnice TEXT,
            tachometer_po REAL,
            auto_bluetooth INTEGER
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
            odoslane INTEGER NOT NULL DEFAULT 0,
            vin TEXT NOT NULL DEFAULT '',
            znacka_typ TEXT NOT NULL DEFAULT '',
            kategoria TEXT NOT NULL DEFAULT 'M1',
            vodic TEXT NOT NULL DEFAULT '',
            pociatocny_tachometer REAL,
            oblubene_miesta TEXT NOT NULL DEFAULT '[]',
            bluetooth_auta TEXT,
            bluetooth_auta_nazov TEXT
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
        if (staraVerzia < 6) {
          // Údaje elektronickej knihy jázd (účel, vodič, tachometer, vozidlo)
          // a adresy namiesto súradníc.
          for (final stlpec in [
            "ucel TEXT NOT NULL DEFAULT ''",
            "vodic TEXT NOT NULL DEFAULT ''",
            'odkial_suradnice TEXT',
            'kam_suradnice TEXT',
            'tachometer_po REAL',
            'auto_bluetooth INTEGER',
          ]) {
            await db.execute('ALTER TABLE jazdy ADD COLUMN $stlpec');
          }
          for (final stlpec in [
            "vin TEXT NOT NULL DEFAULT ''",
            "znacka_typ TEXT NOT NULL DEFAULT ''",
            "kategoria TEXT NOT NULL DEFAULT 'M1'",
            "vodic TEXT NOT NULL DEFAULT ''",
            'pociatocny_tachometer REAL',
            "oblubene_miesta TEXT NOT NULL DEFAULT '[]'",
            'bluetooth_auta TEXT',
            'bluetooth_auta_nazov TEXT',
          ]) {
            await db.execute('ALTER TABLE nastavenia_vozidla ADD COLUMN $stlpec');
          }
          // Staršie jazdy z GPS majú v „odkiaľ/kam“ súradnice: zapamätáme si
          // ich ako dôkaz miesta a adresa sa k nim doplní automaticky.
          for (final (miesto, suradnice) in [
            ('odkial', 'odkial_suradnice'),
            ('kam', 'kam_suradnice'),
          ]) {
            await db.execute('''
              UPDATE jazdy SET $suradnice = $miesto
              WHERE $miesto GLOB '[0-9]*.[0-9]*, [0-9]*.[0-9]*'
            ''');
          }
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
      ..._nastaveniaDoMapy(nastavenia),
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
    await db.insert('nastavenia_vozidla', {
      ..._nastaveniaDoMapy(zmena.nastavenia),
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
    'ucel': jazda.ucel,
    'vodic': jazda.vodic,
    'odkial_suradnice': jazda.odkialSuradnice,
    'kam_suradnice': jazda.kamSuradnice,
    'tachometer_po': jazda.tachometerPo,
    'auto_bluetooth': switch (jazda.autoBluetooth) {
      null => null,
      true => 1,
      false => 0,
    },
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
    ucel: mapa['ucel'] as String? ?? '',
    vodic: mapa['vodic'] as String? ?? '',
    odkialSuradnice: mapa['odkial_suradnice'] as String?,
    kamSuradnice: mapa['kam_suradnice'] as String?,
    tachometerPo: (mapa['tachometer_po'] as num?)?.toDouble(),
    autoBluetooth: switch (mapa['auto_bluetooth']) {
      1 => true,
      0 => false,
      _ => null,
    },
  );

  Map<String, Object?> _nastaveniaDoMapy(NastaveniaVozidla nastavenia) => {
    'id': 1,
    'spz': nastavenia.spz,
    'priemerna_spotreba': nastavenia.priemernaSpotreba,
    'cena_benzinu': nastavenia.cenaBenzinu,
    'cena_nafty': nastavenia.cenaNafty,
    'vin': nastavenia.vin,
    'znacka_typ': nastavenia.znackaTyp,
    'kategoria': nastavenia.kategoria,
    'vodic': nastavenia.vodic,
    'pociatocny_tachometer': nastavenia.pociatocnyTachometer,
    'oblubene_miesta': OblubeneMiesto.naJson(nastavenia.oblubeneMiesta),
    'bluetooth_auta': nastavenia.bluetoothAuta,
    'bluetooth_auta_nazov': nastavenia.bluetoothAutaNazov,
  };

  NastaveniaVozidla _nastaveniaZMapy(Map<String, Object?> mapa) =>
      NastaveniaVozidla(
        spz: mapa['spz']! as String,
        priemernaSpotreba: (mapa['priemerna_spotreba'] as num?)?.toDouble(),
        cenaBenzinu: (mapa['cena_benzinu'] as num?)?.toDouble(),
        cenaNafty: (mapa['cena_nafty'] as num?)?.toDouble(),
        vin: mapa['vin'] as String? ?? '',
        znackaTyp: mapa['znacka_typ'] as String? ?? '',
        kategoria: mapa['kategoria'] as String? ?? 'M1',
        vodic: mapa['vodic'] as String? ?? '',
        pociatocnyTachometer: (mapa['pociatocny_tachometer'] as num?)
            ?.toDouble(),
        oblubeneMiesta: OblubeneMiesto.zJson(
          mapa['oblubene_miesta'] as String?,
        ),
        bluetoothAuta: mapa['bluetooth_auta'] as String?,
        bluetoothAutaNazov: mapa['bluetooth_auta_nazov'] as String?,
      );

  String _novyCloudId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
}

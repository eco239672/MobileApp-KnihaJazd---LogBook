import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniha_jazd/models/jazda.dart';
import 'package:kniha_jazd/models/nastavenia_vozidla.dart';
import 'package:kniha_jazd/models/synchronizacia.dart';
import 'package:kniha_jazd/services/lokalne_ulozisko.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Jazda _jazda({String? cloudId, double km = 10, String kam = 'Nitra'}) => Jazda(
  cloudId: cloudId,
  datum: DateTime(2026, 11, 10, 8, 0),
  odkial: 'Šaľa',
  kam: kam,
  zaciatok: '08:00',
  koniec: '08:40',
  kilometre: km,
  typ: TypJazdy.sluzobna,
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory priecinok;
  late String cesta;

  setUp(() async {
    priecinok = await Directory.systemTemp.createTemp('kniha_jazd_sync_');
    cesta = path.join(priecinok.path, 'kniha_jazd.db');
    // Pridané ako prvé, preto sa spustí až po zatvorení databázy v teste.
    addTearDown(() async {
      await deleteDatabase(cesta);
      await priecinok.delete(recursive: true);
    });
  });

  test('vymazaná jazda sa skryje, odošle sa ako zmazanie a potom zmizne', () async {
    final ulozisko = SqliteLokalneUlozisko(databazovaCesta: cesta);
    addTearDown(ulozisko.zavriet);

    final jazda = await ulozisko.ulozitJazdu(_jazda());
    await ulozisko.oznacitOdoslane(await ulozisko.nacitatNeodoslaneJazdy());
    expect(await ulozisko.nacitatNeodoslaneJazdy(), isEmpty);

    await ulozisko.vymazatJazdy([jazda]);
    expect((await ulozisko.nacitat()).jazdy, isEmpty);

    final zmeny = await ulozisko.nacitatNeodoslaneJazdy();
    expect(zmeny, hasLength(1));
    expect(zmeny.single.vymazana, isTrue);
    expect(zmeny.single.cloudId, jazda.cloudId);

    await ulozisko.oznacitOdoslane(zmeny);
    expect(await ulozisko.nacitatNeodoslaneJazdy(), isEmpty);
  });

  test('úprava počas odosielania zostane na odoslanie', () async {
    final ulozisko = SqliteLokalneUlozisko(databazovaCesta: cesta);
    addTearDown(ulozisko.zavriet);

    final jazda = await ulozisko.ulozitJazdu(_jazda());
    final odosielane = await ulozisko.nacitatNeodoslaneJazdy();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await ulozisko.ulozitJazdu(jazda.copyWith(kilometre: 12));
    await ulozisko.oznacitOdoslane(odosielane);

    final zostava = await ulozisko.nacitatNeodoslaneJazdy();
    expect(zostava, hasLength(1));
    expect(zostava.single.jazda!.kilometre, 12);
  });

  test('z cloudu sa prevezme len novšia verzia jazdy', () async {
    final ulozisko = SqliteLokalneUlozisko(databazovaCesta: cesta);
    addTearDown(ulozisko.zavriet);

    final jazda = await ulozisko.ulozitJazdu(_jazda(cloudId: 'a', km: 10));
    final miestna = (await ulozisko.nacitatNeodoslaneJazdy()).single;

    // Staršia verzia z cloudu: ignoruje sa.
    expect(
      await ulozisko.aplikovatJazdyZCloudu([
        ZmenaJazdy(
          cloudId: 'a',
          upravene: miestna.upravene - 1000,
          jazda: _jazda(km: 99),
        ),
      ]),
      isFalse,
    );
    expect((await ulozisko.nacitat()).jazdy.single.kilometre, 10);

    // Novšia verzia z cloudu: prepíše miestnu a nie je čo odosielať.
    expect(
      await ulozisko.aplikovatJazdyZCloudu([
        ZmenaJazdy(
          cloudId: 'a',
          upravene: miestna.upravene + 1000,
          jazda: _jazda(km: 15),
        ),
      ]),
      isTrue,
    );
    final nacitane = (await ulozisko.nacitat()).jazdy.single;
    expect(nacitane.kilometre, 15);
    expect(nacitane.id, jazda.id);
    expect(await ulozisko.nacitatNeodoslaneJazdy(), isEmpty);

    // Nová jazda z iného zariadenia a zmazanie z cloudu.
    await ulozisko.aplikovatJazdyZCloudu([
      ZmenaJazdy(cloudId: 'b', upravene: 1, jazda: _jazda(kam: 'Komárno')),
    ]);
    expect((await ulozisko.nacitat()).jazdy, hasLength(2));
    await ulozisko.aplikovatJazdyZCloudu([
      ZmenaJazdy(cloudId: 'b', upravene: 2, vymazana: true),
    ]);
    expect((await ulozisko.nacitat()).jazdy.single.kam, 'Nitra');
  });

  test('nastavenia: odoslanie a prevzatie novšej verzie z cloudu', () async {
    final ulozisko = SqliteLokalneUlozisko(databazovaCesta: cesta);
    addTearDown(ulozisko.zavriet);

    await ulozisko.ulozitNastavenia(const NastaveniaVozidla(spz: 'NZ111AA'));
    final zmena = await ulozisko.nacitatNeodoslaneNastavenia();
    expect(zmena?.nastavenia.spz, 'NZ111AA');
    await ulozisko.oznacitNastaveniaOdoslane(zmena!.upravene);
    expect(await ulozisko.nacitatNeodoslaneNastavenia(), isNull);

    expect(
      await ulozisko.aplikovatNastaveniaZCloudu(
        ZmenaNastaveni(
          nastavenia: const NastaveniaVozidla(spz: 'BA222BB'),
          upravene: zmena.upravene + 1000,
        ),
      ),
      isTrue,
    );
    expect((await ulozisko.nacitat()).nastavenia.spz, 'BA222BB');

    await ulozisko.ulozitCasStiahnutia(123456);
    expect(await ulozisko.nacitatCasStiahnutia(), 123456);
  });

  test('aktualizácia zo staršej databázy (verzia 4) zachová jazdy', () async {
    final stara = await openDatabase(
      cesta,
      version: 4,
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
        await db.execute(
          'CREATE UNIQUE INDEX jazdy_cloud_id ON jazdy(cloud_id)',
        );
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
    );
    await stara.insert('jazdy', {
      'cloud_id': 'stara-1',
      'datum': DateTime(2025, 3, 1).toIso8601String(),
      'odkial': 'Šaľa',
      'kam': 'Nitra',
      'zaciatok': '08:00',
      'koniec': '08:45',
      'kilometre': 43.7,
      'typ': 'sluzobna',
    });
    await stara.close();

    final ulozisko = SqliteLokalneUlozisko(databazovaCesta: cesta);
    addTearDown(ulozisko.zavriet);
    final nacitane = await ulozisko.nacitat();
    expect(nacitane.jazdy, hasLength(1));
    expect(nacitane.jazdy.single.cloudId, 'stara-1');
    // Po aktualizácii sa staré jazdy odošlú do cloudu.
    expect(await ulozisko.nacitatNeodoslaneJazdy(), hasLength(1));
  });
}

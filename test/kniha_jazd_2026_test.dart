import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kniha_jazd/models/jazda.dart';
import 'package:kniha_jazd/models/nastavenia_vozidla.dart';
import 'package:kniha_jazd/services/doplnenie_adries.dart';
import 'package:kniha_jazd/services/excel_export_service.dart';
import 'package:kniha_jazd/services/kniha_jazd_vypocty.dart';
import 'package:kniha_jazd/services/lokalne_ulozisko.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _domov = '48.15100, 17.87650';
const _praca = '48.31257, 18.09061';

Jazda _gpsJazda({
  int? id,
  String odkial = _domov,
  String kam = _praca,
  DateTime? datum,
  String zaciatok = '08:00',
  double km = 45,
  TypJazdy typ = TypJazdy.sluzobna,
  double? tachometerPo,
}) => Jazda(
  id: id,
  datum: datum ?? DateTime(2026, 11, 10, 8),
  odkial: odkial,
  kam: kam,
  odkialSuradnice: _domov,
  kamSuradnice: _praca,
  zaciatok: zaciatok,
  koniec: '09:00',
  kilometre: km,
  typ: typ,
  tachometerPo: tachometerPo,
);

void main() {
  group('súradnice', () {
    test('formát sa dá prečítať späť', () {
      final bod = precitatSuradnice(formatovatSuradnice(48.151, 17.8765));
      expect(bod?.latitude, closeTo(48.151, 1e-9));
      expect(bod?.longitude, closeTo(17.8765, 1e-9));
      expect(precitatSuradnice('Šaľa'), isNull);
      expect(precitatSuradnice(null), isNull);
    });

    test('vzdušná vzdialenosť Šaľa – Nitra je približne 24 km', () {
      final metre = vzdialenostMetre(48.151, 17.8765, 48.31257, 18.09061);
      expect(metre, closeTo(24000, 500));
    });
  });

  group('doplnenie adries', () {
    test('obľúbené miesto sa dosadí bez internetu', () {
      final jazda = DoplnenieAdries.pouzitOblubeneMiesta(_gpsJazda(), const [
        OblubeneMiesto(nazov: 'Domov', latitude: 48.1511, longitude: 17.8766),
      ]);
      expect(jazda.odkial, 'Domov');
      expect(jazda.kam, _praca, reason: 'Práca nie je obľúbené miesto');
      expect(jazda.odkialSuradnice, _domov, reason: 'Súradnice ostanú ako dôkaz');
    });

    test('adresa nahradí súradnice, ručný text sa neprepíše', () async {
      final dopyty = <String>[];
      final doplnenie = DoplnenieAdries(
        zistitAdresu: (lat, lon) async {
          dopyty.add(formatovatSuradnice(lat, lon));
          return lat > 48.2 ? 'Štefánikova 1, Nitra' : 'Hlavná 12, Šaľa';
        },
      );
      final zmenene = await doplnenie.doplnit([
        _gpsJazda(id: 1),
        _gpsJazda(id: 2, odkial: 'Sklad'),
      ], const []);

      expect(zmenene, hasLength(2));
      final prva = zmenene.firstWhere((jazda) => jazda.id == 1);
      expect(prva.odkial, 'Hlavná 12, Šaľa');
      expect(prva.kam, 'Štefánikova 1, Nitra');
      final druha = zmenene.firstWhere((jazda) => jazda.id == 2);
      expect(druha.odkial, 'Sklad', reason: 'Ručne zadané miesto ostáva');
      expect(dopyty.toSet(), hasLength(2), reason: 'Rovnaké miesta sa nepýtajú znova');
    });

    test('bez internetu sa nič nezmení a ďalšie dopyty sa nerobia', () async {
      var dopytov = 0;
      final doplnenie = DoplnenieAdries(
        zistitAdresu: (_, _) async {
          dopytov++;
          return null;
        },
      );
      final zmenene = await doplnenie.doplnit([
        _gpsJazda(id: 1),
        _gpsJazda(id: 2, datum: DateTime(2026, 11, 11)),
      ], const []);
      expect(zmenene, isEmpty);
      expect(dopytov, 1);
    });
  });

  group('kniha jázd', () {
    test('tachometer, poradové čísla a vodič', () {
      const nastavenia = NastaveniaVozidla(
        pociatocnyTachometer: 10000,
        vodic: 'Ján Vzorový',
      );
      final riadky = zostavitKnihuJazd([
        _gpsJazda(datum: DateTime(2026, 12, 30), km: 40),
        _gpsJazda(datum: DateTime(2026, 12, 31), km: 60),
        _gpsJazda(datum: DateTime(2027, 1, 2), km: 10),
      ], nastavenia);

      expect(riadky.map((riadok) => riadok.poradoveCislo), [1, 2, 1]);
      expect(riadky.first.vodic, 'Ján Vzorový');
      expect(riadky[0].tachometerPred, 10000);
      expect(riadky[0].tachometerPo, 10040);
      expect(riadky[1].tachometerPo, 10100);
      expect(riadky[2].tachometerPo, 10110);
      expect(stavTachometraNaKonciRokov(riadky), {2026: 10100, 2027: 10110});
    });

    test('zadaný stav tachometra vyrovná rozdiel oproti GPS', () {
      final riadky = zostavitKnihuJazd([
        _gpsJazda(datum: DateTime(2026, 11, 1), km: 40),
        _gpsJazda(datum: DateTime(2026, 11, 2), km: 60, tachometerPo: 10102),
        _gpsJazda(datum: DateTime(2026, 11, 3), km: 10),
      ], const NastaveniaVozidla(pociatocnyTachometer: 10000));

      expect(riadky[1].tachometerPred, 10040);
      expect(riadky[1].tachometerPo, 10102);
      expect(riadky[1].kilometre, 62, reason: 'Kilometre podľa tachometra');
      expect(riadky[2].tachometerPred, 10102);
      expect(riadky[2].tachometerPo, 10112);
    });

    test('služobná jazda bez účelu je označená', () {
      expect(_gpsJazda().chybaUcel, isTrue);
      expect(_gpsJazda().copyWith(ucel: 'Porada').chybaUcel, isFalse);
      expect(_gpsJazda(typ: TypJazdy.sukromna).chybaUcel, isFalse);
    });
  });

  test('Excel obsahuje údaje elektronickej knihy jázd', () {
    final obsah = ExcelExportService().vytvoritObsah(
      jazdy: [_gpsJazda(odkial: 'Domov', kam: 'Práca').copyWith(ucel: 'Porada')],
      nastavenia: const NastaveniaVozidla(
        spz: 'NZ123AB',
        vin: 'TMBJJ7NE0K0123456',
        vodic: 'Ján Vzorový',
        pociatocnyTachometer: 10000,
      ),
    );
    final subor = Excel.decodeBytes(obsah);
    final mesiac = subor.tables['November 2026']!;
    final texty = [
      for (final riadok in mesiac.rows)
        for (final bunka in riadok) '${bunka?.value ?? ''}',
    ];
    expect(texty, contains('TMBJJ7NE0K0123456'));
    expect(texty, containsAll(['Č.', 'Vodič', 'Účel jazdy', 'Tachometer po (km)']));
    expect(texty, containsAll(['Ján Vzorový', 'Porada', 'Domov', 'Práca']));
  });

  group('databáza', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    test('nové údaje jazdy a vozidla sa uložia', () async {
      final priecinok = await Directory.systemTemp.createTemp('kniha_jazd_v6_');
      final cesta = path.join(priecinok.path, 'kniha_jazd.db');
      final ulozisko = SqliteLokalneUlozisko(databazovaCesta: cesta);
      addTearDown(() async {
        await ulozisko.zavriet();
        await priecinok.delete(recursive: true);
      });

      await ulozisko.ulozitJazdu(
        _gpsJazda().copyWith(
          ucel: 'Porada',
          vodic: 'Ján',
          tachometerPo: 12345.6,
          autoBluetooth: false,
        ),
      );
      await ulozisko.ulozitNastavenia(
        const NastaveniaVozidla(
          spz: 'NZ123AB',
          vin: 'TMBJJ7NE0K0123456',
          pociatocnyTachometer: 10000,
          oblubeneMiesta: [
            OblubeneMiesto(nazov: 'Domov', latitude: 48.151, longitude: 17.8765),
          ],
          bluetoothAuta: 'AA:BB:CC:DD:EE:FF',
          bluetoothAutaNazov: 'Moje auto',
        ),
      );
      final nacitane = await ulozisko.nacitat();
      final jazda = nacitane.jazdy.single;
      expect(jazda.ucel, 'Porada');
      expect(jazda.vodic, 'Ján');
      expect(jazda.tachometerPo, 12345.6);
      expect(jazda.autoBluetooth, isFalse);
      expect(jazda.odkialSuradnice, _domov);
      expect(nacitane.nastavenia.vin, 'TMBJJ7NE0K0123456');
      expect(nacitane.nastavenia.oblubeneMiesta.single.nazov, 'Domov');
      expect(nacitane.nastavenia.bluetoothAutaNazov, 'Moje auto');
    });

    test('aktualizácia z verzie 5 zachová jazdy a súradnice uloží ako dôkaz', () async {
      final priecinok = await Directory.systemTemp.createTemp('kniha_jazd_v5_');
      final cesta = path.join(priecinok.path, 'kniha_jazd.db');
      addTearDown(() => priecinok.delete(recursive: true));

      // Databáza v podobe, akú mala aplikácia pred touto verziou.
      final stara = await openDatabase(
        cesta,
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
          await db.execute(
            'CREATE UNIQUE INDEX jazdy_cloud_id ON jazdy(cloud_id)',
          );
          await db.execute(
            'CREATE TABLE meta(kluc TEXT PRIMARY KEY, hodnota TEXT)',
          );
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
      );
      for (final (cloudId, odkial) in [('gps-1', _domov), ('rucna-1', 'Šaľa')]) {
        await stara.insert('jazdy', {
          'cloud_id': cloudId,
          'datum': DateTime(2026, 11, 10).toIso8601String(),
          'odkial': odkial,
          'kam': 'Nitra',
          'zaciatok': '08:00',
          'koniec': '09:00',
          'kilometre': 45.0,
          'typ': 'sluzobna',
        });
      }
      await stara.insert('nastavenia_vozidla', {'id': 1, 'spz': 'NZ123AB'});
      await stara.close();

      final ulozisko = SqliteLokalneUlozisko(databazovaCesta: cesta);
      addTearDown(ulozisko.zavriet);
      final nacitane = await ulozisko.nacitat();
      final gps = nacitane.jazdy.firstWhere((jazda) => jazda.cloudId == 'gps-1');
      final rucna = nacitane.jazdy.firstWhere(
        (jazda) => jazda.cloudId == 'rucna-1',
      );
      expect(gps.odkialSuradnice, _domov);
      expect(gps.odkialJeSuradnica, isTrue);
      expect(rucna.odkialSuradnice, isNull);
      expect(rucna.ucel, '');
      expect(nacitane.nastavenia.spz, 'NZ123AB');
      expect(nacitane.nastavenia.kategoria, 'M1');
      expect(nacitane.nastavenia.oblubeneMiesta, isEmpty);
    });
  });
}

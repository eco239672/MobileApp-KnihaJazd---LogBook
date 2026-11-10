import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniha_jazd/models/jazda.dart';
import 'package:kniha_jazd/models/nastavenia_vozidla.dart';
import 'package:kniha_jazd/services/lokalne_ulozisko.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'zostanú uložené jazda aj nastavenia po znovuotvorení databázy',
    () async {
      final priecinok = await Directory.systemTemp.createTemp(
        'kniha_jazd_test_',
      );
      final cesta = path.join(priecinok.path, 'kniha_jazd.db');
      final ulozisko = SqliteLokalneUlozisko(databazovaCesta: cesta);
      addTearDown(() async {
        await ulozisko.zavriet();
        await deleteDatabase(cesta);
        await priecinok.delete(recursive: true);
      });

      final vytvorenaJazda = await ulozisko.ulozitJazdu(
        Jazda(
          datum: DateTime(2026, 11, 10, 8, 30),
          odkial: 'Šaľa',
          kam: 'Nové Zámky',
          zaciatok: '08:30',
          koniec: '09:05',
          kilometre: 31.2,
          typ: TypJazdy.sluzobna,
        ),
      );
      await ulozisko.ulozitNastavenia(
        const NastaveniaVozidla(
          spz: 'NZ123AB',
          priemernaSpotreba: 6.4,
          cenaBenzinu: 1.55,
          cenaNafty: 1.48,
        ),
      );
      await ulozisko.zavriet();

      final znovuotvoreneUlozisko = SqliteLokalneUlozisko(
        databazovaCesta: cesta,
      );
      addTearDown(znovuotvoreneUlozisko.zavriet);
      final nacitane = await znovuotvoreneUlozisko.nacitat();

      expect(vytvorenaJazda.id, isNotNull);
      expect(nacitane.jazdy, hasLength(1));
      expect(nacitane.jazdy.single.id, vytvorenaJazda.id);
      expect(nacitane.jazdy.single.kilometre, 31.2);
      expect(nacitane.nastavenia.spz, 'NZ123AB');
      expect(nacitane.nastavenia.priemernaSpotreba, 6.4);
      expect(nacitane.nastavenia.cenaBenzinu, 1.55);
      expect(nacitane.nastavenia.cenaNafty, 1.48);
    },
  );
}

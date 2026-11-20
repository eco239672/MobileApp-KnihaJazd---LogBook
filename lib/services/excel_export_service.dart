import 'dart:io';

import 'package:excel/excel.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models/jazda.dart';
import '../models/nastavenia_vozidla.dart';
import '../utils/format_datumu.dart';
import 'kniha_jazd_vypocty.dart';

/// Export knihy jázd do Excelu (elektronicky spracovateľný formát).
///
/// Obsahuje údaje elektronickej knihy jázd: o vozidle (EČV, VIN, názov a typ,
/// kategória, stav tachometra na začiatku evidencie a na konci každého roka)
/// a o každej jazde (poradové číslo, vodič, dátum a čas, účel, odkiaľ – kam,
/// kilometre a stav tachometra pred jazdou a po nej).
class ExcelExportService {
  List<int> vytvoritObsah({
    required List<Jazda> jazdy,
    required NastaveniaVozidla nastavenia,
  }) {
    final excel = Excel.createExcel();
    excel.rename('Sheet1', 'Ročný prehľad');
    final prehlad = excel['Ročný prehľad'];
    final riadky = zostavitKnihuJazd(jazdy, nastavenia);
    final riadkyPodlaMesiaca = _podlaMesiaca(riadky);

    _pridatPrehlad(
      sheet: prehlad,
      riadky: riadky,
      riadkyPodlaMesiaca: riadkyPodlaMesiaca,
      nastavenia: nastavenia,
    );

    for (final zaznam in riadkyPodlaMesiaca.entries) {
      _pridatMesacnyList(
        excel: excel,
        datumMesiaca: zaznam.key,
        riadky: zaznam.value,
        nastavenia: nastavenia,
      );
    }

    final obsah = excel.encode();
    if (obsah == null) {
      throw StateError('Súbor programu Excel sa nepodarilo vytvoriť.');
    }
    return obsah;
  }

  Future<File> vytvoritSubor({
    required List<Jazda> jazdy,
    required NastaveniaVozidla nastavenia,
  }) async {
    final adresar = await getTemporaryDirectory();
    final roky = jazdy.map((jazda) => jazda.datum.year).toSet().toList()
      ..sort();
    final obdobie = roky.isEmpty
        ? '${DateTime.now().year}'
        : roky.first == roky.last
        ? '${roky.first}'
        : '${roky.first}-${roky.last}';
    final subor = File(path.join(adresar.path, 'kniha_jazd_$obdobie.xlsx'));
    await subor.writeAsBytes(
      vytvoritObsah(jazdy: jazdy, nastavenia: nastavenia),
      flush: true,
    );
    return subor;
  }

  Map<DateTime, List<RiadokKnihyJazd>> _podlaMesiaca(
    List<RiadokKnihyJazd> riadky,
  ) {
    final vysledok = <DateTime, List<RiadokKnihyJazd>>{};
    for (final riadok in riadky) {
      final mesiac = DateTime(riadok.jazda.datum.year, riadok.jazda.datum.month);
      vysledok.putIfAbsent(mesiac, () => []).add(riadok);
    }
    return vysledok;
  }

  void _pridatPrehlad({
    required Sheet sheet,
    required List<RiadokKnihyJazd> riadky,
    required Map<DateTime, List<RiadokKnihyJazd>> riadkyPodlaMesiaca,
    required NastaveniaVozidla nastavenia,
  }) {
    sheet.appendRow([TextCellValue('Kniha jázd – ročný prehľad')]);
    _pridatUdajeVozidla(sheet, nastavenia);
    final pociatocny = nastavenia.pociatocnyTachometer;
    sheet.appendRow([
      TextCellValue('Stav tachometra na začiatku evidencie (km)'),
      _cisloAleboPrazdne(pociatocny),
    ]);
    stavTachometraNaKonciRokov(riadky).forEach((rok, stav) {
      sheet.appendRow([
        TextCellValue('Stav tachometra k 31. 12. $rok (km)'),
        _cisloAleboPrazdne(stav),
      ]);
    });
    final bezUcelu = riadky.where((riadok) => riadok.jazda.chybaUcel).length;
    if (bezUcelu > 0) {
      sheet.appendRow([
        TextCellValue('Upozornenie'),
        TextCellValue(
          'Služobné jazdy bez vyplneného účelu: $bezUcelu. Pre daňové účely treba účel doplniť.',
        ),
      ]);
    }
    if (pociatocny == null) {
      sheet.appendRow([
        TextCellValue('Upozornenie'),
        TextCellValue(
          'Nie je zadaný stav tachometra na začiatku evidencie (Nastavenia → Vozidlo).',
        ),
      ]);
    }
    sheet.appendRow([]);
    sheet.appendRow([
      TextCellValue('Mesiac'),
      TextCellValue('Počet jázd'),
      TextCellValue('Kilometre spolu'),
      TextCellValue('Služobné km'),
      TextCellValue('Súkromné km'),
      TextCellValue('Odhad paliva (l)'),
    ]);

    var pocetSpolu = 0;
    var kmSpolu = 0.0;
    var sluzobneSpolu = 0.0;
    var sukromneSpolu = 0.0;
    for (final zaznam in riadkyPodlaMesiaca.entries) {
      final kilometre = _kilometre(zaznam.value);
      final sluzobne = _kilometre(zaznam.value, typ: TypJazdy.sluzobna);
      final sukromne = _kilometre(zaznam.value, typ: TypJazdy.sukromna);
      pocetSpolu += zaznam.value.length;
      kmSpolu += kilometre;
      sluzobneSpolu += sluzobne;
      sukromneSpolu += sukromne;
      sheet.appendRow([
        TextCellValue('${nazovMesiaca(zaznam.key.month)} ${zaznam.key.year}'),
        IntCellValue(zaznam.value.length),
        DoubleCellValue(_zaokruhlit(kilometre)),
        DoubleCellValue(_zaokruhlit(sluzobne)),
        DoubleCellValue(_zaokruhlit(sukromne)),
        _cisloAleboPrazdne(_spotreba(kilometre, nastavenia)),
      ]);
    }

    sheet.appendRow([
      TextCellValue('Spolu'),
      IntCellValue(pocetSpolu),
      DoubleCellValue(_zaokruhlit(kmSpolu)),
      DoubleCellValue(_zaokruhlit(sluzobneSpolu)),
      DoubleCellValue(_zaokruhlit(sukromneSpolu)),
      _cisloAleboPrazdne(_spotreba(kmSpolu, nastavenia)),
    ]);
  }

  void _pridatUdajeVozidla(Sheet sheet, NastaveniaVozidla nastavenia) {
    String alebo(String hodnota) =>
        hodnota.trim().isEmpty ? 'Nezadané' : hodnota.trim();
    sheet.appendRow([
      TextCellValue('Evidenčné číslo vozidla (EČV)'),
      TextCellValue(alebo(nastavenia.spz)),
    ]);
    sheet.appendRow([
      TextCellValue('VIN'),
      TextCellValue(alebo(nastavenia.vin)),
    ]);
    sheet.appendRow([
      TextCellValue('Názov a typ vozidla'),
      TextCellValue(alebo(nastavenia.znackaTyp)),
    ]);
    sheet.appendRow([
      TextCellValue('Kategória vozidla'),
      TextCellValue(alebo(nastavenia.kategoria)),
    ]);
  }

  void _pridatMesacnyList({
    required Excel excel,
    required DateTime datumMesiaca,
    required List<RiadokKnihyJazd> riadky,
    required NastaveniaVozidla nastavenia,
  }) {
    final nazovListu =
        '${nazovMesiaca(datumMesiaca.month)} ${datumMesiaca.year}';
    final sheet = excel[nazovListu];
    sheet.appendRow([TextCellValue('Kniha jázd – $nazovListu')]);
    _pridatUdajeVozidla(sheet, nastavenia);
    sheet.appendRow([]);
    sheet.appendRow([
      TextCellValue('Č.'),
      TextCellValue('Dátum'),
      TextCellValue('Začiatok'),
      TextCellValue('Koniec'),
      TextCellValue('Vodič'),
      TextCellValue('Odkiaľ'),
      TextCellValue('Kam'),
      TextCellValue('Účel jazdy'),
      TextCellValue('Typ jazdy'),
      TextCellValue('Tachometer pred (km)'),
      TextCellValue('Tachometer po (km)'),
      TextCellValue('Kilometre'),
      TextCellValue('Odhad paliva (l)'),
    ]);

    for (final riadok in riadky) {
      final jazda = riadok.jazda;
      sheet.appendRow([
        IntCellValue(riadok.poradoveCislo),
        DateCellValue.fromDateTime(jazda.datum),
        TextCellValue(jazda.zaciatok),
        TextCellValue(jazda.koniec),
        TextCellValue(riadok.vodic),
        TextCellValue(jazda.odkial),
        TextCellValue(jazda.kam),
        TextCellValue(jazda.ucel),
        TextCellValue(jazda.typ.nazov),
        _cisloAleboPrazdne(riadok.tachometerPred),
        _cisloAleboPrazdne(riadok.tachometerPo),
        DoubleCellValue(_zaokruhlit(riadok.kilometre)),
        _cisloAleboPrazdne(_spotreba(riadok.kilometre, nastavenia)),
      ]);
    }

    final kilometre = _kilometre(riadky);
    sheet.appendRow([
      TextCellValue('Spolu'),
      for (var i = 0; i < 10; i++) TextCellValue(''),
      DoubleCellValue(_zaokruhlit(kilometre)),
      _cisloAleboPrazdne(_spotreba(kilometre, nastavenia)),
    ]);
  }

  double _kilometre(List<RiadokKnihyJazd> riadky, {TypJazdy? typ}) =>
      riadky
          .where((riadok) => typ == null || riadok.jazda.typ == typ)
          .fold<double>(0, (sucet, riadok) => sucet + riadok.kilometre);

  double? _spotreba(double kilometre, NastaveniaVozidla nastavenia) {
    final priemernaSpotreba = nastavenia.priemernaSpotreba;
    return priemernaSpotreba == null
        ? null
        : kilometre * priemernaSpotreba / 100;
  }

  /// Na desatiny, aby v Exceli nebolo 12.300000000000001.
  double _zaokruhlit(double hodnota) => (hodnota * 10).roundToDouble() / 10;

  CellValue _cisloAleboPrazdne(double? hodnota) => hodnota == null
      ? TextCellValue('')
      : DoubleCellValue(_zaokruhlit(hodnota));
}

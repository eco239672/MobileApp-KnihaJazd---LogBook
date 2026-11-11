import 'dart:io';

import 'package:excel/excel.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models/jazda.dart';
import '../models/nastavenia_vozidla.dart';
import '../utils/format_datumu.dart';

class ExcelExportService {
  List<int> vytvoritObsah({
    required List<Jazda> jazdy,
    required NastaveniaVozidla nastavenia,
  }) {
    final excel = Excel.createExcel();
    excel.rename('Sheet1', 'Ročný prehľad');
    final prehlad = excel['Ročný prehľad'];
    final jazdyPodlaMesiaca = _jazdyPodlaMesiaca(jazdy);

    _pridatRocnyPrehlad(
      sheet: prehlad,
      jazdyPodlaMesiaca: jazdyPodlaMesiaca,
      nastavenia: nastavenia,
    );

    for (final zaznam in jazdyPodlaMesiaca.entries) {
      final datumMesiaca = zaznam.key;
      _pridatMesacnyList(
        excel: excel,
        datumMesiaca: datumMesiaca,
        jazdy: zaznam.value,
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
    final rok = jazdy.isEmpty ? DateTime.now().year : jazdy.first.datum.year;
    final subor = File(path.join(adresar.path, 'kniha_jazd_$rok.xlsx'));
    await subor.writeAsBytes(
      vytvoritObsah(jazdy: jazdy, nastavenia: nastavenia),
      flush: true,
    );
    return subor;
  }

  Map<DateTime, List<Jazda>> _jazdyPodlaMesiaca(List<Jazda> jazdy) {
    final zoradeneJazdy = [...jazdy]
      ..sort((prva, druha) => prva.datum.compareTo(druha.datum));
    final vysledok = <DateTime, List<Jazda>>{};
    for (final jazda in zoradeneJazdy) {
      final mesiac = DateTime(jazda.datum.year, jazda.datum.month);
      vysledok.putIfAbsent(mesiac, () => []).add(jazda);
    }
    return vysledok;
  }

  void _pridatRocnyPrehlad({
    required Sheet sheet,
    required Map<DateTime, List<Jazda>> jazdyPodlaMesiaca,
    required NastaveniaVozidla nastavenia,
  }) {
    sheet.appendRow([TextCellValue('Kniha jázd – ročný prehľad')]);
    sheet.appendRow([
      TextCellValue('SPZ'),
      TextCellValue(nastavenia.spz.isEmpty ? 'Nezadaná' : nastavenia.spz),
    ]);
    sheet.appendRow([]);
    sheet.appendRow([
      TextCellValue('Mesiac'),
      TextCellValue('Počet jázd'),
      TextCellValue('Kilometre'),
      TextCellValue('Odhad paliva (l)'),
    ]);

    var celkoveKilometre = 0.0;
    var celkovaSpotreba = 0.0;
    final maSpotrebu = nastavenia.priemernaSpotreba != null;
    var celkovyPocetJazd = 0;

    for (final zaznam in jazdyPodlaMesiaca.entries) {
      final kilometre = _kilometre(zaznam.value);
      final spotreba = _spotreba(kilometre, nastavenia);
      celkoveKilometre += kilometre;
      celkovyPocetJazd += zaznam.value.length;
      if (spotreba != null) celkovaSpotreba += spotreba;
      sheet.appendRow([
        TextCellValue('${nazovMesiaca(zaznam.key.month)} ${zaznam.key.year}'),
        IntCellValue(zaznam.value.length),
        DoubleCellValue(kilometre),
        spotreba == null ? TextCellValue('') : DoubleCellValue(spotreba),
      ]);
    }

    sheet.appendRow([
      TextCellValue('Spolu'),
      IntCellValue(celkovyPocetJazd),
      DoubleCellValue(celkoveKilometre),
      maSpotrebu ? DoubleCellValue(celkovaSpotreba) : TextCellValue(''),
    ]);
  }

  void _pridatMesacnyList({
    required Excel excel,
    required DateTime datumMesiaca,
    required List<Jazda> jazdy,
    required NastaveniaVozidla nastavenia,
  }) {
    final nazovListu =
        '${nazovMesiaca(datumMesiaca.month)} ${datumMesiaca.year}';
    final sheet = excel[nazovListu];
    sheet.appendRow([TextCellValue('Kniha jázd – $nazovListu')]);
    sheet.appendRow([
      TextCellValue('SPZ'),
      TextCellValue(nastavenia.spz.isEmpty ? 'Nezadaná' : nastavenia.spz),
    ]);
    sheet.appendRow([]);
    sheet.appendRow([
      TextCellValue('Dátum'),
      TextCellValue('Začiatok'),
      TextCellValue('Koniec'),
      TextCellValue('Odkiaľ'),
      TextCellValue('Kam'),
      TextCellValue('Typ jazdy'),
      TextCellValue('Kilometre'),
      TextCellValue('Odhad paliva (l)'),
    ]);

    for (final jazda in jazdy) {
      final spotreba = _spotreba(jazda.kilometre, nastavenia);
      sheet.appendRow([
        DateCellValue.fromDateTime(jazda.datum),
        TextCellValue(jazda.zaciatok),
        TextCellValue(jazda.koniec),
        TextCellValue(jazda.odkial),
        TextCellValue(jazda.kam),
        TextCellValue(jazda.typ.nazov),
        DoubleCellValue(jazda.kilometre),
        spotreba == null ? TextCellValue('') : DoubleCellValue(spotreba),
      ]);
    }

    final kilometre = _kilometre(jazdy);
    final spotreba = _spotreba(kilometre, nastavenia);
    sheet.appendRow([
      TextCellValue('Spolu'),
      TextCellValue(''),
      TextCellValue(''),
      TextCellValue(''),
      TextCellValue(''),
      TextCellValue(''),
      DoubleCellValue(kilometre),
      spotreba == null ? TextCellValue('') : DoubleCellValue(spotreba),
    ]);
  }

  double _kilometre(List<Jazda> jazdy) =>
      jazdy.fold(0, (sucet, jazda) => sucet + jazda.kilometre);

  double? _spotreba(double kilometre, NastaveniaVozidla nastavenia) {
    final priemernaSpotreba = nastavenia.priemernaSpotreba;
    return priemernaSpotreba == null
        ? null
        : kilometre * priemernaSpotreba / 100;
  }
}

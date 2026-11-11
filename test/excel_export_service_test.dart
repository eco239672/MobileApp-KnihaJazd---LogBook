import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kniha_jazd/models/jazda.dart';
import 'package:kniha_jazd/models/nastavenia_vozidla.dart';
import 'package:kniha_jazd/services/excel_export_service.dart';

void main() {
  test('vytvorí excel s ročným prehľadom a mesačným listom', () {
    final obsah = ExcelExportService().vytvoritObsah(
      jazdy: [
        Jazda(
          datum: DateTime(2026, 11, 10),
          odkial: 'Šaľa',
          kam: 'Nové Zámky',
          zaciatok: '08:15',
          koniec: '09:00',
          kilometre: 18.2,
          typ: TypJazdy.sluzobna,
        ),
      ],
      nastavenia: const NastaveniaVozidla(
        spz: 'NZ123AB',
        priemernaSpotreba: 6.5,
      ),
    );

    final subor = Excel.decodeBytes(obsah);

    expect(subor.tables.keys, containsAll(['Ročný prehľad', 'November 2026']));
  });
}

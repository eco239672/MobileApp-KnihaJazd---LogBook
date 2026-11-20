import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kniha_jazd/features/jazdy/detail_dna_page.dart';
import 'package:kniha_jazd/main.dart';
import 'package:kniha_jazd/models/jazda.dart';
import 'package:kniha_jazd/utils/format_datumu.dart';

import 'support/pamatove_lokalne_ulozisko.dart';

void main() {
  testWidgets('zobrazí prázdnu úvodnú obrazovku knihy jázd', (tester) async {
    await tester.pumpWidget(KnihaJazdApp(ulozisko: PamatoveLokalneUlozisko()));
    await tester.pumpAndSettle();

    expect(find.text('Kniha jázd – Drive Log Cloud'), findsOneWidget);
    expect(
      find.text('${nazovMesiaca(DateTime.now().month)} ${DateTime.now().year}'),
      findsOneWidget,
    );
    expect(find.text('0.0 km'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
    expect(find.text('Pridať jazdu'), findsNothing);
  });

  testWidgets('na hlavnej obrazovke zobrazí iba aktuálny mesiac', (
    tester,
  ) async {
    final ulozisko = PamatoveLokalneUlozisko();
    final dnes = DateTime.now();
    await ulozisko.ulozitJazdu(
      Jazda(
        datum: dnes,
        odkial: 'Aktuálna',
        kam: 'jazda',
        zaciatok: '08:00',
        koniec: '08:30',
        kilometre: 10,
        typ: TypJazdy.sluzobna,
      ),
    );
    await ulozisko.ulozitJazdu(
      Jazda(
        datum: DateTime(dnes.year, dnes.month - 1, 15),
        odkial: 'Staršia',
        kam: 'jazda',
        zaciatok: '08:00',
        koniec: '08:30',
        kilometre: 10,
        typ: TypJazdy.sluzobna,
      ),
    );

    await tester.pumpWidget(KnihaJazdApp(ulozisko: ulozisko));
    await tester.pumpAndSettle();

    expect(find.text('Aktuálna  →  jazda'), findsOneWidget);
    expect(find.text('Staršia  →  jazda'), findsNothing);
  });

  testWidgets('umožní upraviť kilometre jazdy vo vybranom dni', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DetailDnaPage(
          datum: '7. november 2026',
          onJazdaUpravena: (_) async {},
          jazdy: [
            JazdaDna(
              indexVZozname: 0,
              jazda: Jazda(
                datum: DateTime(2026, 11, 7),
                odkial: 'Bratislava',
                kam: 'Nitra',
                zaciatok: '07:30',
                koniec: '08:46',
                kilometre: 91.4,
                typ: TypJazdy.sluzobna,
              ),
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.text('Bratislava  →  Nitra'));
    await tester.pumpAndSettle();

    expect(find.text('Upraviť jazdu'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).at(4), '95,2');
    await tester.tap(find.text('Uložiť'));
    await tester.pumpAndSettle();

    expect(find.text('95.2 km'), findsNWidgets(2));
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'features/jazdy/detail_dna_page.dart';
import 'features/jazdy/widgets/jazda_polozka.dart';
import 'features/nastavenia/nastavenia_vozidla_page.dart';
import 'models/jazda.dart';
import 'models/nastavenia_vozidla.dart';
import 'models/trasa_bod.dart';
import 'services/gps_tracking_service.dart';
import 'services/lokalne_ulozisko.dart';
import 'services/rozpoznavanie_aktivity_service.dart';
import 'utils/format_datumu.dart';

void main() {
  runApp(const KnihaJazdApp());
}

class KnihaJazdApp extends StatelessWidget {
  const KnihaJazdApp({this.ulozisko, super.key});

  final LokalneUlozisko? ulozisko;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kniha jázd – Drive Log Cloud',
      debugShowCheckedModeBanner: false,
      locale: const Locale('sk'),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('sk')],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B6E69)),
        useMaterial3: true,
      ),
      home: KnihaJazdHomePage(ulozisko: ulozisko),
    );
  }
}

class KnihaJazdHomePage extends StatefulWidget {
  const KnihaJazdHomePage({this.ulozisko, super.key});

  final LokalneUlozisko? ulozisko;

  @override
  State<KnihaJazdHomePage> createState() => _KnihaJazdHomePageState();
}

class _KnihaJazdHomePageState extends State<KnihaJazdHomePage> {
  final _gpsTracking = GpsTrackingService();
  final _rozpoznavanieAktivity = RozpoznavanieAktivityService();
  late final LokalneUlozisko _ulozisko;
  NastaveniaVozidla _nastaveniaVozidla = const NastaveniaVozidla();
  var _vybranaZalozka = 0;
  final List<Jazda> _jazdy = [];
  late final StreamSubscription<DokoncenaGpsJazda> _dokoncenaJazda;
  late final StreamSubscription<bool> _stavVozidla;

  late DateTime _vybranyDatum;
  var _nacitavaUdaje = true;

  @override
  void initState() {
    super.initState();
    _ulozisko = widget.ulozisko ?? SqliteLokalneUlozisko();
    _vybranyDatum = DateTime.now();
    _gpsTracking.addListener(_obnovitGpsStav);
    _dokoncenaJazda = _gpsTracking.dokonceneJazdy.listen(
      _ulozitAutomatickuJazdu,
    );
    _stavVozidla = _rozpoznavanieAktivity.stavVozidla.listen(
      _spracovatStavVozidla,
    );
    _inicializovatAplikaciu();
  }

  Future<void> _inicializovatAplikaciu() async {
    try {
      final udaje = await _ulozisko.nacitat();
      if (!mounted) return;
      setState(() {
        _jazdy
          ..clear()
          ..addAll(udaje.jazdy);
        _nastaveniaVozidla = udaje.nastavenia;
        _nacitavaUdaje = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _nacitavaUdaje = false);
      _zobrazitSpravu('Lokálne údaje sa nepodarilo načítať.');
    }
    await _pripravitAutomatickeSledovanie();
  }

  Future<void> _pripravitAutomatickeSledovanie() async {
    final stav = await _rozpoznavanieAktivity.zistitStav();
    if (stav.aktivne && stav.vAute) {
      await _spustitAutomatickeSledovanie();
    }
  }

  Future<void> _spustitAutomatickeSledovanie() async {
    try {
      await _gpsTracking.zacatSledovanie();
    } on GpsTrackingException catch (chyba) {
      _zobrazitSpravu(chyba.sprava);
    } catch (_) {
      _zobrazitSpravu('Automatické GPS sledovanie sa nepodarilo spustiť.');
    }
  }

  Future<void> _spracovatStavVozidla(bool vAute) async {
    if (vAute) {
      await _spustitAutomatickeSledovanie();
    } else if (_gpsTracking.sledovanieBezi) {
      await _gpsTracking.zastavitSledovanie();
    }
  }

  Future<StavRozpoznavaniaAktivity> _povolitRozpoznavanie() async {
    final stav = await _rozpoznavanieAktivity.povolitASpustit();
    if (stav.vAute) await _spustitAutomatickeSledovanie();
    return stav;
  }

  @override
  void dispose() {
    _dokoncenaJazda.cancel();
    _stavVozidla.cancel();
    _gpsTracking
      ..removeListener(_obnovitGpsStav)
      ..dispose();
    _ulozisko.zavriet();
    super.dispose();
  }

  Future<void> _ulozitAutomatickuJazdu(DokoncenaGpsJazda jazda) async {
    String miesto(TrasaBod bod) =>
        '${bod.latitude.toStringAsFixed(5)}, ${bod.longitude.toStringAsFixed(5)}';
    String cas(DateTime datum) =>
        '${datum.hour.toString().padLeft(2, '0')}:${datum.minute.toString().padLeft(2, '0')}';
    final ukladanaJazda = Jazda(
      datum: jazda.zaciatok.cas,
      odkial: miesto(jazda.zaciatok),
      kam: miesto(jazda.koniec),
      zaciatok: cas(jazda.zaciatok.cas),
      koniec: cas(jazda.koniec.cas),
      kilometre: jazda.prejdeneMetre / 1000,
      typ: TypJazdy.sluzobna,
    );
    try {
      final ulozenaJazda = await _ulozisko.ulozitJazdu(ukladanaJazda);
      if (!mounted) return;
      setState(() => _jazdy.add(ulozenaJazda));
    } catch (_) {
      _zobrazitSpravu('Automatickú jazdu sa nepodarilo uložiť.');
      return;
    }
    _zobrazitSpravu('Služobná jazda bola automaticky zaznamenaná.');
  }

  void _obnovitGpsStav() {
    if (mounted) setState(() {});
  }

  void _zobrazitSpravu(String sprava) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(sprava)));
  }

  Future<void> _ulozitNastaveniaVozidla(NastaveniaVozidla nastavenia) async {
    await _ulozisko.ulozitNastavenia(nastavenia);
    setState(() => _nastaveniaVozidla = nastavenia);
  }

  Future<void> _upravitJazdu(JazdaDna upravenaJazda) async {
    final ulozenaJazda = await _ulozisko.ulozitJazdu(upravenaJazda.jazda);
    if (!mounted) return;
    setState(() {
      _jazdy[upravenaJazda.indexVZozname] = ulozenaJazda;
    });
  }

  Future<void> _otvoritKalendar() async {
    final aktualnyRok = DateTime.now().year;
    final vybranyDatum = await showDatePicker(
      context: context,
      initialDate: _vybranyDatum,
      firstDate: DateTime(aktualnyRok),
      lastDate: DateTime(aktualnyRok + 1, 12, 31),
      helpText: 'Vyber dátum jázd',
      cancelText: 'Zrušiť',
      confirmText: 'Vybrať',
    );

    if (vybranyDatum == null || !mounted) return;

    setState(() => _vybranyDatum = vybranyDatum);
    await _otvoritDetailDna(vybranyDatum);
  }

  Future<void> _otvoritDetailDna(DateTime datum) async {
    final jazdyDna = _jazdy
        .asMap()
        .entries
        .where((zaznam) => jeRovnakyDen(zaznam.value.datum, datum))
        .map(
          (zaznam) => JazdaDna(indexVZozname: zaznam.key, jazda: zaznam.value),
        )
        .toList();

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => DetailDnaPage(
          datum: formatovatDatum(datum),
          jazdy: jazdyDna,
          onJazdaUpravena: _upravitJazdu,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final jazdyVMesiaci = _jazdy
        .where(
          (jazda) =>
              jazda.datum.year == _vybranyDatum.year &&
              jazda.datum.month == _vybranyDatum.month,
        )
        .toList();
    final kilometre = jazdyVMesiaci.fold<double>(
      0,
      (sucet, jazda) => sucet + jazda.kilometre,
    );
    final spotrebaPaliva = _nastaveniaVozidla.priemernaSpotreba == null
        ? null
        : kilometre * _nastaveniaVozidla.priemernaSpotreba! / 100;
    final jazdyPodlaDna = <String, List<Jazda>>{};
    for (final jazda in _jazdy) {
      jazdyPodlaDna
          .putIfAbsent(formatovatDatum(jazda.datum), () => [])
          .add(jazda);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _vybranaZalozka == 2 ? 'Nastavenia' : 'Kniha jázd – Drive Log Cloud',
        ),
        actions: [
          if (_vybranaZalozka == 0)
            IconButton(
              tooltip: 'Otvoriť kalendár',
              onPressed: _otvoritKalendar,
              icon: const Icon(Icons.calendar_month_outlined),
            ),
        ],
      ),
      body: SafeArea(
        child: _nacitavaUdaje
            ? const Center(child: CircularProgressIndicator())
            : _vybranaZalozka == 2
            ? NastaveniaVozidlaPage(
                nastavenia: _nastaveniaVozidla,
                onUlozit: _ulozitNastaveniaVozidla,
                onSpatNaJazdy: () {
                  setState(() => _vybranaZalozka = 0);
                },
                onPovolitRozpoznavanie: _povolitRozpoznavanie,
                onZistitStavRozpoznavania: _rozpoznavanieAktivity.zistitStav,
              )
            : _vybranaZalozka == 1
            ? const _PrehladPlaceholder()
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: [
                  Text(
                    '${nazovMesiaca(_vybranyDatum.month)} ${_vybranyDatum.year}',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  Card(
                    color: theme.colorScheme.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        children: [
                          Expanded(
                            child: _Statistika(
                              popis: 'Prejdené kilometre',
                              hodnota: '${kilometre.toStringAsFixed(1)} km',
                            ),
                          ),
                          Container(
                            height: 46,
                            width: 1,
                            color: theme.colorScheme.onPrimaryContainer
                                .withValues(alpha: 0.2),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: _Statistika(
                              popis: 'Záznamy',
                              hodnota: '${jazdyVMesiaci.length}',
                            ),
                          ),
                          Container(
                            height: 46,
                            width: 1,
                            color: theme.colorScheme.onPrimaryContainer
                                .withValues(alpha: 0.2),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: _Statistika(
                              popis: 'Odhad paliva',
                              hodnota: spotrebaPaliva == null
                                  ? '— l'
                                  : '${spotrebaPaliva.toStringAsFixed(1)} l',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text('Jazdy podľa dní', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  ...jazdyPodlaDna.entries.map(
                    (den) => _DennyBlok(datum: den.key, jazdy: den.value),
                  ),
                ],
              ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _vybranaZalozka,
        onDestinationSelected: (index) {
          setState(() => _vybranaZalozka = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.directions_car_outlined),
            selectedIcon: Icon(Icons.directions_car),
            label: 'Jazdy',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart),
            label: 'Prehľad',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Nastavenia',
          ),
        ],
      ),
    );
  }
}

class _PrehladPlaceholder extends StatelessWidget {
  const _PrehladPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Mesačný a ročný prehľad doplníme v ďalšom kroku.',
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _Statistika extends StatelessWidget {
  const _Statistika({required this.popis, required this.hodnota});

  final String popis;
  final String hodnota;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(popis, style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        Text(hodnota, style: theme.textTheme.headlineSmall),
      ],
    );
  }
}

class _DennyBlok extends StatelessWidget {
  const _DennyBlok({required this.datum, required this.jazdy});

  final String datum;
  final List<Jazda> jazdy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dennySucet = jazdy.fold<double>(
      0,
      (sucet, jazda) => sucet + jazda.kilometre,
    );

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(datum, style: theme.textTheme.titleMedium),
              Text(
                '${dennySucet.toStringAsFixed(1)} km',
                style: theme.textTheme.labelLarge,
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...jazdy.map((jazda) => JazdaPolozka(jazda: jazda)),
        ],
      ),
    );
  }
}

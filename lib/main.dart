import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart' as firestore;
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:share_plus/share_plus.dart';

import 'features/jazdy/detail_dna_page.dart';
import 'features/jazdy/widgets/jazda_polozka.dart';
import 'features/nastavenia/nastavenia_vozidla_page.dart';
import 'models/jazda.dart';
import 'models/nastavenia_vozidla.dart';
import 'models/synchronizacia.dart';
import 'models/trasa_bod.dart';
import 'services/gps_tracking_service.dart';
import 'services/gps_pozadie_service.dart';
import 'services/cloudova_synchronizacia.dart';
import 'services/excel_export_service.dart';
import 'services/lokalne_ulozisko.dart';
import 'services/rozpoznavanie_aktivity_service.dart';
import 'utils/format_datumu.dart';

/// Firebase je inicializovaný len v skutočnej aplikácii (nie vo widget testoch).
var firebaseDostupny = false;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await Firebase.initializeApp();
    // Jazdy sú trvalo uložené v SQLite v telefóne a ich odoslanie si stráži
    // aplikácia sama. Druhá kópia dát vo vyrovnávacej pamäti Firestore je zbytočná.
    firestore.FirebaseFirestore.instance.settings = const firestore.Settings(
      persistenceEnabled: false,
    );
    firebaseDostupny = true;
  }
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

class _KnihaJazdHomePageState extends State<KnihaJazdHomePage>
    with WidgetsBindingObserver {
  static const _intervalSynchronizacie = Duration(minutes: 10);

  final _gpsTracking = GpsTrackingService();
  final _gpsPozadie = GpsPozadieService();
  final _rozpoznavanieAktivity = RozpoznavanieAktivityService();
  final _excelExport = ExcelExportService();
  late final LokalneUlozisko _ulozisko;
  CloudovaSynchronizacia? _cloudovaSynchronizacia;
  NastaveniaVozidla _nastaveniaVozidla = const NastaveniaVozidla();
  var _vybranaZalozka = 0;
  final List<Jazda> _jazdy = [];
  late final StreamSubscription<DokoncenaGpsJazda> _dokoncenaJazda;
  late final StreamSubscription<UdalostRozpoznavaniaAktivity> _udalostAktivity;

  late DateTime _vybranyDatum;
  var _nacitavaUdaje = true;
  var _exportujeExcel = false;

  // Prenos jázd z natívnej služby a synchronizácia s cloudom môžu byť vyvolané
  // viackrát naraz (štart aplikácie, udalosť „jazda dokončená“, tlačidlo).
  // Reťazením ich spúšťame po jednom, inak by sa tá istá jazda uložila dvakrát.
  Future<void> _poslednyPrenos = Future.value();
  Future<void> _poslednaSynchronizacia = Future.value();
  Timer? _casovacSynchronizacie;
  CloudovyUcet? _ucet;

  CloudovaSynchronizacia get _cloud =>
      _cloudovaSynchronizacia ??= CloudovaSynchronizacia();

  @override
  void initState() {
    super.initState();
    _ulozisko = widget.ulozisko ?? SqliteLokalneUlozisko();
    _vybranyDatum = DateTime.now();
    _gpsTracking.addListener(_obnovitGpsStav);
    _dokoncenaJazda = _gpsTracking.dokonceneJazdy.listen(
      _ulozitAutomatickuJazdu,
    );
    _udalostAktivity = _rozpoznavanieAktivity.udalosti.listen(
      _spracovatUdalostAktivity,
    );
    WidgetsBinding.instance.addObserver(this);
    if (firebaseDostupny) {
      // Kým je aplikácia otvorená, priebežne dorovnáva zmeny s cloudom.
      _casovacSynchronizacie = Timer.periodic(
        _intervalSynchronizacie,
        (_) => _synchronizovatNaPozadi(),
      );
    }
    _inicializovatAplikaciu();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState stav) {
    if (stav != AppLifecycleState.resumed) return;
    // Po návrate do aplikácie prenesieme jazdy z pozadia a zálohujeme ich.
    unawaited(
      _preniestDokonceneJazdyZOzadia().then((_) => _synchronizovatNaPozadi()),
    );
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
    await _preniestDokonceneJazdyZOzadia();
    await _obnovitRozpoznavaniePoStarte();
    await _pripravitAutomatickeSledovanie();
    await _pripojitCloudPoStarte();
  }

  Future<void> _pripojitCloudPoStarte() async {
    if (!firebaseDostupny) return;
    try {
      final ucet = await _cloud.pockatNaPrihlasenie();
      if (!mounted) return;
      setState(() => _ucet = ucet);
      if (ucet != null) await _synchronizovatNaPozadi();
    } catch (_) {
      // Bez cloudu aplikácia funguje ďalej; jazdy počkajú v telefóne.
    }
  }

  bool get _pouzivaAndroidPozadie =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _obnovitRozpoznavaniePoStarte() async {
    if (!_pouzivaAndroidPozadie) return;
    try {
      await _rozpoznavanieAktivity.obnovitAkJeAktivne();
    } catch (_) {
      // Používateľ môže rozpoznávanie znovu potvrdiť v Nastaveniach aplikácie.
    }
  }

  Future<void> _pripravitAutomatickeSledovanie() async {
    if (_pouzivaAndroidPozadie) return;
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

  Future<void> _spracovatUdalostAktivity(
    UdalostRozpoznavaniaAktivity udalost,
  ) async {
    if (udalost.gpsJazdaDokoncena) {
      await _preniestDokonceneJazdyZOzadia();
      return;
    }
    final vAute = udalost.vAute;
    if (vAute == null) return;
    if (_pouzivaAndroidPozadie) return;
    if (vAute) {
      await _spustitAutomatickeSledovanie();
    } else if (_gpsTracking.sledovanieBezi) {
      await _gpsTracking.zastavitSledovanie();
    }
  }

  Future<StavRozpoznavaniaAktivity> _povolitRozpoznavanie() async {
    final stav = await _rozpoznavanieAktivity.povolitASpustit();
    if (!_pouzivaAndroidPozadie && stav.vAute) {
      await _spustitAutomatickeSledovanie();
    }
    return stav;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _casovacSynchronizacie?.cancel();
    _dokoncenaJazda.cancel();
    _udalostAktivity.cancel();
    _gpsTracking
      ..removeListener(_obnovitGpsStav)
      ..dispose();
    _ulozisko.zavriet();
    super.dispose();
  }

  Future<bool> _ulozitAutomatickuJazdu(
    DokoncenaGpsJazda jazda, {
    bool zobrazitSpravu = true,
    String? identifikator,
  }) async {
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
      // Rovnaký záznam z GPS na pozadí má vždy rovnaké ID, takže sa nemôže
      // uložiť dvakrát ani pri opakovanom prenose.
      cloudId: identifikator == null ? null : 'gps-$identifikator',
    );
    try {
      final ulozenaJazda = await _ulozisko.ulozitJazdu(ukladanaJazda);
      if (!mounted) return true;
      setState(() => _vlozitAleboNahradit(ulozenaJazda));
      unawaited(_synchronizovatNaPozadi());
    } catch (_) {
      _zobrazitSpravu('Automatickú jazdu sa nepodarilo uložiť.');
      return false;
    }
    if (zobrazitSpravu) {
      _zobrazitSpravu('Služobná jazda bola automaticky zaznamenaná.');
    }
    return true;
  }

  void _vlozitAleboNahradit(Jazda jazda) {
    final index = jazda.id == null
        ? -1
        : _jazdy.indexWhere((polozka) => polozka.id == jazda.id);
    if (index >= 0) {
      _jazdy[index] = jazda;
    } else {
      _jazdy.add(jazda);
    }
  }

  Future<void> _preniestDokonceneJazdyZOzadia() {
    final dalsi = _poslednyPrenos.then((_) => _preniestDokonceneJazdyTeraz());
    _poslednyPrenos = dalsi;
    return dalsi;
  }

  Future<void> _preniestDokonceneJazdyTeraz() async {
    if (!_pouzivaAndroidPozadie) return;
    try {
      final cakajuceJazdy = await _gpsPozadie.nacitatDokonceneJazdy();
      final potvrdene = <String>[];
      for (final zaznam in cakajuceJazdy) {
        final ulozena = await _ulozitAutomatickuJazdu(
          zaznam.jazda,
          zobrazitSpravu: false,
          identifikator: zaznam.identifikator,
        );
        if (ulozena) potvrdene.add(zaznam.identifikator);
      }
      await _gpsPozadie.potvrditUlozenie(potvrdene);
      if (cakajuceJazdy.isNotEmpty) {
        _zapisatDiagnostiku(
          'Aplikácia preniesla ${potvrdene.length} z ${cakajuceJazdy.length} jázd do knihy jázd',
        );
      }
      if (potvrdene.isNotEmpty) {
        _zobrazitSpravu(
          'Automaticky sa uložilo ${potvrdene.length} ${potvrdene.length == 1 ? 'jazda' : 'jazdy'} z GPS.',
        );
      }
    } catch (_) {
      // Natívny záznam zostane v telefóne a prenesie sa pri ďalšom otvorení.
    }
  }

  void _zapisatDiagnostiku(String sprava) {
    if (!_pouzivaAndroidPozadie) return;
    unawaited(
      _rozpoznavanieAktivity.zapisatDiagnostiku(sprava).catchError((Object _) {}),
    );
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
    if (!mounted) return;
    setState(() => _nastaveniaVozidla = nastavenia);
    unawaited(_synchronizovatNaPozadi());
  }

  Future<void> _upravitJazdu(JazdaDna upravenaJazda) async {
    final ulozenaJazda = await _ulozisko.ulozitJazdu(upravenaJazda.jazda);
    if (!mounted) return;
    setState(() => _vlozitAleboNahradit(ulozenaJazda));
    unawaited(_synchronizovatNaPozadi());
  }

  Future<Jazda> _pridatJazdu(Jazda jazda) async {
    final ulozenaJazda = await _ulozisko.ulozitJazdu(jazda);
    if (mounted) setState(() => _vlozitAleboNahradit(ulozenaJazda));
    unawaited(_synchronizovatNaPozadi());
    return ulozenaJazda;
  }

  Future<void> _vymazatJazdu(Jazda jazda) async {
    await _ulozisko.vymazatJazdy([jazda]);
    if (mounted) {
      setState(() => _jazdy.removeWhere((polozka) => polozka.id == jazda.id));
    }
    // Zmazanie sa odošle do cloudu pri synchronizácii (aj neskôr, bez signálu).
    unawaited(_synchronizovatNaPozadi());
  }

  Future<int> _vymazatVsetkyJazdy() async {
    final vsetky = List.of(_jazdy);
    await _ulozisko.vymazatJazdy(vsetky);
    if (mounted) setState(_jazdy.clear);
    // Zmazanie sa odošle do cloudu, aby sa jazdy nevrátili pri synchronizácii.
    unawaited(_synchronizovatNaPozadi());
    return vsetky.length;
  }

  Future<void> _prihlasitACSynchronizovat() async {
    try {
      final ucet = await _cloud.prihlasitCezGoogle();
      if (ucet == null || !mounted) return;
      setState(() => _ucet = ucet);
      await _synchronizovatDoCloudu(zobrazitVysledok: true);
    } catch (_) {
      _zobrazitSpravu(
        'Prihlásenie cez Google sa nepodarilo dokončiť. Skontroluj pripojenie a nastavenie aplikácie vo Firebase.',
      );
    }
  }

  Future<void> _synchronizovatNaPozadi() async {
    if (!firebaseDostupny || _cloud.aktualnyUcet == null) return;
    try {
      await _synchronizovatDoCloudu();
    } catch (chyba) {
      // Zmeny ostávajú v telefóne označené na odoslanie; skúsi sa to znova
      // pri návrate do aplikácie, po ďalšej zmene alebo o 10 minút.
      _zapisatDiagnostiku('Synchronizácia s cloudom zlyhala: ${chyba.runtimeType}');
    }
  }

  Future<void> _synchronizovatDoCloudu({bool zobrazitVysledok = false}) {
    final dalsia = _poslednaSynchronizacia.then(
      (_) => _synchronizovatDoCloudTeraz(zobrazitVysledok: zobrazitVysledok),
    );
    // Chyba jednej synchronizácie nesmie zablokovať ďalšie v poradí.
    _poslednaSynchronizacia = dalsia.catchError((Object _) {});
    return dalsia;
  }

  /// Najprv stiahne zmeny z cloudu (novšia úprava vyhráva), potom odošle
  /// to, čo sa zmenilo v telefóne. Do cloudu ide len to, čo sa zmenilo.
  Future<void> _synchronizovatDoCloudTeraz({
    bool zobrazitVysledok = false,
  }) async {
    final stiahnute = await _cloud.stiahnutJazdy(
      odMillis: await _ulozisko.nacitatCasStiahnutia(),
    );
    var zmenene = await _ulozisko.aplikovatJazdyZCloudu(stiahnute.jazdy);
    final najnovsi = stiahnute.najnovsiCasMillis;
    if (najnovsi != null) await _ulozisko.ulozitCasStiahnutia(najnovsi);

    final vzdialeneNastavenia = await _cloud.stiahnutNastavenia();
    if (vzdialeneNastavenia != null &&
        await _ulozisko.aplikovatNastaveniaZCloudu(vzdialeneNastavenia)) {
      zmenene = true;
    }

    final neodoslaneJazdy = await _ulozisko.nacitatNeodoslaneJazdy();
    if (neodoslaneJazdy.isNotEmpty) {
      await _cloud.odoslatJazdy(neodoslaneJazdy);
      await _ulozisko.oznacitOdoslane(neodoslaneJazdy);
    }
    final ZmenaNastaveni? neodoslaneNastavenia = await _ulozisko
        .nacitatNeodoslaneNastavenia();
    if (neodoslaneNastavenia != null) {
      await _cloud.odoslatNastavenia(neodoslaneNastavenia);
      await _ulozisko.oznacitNastaveniaOdoslane(neodoslaneNastavenia.upravene);
    }

    if (zmenene) {
      final udaje = await _ulozisko.nacitat();
      if (!mounted) return;
      setState(() {
        _jazdy
          ..clear()
          ..addAll(udaje.jazdy);
        _nastaveniaVozidla = udaje.nastavenia;
      });
    }
    if (zobrazitVysledok) {
      _zobrazitSpravu('Jazdy a nastavenia sú zosynchronizované s cloudom.');
    }
  }

  Future<StavRozpoznavaniaAktivity> _obnovitRozpoznavanie() async {
    await _rozpoznavanieAktivity.obnovitAkJeAktivne();
    return _rozpoznavanieAktivity.zistitStav();
  }

  Future<StavRozpoznavaniaAktivity> _vypnutRozpoznavanie() async {
    await _rozpoznavanieAktivity.zastavit();
    if (_gpsTracking.sledovanieBezi) await _gpsTracking.zastavitSledovanie();
    return _rozpoznavanieAktivity.zistitStav();
  }

  Future<void> _odhlasitZCloudu() async {
    await _cloud.odhlasit();
    if (mounted) {
      setState(() => _ucet = null);
      _zobrazitSpravu('Z cloudového účtu ste boli odhlásený.');
    }
  }

  Future<void> _exportovatDoExcelu() async {
    if (_exportujeExcel) return;
    setState(() => _exportujeExcel = true);
    try {
      final subor = await _excelExport.vytvoritSubor(
        jazdy: _jazdy,
        nastavenia: _nastaveniaVozidla,
      );
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(files: [XFile(subor.path)], subject: 'Kniha jázd'),
      );
      _zobrazitSpravu('Súbor Excel je pripravený na uloženie alebo odoslanie.');
    } catch (_) {
      _zobrazitSpravu('Export do Excelu sa nepodarilo vytvoriť.');
    } finally {
      if (mounted) setState(() => _exportujeExcel = false);
    }
  }

  Future<void> _otvoritKalendar() async {
    final aktualnyRok = DateTime.now().year;
    // Aj v januári sa musí dať otvoriť december a staršie jazdy.
    final najstarsiRok = _jazdy.fold<int>(
      aktualnyRok - 1,
      (rok, jazda) => jazda.datum.year < rok ? jazda.datum.year : rok,
    );
    final vybranyDatum = await showDatePicker(
      context: context,
      initialDate: _vybranyDatum,
      firstDate: DateTime(najstarsiRok),
      lastDate: DateTime(aktualnyRok + 1, 12, 31),
      helpText: 'Vyber deň',
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
        .toList()
      ..sort((a, b) => porovnatJazdy(a.jazda, b.jazda));

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => DetailDnaPage(
          datum: formatovatDatum(datum),
          den: datum,
          jazdy: jazdyDna,
          onJazdaUpravena: _upravitJazdu,
          onJazdaPridana: _pridatJazdu,
          onJazdaVymazana: _vymazatJazdu,
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
    final jazdyPodlaDna = <DateTime, List<Jazda>>{};
    final zoradene = [...jazdyVMesiaci]
      ..sort((a, b) {
        final den = DateTime(b.datum.year, b.datum.month, b.datum.day)
            .compareTo(DateTime(a.datum.year, a.datum.month, a.datum.day));
        return den != 0 ? den : porovnatJazdy(a, b);
      });
    for (final jazda in zoradene) {
      final datum = DateTime(
        jazda.datum.year,
        jazda.datum.month,
        jazda.datum.day,
      );
      jazdyPodlaDna.putIfAbsent(datum, () => []).add(jazda);
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
                onPovolitRozpoznavanie: _povolitRozpoznavanie,
                onVypnutRozpoznavanie: _vypnutRozpoznavanie,
                onObnovitRozpoznavanie: _obnovitRozpoznavanie,
                onPovolitNotifikacie: _rozpoznavanieAktivity.povolitNotifikacie,
                onNacitatDiagnostiku: _rozpoznavanieAktivity.nacitatDiagnostiku,
                onVymazatDiagnostiku: _rozpoznavanieAktivity.vymazatDiagnostiku,
                onZistitStavRozpoznavania: _rozpoznavanieAktivity.zistitStav,
                onOtvoritNastaveniaPolohy: _gpsPozadie.otvoritNastaveniaPolohy,
                cloudovyUcet: firebaseDostupny ? _cloud.aktualnyUcet : null,
                onPrihlasitACSynchronizovat: _prihlasitACSynchronizovat,
                onSynchronizovat: () =>
                    _synchronizovatDoCloudu(zobrazitVysledok: true),
                onOdhlasitZCloudu: _odhlasitZCloudu,
                onVymazatVsetkyJazdy: _vymazatVsetkyJazdy,
              )
            : _vybranaZalozka == 1
            ? _PrehladPage(
                jazdy: _jazdy,
                nastavenia: _nastaveniaVozidla,
                exportuje: _exportujeExcel,
                onExportovat: _exportovatDoExcelu,
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: [
                  if (firebaseDostupny && _ucet == null) ...[
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.cloud_off_outlined),
                        title: const Text('Jazdy nie sú zálohované'),
                        subtitle: const Text(
                          'Prihlás sa cez Google a jazdy sa budú automaticky zálohovať do cloudu.',
                        ),
                        trailing: TextButton(
                          onPressed: _prihlasitACSynchronizovat,
                          child: const Text('Prihlásiť'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
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
                    (den) => _DennyBlok(
                      datum: formatovatDatum(den.key),
                      jazdy: den.value,
                      onTap: () => _otvoritDetailDna(den.key),
                    ),
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

class _PrehladPage extends StatelessWidget {
  const _PrehladPage({
    required this.jazdy,
    required this.nastavenia,
    required this.exportuje,
    required this.onExportovat,
  });

  final List<Jazda> jazdy;
  final NastaveniaVozidla nastavenia;
  final bool exportuje;
  final Future<void> Function() onExportovat;

  @override
  Widget build(BuildContext context) {
    final kilometre = jazdy.fold<double>(
      0,
      (sucet, jazda) => sucet + jazda.kilometre,
    );
    final spotreba = nastavenia.priemernaSpotreba == null
        ? null
        : kilometre * nastavenia.priemernaSpotreba! / 100;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Prehľad jázd', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'Celkom ${jazdy.length} záznamov a ${kilometre.toStringAsFixed(1)} km.',
        ),
        if (spotreba != null)
          Text('Odhadovaná spotreba paliva: ${spotreba.toStringAsFixed(1)} l.'),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: exportuje ? null : onExportovat,
          icon: exportuje
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.file_download_outlined),
          label: Text(
            exportuje ? 'Pripravujem Excel…' : 'Exportovať do Excelu',
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Súbor bude mať ročný prehľad a samostatný list pre každý mesiac s jazdami.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
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
  const _DennyBlok({
    required this.datum,
    required this.jazdy,
    required this.onTap,
  });

  final String datum;
  final List<Jazda> jazdy;
  final VoidCallback onTap;

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
          ...jazdy.map((jazda) => JazdaPolozka(jazda: jazda, onTap: onTap)),
        ],
      ),
    );
  }
}

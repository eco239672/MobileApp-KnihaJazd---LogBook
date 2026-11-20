import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart' as firestore;
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';

import 'features/jazdy/detail_dna_page.dart';
import 'features/nastavenia/nastavenia_vozidla_page.dart';
import 'features/prehlad/prehlad_page.dart';
import 'models/jazda.dart';
import 'models/nastavenia_vozidla.dart';
import 'services/gps_tracking_service.dart';
import 'services/gps_pozadie_service.dart';
import 'services/cloudova_synchronizacia.dart';
import 'services/doplnenie_adries.dart';
import 'services/excel_export_service.dart';
import 'services/jazda_z_gps.dart';
import 'services/lokalne_ulozisko.dart';
import 'services/rozpoznavanie_aktivity_service.dart';
import 'services/synchronizacia_jazd.dart';
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
  late final _doplnenieAdries = DoplnenieAdries(
    zistitAdresu: _gpsPozadie.zistitAdresu,
  );
  var _doplnajuSaAdresy = false;
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

  // Prenos jázd z natívnej služby môže byť vyvolaný viackrát naraz (štart
  // aplikácie, udalosť „jazda dokončená“). Reťazením beží po jednom, inak by
  // sa tá istá jazda uložila dvakrát.
  Future<void> _poslednyPrenos = Future.value();
  Timer? _casovacSynchronizacie;
  CloudovyUcet? _ucet;

  CloudovaSynchronizacia get _cloud =>
      _cloudovaSynchronizacia ??= CloudovaSynchronizacia();
  late final _synchronizacia = SynchronizaciaJazd(
    ulozisko: _ulozisko,
    cloud: _cloud,
  );

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
      _preniestDokonceneJazdyZOzadia()
          .then((_) => _synchronizovatNaPozadi())
          .then((_) => _doplnitAdresy()),
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
      _odovzdatBluetoothAuta();
    } catch (_) {
      if (!mounted) return;
      setState(() => _nacitavaUdaje = false);
      _zobrazitSpravu('Lokálne údaje sa nepodarilo načítať.');
    }
    await _preniestDokonceneJazdyZOzadia();
    await _obnovitRozpoznavaniePoStarte();
    await _pripravitAutomatickeSledovanie();
    await _pripojitCloudPoStarte();
    await _doplnitAdresy();
  }

  /// Natívna služba si pri konci jazdy overí, či bol telefón pripojený
  /// k Bluetooth auta; potrebuje preto vedieť, ktoré zariadenie je auto.
  void _odovzdatBluetoothAuta() {
    if (!_pouzivaAndroidPozadie) return;
    unawaited(
      _gpsPozadie
          .nastavitBluetoothAuta(_nastaveniaVozidla.bluetoothAuta)
          .catchError((Object _) {}),
    );
  }

  /// Nahradí súradnice v jazdách adresou alebo obľúbeným miestom.
  Future<void> _doplnitAdresy() async {
    if (_doplnajuSaAdresy || !mounted) return;
    _doplnajuSaAdresy = true;
    try {
      final doplnene = await _doplnenieAdries.doplnit(
        List.of(_jazdy),
        _nastaveniaVozidla.oblubeneMiesta,
      );
      var ulozene = 0;
      for (final nova in doplnene) {
        // Medzičasom mohol používateľ jazdu upraviť: meníme len miesta,
        // ktoré sú v aktuálnej verzii jazdy stále v súradniciach.
        final index = _jazdy.indexWhere((jazda) => jazda.id == nova.id);
        if (index < 0) continue;
        final aktualna = _jazdy[index];
        final upravena = aktualna.copyWith(
          odkial: aktualna.odkialJeSuradnica ? nova.odkial : null,
          kam: aktualna.kamJeSuradnica ? nova.kam : null,
        );
        if (upravena.odkial == aktualna.odkial && upravena.kam == aktualna.kam) {
          continue;
        }
        final ulozena = await _ulozisko.ulozitJazdu(upravena);
        ulozene++;
        if (mounted) setState(() => _vlozitAleboNahradit(ulozena));
      }
      if (ulozene > 0) unawaited(_synchronizovatNaPozadi());
    } catch (_) {
      // Adresy sa skúsia doplniť pri ďalšom otvorení aplikácie.
    } finally {
      _doplnajuSaAdresy = false;
    }
  }

  /// Pridá obľúbené miesto a ponúkne premenovanie starších jázd v jeho okolí.
  /// Vráti premenované jazdy (aby ich mohla obnoviť aj otvorená obrazovka dňa).
  Future<List<Jazda>> _pridatOblubeneMiesto(OblubeneMiesto miesto) async {
    await _ulozitNastaveniaVozidla(
      _nastaveniaVozidla.copyWith(
        oblubeneMiesta: [..._nastaveniaVozidla.oblubeneMiesta, miesto],
      ),
    );
    bool blizko(String? suradnice) {
      final bod = precitatSuradnice(suradnice);
      return bod != null &&
          miesto.vzdialenostOd(bod.latitude, bod.longitude) <=
              miesto.polomerMetre;
    }

    final dotknute = _jazdy
        .where(
          (jazda) =>
              (blizko(jazda.odkialSuradnice) && jazda.odkial != miesto.nazov) ||
              (blizko(jazda.kamSuradnice) && jazda.kam != miesto.nazov),
        )
        .toList();
    if (dotknute.isEmpty || !mounted) {
      _zobrazitSpravu('Obľúbené miesto „${miesto.nazov}“ je uložené.');
      return const [];
    }
    final premenovat = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Premenovať staršie jazdy na „${miesto.nazov}“?'),
        content: Text(
          'V okolí tohto miesta začína alebo končí ${dotknute.length} '
          '${dotknute.length == 1 ? 'jazda' : 'jázd'}. Ich adresa sa nahradí '
          'názvom „${miesto.nazov}“ (aj ručne prepísaná).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Nie'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Premenovať'),
          ),
        ],
      ),
    );
    if (premenovat != true) return const [];
    final premenovane = <Jazda>[];
    for (final jazda in dotknute) {
      final ulozena = await _ulozisko.ulozitJazdu(
        jazda.copyWith(
          odkial: blizko(jazda.odkialSuradnice) ? miesto.nazov : null,
          kam: blizko(jazda.kamSuradnice) ? miesto.nazov : null,
        ),
      );
      premenovane.add(ulozena);
      if (mounted) setState(() => _vlozitAleboNahradit(ulozena));
    }
    unawaited(_synchronizovatNaPozadi());
    _zobrazitSpravu('Premenované jazdy: ${premenovane.length}.');
    return premenovane;
  }

  /// Aktuálna poloha telefónu (na pridanie obľúbeného miesta).
  Future<({double latitude, double longitude})?> _aktualnaPoloha() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _zobrazitSpravu('Zapni v telefóne polohu (GPS).');
        return null;
      }
      var povolenie = await Geolocator.checkPermission();
      if (povolenie == LocationPermission.denied) {
        povolenie = await Geolocator.requestPermission();
      }
      if (povolenie == LocationPermission.denied ||
          povolenie == LocationPermission.deniedForever) {
        _zobrazitSpravu('Aplikácia nemá povolenú polohu.');
        return null;
      }
      final poloha = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 30),
        ),
      );
      return (latitude: poloha.latitude, longitude: poloha.longitude);
    } catch (_) {
      _zobrazitSpravu('Polohu sa nepodarilo zistiť. Skús to vonku.');
      return null;
    }
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
    final ukladanaJazda = jazdaZGps(
      jazda,
      identifikator: identifikator,
      oblubeneMiesta: _nastaveniaVozidla.oblubeneMiesta,
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
      _zobrazitSpravu('Jazda bola automaticky zaznamenaná.');
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
      if (potvrdene.isNotEmpty) unawaited(_doplnitAdresy());
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
    _odovzdatBluetoothAuta();
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
      final popis = chyba is FirebaseException
          ? '${chyba.plugin}/${chyba.code}: ${chyba.message ?? ''}'
          : '$chyba';
      _zapisatDiagnostiku(
        'Synchronizácia s cloudom zlyhala: '
        '${popis.length > 200 ? popis.substring(0, 200) : popis}',
      );
    }
  }

  Future<void> _synchronizovatDoCloudu({bool zobrazitVysledok = false}) async {
    final zmenene = await _synchronizacia.synchronizovat();
    if (zmenene) {
      final udaje = await _ulozisko.nacitat();
      if (!mounted) return;
      setState(() {
        _jazdy
          ..clear()
          ..addAll(udaje.jazdy);
        _nastaveniaVozidla = udaje.nastavenia;
      });
      _odovzdatBluetoothAuta();
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
          predvolenyVodic: _nastaveniaVozidla.vodic,
          onJazdaUpravena: _upravitJazdu,
          onJazdaPridana: _pridatJazdu,
          onJazdaVymazana: _vymazatJazdu,
          onPridatOblubeneMiesto: _pridatOblubeneMiesto,
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
                onOtvoritUsporuBaterie: _rozpoznavanieAktivity.otvoritUsporuBaterie,
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
                onPridatOblubeneMiesto: _pridatOblubeneMiesto,
                onAktualnaPoloha: _aktualnaPoloha,
                onSparovaneBluetooth: _gpsPozadie.sparovaneBluetooth,
              )
            : _vybranaZalozka == 1
            ? PrehladPage(
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
                            child: Statistika(
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
                            child: Statistika(
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
                            child: Statistika(
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
                    (den) => DennyBlok(
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

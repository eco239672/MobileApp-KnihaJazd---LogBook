import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/nastavenia_vozidla.dart';
import '../../services/cloudova_synchronizacia.dart';
import '../../services/rozpoznavanie_aktivity_service.dart';
import '../../utils/decimalny_vstup.dart';
import 'diagnostika_page.dart';

class NastaveniaVozidlaPage extends StatefulWidget {
  const NastaveniaVozidlaPage({
    required this.nastavenia,
    required this.onUlozit,
    required this.onPovolitRozpoznavanie,
    required this.onVypnutRozpoznavanie,
    required this.onObnovitRozpoznavanie,
    required this.onPovolitNotifikacie,
    required this.onOtvoritUsporuBaterie,
    required this.onNacitatDiagnostiku,
    required this.onVymazatDiagnostiku,
    required this.onZistitStavRozpoznavania,
    required this.onOtvoritNastaveniaPolohy,
    required this.cloudovyUcet,
    required this.onPrihlasitACSynchronizovat,
    required this.onSynchronizovat,
    required this.onOdhlasitZCloudu,
    this.onVymazatVsetkyJazdy,
    super.key,
  });

  final NastaveniaVozidla nastavenia;
  final Future<void> Function(NastaveniaVozidla) onUlozit;
  final Future<StavRozpoznavaniaAktivity> Function() onPovolitRozpoznavanie;
  final Future<StavRozpoznavaniaAktivity> Function() onVypnutRozpoznavanie;

  /// Tichá obnova registrácie bez systémových dialógov (po návrate do aplikácie).
  final Future<StavRozpoznavaniaAktivity> Function() onObnovitRozpoznavanie;
  final Future<StavRozpoznavaniaAktivity> Function() onPovolitNotifikacie;
  final Future<void> Function() onOtvoritUsporuBaterie;
  final Future<String> Function() onNacitatDiagnostiku;
  final Future<void> Function() onVymazatDiagnostiku;
  final Future<StavRozpoznavaniaAktivity> Function() onZistitStavRozpoznavania;
  final Future<void> Function() onOtvoritNastaveniaPolohy;
  final CloudovyUcet? cloudovyUcet;
  final Future<void> Function() onPrihlasitACSynchronizovat;
  final Future<void> Function() onSynchronizovat;
  final Future<void> Function() onOdhlasitZCloudu;

  /// Vymaže všetky jazdy v telefóne (a po synchronizácii aj v cloude).
  /// Vráti počet vymazaných jázd.
  final Future<int> Function()? onVymazatVsetkyJazdy;

  @override
  State<NastaveniaVozidlaPage> createState() => _NastaveniaVozidlaPageState();
}

class _NastaveniaVozidlaPageState extends State<NastaveniaVozidlaPage>
    with WidgetsBindingObserver {
  final _formular = GlobalKey<FormState>();
  late final TextEditingController _spz;
  late final TextEditingController _spotreba;
  late final TextEditingController _cenaBenzinu;
  late final TextEditingController _cenaNafty;
  StavRozpoznavaniaAktivity? _stavRozpoznavania;
  var _meniSaRozpoznavanie = false;
  var _otvaraNastaveniaPolohy = false;
  var _pracujeSCloudom = false;
  var _mazeJazdy = false;

  // Ochrana pred omylom: tlačidlo treba stlačiť niekoľkokrát po sebe.
  static const _potrebnychStlaceni = 3;
  static const _limitMedziStlaceniami = Duration(seconds: 3);
  var _stlaceniaMazania = 0;
  Timer? _vynulovanieStlaceni;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _spz = TextEditingController(text: widget.nastavenia.spz);
    _spotreba = TextEditingController(
      text: widget.nastavenia.priemernaSpotreba?.toString(),
    );
    _cenaBenzinu = TextEditingController(
      text: widget.nastavenia.cenaBenzinu?.toString(),
    );
    _cenaNafty = TextEditingController(
      text: widget.nastavenia.cenaNafty?.toString(),
    );
    _nacitatStavRozpoznavania();
  }

  @override
  void didUpdateWidget(NastaveniaVozidlaPage starsi) {
    super.didUpdateWidget(starsi);
    // Nastavenia sa môžu zmeniť zvonka (stiahnutie z cloudu). Bez tohto by
    // formulár ukazoval staré hodnoty a „Uložiť“ by ich znova prepísal.
    final nove = widget.nastavenia;
    final stare = starsi.nastavenia;
    if (nove.spz != stare.spz ||
        nove.priemernaSpotreba != stare.priemernaSpotreba ||
        nove.cenaBenzinu != stare.cenaBenzinu ||
        nove.cenaNafty != stare.cenaNafty) {
      _spz.text = nove.spz;
      _spotreba.text = nove.priemernaSpotreba?.toString() ?? '';
      _cenaBenzinu.text = nove.cenaBenzinu?.toString() ?? '';
      _cenaNafty.text = nove.cenaNafty?.toString() ?? '';
    }
  }

  @override
  void dispose() {
    _vynulovanieStlaceni?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _spz.dispose();
    _spotreba.dispose();
    _cenaBenzinu.dispose();
    _cenaNafty.dispose();
    super.dispose();
  }

  Future<void> _ulozit() async {
    if (!_formular.currentState!.validate()) return;

    FocusScope.of(context).unfocus();
    try {
      await widget.onUlozit(
        NastaveniaVozidla(
          spz: _spz.text.trim().toUpperCase(),
          priemernaSpotreba: _cislo(_spotreba.text),
          cenaBenzinu: _cislo(_cenaBenzinu.text),
          cenaNafty: _cislo(_cenaNafty.text),
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nastavenia vozidla boli uložené.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nastavenia sa nepodarilo uložiť.')),
      );
    }
  }

  Future<void> _nacitatStavRozpoznavania() async {
    final stav = await widget.onZistitStavRozpoznavania();
    if (mounted) setState(() => _stavRozpoznavania = stav);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState stavAplikacie) {
    if (stavAplikacie == AppLifecycleState.resumed) {
      _obnovitPoNavrateZoSystemovychNastaveni();
    }
  }

  Future<void> _obnovitPoNavrateZoSystemovychNastaveni() async {
    try {
      await _nacitatStavRozpoznavania();
      final stav = _stavRozpoznavania;
      if (stav == null ||
          !stav.povolene ||
          !stav.aktivne ||
          !stav.polohaNaPozadiPovolena) {
        return;
      }
      // Po návrate zo systémových nastavení znovu zaregistruje Android
      // rozpoznávanie jazdy, bez ďalšieho dialógu pre používateľa.
      final obnovenyStav = await widget.onObnovitRozpoznavanie();
      if (mounted) setState(() => _stavRozpoznavania = obnovenyStav);
    } catch (_) {
      // Používateľ môže aplikáciu naďalej používať a stav znovu overiť neskôr.
    }
  }

  Future<void> _povolitRozpoznavanie() async {
    setState(() => _meniSaRozpoznavanie = true);
    try {
      final stav = await widget.onPovolitRozpoznavanie();
      if (!mounted) return;
      setState(() => _stavRozpoznavania = stav);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Rozpoznávanie jazdy sa nepodarilo zapnúť.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _meniSaRozpoznavanie = false);
    }
  }

  Future<void> _vypnutRozpoznavanie() async {
    final potvrdene = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Vypnúť automatické sledovanie?'),
        content: const Text(
          'Jazdy sa prestanú zaznamenávať automaticky. Prebiehajúca jazda sa uloží.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Zrušiť'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Vypnúť'),
          ),
        ],
      ),
    );
    if (potvrdene != true || !mounted) return;
    setState(() => _meniSaRozpoznavanie = true);
    try {
      final stav = await widget.onVypnutRozpoznavanie();
      if (!mounted) return;
      setState(() => _stavRozpoznavania = stav);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Automatické sledovanie sa nepodarilo vypnúť.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _meniSaRozpoznavanie = false);
    }
  }

  Future<void> _povolitNotifikacie() async {
    try {
      final stav = await widget.onPovolitNotifikacie();
      if (mounted) setState(() => _stavRozpoznavania = stav);
    } catch (_) {
      // Stav sa znova overí po návrate do aplikácie.
    }
  }

  void _otvoritDiagnostiku() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => DiagnostikaPage(
          onNacitat: widget.onNacitatDiagnostiku,
          onVymazat: widget.onVymazatDiagnostiku,
        ),
      ),
    );
  }

  Future<void> _otvoritNastaveniaPolohy() async {
    setState(() => _otvaraNastaveniaPolohy = true);
    try {
      await widget.onOtvoritNastaveniaPolohy();
    } finally {
      if (mounted) setState(() => _otvaraNastaveniaPolohy = false);
    }
  }

  Future<void> _vykonatCloudovuAkciu(Future<void> Function() akcia) async {
    setState(() => _pracujeSCloudom = true);
    try {
      await akcia();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Synchronizácia s cloudom sa nepodarila.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _pracujeSCloudom = false);
    }
  }

  void _stlacitMazanie() {
    _vynulovanieStlaceni?.cancel();
    final stlacenia = _stlaceniaMazania + 1;
    if (stlacenia < _potrebnychStlaceni) {
      setState(() => _stlaceniaMazania = stlacenia);
      // Bez ďalšieho stlačenia do 3 sekúnd sa počítadlo vynuluje.
      _vynulovanieStlaceni = Timer(_limitMedziStlaceniami, () {
        if (mounted) setState(() => _stlaceniaMazania = 0);
      });
      return;
    }
    setState(() => _stlaceniaMazania = 0);
    unawaited(_vymazatVsetkyJazdy());
  }

  Future<void> _vymazatVsetkyJazdy() async {
    final akcia = widget.onVymazatVsetkyJazdy;
    if (akcia == null) return;
    final prihlaseny = widget.cloudovyUcet != null;
    final potvrdene = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Vymazať všetky jazdy?'),
        content: Text(
          prihlaseny
              ? 'Natrvalo sa vymažú všetky jazdy v telefóne aj v cloude. Nastavenia vozidla zostanú. Túto akciu nie je možné vrátiť.'
              : 'Natrvalo sa vymažú všetky jazdy v telefóne. Nastavenia vozidla zostanú. Túto akciu nie je možné vrátiť.\n\nAk máš jazdy zálohované v cloude, najprv sa prihlás cez Google, inak sa pri ďalšom prihlásení z cloudu vrátia.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Zrušiť'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Vymazať všetko'),
          ),
        ],
      ),
    );
    if (potvrdene != true || !mounted) return;
    setState(() => _mazeJazdy = true);
    try {
      final pocet = await akcia();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Vymazaných jázd: $pocet.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Jazdy sa nepodarilo vymazať.')),
      );
    } finally {
      if (mounted) setState(() => _mazeJazdy = false);
    }
  }

  double? _cislo(String hodnota) {
    final orezanaHodnota = hodnota.trim();
    if (orezanaHodnota.isEmpty) return null;
    return double.parse(orezanaHodnota.replaceAll(',', '.'));
  }

  String? _spzValidator(String? hodnota) {
    return hodnota == null || hodnota.trim().isEmpty
        ? 'Zadaj evidenčné číslo vozidla.'
        : null;
  }

  String? _kladneCislo(String? hodnota, String nazov) {
    if (hodnota == null || hodnota.trim().isEmpty) return null;
    final cislo = double.tryParse(hodnota.trim().replaceAll(',', '.'));
    return cislo == null || !cislo.isFinite || cislo < 0
        ? 'Zadaj platnú hodnotu pre $nazov.'
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      children: [
        Text('Nastavenia', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formular,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Vozidlo', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    'Údaje slúžia na identifikáciu auta a orientačný výpočet paliva.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _spz,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Evidenčné číslo vozidla (SPZ)',
                      hintText: 'napr. BA123AB',
                      prefixIcon: Icon(Icons.directions_car_outlined),
                    ),
                    validator: _spzValidator,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _spotreba,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [decimalnyVstup],
                    decoration: const InputDecoration(
                      labelText: 'Priemerná spotreba',
                      suffixText: 'l / 100 km',
                      hintText: 'napr. 6,4',
                    ),
                    validator: (hodnota) => _kladneCislo(hodnota, 'spotrebu'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _cenaBenzinu,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [decimalnyVstup],
                    decoration: const InputDecoration(
                      labelText: 'Cena benzínu',
                      suffixText: '€ / l',
                      hintText: 'nepovinné',
                    ),
                    validator: (hodnota) =>
                        _kladneCislo(hodnota, 'cenu benzínu'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _cenaNafty,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [decimalnyVstup],
                    decoration: const InputDecoration(
                      labelText: 'Cena nafty',
                      suffixText: '€ / l',
                      hintText: 'nepovinné',
                    ),
                    validator: (hodnota) => _kladneCislo(hodnota, 'cenu nafty'),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _ulozit,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Uložiť'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Cloudová synchronizácia',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  widget.cloudovyUcet == null
                      ? 'Prihlásením cez Google sa jazdy bezpečne zálohujú do vášho súkromného priestoru vo Firestore.'
                      : 'Prihlásený účet: ${widget.cloudovyUcet!.email ?? widget.cloudovyUcet!.meno ?? 'Google účet'}',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                if (widget.cloudovyUcet == null)
                  FilledButton.icon(
                    onPressed: _pracujeSCloudom
                        ? null
                        : () => _vykonatCloudovuAkciu(
                            widget.onPrihlasitACSynchronizovat,
                          ),
                    icon: _pracujeSCloudom
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_upload_outlined),
                    label: const Text('Prihlásiť cez Google a synchronizovať'),
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _pracujeSCloudom
                              ? null
                              : () => _vykonatCloudovuAkciu(
                                  widget.onSynchronizovat,
                                ),
                          icon: const Icon(Icons.sync),
                          label: const Text('Synchronizovať'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        tooltip: 'Odhlásiť z cloudu',
                        onPressed: _pracujeSCloudom
                            ? null
                            : () => _vykonatCloudovuAkciu(
                                widget.onOdhlasitZCloudu,
                              ),
                        icon: const Icon(Icons.logout),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Automatické sledovanie jázd',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  'Telefón rozpozná jazdu autom, zapne GPS na pozadí a po skončení uloží záznam do knihy jázd.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  _stavRozpoznavania?.aktivne != true
                      ? 'Stačí raz povoliť rozpoznávanie pohybu.'
                      : !_stavRozpoznavania!.polohaNaPozadiPovolena
                      ? 'Ešte treba povoliť polohu: v nastaveniach aplikácie otvor Povolenia → Poloha, zvoľ „Povoliť vždy“ a zapni „Použiť presnú polohu“.'
                      : _stavRozpoznavania?.vAute == true
                      ? 'Automatické sledovanie je pripravené: práve v aute.'
                      : 'Automatické sledovanie je pripravené a čaká na jazdu.',
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(height: 12),
                if (_stavRozpoznavania?.aktivne != true)
                  FilledButton.icon(
                    onPressed: _meniSaRozpoznavanie
                        ? null
                        : _povolitRozpoznavanie,
                    icon: _meniSaRozpoznavanie
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.directions_car_outlined),
                    label: const Text('Zapnúť automatické sledovanie'),
                  )
                else if (!_stavRozpoznavania!.polohaNaPozadiPovolena)
                  FilledButton.icon(
                    onPressed: _otvaraNastaveniaPolohy
                        ? null
                        : _otvoritNastaveniaPolohy,
                    icon: _otvaraNastaveniaPolohy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.location_on_outlined),
                    label: const Text('Otvoriť nastavenia polohy'),
                  ),
                if (_stavRozpoznavania?.aktivne == true &&
                    _stavRozpoznavania?.usporaBaterieVypnuta == false) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Úspora batérie môže aplikáciu uspať a jazda sa nezaznamená. V zozname vyber Kniha jázd a zvoľ „Neoptimalizovať“ (alebo „Bez obmedzení“).',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: widget.onOtvoritUsporuBaterie,
                    icon: const Icon(Icons.battery_alert_outlined),
                    label: const Text('Vypnúť úsporu batérie'),
                  ),
                ],
                if (_stavRozpoznavania?.aktivne == true &&
                    _stavRozpoznavania?.notifikaciePovolene == false) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Notifikácie sú vypnuté: počas jazdy neuvidíš, že sa jazda zaznamenáva.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _povolitNotifikacie,
                    icon: const Icon(Icons.notifications_active_outlined),
                    label: const Text('Povoliť notifikácie'),
                  ),
                ],
                if (_stavRozpoznavania?.aktivne == true) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _meniSaRozpoznavanie
                        ? null
                        : _vypnutRozpoznavanie,
                    icon: const Icon(Icons.pause_circle_outline),
                    label: const Text('Vypnúť automatické sledovanie'),
                  ),
                ],
                const SizedBox(height: 4),
                TextButton.icon(
                  onPressed: _otvoritDiagnostiku,
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: const Text('Diagnostika sledovania'),
                ),
              ],
            ),
          ),
        ),
        if (widget.onVymazatVsetkyJazdy != null) ...[
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Údaje', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Vymaže natrvalo všetky jazdy. Pre istotu treba tlačidlo stlačiť $_potrebnychStlaceni× po sebe.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _mazeJazdy ? null : _stlacitMazanie,
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                        foregroundColor: theme.colorScheme.onError,
                      ),
                      icon: _mazeJazdy
                          ? SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: theme.colorScheme.onError,
                              ),
                            )
                          : const Icon(Icons.delete_forever_outlined),
                      label: Text(
                        _stlaceniaMazania == 0
                            ? 'Vymazať všetky jazdy'
                            : 'Stlač ešte ${_potrebnychStlaceni - _stlaceniaMazania}× pre vymazanie',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

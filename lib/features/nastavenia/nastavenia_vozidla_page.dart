import 'package:flutter/material.dart';

import '../../models/nastavenia_vozidla.dart';
import '../../services/cloudova_synchronizacia.dart';
import '../../services/rozpoznavanie_aktivity_service.dart';
import '../../utils/decimalny_vstup.dart';

class NastaveniaVozidlaPage extends StatefulWidget {
  const NastaveniaVozidlaPage({
    required this.nastavenia,
    required this.onUlozit,
    required this.onSpatNaJazdy,
    required this.onPovolitRozpoznavanie,
    required this.onZistitStavRozpoznavania,
    required this.cloudovyUcet,
    required this.onPrihlasitACSynchronizovat,
    required this.onSynchronizovat,
    required this.onOdhlasitZCloudu,
    this.onVlozitUkazkoveJazdy,
    super.key,
  });

  final NastaveniaVozidla nastavenia;
  final Future<void> Function(NastaveniaVozidla) onUlozit;
  final VoidCallback onSpatNaJazdy;
  final Future<StavRozpoznavaniaAktivity> Function() onPovolitRozpoznavanie;
  final Future<StavRozpoznavaniaAktivity> Function() onZistitStavRozpoznavania;
  final CloudovyUcet? cloudovyUcet;
  final Future<void> Function() onPrihlasitACSynchronizovat;
  final Future<void> Function() onSynchronizovat;
  final Future<void> Function() onOdhlasitZCloudu;
  final Future<int> Function()? onVlozitUkazkoveJazdy;

  @override
  State<NastaveniaVozidlaPage> createState() => _NastaveniaVozidlaPageState();
}

class _NastaveniaVozidlaPageState extends State<NastaveniaVozidlaPage> {
  final _formular = GlobalKey<FormState>();
  late final TextEditingController _spz;
  late final TextEditingController _spotreba;
  late final TextEditingController _cenaBenzinu;
  late final TextEditingController _cenaNafty;
  StavRozpoznavaniaAktivity? _stavRozpoznavania;
  var _meniSaRozpoznavanie = false;
  var _pracujeSCloudom = false;
  var _vytvaraUkazkoveJazdy = false;

  @override
  void initState() {
    super.initState();
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
  void dispose() {
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

  Future<void> _vlozitUkazkoveJazdy() async {
    final akcia = widget.onVlozitUkazkoveJazdy;
    if (akcia == null) return;
    setState(() => _vytvaraUkazkoveJazdy = true);
    try {
      final pocet = await akcia();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Pridaných ukážkových jázd: $pocet.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ukážkové jazdy sa nepodarilo vytvoriť.')),
      );
    } finally {
      if (mounted) setState(() => _vytvaraUkazkoveJazdy = false);
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
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: widget.onSpatNaJazdy,
                          icon: const Icon(Icons.arrow_back),
                          label: const Text('Späť na jazdy'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _ulozit,
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('Uložiť'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        if (widget.onVlozitUkazkoveJazdy != null) ...[
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(Icons.science_outlined),
              title: const Text('Ukážkové jazdy'),
              subtitle: const Text(
                'Vytvorí testovacie jazdy od prvého dňa aktuálneho mesiaca.',
              ),
              trailing: FilledButton(
                onPressed: _vytvaraUkazkoveJazdy ? null : _vlozitUkazkoveJazdy,
                child: _vytvaraUkazkoveJazdy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Vytvoriť'),
              ),
            ),
          ),
        ],
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
                  'Automatické rozpoznanie jazdy',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  'Android rozpozná stav „v aute“ a až potom zapne presné GPS sledovanie.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  _stavRozpoznavania?.aktivne == true
                      ? (_stavRozpoznavania?.vAute == true
                            ? 'Rozpoznávanie je zapnuté: práve v aute.'
                            : 'Rozpoznávanie je zapnuté a čaká na jazdu.')
                      : 'Vyžaduje jednorazové povolenie Fyzická aktivita.',
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(height: 12),
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
                  label: Text(
                    _stavRozpoznavania?.aktivne == true
                        ? 'Znova overiť povolenie'
                        : 'Povoliť rozpoznávanie jazdy',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

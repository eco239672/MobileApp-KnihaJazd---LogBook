import 'package:flutter/material.dart';

import '../../models/jazda.dart';
import '../../models/nastavenia_vozidla.dart';
import '../../utils/decimalny_vstup.dart';
import 'widgets/jazda_polozka.dart';

class DetailDnaPage extends StatefulWidget {
  const DetailDnaPage({
    required this.datum,
    required this.jazdy,
    required this.onJazdaUpravena,
    this.den,
    this.onJazdaPridana,
    this.onJazdaVymazana,
    this.onPridatOblubeneMiesto,
    this.predvolenyVodic = '',
    super.key,
  });

  final String datum;
  final List<JazdaDna> jazdy;
  final Future<void> Function(JazdaDna) onJazdaUpravena;

  /// Deň, do ktorého sa pridáva nová jazda. Bez neho sa pridanie nezobrazí.
  final DateTime? den;
  final Future<Jazda> Function(Jazda)? onJazdaPridana;
  final Future<void> Function(Jazda)? onJazdaVymazana;

  /// Uloží miesto začiatku alebo konca jazdy ako obľúbené (napr. „Domov“).
  /// Vráti jazdy, ktoré sa pritom premenovali.
  final Future<List<Jazda>> Function(OblubeneMiesto)? onPridatOblubeneMiesto;

  /// Vodič z nastavení vozidla; zobrazí sa ako nápoveda pri jazde bez vodiča.
  final String predvolenyVodic;

  @override
  State<DetailDnaPage> createState() => _DetailDnaPageState();
}

class _DetailDnaPageState extends State<DetailDnaPage> {
  late final List<JazdaDna> _jazdy;

  @override
  void initState() {
    super.initState();
    _jazdy = List.of(widget.jazdy);
  }

  void _zobrazitChybu(String sprava) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(sprava)));
  }

  Future<void> _upravitJazdu(int index) async {
    final vysledok = await showDialog<_VysledokEditora>(
      context: context,
      builder: (context) => _EditorJazdyDialog(
        jazda: _jazdy[index].jazda,
        mozeVymazat: widget.onJazdaVymazana != null,
        predvolenyVodic: widget.predvolenyVodic,
        onPridatOblubeneMiesto: widget.onPridatOblubeneMiesto == null
            ? null
            : _pridatOblubeneMiesto,
      ),
    );
    if (vysledok == null || !mounted) return;

    if (vysledok.vymazat) {
      await _vymazatJazdu(index);
      return;
    }
    final upravenaJazda = vysledok.jazda;
    if (upravenaJazda != null) {
      final upravenyZaznam = _jazdy[index].copyWith(jazda: upravenaJazda);
      try {
        await widget.onJazdaUpravena(upravenyZaznam);
        if (!mounted) return;
        setState(() => _jazdy[index] = upravenyZaznam);
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Jazdu sa nepodarilo uložiť.')),
        );
      }
    }
  }

  /// Pridá obľúbené miesto a premenované jazdy hneď ukáže aj v tomto dni.
  Future<void> _pridatOblubeneMiesto(OblubeneMiesto miesto) async {
    final pridat = widget.onPridatOblubeneMiesto;
    if (pridat == null) return;
    final premenovane = await pridat(miesto);
    if (!mounted || premenovane.isEmpty) return;
    setState(() {
      for (final jazda in premenovane) {
        final index = _jazdy.indexWhere((zaznam) => zaznam.jazda.id == jazda.id);
        if (index >= 0) _jazdy[index] = _jazdy[index].copyWith(jazda: jazda);
      }
    });
  }

  Future<void> _vymazatJazdu(int index) async {
    final vymazat = widget.onJazdaVymazana;
    if (vymazat == null) return;
    final potvrdene = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Vymazať jazdu?'),
        content: const Text('Jazda sa natrvalo odstráni z knihy jázd.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Zrušiť'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Vymazať'),
          ),
        ],
      ),
    );
    if (potvrdene != true || !mounted) return;
    try {
      await vymazat(_jazdy[index].jazda);
      if (!mounted) return;
      setState(() => _jazdy.removeAt(index));
    } catch (_) {
      _zobrazitChybu('Jazdu sa nepodarilo vymazať.');
    }
  }

  Future<void> _pridatJazdu() async {
    final pridat = widget.onJazdaPridana;
    final den = widget.den;
    if (pridat == null || den == null) return;
    final vysledok = await showDialog<_VysledokEditora>(
      context: context,
      builder: (context) => _EditorJazdyDialog(
        jazda: Jazda(
          datum: DateTime(den.year, den.month, den.day),
          odkial: '',
          kam: '',
          zaciatok: '',
          koniec: '',
          kilometre: 0,
          typ: TypJazdy.sluzobna,
        ),
        nova: true,
        predvolenyVodic: widget.predvolenyVodic,
      ),
    );
    final novaJazda = vysledok?.jazda;
    if (novaJazda == null || !mounted) return;
    try {
      final ulozena = await pridat(novaJazda);
      if (!mounted) return;
      setState(() {
        _jazdy
          ..add(JazdaDna(indexVZozname: -1, jazda: ulozena))
          ..sort((a, b) => porovnatJazdy(a.jazda, b.jazda));
      });
    } catch (_) {
      _zobrazitChybu('Jazdu sa nepodarilo pridať.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mozePridat = widget.onJazdaPridana != null && widget.den != null;
    final pridatTlacidlo = TextButton.icon(
      onPressed: _pridatJazdu,
      icon: const Icon(Icons.add),
      label: const Text('Doplniť jazdu ručne'),
    );
    final kilometre = _jazdy.fold<double>(
      0,
      (sucet, zaznam) => sucet + zaznam.jazda.kilometre,
    );

    return Scaffold(
      appBar: AppBar(title: Text(widget.datum)),
      body: _jazdy.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'V tento deň nie sú zaznamenané žiadne jazdy.',
                      style: theme.textTheme.titleMedium,
                      textAlign: TextAlign.center,
                    ),
                    if (mozePridat) ...[
                      const SizedBox(height: 12),
                      pridatTlacidlo,
                    ],
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              children: [
                Text('Jazdy dňa', style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  'Ťuknutím na jazdu upravíš jej údaje.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                ..._jazdy.asMap().entries.map(
                  (zaznam) => JazdaPolozka(
                    jazda: zaznam.value.jazda,
                    onTap: () => _upravitJazdu(zaznam.key),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  color: theme.colorScheme.primaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.route_outlined),
                    title: const Text('Spolu za deň'),
                    trailing: Text(
                      '${kilometre.toStringAsFixed(1)} km',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ),
                if (mozePridat) ...[
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerLeft, child: pridatTlacidlo),
                ],
              ],
            ),
    );
  }
}

/// Výsledok editora: upravená jazda, alebo požiadavka na jej vymazanie.
class _VysledokEditora {
  const _VysledokEditora.ulozit(Jazda this.jazda) : vymazat = false;
  const _VysledokEditora.zmazat() : jazda = null, vymazat = true;

  final Jazda? jazda;
  final bool vymazat;
}

class _EditorJazdyDialog extends StatefulWidget {
  const _EditorJazdyDialog({
    required this.jazda,
    this.nova = false,
    this.mozeVymazat = false,
    this.predvolenyVodic = '',
    this.onPridatOblubeneMiesto,
  });

  final Jazda jazda;
  final bool nova;
  final bool mozeVymazat;
  final String predvolenyVodic;
  final Future<void> Function(OblubeneMiesto)? onPridatOblubeneMiesto;

  @override
  State<_EditorJazdyDialog> createState() => _EditorJazdyDialogState();
}

class _EditorJazdyDialogState extends State<_EditorJazdyDialog> {
  final _formular = GlobalKey<FormState>();
  late final TextEditingController _odkial;
  late final TextEditingController _kam;
  late final TextEditingController _zaciatok;
  late final TextEditingController _koniec;
  late final TextEditingController _kilometre;
  late final TextEditingController _ucel;
  late final TextEditingController _vodic;
  late final TextEditingController _tachometerPo;
  late TypJazdy _typ;

  @override
  void initState() {
    super.initState();
    _odkial = TextEditingController(text: widget.jazda.odkial);
    _kam = TextEditingController(text: widget.jazda.kam);
    _zaciatok = TextEditingController(text: widget.jazda.zaciatok);
    _koniec = TextEditingController(text: widget.jazda.koniec);
    _kilometre = TextEditingController(
      text: widget.nova ? '' : widget.jazda.kilometre.toStringAsFixed(1),
    );
    _ucel = TextEditingController(text: widget.jazda.ucel);
    _vodic = TextEditingController(text: widget.jazda.vodic);
    _tachometerPo = TextEditingController(
      text: widget.jazda.tachometerPo?.toStringAsFixed(1) ?? '',
    );
    _typ = widget.jazda.typ;
  }

  @override
  void dispose() {
    _odkial.dispose();
    _kam.dispose();
    _zaciatok.dispose();
    _koniec.dispose();
    _kilometre.dispose();
    _ucel.dispose();
    _vodic.dispose();
    _tachometerPo.dispose();
    super.dispose();
  }

  void _ulozit() {
    if (!_formular.currentState!.validate()) return;

    Navigator.of(context).pop(
      _VysledokEditora.ulozit(
        widget.jazda.copyWith(
          odkial: _odkial.text.trim(),
          kam: _kam.text.trim(),
          zaciatok: _normalizovatCas(_zaciatok.text),
          koniec: _normalizovatCas(_koniec.text),
          kilometre: double.parse(_kilometre.text.replaceAll(',', '.')),
          typ: _typ,
          ucel: _ucel.text.trim(),
          vodic: _vodic.text.trim(),
          tachometerPo: _volitelneCislo(_tachometerPo.text),
        ),
      ),
    );
  }

  double? _volitelneCislo(String hodnota) {
    final text = hodnota.trim().replaceAll(',', '.');
    return text.isEmpty ? null : double.tryParse(text);
  }

  String? _tachometerValidator(String? hodnota) {
    final text = (hodnota ?? '').trim();
    if (text.isEmpty) return null;
    final cislo = double.tryParse(text.replaceAll(',', '.'));
    return cislo == null || !cislo.isFinite || cislo < 0
        ? 'Zadaj stav tachometra v km alebo pole nechaj prázdne.'
        : null;
  }

  /// Uloží začiatok alebo koniec jazdy ako obľúbené miesto (napr. „Domov“).
  Future<void> _ulozitAkoOblubene(String suradnice, String navrh) async {
    final pridat = widget.onPridatOblubeneMiesto;
    final bod = precitatSuradnice(suradnice);
    if (pridat == null || bod == null) return;
    final nazov = await showDialog<String>(
      context: context,
      builder: (context) => _NazovMiestaDialog(navrh: navrh),
    );
    if (nazov == null || nazov.trim().isEmpty || !mounted) return;
    final navigator = Navigator.of(context);
    try {
      await pridat(
        OblubeneMiesto(
          nazov: nazov.trim(),
          latitude: bod.latitude,
          longitude: bod.longitude,
        ),
      );
      // Editor zavrieme bez uloženia; jazda sa premenuje podľa voľby.
      if (mounted) navigator.pop();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Obľúbené miesto sa nepodarilo uložiť.')),
      );
    }
  }

  /// „8:05“ → „08:05“, aby sa časy dali spoľahlivo zoraďovať a exportovať.
  String _normalizovatCas(String hodnota) {
    final casti = hodnota.trim().split(':');
    return '${casti[0].padLeft(2, '0')}:${casti[1]}';
  }

  String? _povinnePole(String? hodnota) {
    return hodnota == null || hodnota.trim().isEmpty
        ? 'Vyplň toto pole.'
        : null;
  }

  String? _cas(String? hodnota) {
    if (_povinnePole(hodnota) != null) return 'Vyplň čas.';
    final jePlatny = RegExp(r'^([01]?[0-9]|2[0-3]):[0-5][0-9]$')
        .hasMatch(hodnota!.trim());
    return jePlatny ? null : 'Použi formát HH:MM, napr. 08:30.';
  }

  String? _kilometreValidator(String? hodnota) {
    final kilometre = double.tryParse((hodnota ?? '').replaceAll(',', '.'));
    return kilometre == null || !kilometre.isFinite || kilometre < 0
        ? 'Zadaj platný počet kilometrov.'
        : null;
  }

  /// GPS súradnice miesta (dôkaz) a tlačidlo na uloženie obľúbeného miesta.
  List<Widget> _suradnice(String popis, String? suradnice, String miesto) {
    if (suradnice == null) return const [];
    final mozePridat = widget.onPridatOblubeneMiesto != null && !widget.nova;
    final navrh = miesto == suradnice ? '' : miesto;
    return [
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: Text(
              '$popis podľa GPS: $suradnice',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (mozePridat)
            IconButton(
              tooltip: 'Uložiť ako obľúbené miesto',
              onPressed: () => _ulozitAkoOblubene(suradnice, navrh),
              icon: const Icon(Icons.star_outline),
            ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.nova ? 'Doplniť jazdu' : 'Upraviť jazdu'),
      scrollable: true,
      content: Form(
        key: _formular,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _odkial,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Odkiaľ (mesto A)'),
              validator: _povinnePole,
            ),
            TextFormField(
              controller: _kam,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Kam (mesto B)'),
              validator: _povinnePole,
            ),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _zaciatok,
                    keyboardType: TextInputType.datetime,
                    decoration: const InputDecoration(labelText: 'Začiatok'),
                    validator: _cas,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _koniec,
                    keyboardType: TextInputType.datetime,
                    decoration: const InputDecoration(labelText: 'Koniec'),
                    validator: _cas,
                  ),
                ),
              ],
            ),
            TextFormField(
              controller: _kilometre,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [decimalnyVstup],
              decoration: const InputDecoration(labelText: 'Kilometre'),
              validator: _kilometreValidator,
            ),
            TextFormField(
              controller: _ucel,
              textCapitalization: TextCapitalization.sentences,
              maxLines: null,
              decoration: InputDecoration(
                labelText: 'Účel jazdy',
                hintText: 'napr. Stretnutie so zákazníkom XY',
                helperText: _typ == TypJazdy.sluzobna
                    ? 'Pre daňové účely konkrétne, nie len „služobná cesta“.'
                    : null,
                helperMaxLines: 2,
              ),
            ),
            TextFormField(
              controller: _vodic,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: 'Vodič',
                hintText: widget.predvolenyVodic.trim().isEmpty
                    ? 'Meno a priezvisko'
                    : widget.predvolenyVodic.trim(),
              ),
            ),
            TextFormField(
              controller: _tachometerPo,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [decimalnyVstup],
              decoration: const InputDecoration(
                labelText: 'Stav tachometra po jazde (nepovinné)',
                suffixText: 'km',
                helperText: 'Vyplň, keď chceš zladiť knihu jázd s tachometrom.',
                helperMaxLines: 2,
              ),
              validator: _tachometerValidator,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<TypJazdy>(
              initialValue: _typ,
              decoration: const InputDecoration(labelText: 'Typ jazdy'),
              items: TypJazdy.values
                  .map(
                    (typ) =>
                        DropdownMenuItem(value: typ, child: Text(typ.nazov)),
                  )
                  .toList(),
              onChanged: (typ) {
                if (typ != null) setState(() => _typ = typ);
              },
            ),
            if (widget.jazda.autoBluetooth == false) ...[
              const SizedBox(height: 8),
              Text(
                'Počas jazdy nebol telefón pripojený k Bluetooth auta, preto je jazda označená ako súkromná.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            ..._suradnice(
              'Začiatok',
              widget.jazda.odkialSuradnice,
              widget.jazda.odkial,
            ),
            ..._suradnice('Koniec', widget.jazda.kamSuradnice, widget.jazda.kam),
          ],
        ),
      ),
      actions: [
        if (widget.mozeVymazat && !widget.nova)
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(const _VysledokEditora.zmazat()),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Vymazať'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zrušiť'),
        ),
        FilledButton(onPressed: _ulozit, child: const Text('Uložiť')),
      ],
    );
  }
}

/// Dialóg na pomenovanie obľúbeného miesta (Domov, Práca…).
class _NazovMiestaDialog extends StatefulWidget {
  const _NazovMiestaDialog({required this.navrh});

  final String navrh;

  @override
  State<_NazovMiestaDialog> createState() => _NazovMiestaDialogState();
}

class _NazovMiestaDialogState extends State<_NazovMiestaDialog> {
  late final TextEditingController _nazov = TextEditingController(
    text: widget.navrh,
  );

  @override
  void dispose() {
    _nazov.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Obľúbené miesto'),
      content: TextField(
        controller: _nazov,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          labelText: 'Názov',
          hintText: 'napr. Domov, Práca, Sklad',
        ),
        onSubmitted: (hodnota) => Navigator.of(context).pop(hodnota),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zrušiť'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_nazov.text),
          child: const Text('Uložiť'),
        ),
      ],
    );
  }
}

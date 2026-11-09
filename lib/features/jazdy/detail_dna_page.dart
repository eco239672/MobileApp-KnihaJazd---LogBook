import 'package:flutter/material.dart';

import '../../models/jazda.dart';
import '../../utils/decimalny_vstup.dart';
import 'widgets/jazda_polozka.dart';

class DetailDnaPage extends StatefulWidget {
  const DetailDnaPage({
    required this.datum,
    required this.jazdy,
    required this.onJazdaUpravena,
    super.key,
  });

  final String datum;
  final List<JazdaDna> jazdy;
  final ValueChanged<JazdaDna> onJazdaUpravena;

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

  Future<void> _upravitJazdu(int index) async {
    final upravenaJazda = await showDialog<Jazda>(
      context: context,
      builder: (context) => _EditorJazdyDialog(jazda: _jazdy[index].jazda),
    );

    if (upravenaJazda != null && mounted) {
      setState(() {
        _jazdy[index] = _jazdy[index].copyWith(jazda: upravenaJazda);
      });
      widget.onJazdaUpravena(_jazdy[index]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                child: Text(
                  'V tento deň nie sú zaznamenané žiadne jazdy.',
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center,
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
              ],
            ),
    );
  }
}

class _EditorJazdyDialog extends StatefulWidget {
  const _EditorJazdyDialog({required this.jazda});

  final Jazda jazda;

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
  late TypJazdy _typ;

  @override
  void initState() {
    super.initState();
    _odkial = TextEditingController(text: widget.jazda.odkial);
    _kam = TextEditingController(text: widget.jazda.kam);
    _zaciatok = TextEditingController(text: widget.jazda.zaciatok);
    _koniec = TextEditingController(text: widget.jazda.koniec);
    _kilometre = TextEditingController(
      text: widget.jazda.kilometre.toStringAsFixed(1),
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
    super.dispose();
  }

  void _ulozit() {
    if (!_formular.currentState!.validate()) return;

    Navigator.of(context).pop(
      widget.jazda.copyWith(
        odkial: _odkial.text.trim(),
        kam: _kam.text.trim(),
        zaciatok: _zaciatok.text.trim(),
        koniec: _koniec.text.trim(),
        kilometre: double.parse(_kilometre.text.replaceAll(',', '.')),
        typ: _typ,
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Upraviť jazdu'),
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
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zrušiť'),
        ),
        FilledButton(onPressed: _ulozit, child: const Text('Uložiť')),
      ],
    );
  }
}

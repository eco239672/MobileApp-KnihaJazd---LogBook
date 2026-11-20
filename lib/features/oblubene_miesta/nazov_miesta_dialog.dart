import 'package:flutter/material.dart';

/// Dialóg na pomenovanie obľúbeného miesta (Domov, Práca…). Vráti zadaný
/// názov, alebo null, ak používateľ dialóg zruší.
class NazovMiestaDialog extends StatefulWidget {
  const NazovMiestaDialog({this.navrh = '', super.key});

  /// Predvyplnený názov, napr. adresa miesta.
  final String navrh;

  @override
  State<NazovMiestaDialog> createState() => _NazovMiestaDialogState();
}

class _NazovMiestaDialogState extends State<NazovMiestaDialog> {
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

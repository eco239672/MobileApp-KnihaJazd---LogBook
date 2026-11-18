import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Záznam toho, čo sa dialo na pozadí: rozpoznanie jazdy, spustenie GPS,
/// odmietnutia systémom, uložené jazdy. Slúži na hľadanie príčin, prečo sa
/// jazda nezaznamenala.
class DiagnostikaPage extends StatefulWidget {
  const DiagnostikaPage({
    required this.onNacitat,
    required this.onVymazat,
    super.key,
  });

  final Future<String> Function() onNacitat;
  final Future<void> Function() onVymazat;

  @override
  State<DiagnostikaPage> createState() => _DiagnostikaPageState();
}

class _DiagnostikaPageState extends State<DiagnostikaPage> {
  String? _zaznam;
  var _chyba = false;

  @override
  void initState() {
    super.initState();
    _nacitat();
  }

  Future<void> _nacitat() async {
    try {
      final zaznam = await widget.onNacitat();
      if (!mounted) return;
      setState(() {
        _zaznam = zaznam;
        _chyba = false;
      });
    } catch (_) {
      if (mounted) setState(() => _chyba = true);
    }
  }

  // Najnovšie udalosti hore, aby ich nebolo treba hľadať na konci.
  String get _zobrazenyText =>
      (_zaznam ?? '').split('\n').where((r) => r.trim().isNotEmpty).toList().reversed.join('\n');

  Future<void> _kopirovat() async {
    final text = _zaznam ?? '';
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Záznam je skopírovaný, môžeš ho vložiť do správy.')),
    );
  }

  Future<void> _vymazat() async {
    final potvrdene = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Vymazať diagnostický záznam?'),
        content: const Text('Jazdy sa tým nemažú, len tento záznam udalostí.'),
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
    if (potvrdene != true) return;
    await widget.onVymazat();
    await _nacitat();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = _zobrazenyText;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostika'),
        actions: [
          IconButton(
            tooltip: 'Obnoviť',
            onPressed: _nacitat,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Kopírovať',
            onPressed: text.isEmpty ? null : _kopirovat,
            icon: const Icon(Icons.copy_outlined),
          ),
          IconButton(
            tooltip: 'Vymazať záznam',
            onPressed: text.isEmpty ? null : _vymazat,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: _chyba
          ? const Center(child: Text('Záznam sa nepodarilo načítať.'))
          : _zaznam == null
          ? const Center(child: CircularProgressIndicator())
          : text.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Zatiaľ žiadne udalosti. Po jazde sa tu objaví, čo telefón rozpoznal a čo aplikácia urobila.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.5,
                ),
              ),
            ),
    );
  }
}

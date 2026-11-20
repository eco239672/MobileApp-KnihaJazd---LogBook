import 'package:flutter/material.dart';

import '../../../models/nastavenia_vozidla.dart';
import '../../oblubene_miesta/nazov_miesta_dialog.dart';

/// Karta v Nastaveniach: zoznam obľúbených miest (Domov, Práca…).
class OblubeneMiestaKarta extends StatefulWidget {
  const OblubeneMiestaKarta({
    required this.nastavenia,
    required this.onUlozit,
    required this.onPridat,
    this.onAktualnaPoloha,
    super.key,
  });

  final NastaveniaVozidla nastavenia;
  final Future<void> Function(NastaveniaVozidla) onUlozit;

  /// Pridá miesto (a ponúkne premenovanie starších jázd v jeho okolí).
  final Future<void> Function(OblubeneMiesto) onPridat;
  final Future<({double latitude, double longitude})?> Function()?
  onAktualnaPoloha;

  @override
  State<OblubeneMiestaKarta> createState() => _OblubeneMiestaKartaState();
}

class _OblubeneMiestaKartaState extends State<OblubeneMiestaKarta> {
  var _pridavaMiesto = false;

  void _sprava(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _pridatAktualnuPolohu() async {
    final poloha = widget.onAktualnaPoloha;
    final pridat = widget.onPridat;
    if (poloha == null) return;
    final nazov = await showDialog<String>(
      context: context,
      builder: (context) => const NazovMiestaDialog(),
    );
    if (nazov == null || nazov.trim().isEmpty || !mounted) return;
    setState(() => _pridavaMiesto = true);
    try {
      final bod = await poloha();
      if (bod == null) return;
      await pridat(
        OblubeneMiesto(
          nazov: nazov.trim(),
          latitude: bod.latitude,
          longitude: bod.longitude,
        ),
      );
    } catch (_) {
      _sprava('Obľúbené miesto sa nepodarilo uložiť.');
    } finally {
      if (mounted) setState(() => _pridavaMiesto = false);
    }
  }

  Future<void> _odstranitMiesto(OblubeneMiesto miesto) async {
    final potvrdene = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Odstrániť „${miesto.nazov}“?'),
        content: const Text(
          'Staršie jazdy si názov ponechajú. Nové jazdy tu dostanú adresu.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Zrušiť'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Odstrániť'),
          ),
        ],
      ),
    );
    if (potvrdene != true || !mounted) return;
    try {
      await widget.onUlozit(
        widget.nastavenia.copyWith(
          oblubeneMiesta: [
            for (final polozka in widget.nastavenia.oblubeneMiesta)
              if (!identical(polozka, miesto)) polozka,
          ],
        ),
      );
    } catch (_) {
      _sprava('Miesto sa nepodarilo odstrániť.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Obľúbené miesta', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Jazda, ktorá začne alebo skončí do 150 m od takého miesta, dostane namiesto adresy jeho názov. Miesto pridáš aj z detailu jazdy (hviezdička).',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            for (final miesto in widget.nastavenia.oblubeneMiesta)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.star),
                title: Text(miesto.nazov),
                trailing: IconButton(
                  tooltip: 'Odstrániť',
                  onPressed: () => _odstranitMiesto(miesto),
                  icon: const Icon(Icons.delete_outline),
                ),
              ),
            if (widget.onAktualnaPoloha != null)
              OutlinedButton.icon(
                onPressed: _pridavaMiesto ? null : _pridatAktualnuPolohu,
                icon: _pridavaMiesto
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_location_alt_outlined),
                label: const Text('Pridať miesto, kde práve som'),
              ),
          ],
        ),
      ),
    );
  }
}

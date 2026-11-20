import 'package:flutter/material.dart';

import '../../models/jazda.dart';
import '../../models/nastavenia_vozidla.dart';
import '../jazdy/widgets/jazda_polozka.dart';

/// Záložka Prehľad: súčty, export do Excelu a čo treba doplniť pre daňové účely.
class PrehladPage extends StatelessWidget {
  const PrehladPage({
    super.key,
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
    final bezUcelu = jazdy.where((jazda) => jazda.chybaUcel).length;
    final chybaVozidlo =
        nastavenia.vin.trim().isEmpty ||
        nastavenia.vodic.trim().isEmpty ||
        nastavenia.pociatocnyTachometer == null;

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
          'Súbor bude mať ročný prehľad s údajmi o vozidle a samostatný list pre každý mesiac: poradové číslo, vodič, čas, odkiaľ – kam, účel, kilometre a stav tachometra.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (bezUcelu > 0 || chybaVozidlo) ...[
          const SizedBox(height: 16),
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Pred odovzdaním na daňové účely doplň:',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  if (bezUcelu > 0)
                    Text('• účel pri $bezUcelu služobných jazdách'),
                  if (nastavenia.vin.trim().isEmpty)
                    const Text('• VIN vozidla (Nastavenia)'),
                  if (nastavenia.vodic.trim().isEmpty)
                    const Text('• meno vodiča (Nastavenia)'),
                  if (nastavenia.pociatocnyTachometer == null)
                    const Text(
                      '• stav tachometra na začiatku evidencie (Nastavenia)',
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

/// Jedno číslo s popisom na hlavnej obrazovke (záznamy, km…).
class Statistika extends StatelessWidget {
  const Statistika({required this.popis, required this.hodnota, super.key});

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

/// Jazdy jedného dňa na hlavnej obrazovke.
class DennyBlok extends StatelessWidget {
  const DennyBlok({
    super.key,
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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/nastavenia_vozidla.dart';
import '../../../services/gps_pozadie_service.dart';

/// Karta v Nastaveniach: výber Bluetooth zariadenia auta. Jazda bez
/// pripojenia k nemu sa zaznamená ako súkromná.
class BluetoothAutaKarta extends StatefulWidget {
  const BluetoothAutaKarta({
    required this.nastavenia,
    required this.onUlozit,
    required this.onSparovane,
    super.key,
  });

  final NastaveniaVozidla nastavenia;
  final Future<void> Function(NastaveniaVozidla) onUlozit;

  /// Spárované Bluetooth zariadenia telefónu.
  final Future<List<BluetoothZariadenie>> Function() onSparovane;

  @override
  State<BluetoothAutaKarta> createState() => _BluetoothAutaKartaState();
}

class _BluetoothAutaKartaState extends State<BluetoothAutaKarta> {
  var _vyberaBluetooth = false;

  void _sprava(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _vybratBluetoothAuto() async {
    final nacitat = widget.onSparovane;
    setState(() => _vyberaBluetooth = true);
    List<BluetoothZariadenie> zariadenia;
    try {
      zariadenia = await nacitat();
    } on PlatformException {
      _sprava(
        'Bez povolenia „Zariadenia v okolí“ nevidím spárované zariadenia. Povoľ ho v nastaveniach aplikácie.',
      );
      return;
    } catch (_) {
      _sprava('Zoznam Bluetooth zariadení sa nepodarilo načítať.');
      return;
    } finally {
      if (mounted) setState(() => _vyberaBluetooth = false);
    }
    if (!mounted) return;
    if (zariadenia.isEmpty) {
      _sprava(
        'Telefón nemá spárované žiadne zariadenie. Najprv ho spáruj s autom cez Bluetooth.',
      );
      return;
    }
    final vybrane = await showDialog<BluetoothZariadenie>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Ktoré zariadenie je tvoje auto?'),
        children: [
          for (final zariadenie in zariadenia)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(zariadenie),
              child: Text(zariadenie.nazov),
            ),
        ],
      ),
    );
    if (vybrane == null || !mounted) return;
    try {
      await widget.onUlozit(
        widget.nastavenia.copyWith(
          bluetoothAuta: vybrane.adresa,
          bluetoothAutaNazov: vybrane.nazov,
        ),
      );
    } catch (_) {
      _sprava('Výber auta sa nepodarilo uložiť.');
    }
  }

  Future<void> _zrusitBluetoothAuto() async {
    try {
      await widget.onUlozit(
        widget.nastavenia.copyWith(bluetoothAuta: null, bluetoothAutaNazov: null),
      );
    } catch (_) {
      _sprava('Zmenu sa nepodarilo uložiť.');
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
            Text(
              'Rozpoznanie auta (Bluetooth)',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              widget.nastavenia.bluetoothAuta == null
                  ? 'Nevybrané: každá jazda sa zaznamená ako služobná. Ak vyberieš Bluetooth svojho auta, jazda bez pripojenia k nemu (autobus, cudzie auto) sa zaznamená ako súkromná.'
                  : 'Auto: ${widget.nastavenia.bluetoothAutaNazov ?? widget.nastavenia.bluetoothAuta}. Jazda bez pripojenia k nemu sa zaznamená ako súkromná.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _vyberaBluetooth
                      ? null
                      : _vybratBluetoothAuto,
                  icon: _vyberaBluetooth
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Icons.bluetooth),
                  label: Text(
                    widget.nastavenia.bluetoothAuta == null
                        ? 'Vybrať auto'
                        : 'Zmeniť',
                  ),
                ),
                if (widget.nastavenia.bluetoothAuta != null) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _zrusitBluetoothAuto,
                    child: const Text('Zrušiť výber'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

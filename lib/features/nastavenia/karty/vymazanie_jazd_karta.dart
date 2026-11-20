import 'dart:async';

import 'package:flutter/material.dart';

/// Karta v Nastaveniach: vymazanie všetkých jázd. Pre istotu treba tlačidlo
/// stlačiť niekoľkokrát po sebe a potom ešte potvrdiť.
class VymazanieJazdKarta extends StatefulWidget {
  const VymazanieJazdKarta({
    required this.prihlaseny,
    required this.onVymazat,
    super.key,
  });

  /// Je používateľ prihlásený do cloudu (jazdy sa vymažú aj tam)?
  final bool prihlaseny;

  /// Vymaže všetky jazdy a vráti ich počet.
  final Future<int> Function() onVymazat;

  @override
  State<VymazanieJazdKarta> createState() => _VymazanieJazdKartaState();
}

class _VymazanieJazdKartaState extends State<VymazanieJazdKarta> {
  // Ochrana pred omylom: tlačidlo treba stlačiť niekoľkokrát po sebe.
  static const _potrebnychStlaceni = 3;
  static const _limitMedziStlaceniami = Duration(seconds: 3);
  var _stlaceniaMazania = 0;
  Timer? _vynulovanieStlaceni;
  var _mazeJazdy = false;

  @override
  void dispose() {
    _vynulovanieStlaceni?.cancel();
    super.dispose();
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
    final akcia = widget.onVymazat;
    final prihlaseny = widget.prihlaseny;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
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
    );
  }
}

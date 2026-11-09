import 'dart:async';

import 'package:flutter/services.dart';

/// Most k Android Activity Recognition Transition API.
///
/// Android vyhodnocuje pohyb úsporne a oznámi iba vstup/výstup zo stavu
/// „v aute“. GPS preto nemusí bežať nepretržite počas chôdze či státia.
class RozpoznavanieAktivityService {
  static const _kanal = MethodChannel(
    'sk.knihajazd.kniha_jazd/rozpoznavanie_aktivity',
  );
  static const _udalosti = EventChannel(
    'sk.knihajazd.kniha_jazd/rozpoznavanie_aktivity_udalosti',
  );

  Stream<bool> get stavVozidla => _udalosti
      .receiveBroadcastStream()
      .map((udalost) => (udalost as Map)['vAute'] == true);

  Future<StavRozpoznavaniaAktivity> zistitStav() async {
    final odpoved = await _kanal.invokeMapMethod<String, dynamic>('stav');
    return StavRozpoznavaniaAktivity(
      povolene: odpoved?['povolene'] == true,
      aktivne: odpoved?['aktivne'] == true,
      vAute: odpoved?['vAute'] == true,
    );
  }

  /// Otvorí jednorazový systémový dialóg pre oprávnenie Fyzická aktivita a po
  /// jeho schválení sa prihlási na udalosti „v aute“.
  Future<StavRozpoznavaniaAktivity> povolitASpustit() async {
    await _kanal.invokeMethod<void>('povolitASpustit');
    return zistitStav();
  }

  Future<void> zastavit() => _kanal.invokeMethod<void>('zastavit');
}

class StavRozpoznavaniaAktivity {
  const StavRozpoznavaniaAktivity({
    required this.povolene,
    required this.aktivne,
    required this.vAute,
  });

  final bool povolene;
  final bool aktivne;
  final bool vAute;
}

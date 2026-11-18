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

  Stream<UdalostRozpoznavaniaAktivity> get udalosti =>
      _udalosti.receiveBroadcastStream().map((udalost) {
        final hodnoty = Map<Object?, Object?>.from(udalost as Map);
        return UdalostRozpoznavaniaAktivity(
          vAute: hodnoty['vAute'] as bool?,
          gpsJazdaDokoncena: hodnoty['gpsJazdaDokoncena'] == true,
        );
      });

  Future<StavRozpoznavaniaAktivity> zistitStav() async {
    final odpoved = await _kanal.invokeMapMethod<String, dynamic>('stav');
    return StavRozpoznavaniaAktivity(
      povolene: odpoved?['povolene'] == true,
      aktivne: odpoved?['aktivne'] == true,
      vAute: odpoved?['vAute'] == true,
      polohaNaPozadiPovolena: odpoved?['polohaNaPozadiPovolena'] == true,
      // Staršia natívna časť túto hodnotu nemusí poslať: vtedy nič nehlásime.
      notifikaciePovolene: odpoved?['notifikaciePovolene'] != false,
    );
  }

  /// Otvorí jednorazový systémový dialóg pre oprávnenie Fyzická aktivita a po
  /// jeho schválení sa prihlási na udalosti „v aute“.
  Future<StavRozpoznavaniaAktivity> povolitASpustit() async {
    await _kanal.invokeMethod<void>('povolitASpustit');
    return zistitStav();
  }

  /// Obnoví registráciu po vynútenom zastavení aplikácie bez zobrazenia
  /// ďalšieho dialógu, ak používateľ už rozpoznávanie povolil.
  Future<void> obnovitAkJeAktivne() =>
      _kanal.invokeMethod<void>('obnovitAkJeAktivne');

  Future<void> zastavit() => _kanal.invokeMethod<void>('zastavit');

  /// Vypýta povolenie notifikácií, prípadne otvorí ich nastavenia.
  Future<StavRozpoznavaniaAktivity> povolitNotifikacie() async {
    await _kanal.invokeMethod<bool>('povolitNotifikacie');
    return zistitStav();
  }

  // --- diagnostický záznam (ukladá ho natívna časť v telefóne) ---

  Future<String> nacitatDiagnostiku() async =>
      await _kanal.invokeMethod<String>('nacitatDiagnostiku') ?? '';

  Future<void> vymazatDiagnostiku() =>
      _kanal.invokeMethod<void>('vymazatDiagnostiku');

  Future<void> zapisatDiagnostiku(String sprava) =>
      _kanal.invokeMethod<void>('zapisatDiagnostiku', sprava);
}

class StavRozpoznavaniaAktivity {
  const StavRozpoznavaniaAktivity({
    required this.povolene,
    required this.aktivne,
    required this.vAute,
    required this.polohaNaPozadiPovolena,
    this.notifikaciePovolene = true,
  });

  final bool povolene;
  final bool aktivne;
  final bool vAute;
  final bool polohaNaPozadiPovolena;
  final bool notifikaciePovolene;
}

class UdalostRozpoznavaniaAktivity {
  const UdalostRozpoznavaniaAktivity({
    required this.vAute,
    required this.gpsJazdaDokoncena,
  });

  final bool? vAute;
  final bool gpsJazdaDokoncena;
}

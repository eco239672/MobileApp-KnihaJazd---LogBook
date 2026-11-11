import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/trasa_bod.dart';
import 'gps_tracking_service.dart';

/// Komunikácia s natívnou Android službou, ktorá GPS zaznamenáva aj bez
/// otvorenej Flutter obrazovky.
class GpsPozadieService {
  static const _kanal = MethodChannel(
    'sk.knihajazd.kniha_jazd/rozpoznavanie_aktivity',
  );

  Future<List<DokoncenaGpsJazdaNaPrenos>> nacitatDokonceneJazdy() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return [];

    final odpoved = await _kanal.invokeListMethod<dynamic>(
      'nacitatDokonceneGpsJazdy',
    );
    return (odpoved ?? [])
        .whereType<Map>()
        .map(
          (hodnota) => DokoncenaGpsJazdaNaPrenos.zMapy(
            Map<Object?, Object?>.from(hodnota),
          ),
        )
        .toList();
  }

  Future<void> potvrditUlozenie(Iterable<String> identifikatory) async {
    final hodnoty = identifikatory.toList();
    if (hodnoty.isEmpty ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    await _kanal.invokeMethod<void>('potvrditDokonceneGpsJazdy', hodnoty);
  }

  Future<void> otvoritNastaveniaPolohy() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _kanal.invokeMethod<void>('otvoritNastaveniaPolohy');
  }
}

class DokoncenaGpsJazdaNaPrenos {
  const DokoncenaGpsJazdaNaPrenos({
    required this.identifikator,
    required this.jazda,
  });

  factory DokoncenaGpsJazdaNaPrenos.zMapy(Map<Object?, Object?> mapa) {
    num cislo(String kluc) => mapa[kluc] as num;

    TrasaBod bod(String nazov) => TrasaBod(
      latitude: cislo('${nazov}Latitude').toDouble(),
      longitude: cislo('${nazov}Longitude').toDouble(),
      cas: DateTime.fromMillisecondsSinceEpoch(
        cislo('${nazov}CasMillis').toInt(),
      ),
      presnostMetre: cislo('${nazov}Presnost').toDouble(),
      rychlostMetreZaSekundu: cislo('${nazov}Rychlost').toDouble(),
    );

    return DokoncenaGpsJazdaNaPrenos(
      identifikator: mapa['id']! as String,
      jazda: DokoncenaGpsJazda(
        zaciatok: bod('zaciatok'),
        koniec: bod('koniec'),
        prejdeneMetre: cislo('prejdeneMetre').toDouble(),
      ),
    );
  }

  final String identifikator;
  final DokoncenaGpsJazda jazda;
}

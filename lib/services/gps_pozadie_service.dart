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

  /// Adresa k súradniciam cez Geocoder telefónu (zadarmo, potrebuje internet).
  /// null = teraz sa nedá zistiť; prázdny text = pre miesto adresa neexistuje.
  Future<String?> zistitAdresu(double latitude, double longitude) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      return await _kanal.invokeMethod<String>('adresa', {
        'latitude': latitude,
        'longitude': longitude,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Spárované Bluetooth zariadenia (na výber auta). Na Androide 12+ si
  /// najprv vypýta povolenie „Zariadenia v okolí“.
  Future<List<BluetoothZariadenie>> sparovaneBluetooth() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return [];
    final odpoved = await _kanal.invokeListMethod<dynamic>(
      'sparovaneBluetooth',
    );
    return [
      for (final polozka in odpoved ?? const [])
        if (polozka is Map &&
            polozka['adresa'] is String &&
            polozka['nazov'] is String)
          BluetoothZariadenie(
            adresa: polozka['adresa'] as String,
            nazov: polozka['nazov'] as String,
          ),
    ];
  }

  /// Povie natívnej časti, ktoré Bluetooth zariadenie je auto (null = žiadne).
  Future<void> nastavitBluetoothAuta(String? adresa) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _kanal.invokeMethod<void>('nastavitBluetoothAuta', adresa);
  }
}

class BluetoothZariadenie {
  const BluetoothZariadenie({required this.adresa, required this.nazov});

  final String adresa;
  final String nazov;
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
        autoBluetooth: mapa['autoBluetooth'] as bool?,
      ),
    );
  }

  final String identifikator;
  final DokoncenaGpsJazda jazda;
}

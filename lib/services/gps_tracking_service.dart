import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../models/trasa_bod.dart';

/// Zbiera kvalitné GPS body počas otvorenej aplikácie.
///
/// Dlhodobé sledovanie na pozadí je samostatný krok, pretože vyžaduje
/// osobitné systémové oprávnenia a viditeľné upozornenie pre používateľa.
class GpsTrackingService extends ChangeNotifier {
  static const _rychlostStartMetreZaSekundu = 12 / 3.6;
  static const _rychlostPohybMetreZaSekundu = 3 / 3.6;
  // Krátke státie v zápche alebo na semafore nemá rozdeliť jednu jazdu.
  static const _casZastavenia = Duration(minutes: 20);
  static const _maximalnaPresnostMetre = 35.0;
  static const _minimalnyOdstupMetre = 10;

  final List<TrasaBod> _body = [];
  StreamSubscription<Position>? _predplatne;
  double _prejdeneMetre = 0;
  bool _sledovanieBezi = false;
  String? _chyba;
  bool _jazdaAktivna = false;
  DateTime? _poslednyPohyb;
  Timer? _kontrolaZastavenia;
  final StreamController<DokoncenaGpsJazda> _dokonceneJazdy =
      StreamController.broadcast();

  bool get sledovanieBezi => _sledovanieBezi;
  List<TrasaBod> get body => List.unmodifiable(_body);
  double get prejdeneMetre => _prejdeneMetre;
  String? get chyba => _chyba;
  Stream<DokoncenaGpsJazda> get dokonceneJazdy => _dokonceneJazdy.stream;

  Future<void> zacatSledovanie() async {
    if (_sledovanieBezi) return;

    await _overitDostupnostAPovolenie();
    await _predplatne?.cancel();
    _predplatne = null;
    _body.clear();
    _prejdeneMetre = 0;
    _chyba = null;
    _sledovanieBezi = true;
    _kontrolaZastavenia ??= Timer.periodic(
      const Duration(seconds: 30),
      (_) => _skontrolovatZastavenie(),
    );
    notifyListeners();

    final nastavenia = _nastaveniaPolohy();

    _predplatne = Geolocator.getPositionStream(locationSettings: nastavenia)
        .listen(_spracovatPolohu, onError: _spracovatChybu);
  }

  LocationSettings _nastaveniaPolohy() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: _minimalnyOdstupMetre,
        intervalDuration: const Duration(seconds: 10),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Kniha jázd – Drive Log Cloud',
          notificationText: 'Automatické sledovanie jázd je aktívne.',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }

    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: _minimalnyOdstupMetre,
    );
  }

  Future<void> zastavitSledovanie() async {
    _dokoncitJazdu();
    await _predplatne?.cancel();
    _predplatne = null;
    _sledovanieBezi = false;
    notifyListeners();
  }

  Future<void> _overitDostupnostAPovolenie() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const GpsTrackingException(
        'Služby určovania polohy sú v telefóne vypnuté.',
      );
    }

    var povolenie = await Geolocator.checkPermission();
    if (povolenie == LocationPermission.denied) {
      povolenie = await Geolocator.requestPermission();
    }

    if (povolenie == LocationPermission.denied) {
      throw const GpsTrackingException('Prístup k polohe nebol povolený.');
    }
    if (povolenie == LocationPermission.deniedForever) {
      throw const GpsTrackingException(
        'Prístup k polohe je trvalo zamietnutý. Povoľ ho v nastaveniach aplikácie.',
      );
    }
  }

  void _spracovatPolohu(Position poloha) {
    if (!_sledovanieBezi ||
        !poloha.accuracy.isFinite ||
        poloha.accuracy < 0 ||
        poloha.accuracy > _maximalnaPresnostMetre) {
      return;
    }

    final novyBod = TrasaBod(
      latitude: poloha.latitude,
      longitude: poloha.longitude,
      cas: poloha.timestamp,
      presnostMetre: poloha.accuracy,
      rychlostMetreZaSekundu: poloha.speed.isFinite && poloha.speed > 0
          ? poloha.speed
          : 0,
    );

    if (!_jazdaAktivna) {
      if (novyBod.rychlostMetreZaSekundu < _rychlostStartMetreZaSekundu) return;
      _jazdaAktivna = true;
      _body.clear();
      _prejdeneMetre = 0;
    }

    if (_body.isNotEmpty) {
      final poslednyBod = _body.last;
      final vzdialenost = Geolocator.distanceBetween(
        poslednyBod.latitude,
        poslednyBod.longitude,
        novyBod.latitude,
        novyBod.longitude,
      );
      // Pri státí GPS „poskakuje“ v rámci nepresnosti; tieto skoky nie sú jazda.
      final presnost = novyBod.presnostMetre > poslednyBod.presnostMetre
          ? novyBod.presnostMetre
          : poslednyBod.presnostMetre;
      if (novyBod.rychlostMetreZaSekundu < _rychlostPohybMetreZaSekundu &&
          vzdialenost < presnost) {
        return;
      }
      _prejdeneMetre += vzdialenost;
    }

    _body.add(novyBod);
    if (novyBod.rychlostMetreZaSekundu >= _rychlostPohybMetreZaSekundu) {
      _poslednyPohyb = novyBod.cas;
    }
    notifyListeners();
  }

  void _skontrolovatZastavenie() {
    if (_jazdaAktivna &&
        _poslednyPohyb != null &&
        DateTime.now().difference(_poslednyPohyb!) >= _casZastavenia) {
      _dokoncitJazdu();
    }
  }

  void _dokoncitJazdu() {
    if (!_jazdaAktivna) return;
    if (_body.length >= 2) {
      _dokonceneJazdy.add(
        DokoncenaGpsJazda(
          zaciatok: _body.first,
          koniec: _body.last,
          prejdeneMetre: _prejdeneMetre,
        ),
      );
    }
    _jazdaAktivna = false;
    _poslednyPohyb = null;
    _body.clear();
    _prejdeneMetre = 0;
    notifyListeners();
  }

  void _spracovatChybu(Object chyba) {
    _predplatne?.cancel();
    _predplatne = null;
    _chyba = 'GPS sa nedá čítať: $chyba';
    _sledovanieBezi = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _predplatne?.cancel();
    _kontrolaZastavenia?.cancel();
    _dokonceneJazdy.close();
    super.dispose();
  }
}

class DokoncenaGpsJazda {
  const DokoncenaGpsJazda({
    required this.zaciatok,
    required this.koniec,
    required this.prejdeneMetre,
  });
  final TrasaBod zaciatok;
  final TrasaBod koniec;
  final double prejdeneMetre;
}

class GpsTrackingException implements Exception {
  const GpsTrackingException(this.sprava);

  final String sprava;

  @override
  String toString() => sprava;
}

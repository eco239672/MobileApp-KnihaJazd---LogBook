class TrasaBod {
  const TrasaBod({
    required this.latitude,
    required this.longitude,
    required this.cas,
    required this.presnostMetre,
    required this.rychlostMetreZaSekundu,
  });

  final double latitude;
  final double longitude;
  final DateTime cas;
  final double presnostMetre;
  final double rychlostMetreZaSekundu;
}

import 'package:flutter/services.dart';

final decimalnyVstup = TextInputFormatter.withFunction((
  staraHodnota,
  novaHodnota,
) {
  final jePlatny = RegExp(r'^\d*([,.]\d*)?$').hasMatch(novaHodnota.text);
  return jePlatny ? novaHodnota : staraHodnota;
});

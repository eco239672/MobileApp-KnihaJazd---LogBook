const _nazvyMesiacov = [
  'Január',
  'Február',
  'Marec',
  'Apríl',
  'Máj',
  'Jún',
  'Júl',
  'August',
  'September',
  'Október',
  'November',
  'December',
];

String nazovMesiaca(int mesiac) => _nazvyMesiacov[mesiac - 1];

String formatovatDatum(DateTime datum) {
  return '${datum.day}. ${nazovMesiaca(datum.month).toLowerCase()} ${datum.year}';
}

bool jeRovnakyDen(DateTime prvy, DateTime druhy) {
  return prvy.year == druhy.year &&
      prvy.month == druhy.month &&
      prvy.day == druhy.day;
}

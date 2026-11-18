import 'jazda.dart';
import 'nastavenia_vozidla.dart';

/// Jedna zmena jazdy: na odoslanie do cloudu alebo stiahnutá z cloudu.
///
/// [upravene] je čas poslednej úpravy na zariadení (ms od 1970). Pri konflikte
/// dvoch zariadení vyhráva novšia úprava.
class ZmenaJazdy {
  const ZmenaJazdy({
    required this.cloudId,
    required this.upravene,
    this.jazda,
    this.vymazana = false,
  });

  final String cloudId;

  /// Údaje jazdy; pri vymazanej jazde je null.
  final Jazda? jazda;
  final bool vymazana;
  final int upravene;
}

class ZmenaNastaveni {
  const ZmenaNastaveni({required this.nastavenia, required this.upravene});

  final NastaveniaVozidla nastavenia;
  final int upravene;
}

class StiahnuteZmeny {
  const StiahnuteZmeny({required this.jazdy, this.najnovsiCasMillis});

  final List<ZmenaJazdy> jazdy;

  /// Najnovší serverový čas medzi stiahnutými záznammi; od neho sa nabudúce
  /// sťahuje znova (s malým prekryvom).
  final int? najnovsiCasMillis;
}

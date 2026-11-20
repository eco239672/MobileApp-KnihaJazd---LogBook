import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../models/jazda.dart';
import '../models/nastavenia_vozidla.dart';
import '../models/synchronizacia.dart';

class CloudovyUcet {
  const CloudovyUcet({required this.uid, this.email, this.meno});

  final String uid;
  final String? email;
  final String? meno;

  factory CloudovyUcet.zFirebase(User user) =>
      CloudovyUcet(uid: user.uid, email: user.email, meno: user.displayName);
}

/// Prepojenie lokálnej knihy jázd s Firestore pre jeden Google účet.
class CloudovaSynchronizacia {
  CloudovaSynchronizacia({
    FirebaseAuth? autentifikacia,
    FirebaseFirestore? firestore,
    GoogleSignIn? googlePrihlasenie,
  }) : _autentifikacia = autentifikacia ?? FirebaseAuth.instance,
       _firestore = firestore ?? FirebaseFirestore.instance,
       _googlePrihlasenie = googlePrihlasenie ?? GoogleSignIn();

  final FirebaseAuth _autentifikacia;
  final FirebaseFirestore _firestore;
  final GoogleSignIn _googlePrihlasenie;

  // Firestore nemusí byť pri slabom signáli dostupný; nečakáme donekonečna.
  // Neodoslané zmeny zostávajú v telefóne a odošlú sa pri ďalšej synchronizácii.
  static const _limitOdoslania = Duration(seconds: 30);

  // Prekryv pri sťahovaní: zmeny zapísané tesne pred posledným stiahnutím
  // sa stiahnu ešte raz (zápis je opakovateľný, nič sa nezdvojí).
  static const _prekryvStiahnutia = Duration(minutes: 5);

  CloudovyUcet? get aktualnyUcet {
    final user = _autentifikacia.currentUser;
    return user == null ? null : CloudovyUcet.zFirebase(user);
  }

  Future<CloudovyUcet?> prihlasitCezGoogle() async {
    final googleUcet = await _googlePrihlasenie.signIn();
    if (googleUcet == null) return null;

    final googleAutentifikacia = await googleUcet.authentication;
    final poverenie = GoogleAuthProvider.credential(
      accessToken: googleAutentifikacia.accessToken,
      idToken: googleAutentifikacia.idToken,
    );
    final vysledok = await _autentifikacia.signInWithCredential(poverenie);
    return CloudovyUcet.zFirebase(vysledok.user!);
  }

  /// Počká, kým Firebase po štarte aplikácie obnoví prihlásenie.
  Future<CloudovyUcet?> pockatNaPrihlasenie() async {
    final user = await _autentifikacia.authStateChanges().first;
    return user == null ? null : CloudovyUcet.zFirebase(user);
  }

  Future<void> odhlasit() async {
    await Future.wait([
      _autentifikacia.signOut(),
      _googlePrihlasenie.signOut(),
    ]);
  }

  DocumentReference<Map<String, dynamic>> _pouzivatel() {
    final user = _autentifikacia.currentUser;
    if (user == null) {
      throw StateError('Pred synchronizáciou sa treba prihlásiť cez Google.');
    }
    return _firestore.collection('users').doc(user.uid);
  }

  /// Odošle zmenené a vymazané jazdy. Vymazaná jazda zostane v cloude ako
  /// značka „vymazane“, aby ju zmazali aj ostatné zariadenia.
  Future<void> odoslatJazdy(List<ZmenaJazdy> zmeny) async {
    if (zmeny.isEmpty) return;
    final kolekcia = _pouzivatel().collection('jazdy');
    for (var zaciatok = 0; zaciatok < zmeny.length; zaciatok += 450) {
      final davka = _firestore.batch();
      final koniec = (zaciatok + 450).clamp(0, zmeny.length).toInt();
      for (final zmena in zmeny.sublist(zaciatok, koniec)) {
        final jazda = zmena.jazda;
        davka.set(
          kolekcia.doc(zmena.cloudId),
          zmena.vymazana || jazda == null
              ? {
                  'vymazane': true,
                  'upravene': zmena.upravene,
                  'aktualizovane': FieldValue.serverTimestamp(),
                }
              : {
                  ..._jazdaDoMapy(jazda),
                  'vymazane': false,
                  'upravene': zmena.upravene,
                },
          SetOptions(merge: true),
        );
      }
      await davka.commit().timeout(_limitOdoslania);
    }
  }

  /// Stiahne jazdy zmenené od [odMillis] (serverový čas). Bez [odMillis] všetky.
  Future<StiahnuteZmeny> stiahnutJazdy({int? odMillis}) async {
    Query<Map<String, dynamic>> dotaz = _pouzivatel().collection('jazdy');
    if (odMillis != null) {
      dotaz = dotaz.where(
        'aktualizovane',
        isGreaterThan: Timestamp.fromMillisecondsSinceEpoch(
          odMillis - _prekryvStiahnutia.inMilliseconds,
        ),
      );
    }
    // Len zo servera: údaje z vyrovnávacej pamäte by posunuli čas stiahnutia
    // a skutočné zmeny z iného zariadenia by sa už nestiahli.
    final vysledok = await dotaz
        .get(const GetOptions(source: Source.server))
        .timeout(_limitOdoslania);

    int? najnovsi;
    final zmeny = <ZmenaJazdy>[];
    for (final dokument in vysledok.docs) {
      final data = dokument.data();
      final aktualizovane = data['aktualizovane'];
      final aktualizovaneMillis = aktualizovane is Timestamp
          ? aktualizovane.millisecondsSinceEpoch
          : null;
      if (aktualizovaneMillis != null &&
          (najnovsi == null || aktualizovaneMillis > najnovsi)) {
        najnovsi = aktualizovaneMillis;
      }
      // Staršie záznamy (pred touto verziou) nemajú „upravene“.
      final upravene = (data['upravene'] as num?)?.toInt() ?? 0;
      if (data['vymazane'] == true) {
        zmeny.add(
          ZmenaJazdy(cloudId: dokument.id, upravene: upravene, vymazana: true),
        );
        continue;
      }
      final jazda = _jazdaZDokumentu(dokument);
      if (jazda == null) continue;
      zmeny.add(
        ZmenaJazdy(cloudId: dokument.id, upravene: upravene, jazda: jazda),
      );
    }
    return StiahnuteZmeny(jazdy: zmeny, najnovsiCasMillis: najnovsi);
  }

  Future<void> odoslatNastavenia(ZmenaNastaveni zmena) async {
    await _pouzivatel()
        .collection('profil')
        .doc('vozidlo')
        .set({
          ..._nastaveniaDoMapy(zmena.nastavenia),
          'upravene': zmena.upravene,
        }, SetOptions(merge: true))
        .timeout(_limitOdoslania);
  }

  Future<ZmenaNastaveni?> stiahnutNastavenia() async {
    final dokument = await _pouzivatel()
        .collection('profil')
        .doc('vozidlo')
        .get(const GetOptions(source: Source.server))
        .timeout(_limitOdoslania);
    final data = dokument.data();
    if (!dokument.exists || data == null) return null;
    return ZmenaNastaveni(
      nastavenia: _nastaveniaZMapy(data),
      upravene: (data['upravene'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, Object?> _jazdaDoMapy(Jazda jazda) => {
    'datum': Timestamp.fromDate(jazda.datum),
    'odkial': jazda.odkial,
    'kam': jazda.kam,
    'zaciatok': jazda.zaciatok,
    'koniec': jazda.koniec,
    'kilometre': jazda.kilometre,
    'typ': jazda.typ.name,
    'ucel': jazda.ucel,
    'vodic': jazda.vodic,
    'odkialSuradnice': jazda.odkialSuradnice,
    'kamSuradnice': jazda.kamSuradnice,
    'tachometerPo': jazda.tachometerPo,
    'autoBluetooth': jazda.autoBluetooth,
    'aktualizovane': FieldValue.serverTimestamp(),
  };

  Jazda? _jazdaZDokumentu(
    QueryDocumentSnapshot<Map<String, dynamic>> dokument,
  ) {
    final data = dokument.data();
    final datum = data['datum'];
    if (datum is! Timestamp) return null;
    final typ = data['typ'];
    if (typ is! String ||
        !TypJazdy.values.map((hodnota) => hodnota.name).contains(typ)) {
      return null;
    }
    final kilometre = data['kilometre'];
    if (kilometre is! num) return null;
    return Jazda(
      cloudId: dokument.id,
      datum: datum.toDate(),
      odkial: data['odkial'] as String? ?? '',
      kam: data['kam'] as String? ?? '',
      zaciatok: data['zaciatok'] as String? ?? '',
      koniec: data['koniec'] as String? ?? '',
      kilometre: kilometre.toDouble(),
      typ: TypJazdy.values.byName(typ),
      ucel: data['ucel'] as String? ?? '',
      vodic: data['vodic'] as String? ?? '',
      odkialSuradnice: data['odkialSuradnice'] as String?,
      kamSuradnice: data['kamSuradnice'] as String?,
      tachometerPo: (data['tachometerPo'] as num?)?.toDouble(),
      autoBluetooth: data['autoBluetooth'] as bool?,
    );
  }

  Map<String, Object?> _nastaveniaDoMapy(NastaveniaVozidla nastavenia) => {
    'spz': nastavenia.spz,
    'priemernaSpotreba': nastavenia.priemernaSpotreba,
    'cenaBenzinu': nastavenia.cenaBenzinu,
    'cenaNafty': nastavenia.cenaNafty,
    'vin': nastavenia.vin,
    'znackaTyp': nastavenia.znackaTyp,
    'kategoria': nastavenia.kategoria,
    'vodic': nastavenia.vodic,
    'pociatocnyTachometer': nastavenia.pociatocnyTachometer,
    'oblubeneMiesta': [
      for (final miesto in nastavenia.oblubeneMiesta) miesto.naMapu(),
    ],
    'bluetoothAuta': nastavenia.bluetoothAuta,
    'bluetoothAutaNazov': nastavenia.bluetoothAutaNazov,
    'aktualizovane': FieldValue.serverTimestamp(),
  };

  NastaveniaVozidla _nastaveniaZMapy(Map<String, dynamic> data) =>
      NastaveniaVozidla(
        spz: data['spz'] as String? ?? '',
        priemernaSpotreba: (data['priemernaSpotreba'] as num?)?.toDouble(),
        cenaBenzinu: (data['cenaBenzinu'] as num?)?.toDouble(),
        cenaNafty: (data['cenaNafty'] as num?)?.toDouble(),
        vin: data['vin'] as String? ?? '',
        znackaTyp: data['znackaTyp'] as String? ?? '',
        kategoria: data['kategoria'] as String? ?? 'M1',
        vodic: data['vodic'] as String? ?? '',
        pociatocnyTachometer: (data['pociatocnyTachometer'] as num?)
            ?.toDouble(),
        oblubeneMiesta: OblubeneMiesto.zoZoznamu(data['oblubeneMiesta']),
        bluetoothAuta: data['bluetoothAuta'] as String?,
        bluetoothAutaNazov: data['bluetoothAutaNazov'] as String?,
      );
}

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../models/jazda.dart';
import '../models/nastavenia_vozidla.dart';

class CloudovyUcet {
  const CloudovyUcet({required this.uid, this.email, this.meno});

  final String uid;
  final String? email;
  final String? meno;

  factory CloudovyUcet.zFirebase(User user) =>
      CloudovyUcet(uid: user.uid, email: user.email, meno: user.displayName);
}

class VysledokSynchronizacie {
  const VysledokSynchronizacie({
    required this.stiahnuteJazdy,
    this.stiahnuteNastavenia,
  });

  final List<Jazda> stiahnuteJazdy;
  final NastaveniaVozidla? stiahnuteNastavenia;
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

  Future<void> odhlasit() async {
    await Future.wait([
      _autentifikacia.signOut(),
      _googlePrihlasenie.signOut(),
    ]);
  }

  Future<void> vymazatJazdy(Iterable<Jazda> jazdy) async {
    final user = _autentifikacia.currentUser;
    if (user == null) {
      throw StateError('Pred úpravou cloudových dát sa treba prihlásiť.');
    }
    final davka = _firestore.batch();
    final kolekcia = _firestore
        .collection('users')
        .doc(user.uid)
        .collection('jazdy');
    for (final jazda in jazdy) {
      final cloudId = jazda.cloudId;
      if (cloudId != null) davka.delete(kolekcia.doc(cloudId));
    }
    await davka.commit();
  }

  /// Stiahne chýbajúce jazdy a potom odošle miestne dáta do súkromnej vetvy
  /// prihláseného používateľa. Firestore môže požiadavky pri strate signálu
  /// zaradiť do svojej lokálnej fronty.
  Future<VysledokSynchronizacie> synchronizovat({
    required List<Jazda> jazdy,
    required NastaveniaVozidla nastavenia,
  }) async {
    final user = _autentifikacia.currentUser;
    if (user == null) {
      throw StateError('Pred synchronizáciou sa treba prihlásiť cez Google.');
    }

    final pouzivatel = _firestore.collection('users').doc(user.uid);
    final vzdialeneJazdy = await pouzivatel.collection('jazdy').get();
    final cloudIds = jazdy
        .map((jazda) => jazda.cloudId)
        .whereType<String>()
        .toSet();
    final stiahnuteJazdy = vzdialeneJazdy.docs
        .where((dokument) => !cloudIds.contains(dokument.id))
        .map((dokument) => _jazdaZDokumentu(dokument))
        .whereType<Jazda>()
        .toList();

    final dokumentNastaveni = await pouzivatel
        .collection('profil')
        .doc('vozidlo')
        .get();
    final maMiestneNastavenia = nastavenia.spz.trim().isNotEmpty;
    final stiahnuteNastavenia = !maMiestneNastavenia && dokumentNastaveni.exists
        ? _nastaveniaZMapy(dokumentNastaveni.data()!)
        : null;

    final davka = _firestore.batch();
    for (final jazda in jazdy) {
      final cloudId = jazda.cloudId;
      if (cloudId == null) continue;
      davka.set(
        pouzivatel.collection('jazdy').doc(cloudId),
        _jazdaDoMapy(jazda),
        SetOptions(merge: true),
      );
    }
    if (maMiestneNastavenia || !dokumentNastaveni.exists) {
      davka.set(
        pouzivatel.collection('profil').doc('vozidlo'),
        _nastaveniaDoMapy(nastavenia),
        SetOptions(merge: true),
      );
    }
    await davka.commit();

    return VysledokSynchronizacie(
      stiahnuteJazdy: stiahnuteJazdy,
      stiahnuteNastavenia: stiahnuteNastavenia,
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
    );
  }

  Map<String, Object?> _nastaveniaDoMapy(NastaveniaVozidla nastavenia) => {
    'spz': nastavenia.spz,
    'priemernaSpotreba': nastavenia.priemernaSpotreba,
    'cenaBenzinu': nastavenia.cenaBenzinu,
    'cenaNafty': nastavenia.cenaNafty,
    'aktualizovane': FieldValue.serverTimestamp(),
  };

  NastaveniaVozidla _nastaveniaZMapy(Map<String, dynamic> data) =>
      NastaveniaVozidla(
        spz: data['spz'] as String? ?? '',
        priemernaSpotreba: (data['priemernaSpotreba'] as num?)?.toDouble(),
        cenaBenzinu: (data['cenaBenzinu'] as num?)?.toDouble(),
        cenaNafty: (data['cenaNafty'] as num?)?.toDouble(),
      );
}

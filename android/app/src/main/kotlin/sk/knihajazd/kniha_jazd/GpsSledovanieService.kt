package sk.knihajazd.kniha_jazd

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.content.ContextCompat
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * Natívna služba Androidu, ktorá zaznamenáva GPS aj keď Flutter obrazovka nie
 * je otvorená. Po skončení jazdy uloží len jej začiatok, koniec a vzdialenosť
 * do SharedPreferences; Flutter ich pri ďalšom otvorení prenesie do SQLite.
 */
class GpsSledovanieService : Service() {
    private val klient: FusedLocationProviderClient by lazy {
        LocationServices.getFusedLocationProviderClient(this)
    }
    private val handler = Handler(Looper.getMainLooper())

    private val zaznam = ZaznamJazdy(
        hodiny = System::currentTimeMillis,
        zapis = { sprava -> Diagnostika.zapisat(this, sprava) },
    )
    private var sleduje = false
    private var gpsUsporne = false
    private var ukonceneZamerne = false

    private val kontrolaZastavenia = object : Runnable {
        override fun run() {
            if (!sleduje) return
            val dovod = zaznam.skontrolovat(aktualnaIstotaAuta())
            if (dovod == null) {
                nastavitIntervalGps()
                handler.postDelayed(this, INTERVAL_KONTROLY_MILLIS)
                return
            }
            Diagnostika.zapisat(
                this@GpsSledovanieService,
                when (dovod) {
                    DovodKonca.ZIADNY_ROZBEH ->
                        "Koniec: auto sa nerozbehlo nad 12 km/h (GPS bodov: ${zaznam.prijateBody} presných, ${zaznam.odmietnuteBody} nepresných)"
                    DovodKonca.VYSTUPIL -> "Koniec: vystúpil z auta a 3 min bez ďalšej jazdy"
                    DovodKonca.BEZ_POHYBU -> "Koniec: auto dlho stojí"
                },
            )
            ukoncitSledovaniePreNecinnost()
        }
    }

    private val polohaCallback = object : LocationCallback() {
        override fun onLocationResult(vysledok: LocationResult) {
            vysledok.locations.forEach(::spracovatPolohu)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Android gives a service started from a BroadcastReceiver only a few
        // seconds to become a foreground service. Activity recognition often
        // wakes the process cold while the phone is locked, so doing permission
        // checks, restoring state, or creating the location request first can
        // exceed that deadline and Android kills the service before a return
        // journey can be recorded.
        Diagnostika.zapisat(this, "Služba: príkaz ${popisAkcie(intent?.action)}")
        if (!ensureForegroundNotification()) {
            // Bez povolenia polohy (Android 14+) alebo keď systém nepovolí
            // spustenie na popredí, by služba padala stále dokola cez
            // START_STICKY. Rozpracovanú jazdu radšej uložíme a skončíme.
            if (!sleduje) obnovitStavJazdy()
            dokoncitJazdu()
            ukonceneZamerne = true
            vymazatStavSledovania()
            stopSelf()
            return START_NOT_STICKY
        }
        when (intent?.action) {
            AKCIA_SPUSTIT -> spustitSledovanie()
            AKCIA_SPRACOVAT_AKTIVITU -> spracovatRozpoznanieAktivity(intent)
            AKCIA_ZASTAVIT -> {
                dokoncitJazdu()
                ukonceneZamerne = true
                vymazatStavSledovania()
                stopSelf()
            }
            null -> if (maUlozeneSledovanie()) spustitSledovanie() else stopSelf()
        }
        // Ak Android proces dočasne uvoľní napríklad počas hovoru alebo pri
        // nedostatku pamäte, vytvorí službu znova. Stav trasy je priebežne
        // uložený, takže sa pokračuje v tej istej jazde.
        return START_STICKY
    }

    /** Prijíma systémovú udalosť „v aute“ priamo ako foreground služba. */
    private fun spracovatRozpoznanieAktivity(intent: Intent) {
        if (!ActivityTransitionResult.hasResult(intent)) {
            stopSelf()
            return
        }
        val vysledok = ActivityTransitionResult.extractResult(intent) ?: run {
            stopSelf()
            return
        }
        for (udalost in vysledok.transitionEvents) {
            if (udalost.activityType != DetectedActivity.IN_VEHICLE) continue
            val vAute = udalost.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER
            Diagnostika.zapisat(
                this,
                "Prechod: ${if (vAute) "nastúpil do auta" else "vystúpil z auta"}",
            )
            getSharedPreferences(RozpoznavanieAktivityReceiver.PREFERENCIE, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(RozpoznavanieAktivityReceiver.KLUC_V_AUTE, vAute)
                .apply()
            sendBroadcast(
                Intent(RozpoznavanieAktivityReceiver.AKCIA_STAV_AKTIVITY)
                    .setPackage(packageName)
                    .putExtra(RozpoznavanieAktivityReceiver.EXTRA_V_AUTE, vAute),
            )
            if (vAute) {
                zaznam.nastupil()
                spustitSledovanie()
                continue
            }

            // Google posiela „vystúpil z auta“ aj počas jazdy (overené na
            // Ulefone: 7× za jednu jazdu, pričom odhad súčasne hlásil auto
            // na 85 – 96 %). Preto sa jazda podľa tejto udalosti hneď nekončí.
            val istotaAuta = aktualnaIstotaAuta()
            if (istotaAuta != null && istotaAuta >= ZaznamJazdy.MINIMALNA_ISTOTA_AUTA) {
                Diagnostika.zapisat(
                    this,
                    "Vystúpenie ignorované: odhad stále hlási auto ($istotaAuta %)",
                )
                zaznam.nastupil()
                // Pri tejto udalosti Android dovolí spustiť GPS aj z pozadia.
                spustitSledovanie()
                continue
            }
            if (sleduje || maUlozeneSledovanie()) {
                spustitSledovanie()
                zaznam.vystupil()
                Diagnostika.zapisat(
                    this,
                    "Vystúpenie: jazda sa ukončí, ak sa auto do 3 min znova nerozbehne",
                )
            }
        }
        // Žiadna udalosť „v aute“: služba nemá čo robiť a nesmie zostať
        // visieť na popredí s notifikáciou.
        if (!sleduje) stopSelf()
    }

    /** Istota „v aute“ z posledného odhadu pohybu, ak nie je starší ako 2 minúty. */
    private fun aktualnaIstotaAuta(): Int? {
        val preferencie = getSharedPreferences(
            RozpoznavanieAktivityReceiver.PREFERENCIE,
            Context.MODE_PRIVATE,
        )
        val cas = preferencie.getLong(RozpoznavanieAktivityReceiver.KLUC_ODHAD_CAS, 0L)
        if (System.currentTimeMillis() - cas > MAX_VEK_ODHADU_MILLIS) return null
        return preferencie.getInt(RozpoznavanieAktivityReceiver.KLUC_ODHAD_AUTO_ISTOTA, 0)
    }

    private fun spustitSledovanie() {
        if (sleduje) return
        if (!maPovoleniePolohyNaPozadi(this)) {
            Diagnostika.zapisat(this, "Sledovanie nespustené: chýba presná poloha alebo poloha na pozadí")
            ukonceneZamerne = true
            vymazatStavSledovania()
            stopSelf()
            return
        }
        obnovitStavJazdy()
        zaznam.spustit()

        try {
            poziadatOPolohu(usporne = false)
            sleduje = true
            ukonceneZamerne = false
            ulozitStavSledovania()
            handler.post(kontrolaZastavenia)
            Diagnostika.zapisat(
                this,
                if (zaznam.jazdaZacala) "GPS sledovanie pokračuje v rozpracovanej jazde" else "GPS sledovanie beží, čakám na rozbeh",
            )
        } catch (chyba: SecurityException) {
            Diagnostika.zapisat(this, "GPS odmietnuté: ${Diagnostika.popisChyby(chyba)}")
            ukonceneZamerne = true
            vymazatStavSledovania()
            stopSelf()
        }
    }

    /** GPS každých 10 s počas jazdy, raz za minútu v úspornom režime (auto stojí). */
    private fun poziadatOPolohu(usporne: Boolean) {
        val poziadavka = if (usporne) {
            LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, INTERVAL_GPS_USPORNY_MILLIS)
                .setMinUpdateIntervalMillis(INTERVAL_GPS_USPORNY_MILLIS)
                .build()
        } else {
            LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, INTERVAL_GPS_MILLIS)
                .setMinUpdateDistanceMeters(10f)
                .build()
        }
        klient.requestLocationUpdates(poziadavka, polohaCallback, Looper.getMainLooper())
        gpsUsporne = usporne
    }

    /** Prepne interval GPS, ak sa zmenil úsporný režim záznamu. */
    private fun nastavitIntervalGps() {
        if (!sleduje || zaznam.uspornyRezim == gpsUsporne) return
        try {
            klient.removeLocationUpdates(polohaCallback)
            poziadatOPolohu(zaznam.uspornyRezim)
        } catch (chyba: SecurityException) {
            Diagnostika.zapisat(this, "Zmena intervalu GPS odmietnutá: ${Diagnostika.popisChyby(chyba)}")
        }
    }

    private fun spracovatPolohu(poloha: Location) {
        if (!sleduje) return
        val zmenene = zaznam.spracovatPolohu(
            latitude = poloha.latitude,
            longitude = poloha.longitude,
            presnostMetre = if (poloha.hasAccuracy()) poloha.accuracy else null,
            rychlostMetreZaSekundu = if (poloha.hasSpeed()) poloha.speed else null,
        )
        nastavitIntervalGps()
        if (!zmenene) return
        if (zaznam.pocetBodov <= 2 && poloha.time > 0) {
            // Kontrola, či GPS čip hlási správny čas (Ulefone hlásil zlý rok).
            val rozdiel = poloha.time - System.currentTimeMillis()
            if (kotlin.math.abs(rozdiel) > 60 * 60_000L) {
                Diagnostika.zapisat(this, "GPS čas sa líši od hodín telefónu o ${rozdiel / 86_400_000L} dní")
            }
        }
        ulozitStavSledovania()
    }

    private fun dokoncitJazdu() {
        val pocetBodov = zaznam.pocetBodov
        val jazda = zaznam.dokoncit()
        if (jazda != null) {
            ulozitDokoncenuJazdu(jazda)
        } else if (pocetBodov > 0) {
            Diagnostika.zapisat(this, "Jazda zahodená: len $pocetBodov GPS bod(ov)")
        }
    }

    private fun ulozitDokoncenuJazdu(jazda: DokoncenaJazda) {
        ulozitDokoncenuJazdu(jazda.zaciatok, jazda.koniec, jazda.prejdeneMetre)
        Diagnostika.zapisat(
            this,
            "Jazda uložená: ${"%.1f".format(jazda.prejdeneMetre / 1000)} km, " +
                "${jazda.pocetBodov} bodov, ${jazda.trvanieMinut} min",
        )
    }

    private fun ukoncitSledovaniePreNecinnost() {
        dokoncitJazdu()
        ukonceneZamerne = true
        vymazatStavSledovania()
        getSharedPreferences(RozpoznavanieAktivityReceiver.PREFERENCIE, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(RozpoznavanieAktivityReceiver.KLUC_V_AUTE, false)
            .apply()
        stopSelf()
    }

    private fun ulozitStavSledovania() {
        val stav = zaznam.stav()
        val stavJazdy = JSONObject()
            .put("prvyBod", stav.prvyBod?.naJson())
            .put("poslednyBod", stav.poslednyBod?.naJson())
            .put("pocetBodov", stav.pocetBodov)
            .put("prejdeneMetre", stav.prejdeneMetre)
            .put("poslednyPohybMillis", stav.poslednyPohybMillis)
        getSharedPreferences(PREFERENCIE_STAV_SLEDOVANIA, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KLUC_SLEDOVANIE_AKTIVNE, true)
            .putString(KLUC_STAV_JAZDY, stavJazdy.toString())
            .apply()
    }

    private fun maUlozeneSledovanie(): Boolean =
        getSharedPreferences(PREFERENCIE_STAV_SLEDOVANIA, Context.MODE_PRIVATE)
            .getBoolean(KLUC_SLEDOVANIE_AKTIVNE, false)

    private fun obnovitStavJazdy() {
        val preferencie = getSharedPreferences(PREFERENCIE_STAV_SLEDOVANIA, Context.MODE_PRIVATE)
        val obsah = preferencie.getString(KLUC_STAV_JAZDY, null) ?: return
        val stav = runCatching { JSONObject(obsah) }.getOrNull() ?: return
        val obnovena = runCatching {
            StavJazdy(
                prvyBod = stav.optJSONObject("prvyBod")?.naBod(),
                poslednyBod = stav.optJSONObject("poslednyBod")?.naBod(),
                pocetBodov = stav.optInt("pocetBodov", 0),
                prejdeneMetre = stav.optDouble("prejdeneMetre", 0.0),
                poslednyPohybMillis = if (stav.has("poslednyPohybMillis") &&
                    !stav.isNull("poslednyPohybMillis")
                ) {
                    stav.optLong("poslednyPohybMillis")
                } else {
                    null
                },
            )
        }.getOrNull() ?: return
        // Stará jazda (napr. po reštarte telefónu) sa uzavrie ako samostatná.
        zaznam.obnovit(obnovena)?.let { ulozitDokoncenuJazdu(it) }
    }

    private fun vymazatStavSledovania() {
        getSharedPreferences(PREFERENCIE_STAV_SLEDOVANIA, Context.MODE_PRIVATE)
            .edit()
            .clear()
            .apply()
    }

    private fun ulozitDokoncenuJazdu(zaciatok: GpsBod, koniec: GpsBod, kilometre: Double) {
        val preferencie = getSharedPreferences(PREFERENCIE_DOKONCENE_JAZDY, Context.MODE_PRIVATE)
        val jazdy = runCatching {
            JSONArray(preferencie.getString(KLUC_DOKONCENE_JAZDY, "[]"))
        }.getOrDefault(JSONArray())
        jazdy.put(
            JSONObject()
                .put("id", UUID.randomUUID().toString())
                .put("zaciatokLatitude", zaciatok.latitude)
                .put("zaciatokLongitude", zaciatok.longitude)
                .put("zaciatokCasMillis", zaciatok.casMillis)
                .put("zaciatokPresnost", zaciatok.presnostMetre)
                .put("zaciatokRychlost", zaciatok.rychlostMetreZaSekundu)
                .put("koniecLatitude", koniec.latitude)
                .put("koniecLongitude", koniec.longitude)
                .put("koniecCasMillis", koniec.casMillis)
                .put("koniecPresnost", koniec.presnostMetre)
                .put("koniecRychlost", koniec.rychlostMetreZaSekundu)
                .put("prejdeneMetre", kilometre)
                .apply {
                    // Ak je nastavené Bluetooth auta: bola to jazda vlastným autom?
                    BluetoothAuta.bolPripojenyPocasJazdy(
                        this@GpsSledovanieService,
                        zaciatok.casMillis,
                        koniec.casMillis,
                    )?.let { put("autoBluetooth", it) }
                },
        )
        // Bezpečnostný strop: pri dlhšom nepoužití aplikácie nezaberú záznamy
        // o dokončených jazdách viac než zanedbateľné miesto v telefóne.
        while (jazdy.length() > MAX_DOKONCENYCH_JAZD) jazdy.remove(0)
        preferencie.edit().putString(KLUC_DOKONCENE_JAZDY, jazdy.toString()).apply()
        // Ak je aplikácia práve otvorená, môže nový záznam hneď preniesť do
        // lokálnej databázy a zobraziť ho bez potreby jej opätovného otvorenia.
        sendBroadcast(
            Intent(AKCIA_JAZDA_DOKONCENA).setPackage(packageName),
        )
    }

    private fun vytvoritKanalNotifikacie() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val kanal = NotificationChannel(
            KANAL_NOTIFIKACIE,
            "Sledovanie jázd",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Zobrazuje sa počas automatického GPS sledovania jazdy."
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(kanal)
    }

    /**
     * Must run as the first operation of [onStartCommand]. Keeping it separate
     * makes every service entry point (manual start, activity transition, and
     * sticky restart) meet Android's foreground-service deadline.
     */
    private fun ensureForegroundNotification(): Boolean {
        vytvoritKanalNotifikacie()
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    ID_NOTIFIKACIE,
                    notifikacia(),
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
                )
            } else {
                startForeground(ID_NOTIFIKACIE, notifikacia())
            }
            true
        } catch (chyba: SecurityException) {
            // Android 14+: chýba povolenie polohy pre službu typu „location“.
            Diagnostika.zapisat(this, "Služba na popredí ODMIETNUTÁ: ${Diagnostika.popisChyby(chyba)}")
            false
        } catch (chyba: IllegalStateException) {
            // Android 12+: ForegroundServiceStartNotAllowedException.
            Diagnostika.zapisat(this, "Služba na popredí ODMIETNUTÁ: ${Diagnostika.popisChyby(chyba)}")
            false
        }
    }

    private fun notifikacia(): Notification {
        val otvoritAplikaciu = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, KANAL_NOTIFIKACIE)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("Kniha jázd - GPS sledovanie")
            .setContentText("Automaticky zaznamenávam jazdu.")
            .setContentIntent(otvoritAplikaciu)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        Diagnostika.zapisat(this, if (ukonceneZamerne) "Služba ukončená" else "Služba ukončená systémom (obnoví sa)")
        handler.removeCallbacks(kontrolaZastavenia)
        klient.removeLocationUpdates(polohaCallback)
        // Pri neočakávanom ukončení nevytvárame skrátenú jazdu. Služba sa cez
        // START_STICKY obnoví a nadviaže na priebežne uložený stav.
        if (!ukonceneZamerne && sleduje) ulozitStavSledovania()
        sleduje = false
        super.onDestroy()
    }

    private fun popisAkcie(akcia: String?): String = when (akcia) {
        AKCIA_SPUSTIT -> "spustiť"
        AKCIA_ZASTAVIT -> "zastaviť"
        AKCIA_SPRACOVAT_AKTIVITU -> "udalosť auta"
        null -> "obnovenie po ukončení systémom"
        else -> akcia
    }

    companion object {
        const val AKCIA_SPUSTIT = "sk.knihajazd.kniha_jazd.SPUSTIT_GPS_SLEDOVANIE"
        const val AKCIA_ZASTAVIT = "sk.knihajazd.kniha_jazd.ZASTAVIT_GPS_SLEDOVANIE"
        const val AKCIA_SPRACOVAT_AKTIVITU = "sk.knihajazd.kniha_jazd.SPRACOVAT_AKTIVITU"
        const val AKCIA_JAZDA_DOKONCENA = "sk.knihajazd.kniha_jazd.GPS_JAZDA_DOKONCENA"
        const val PREFERENCIE_DOKONCENE_JAZDY = "dokoncene_gps_jazdy"
        const val KLUC_DOKONCENE_JAZDY = "jazdy"
        private const val PREFERENCIE_STAV_SLEDOVANIA = "stav_gps_sledovania"
        private const val KLUC_SLEDOVANIE_AKTIVNE = "aktivne"
        private const val KLUC_STAV_JAZDY = "stav_jazdy"

        private const val KANAL_NOTIFIKACIE = "gps_sledovanie_jazd"
        private const val ID_NOTIFIKACIE = 742
        private const val MAX_VEK_ODHADU_MILLIS = 2 * 60 * 1_000L
        private const val INTERVAL_KONTROLY_MILLIS = 30_000L
        private const val INTERVAL_GPS_MILLIS = 10_000L
        private const val INTERVAL_GPS_USPORNY_MILLIS = 60_000L
        private const val MAX_DOKONCENYCH_JAZD = 50

        fun maRozpracovaneSledovanie(context: Context): Boolean =
            context.getSharedPreferences(PREFERENCIE_STAV_SLEDOVANIA, Context.MODE_PRIVATE)
                .getBoolean(KLUC_SLEDOVANIE_AKTIVNE, false)

        fun maPovoleniePolohyNaPozadi(context: Context): Boolean {
            val maPresnuPolohu = ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.ACCESS_FINE_LOCATION,
            ) == PackageManager.PERMISSION_GRANTED
            val maPozadie = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.ACCESS_BACKGROUND_LOCATION,
                ) == PackageManager.PERMISSION_GRANTED
            return maPresnuPolohu && maPozadie
        }

        private fun GpsBod.naJson(): JSONObject = JSONObject()
            .put("latitude", latitude)
            .put("longitude", longitude)
            .put("casMillis", casMillis)
            .put("presnostMetre", presnostMetre)
            .put("rychlostMetreZaSekundu", rychlostMetreZaSekundu)

        private fun JSONObject.naBod(): GpsBod = GpsBod(
            latitude = getDouble("latitude"),
            longitude = getDouble("longitude"),
            casMillis = getLong("casMillis"),
            presnostMetre = getDouble("presnostMetre").toFloat(),
            rychlostMetreZaSekundu = getDouble("rychlostMetreZaSekundu").toFloat(),
        )
    }
}

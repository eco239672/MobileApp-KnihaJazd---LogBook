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

    private var prvyBod: Bod? = null
    private var poslednyBod: Bod? = null
    private var pocetBodov = 0
    private var prejdeneMetre = 0.0
    private var poslednyPohybMillis: Long? = null
    private var spusteneSledovanieMillis = 0L
    private var sleduje = false
    private var ukonceneZamerne = false
    private var kandidatZaciatku: Bod? = null

    private val kontrolaZastavenia = object : Runnable {
        override fun run() {
            val poslednyPohyb = poslednyPohybMillis
            val teraz = System.currentTimeMillis()
            if (sleduje && prvyBod == null &&
                teraz - spusteneSledovanieMillis >= CAS_CAKANIA_NA_POHYB_MILLIS
            ) {
                ukoncitSledovaniePreNecinnost()
                return
            }
            if (sleduje && poslednyPohyb != null &&
                teraz - poslednyPohyb >= CAS_ZASTAVENIA_MILLIS
            ) {
                ukoncitSledovaniePreNecinnost()
                return
            }
            if (sleduje) handler.postDelayed(this, INTERVAL_KONTROLY_MILLIS)
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
                spustitSledovanie()
            } else {
                dokoncitJazdu()
                ukonceneZamerne = true
                vymazatStavSledovania()
                stopSelf()
                return
            }
        }
        // Žiadna udalosť „v aute“: služba nemá čo robiť a nesmie zostať
        // visieť na popredí s notifikáciou.
        if (!sleduje) stopSelf()
    }

    private fun spustitSledovanie() {
        if (sleduje) return
        if (!maPovoleniePolohyNaPozadi(this)) {
            ukonceneZamerne = true
            vymazatStavSledovania()
            stopSelf()
            return
        }
        obnovitStavJazdy()
        spusteneSledovanieMillis = System.currentTimeMillis()

        val poziadavka = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 10_000)
            .setMinUpdateDistanceMeters(10f)
            .build()
        try {
            klient.requestLocationUpdates(poziadavka, polohaCallback, Looper.getMainLooper())
            sleduje = true
            ukonceneZamerne = false
            ulozitStavSledovania()
            handler.post(kontrolaZastavenia)
        } catch (_: SecurityException) {
            ukonceneZamerne = true
            vymazatStavSledovania()
            stopSelf()
        }
    }

    private fun spracovatPolohu(poloha: Location) {
        if (!sleduje || !poloha.hasAccuracy() || poloha.accuracy > MAXIMALNA_PRESNOST_METRE) {
            return
        }

        val rychlost = if (poloha.hasSpeed() && poloha.speed > 0) poloha.speed else 0f
        val novyBod = Bod(
            latitude = poloha.latitude,
            longitude = poloha.longitude,
            casMillis = if (poloha.time > 0) poloha.time else System.currentTimeMillis(),
            presnostMetre = poloha.accuracy,
            rychlostMetreZaSekundu = rychlost,
        )

        if (prvyBod == null) {
            if (rychlost < RYCHLOST_START_METRE_ZA_SEKUNDU) {
                // Zapamätáme si miesto pred rozbehom, aby jazde nechýbal úvodný úsek.
                kandidatZaciatku = novyBod
                return
            }
            val kandidat = kandidatZaciatku
            kandidatZaciatku = null
            if (kandidat != null &&
                novyBod.casMillis - kandidat.casMillis in 0..MAX_VEK_ZACIATKU_MILLIS
            ) {
                prvyBod = kandidat
                poslednyBod = kandidat
                pocetBodov = 1
            }
        }

        val predchadzajuciBod = poslednyBod
        if (predchadzajuciBod != null) {
            val vzdialenost = FloatArray(1)
            Location.distanceBetween(
                predchadzajuciBod.latitude,
                predchadzajuciBod.longitude,
                novyBod.latitude,
                novyBod.longitude,
                vzdialenost,
            )
            // Pri státí GPS „poskakuje“ v rámci svojej nepresnosti. Takéto
            // skoky nepripočítavame, inak by zápcha pridávala kilometre.
            val stoji = rychlost < RYCHLOST_POHYB_METRE_ZA_SEKUNDU &&
                vzdialenost[0] < maxOf(novyBod.presnostMetre, predchadzajuciBod.presnostMetre)
            if (stoji) return
            prejdeneMetre += vzdialenost[0]
        } else {
            prvyBod = novyBod
        }
        poslednyBod = novyBod
        pocetBodov += 1
        if (rychlost >= RYCHLOST_POHYB_METRE_ZA_SEKUNDU) {
            poslednyPohybMillis = novyBod.casMillis
        }
        ulozitStavSledovania()
    }

    private fun dokoncitJazdu() {
        val zaciatok = prvyBod
        val koniec = poslednyBod
        if (zaciatok != null && koniec != null && pocetBodov >= 2) {
            ulozitDokoncenuJazdu(zaciatok, koniec, prejdeneMetre)
        }
        prvyBod = null
        poslednyBod = null
        pocetBodov = 0
        prejdeneMetre = 0.0
        poslednyPohybMillis = null
        kandidatZaciatku = null
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
        val stavJazdy = JSONObject()
            .put("prvyBod", prvyBod?.naJson())
            .put("poslednyBod", poslednyBod?.naJson())
            .put("pocetBodov", pocetBodov)
            .put("prejdeneMetre", prejdeneMetre)
            .put("poslednyPohybMillis", poslednyPohybMillis)
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
        prvyBod = stav.optJSONObject("prvyBod")?.naBod()
        poslednyBod = stav.optJSONObject("poslednyBod")?.naBod()
        pocetBodov = stav.optInt("pocetBodov", 0)
        prejdeneMetre = stav.optDouble("prejdeneMetre", 0.0)
        poslednyPohybMillis = if (stav.has("poslednyPohybMillis") &&
            !stav.isNull("poslednyPohybMillis")
        ) {
            stav.optLong("poslednyPohybMillis")
        } else {
            null
        }
        // Starý rozpracovaný záznam (napr. po reštarte telefónu) uzavrieme ako
        // samostatnú jazdu, aby sa nespojil s novou jazdou o niekoľko hodín neskôr.
        val posledny = poslednyBod
        if (posledny != null &&
            System.currentTimeMillis() - posledny.casMillis >= CAS_ZASTAVENIA_MILLIS
        ) {
            dokoncitJazdu()
        }
    }

    private fun vymazatStavSledovania() {
        getSharedPreferences(PREFERENCIE_STAV_SLEDOVANIA, Context.MODE_PRIVATE)
            .edit()
            .clear()
            .apply()
    }

    private fun ulozitDokoncenuJazdu(zaciatok: Bod, koniec: Bod, kilometre: Double) {
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
                .put("prejdeneMetre", kilometre),
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
        } catch (_: SecurityException) {
            // Android 14+: chýba povolenie polohy pre službu typu „location“.
            false
        } catch (_: IllegalStateException) {
            // Android 12+: ForegroundServiceStartNotAllowedException.
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
        handler.removeCallbacks(kontrolaZastavenia)
        klient.removeLocationUpdates(polohaCallback)
        // Pri neočakávanom ukončení nevytvárame skrátenú jazdu. Služba sa cez
        // START_STICKY obnoví a nadviaže na priebežne uložený stav.
        if (!ukonceneZamerne && sleduje) ulozitStavSledovania()
        sleduje = false
        super.onDestroy()
    }

    private data class Bod(
        val latitude: Double,
        val longitude: Double,
        val casMillis: Long,
        val presnostMetre: Float,
        val rychlostMetreZaSekundu: Float,
    ) {
        fun naJson() = JSONObject()
            .put("latitude", latitude)
            .put("longitude", longitude)
            .put("casMillis", casMillis)
            .put("presnostMetre", presnostMetre)
            .put("rychlostMetreZaSekundu", rychlostMetreZaSekundu)
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
        private const val RYCHLOST_START_METRE_ZA_SEKUNDU = 12 / 3.6f
        private const val RYCHLOST_POHYB_METRE_ZA_SEKUNDU = 3 / 3.6f
        private const val MAXIMALNA_PRESNOST_METRE = 35f
        private const val CAS_ZASTAVENIA_MILLIS = 20 * 60 * 1_000L
        private const val CAS_CAKANIA_NA_POHYB_MILLIS = 5 * 60 * 1_000L
        private const val INTERVAL_KONTROLY_MILLIS = 30_000L
        private const val MAX_DOKONCENYCH_JAZD = 50
        // Posledná poloha pred rozbehom sa použije ako začiatok jazdy, ak je čerstvá.
        private const val MAX_VEK_ZACIATKU_MILLIS = 3 * 60 * 1_000L

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

        private fun JSONObject.naBod(): Bod = Bod(
            latitude = getDouble("latitude"),
            longitude = getDouble("longitude"),
            casMillis = getLong("casMillis"),
            presnostMetre = getDouble("presnostMetre").toFloat(),
            rychlostMetreZaSekundu = getDouble("rychlostMetreZaSekundu").toFloat(),
        )
    }
}

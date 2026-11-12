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
    private var sleduje = false
    private var ukonceneZamerne = false

    private val kontrolaZastavenia = object : Runnable {
        override fun run() {
            val poslednyPohyb = poslednyPohybMillis
            if (sleduje && poslednyPohyb != null &&
                System.currentTimeMillis() - poslednyPohyb >= CAS_ZASTAVENIA_MILLIS
            ) {
                dokoncitJazdu()
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
            }
        }
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

        vytvoritKanalNotifikacie()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                ID_NOTIFIKACIE,
                notifikacia(),
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
            )
        } else {
            startForeground(ID_NOTIFIKACIE, notifikacia())
        }

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
        if (prvyBod == null && rychlost < RYCHLOST_START_METRE_ZA_SEKUNDU) return

        val novyBod = Bod(
            latitude = poloha.latitude,
            longitude = poloha.longitude,
            casMillis = if (poloha.time > 0) poloha.time else System.currentTimeMillis(),
            presnostMetre = poloha.accuracy,
            rychlostMetreZaSekundu = rychlost,
        )
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
        if (sleduje) ulozitStavSledovania()
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
        private const val RYCHLOST_START_METRE_ZA_SEKUNDU = 12 / 3f
        private const val RYCHLOST_POHYB_METRE_ZA_SEKUNDU = 3 / 3f
        private const val MAXIMALNA_PRESNOST_METRE = 35f
        private const val CAS_ZASTAVENIA_MILLIS = 20 * 60 * 1_000L
        private const val INTERVAL_KONTROLY_MILLIS = 30_000L
        private const val MAX_DOKONCENYCH_JAZD = 50

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

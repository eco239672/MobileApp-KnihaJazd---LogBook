package sk.knihajazd.kniha_jazd

import android.Manifest
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.Address
import android.location.Geocoder
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val methodChannelName = "sk.knihajazd.kniha_jazd/rozpoznavanie_aktivity"
    private val eventChannelName = "sk.knihajazd.kniha_jazd/rozpoznavanie_aktivity_udalosti"
    private val requestPovolenia = 481
    private val requestNotifikacie = 482
    private val requestBluetooth = 483
    private var cakajuciVysledokBluetooth: MethodChannel.Result? = null

    private var eventSink: EventChannel.EventSink? = null
    private var cakajuciVysledokPovolenia: MethodChannel.Result? = null
    private var cakajuciVysledokNotifikacii: MethodChannel.Result? = null
    private var prijimacZaregistrovany = false

    private val prijimacStavu = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                RozpoznavanieAktivityReceiver.AKCIA_STAV_AKTIVITY -> {
                    eventSink?.success(
                        mapOf(
                            "vAute" to intent.getBooleanExtra(
                                RozpoznavanieAktivityReceiver.EXTRA_V_AUTE,
                                false,
                            ),
                        ),
                    )
                }
                GpsSledovanieService.AKCIA_JAZDA_DOKONCENA -> {
                    eventSink?.success(mapOf("gpsJazdaDokoncena" to true))
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "stav" -> result.success(stav())
                    "povolitASpustit" -> povolitASpustit(result)
                    "obnovitAkJeAktivne" -> obnovitAkJeAktivne(result)
                    "zastavit" -> zastavit(result)
                    "nacitatDokonceneGpsJazdy" -> result.success(nacitatDokonceneGpsJazdy())
                    "potvrditDokonceneGpsJazdy" -> {
                        val identifikatory = call.arguments<List<String>>() ?: emptyList()
                        potvrditDokonceneGpsJazdy(identifikatory)
                        result.success(null)
                    }
                    "otvoritNastaveniaPolohy" -> otvoritNastaveniaPolohy(result)
                    "povolitNotifikacie" -> povolitNotifikacie(result)
                    "otvoritUsporuBaterie" -> otvoritUsporuBaterie(result)
                    "nacitatDiagnostiku" -> result.success(Diagnostika.nacitat(this))
                    "vymazatDiagnostiku" -> {
                        Diagnostika.vymazat(this)
                        result.success(null)
                    }
                    "zapisatDiagnostiku" -> {
                        call.arguments<String>()?.let { Diagnostika.zapisat(this, it) }
                        result.success(null)
                    }
                    "adresa" -> {
                        val latitude = call.argument<Double>("latitude")
                        val longitude = call.argument<Double>("longitude")
                        if (latitude == null || longitude == null) {
                            result.success(null)
                        } else {
                            zistitAdresu(latitude, longitude, result)
                        }
                    }
                    "sparovaneBluetooth" -> sparovaneBluetooth(result)
                    "nastavitBluetoothAuta" -> {
                        BluetoothAuta.nastavit(this, call.arguments<String>())
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    zaregistrovatPrijimac()
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    odregistrovatPrijimac()
                }
            })
    }

    private fun stav(): Map<String, Boolean> {
        val preferencie = getSharedPreferences(
            RozpoznavanieAktivityReceiver.PREFERENCIE,
            Context.MODE_PRIVATE,
        )
        return mapOf(
            "povolene" to maPovolenie(),
            "aktivne" to RegistraciaRozpoznavania.jeZapnute(this),
            "vAute" to preferencie.getBoolean(
                RozpoznavanieAktivityReceiver.KLUC_V_AUTE,
                false,
            ),
            "polohaNaPozadiPovolena" to GpsSledovanieService.maPovoleniePolohyNaPozadi(this),
            "notifikaciePovolene" to NotificationManagerCompat.from(this).areNotificationsEnabled(),
            "usporaBaterieVypnuta" to getSystemService(PowerManager::class.java)
                .isIgnoringBatteryOptimizations(packageName),
        )
    }

    private fun nacitatDokonceneGpsJazdy(): List<Map<String, Any>> {
        val preferencie = getSharedPreferences(
            GpsSledovanieService.PREFERENCIE_DOKONCENE_JAZDY,
            MODE_PRIVATE,
        )
        val jazdy = runCatching {
            JSONArray(preferencie.getString(GpsSledovanieService.KLUC_DOKONCENE_JAZDY, "[]"))
        }.getOrDefault(JSONArray())
        return buildList {
            for (index in 0 until jazdy.length()) {
                val jazda = jazdy.optJSONObject(index) ?: continue
                val zaznam = runCatching {
                    mapOf(
                        "id" to jazda.getString("id"),
                        "zaciatokLatitude" to jazda.getDouble("zaciatokLatitude"),
                        "zaciatokLongitude" to jazda.getDouble("zaciatokLongitude"),
                        "zaciatokCasMillis" to jazda.getLong("zaciatokCasMillis"),
                        "zaciatokPresnost" to jazda.getDouble("zaciatokPresnost"),
                        "zaciatokRychlost" to jazda.getDouble("zaciatokRychlost"),
                        "koniecLatitude" to jazda.getDouble("koniecLatitude"),
                        "koniecLongitude" to jazda.getDouble("koniecLongitude"),
                        "koniecCasMillis" to jazda.getLong("koniecCasMillis"),
                        "koniecPresnost" to jazda.getDouble("koniecPresnost"),
                        "koniecRychlost" to jazda.getDouble("koniecRychlost"),
                        "prejdeneMetre" to jazda.getDouble("prejdeneMetre"),
                    ) + if (jazda.has("autoBluetooth")) {
                        mapOf("autoBluetooth" to jazda.getBoolean("autoBluetooth"))
                    } else {
                        emptyMap()
                    }
                }.getOrNull() ?: continue
                add(zaznam)
            }
        }
    }

    private fun potvrditDokonceneGpsJazdy(identifikatory: List<String>) {
        if (identifikatory.isEmpty()) return
        val preferencie = getSharedPreferences(
            GpsSledovanieService.PREFERENCIE_DOKONCENE_JAZDY,
            MODE_PRIVATE,
        )
        val povodne = runCatching {
            JSONArray(preferencie.getString(GpsSledovanieService.KLUC_DOKONCENE_JAZDY, "[]"))
        }.getOrDefault(JSONArray())
        val zostavajuce = JSONArray()
        for (index in 0 until povodne.length()) {
            val jazda = povodne.optJSONObject(index) ?: continue
            if (jazda.optString("id") !in identifikatory) zostavajuce.put(jazda)
        }
        preferencie.edit()
            .putString(GpsSledovanieService.KLUC_DOKONCENE_JAZDY, zostavajuce.toString())
            .apply()
    }

    private fun otvoritNastaveniaPolohy(result: MethodChannel.Result) {
        startActivity(
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", packageName, null),
            ),
        )
        result.success(null)
    }

    private fun maPovolenie(): Boolean = RegistraciaRozpoznavania.maPovolenieAktivity(this)

    /**
     * Adresa k súradniciam cez Geocoder telefónu (zadarmo, potrebuje internet).
     * Vráti null pri chybe (napr. bez internetu) a prázdny text, ak pre
     * miesto žiadna adresa neexistuje.
     */
    private fun zistitAdresu(latitude: Double, longitude: Double, result: MethodChannel.Result) {
        if (!Geocoder.isPresent()) {
            result.success(null)
            return
        }
        val hlavneVlakno = Handler(Looper.getMainLooper())
        var odoslane = false
        fun odoslat(hodnota: String?) {
            hlavneVlakno.post {
                if (odoslane) return@post
                odoslane = true
                result.success(hodnota)
            }
        }
        val geocoder = Geocoder(this, Locale.forLanguageTag("sk-SK"))
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                geocoder.getFromLocation(
                    latitude,
                    longitude,
                    1,
                    object : Geocoder.GeocodeListener {
                        override fun onGeocode(adresy: MutableList<Address>) {
                            odoslat(adresy.firstOrNull()?.let { formatovatAdresu(it) } ?: "")
                        }

                        override fun onError(sprava: String?) {
                            odoslat(null)
                        }
                    },
                )
            } else {
                Thread {
                    try {
                        @Suppress("DEPRECATION")
                        val adresy = geocoder.getFromLocation(latitude, longitude, 1)
                        odoslat(adresy?.firstOrNull()?.let { formatovatAdresu(it) } ?: "")
                    } catch (_: Exception) {
                        odoslat(null)
                    }
                }.start()
            }
        } catch (_: Exception) {
            odoslat(null)
        }
    }

    /** „Hlavná 12, Šaľa“; bez ulice len obec. */
    private fun formatovatAdresu(adresa: Address): String {
        val ulica = listOfNotNull(adresa.thoroughfare, adresa.subThoroughfare)
            .joinToString(" ")
            .trim()
        val obec = adresa.locality ?: adresa.subLocality ?: adresa.subAdminArea
        val casti = listOfNotNull(ulica.ifBlank { null }, obec).distinct()
        if (casti.isNotEmpty()) return casti.joinToString(", ")
        return adresa.getAddressLine(0) ?: ""
    }

    /** Spárované Bluetooth zariadenia (Android 12+ najprv vypýta povolenie). */
    private fun sparovaneBluetooth(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED
        ) {
            cakajuciVysledokBluetooth?.error("ZRUSENE", "Nová žiadosť o povolenie", null)
            cakajuciVysledokBluetooth = result
            requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), requestBluetooth)
            return
        }
        result.success(zoznamSparovanych())
    }

    private fun zoznamSparovanych(): List<Map<String, String>> {
        val adapter = getSystemService(BluetoothManager::class.java)?.adapter ?: return emptyList()
        return try {
            adapter.bondedDevices.orEmpty()
                .map { zariadenie ->
                    mapOf(
                        "adresa" to zariadenie.address,
                        "nazov" to (zariadenie.name ?: zariadenie.address),
                    )
                }
                .sortedBy { it["nazov"]?.lowercase() }
        } catch (_: SecurityException) {
            emptyList()
        }
    }

    /**
     * Jedným systémovým dialógom vypýta všetko, čo automatické sledovanie
     * potrebuje: Fyzická aktivita, presná poloha a (Android 13+) notifikácie.
     * Polohu „Povoliť vždy“ Android 11+ dovolí zapnúť už len v nastaveniach.
     */
    private fun povolitASpustit(result: MethodChannel.Result) {
        val chybajuce = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                add(Manifest.permission.ACTIVITY_RECOGNITION)
            }
            add(Manifest.permission.ACCESS_FINE_LOCATION)
            add(Manifest.permission.ACCESS_COARSE_LOCATION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }

        if (chybajuce.isEmpty()) {
            spustitRozpoznavanie(result)
            return
        }
        cakajuciVysledokPovolenia = result
        requestPermissions(chybajuce.toTypedArray(), requestPovolenia)
    }

    /**
     * Android po vynútenom zastavení aplikácie zruší PendingIntent pre
     * rozpoznávanie aktivity. Pri ďalšom otvorení ho preto ticho obnovíme,
     * ak používateľ už raz udelil potrebné povolenie.
     */
    private fun obnovitAkJeAktivne(result: MethodChannel.Result) {
        if (!maPovolenie() || !RegistraciaRozpoznavania.jeZapnute(this)) {
            result.success(null)
            return
        }
        spustitRozpoznavanie(result)
    }

    /**
     * Notifikácia počas jazdy ukazuje, že sledovanie beží. Ak už systém dialóg
     * nezobrazí (používateľ ho dvakrát zamietol), otvorí nastavenia notifikácií.
     */
    private fun povolitNotifikacie(result: MethodChannel.Result) {
        if (NotificationManagerCompat.from(this).areNotificationsEnabled()) {
            result.success(true)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            cakajuciVysledokNotifikacii = result
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), requestNotifikacie)
            return
        }
        otvoritNastaveniaNotifikacii()
        result.success(false)
    }

    /**
     * Zoznam aplikácií v optimalizácii batérie. Optimalizovanú aplikáciu
     * Android uspí a nedoručí jej ani udalosti „v aute“ (overené na Ulefone).
     */
    private fun otvoritUsporuBaterie(result: MethodChannel.Result) {
        try {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        } catch (_: Exception) {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", packageName, null),
                ),
            )
        }
        result.success(null)
    }

    private fun otvoritNastaveniaNotifikacii() {
        startActivity(
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName),
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == requestBluetooth) {
            val vysledok = cakajuciVysledokBluetooth ?: return
            cakajuciVysledokBluetooth = null
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                vysledok.success(zoznamSparovanych())
            } else {
                vysledok.error("BLUETOOTH_ZAMIETNUTE", "Povolenie Zariadenia v okolí nebolo udelené.", null)
            }
            return
        }
        if (requestCode == requestNotifikacie) {
            val vysledok = cakajuciVysledokNotifikacii ?: return
            cakajuciVysledokNotifikacii = null
            val povolene = NotificationManagerCompat.from(this).areNotificationsEnabled()
            if (!povolene) otvoritNastaveniaNotifikacii()
            vysledok.success(povolene)
            return
        }
        if (requestCode != requestPovolenia) return

        val result = cakajuciVysledokPovolenia ?: return
        cakajuciVysledokPovolenia = null
        // Bez Fyzickej aktivity nevieme rozpoznať jazdu. Polohu a notifikácie
        // používateľ môže doplniť neskôr; obrazovka Nastavenia ho na to upozorní.
        if (!maPovolenie()) {
            result.error("POVOLENIE_ZAMIETNUTE", "Povolenie Fyzická aktivita nebolo udelené.", null)
            return
        }
        spustitRozpoznavanie(result)
    }

    private fun spustitRozpoznavanie(result: MethodChannel.Result) {
        RegistraciaRozpoznavania.zaregistrovat(this) { chyba ->
            if (chyba == null) {
                result.success(null)
            } else {
                result.error("ROZPOZNAVANIE_CHYBA", chyba.message, null)
            }
        }
    }

    /** Vypne automatické sledovanie a ukončí prípadnú prebiehajúcu jazdu. */
    private fun zastavit(result: MethodChannel.Result) {
        if (GpsSledovanieService.maRozpracovaneSledovanie(this)) {
            runCatching {
                startService(
                    Intent(this, GpsSledovanieService::class.java)
                        .setAction(GpsSledovanieService.AKCIA_ZASTAVIT),
                )
            }
        }
        RegistraciaRozpoznavania.odregistrovat(this) { result.success(null) }
    }

    private fun zaregistrovatPrijimac() {
        if (prijimacZaregistrovany) return
        val filter = IntentFilter().apply {
            addAction(RozpoznavanieAktivityReceiver.AKCIA_STAV_AKTIVITY)
            addAction(GpsSledovanieService.AKCIA_JAZDA_DOKONCENA)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(prijimacStavu, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(prijimacStavu, filter)
        }
        prijimacZaregistrovany = true
    }

    private fun odregistrovatPrijimac() {
        if (!prijimacZaregistrovany) return
        unregisterReceiver(prijimacStavu)
        prijimacZaregistrovany = false
    }

    override fun onDestroy() {
        odregistrovatPrijimac()
        super.onDestroy()
    }
}

package sk.knihajazd.kniha_jazd

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray

class MainActivity : FlutterActivity() {
    private val methodChannelName = "sk.knihajazd.kniha_jazd/rozpoznavanie_aktivity"
    private val eventChannelName = "sk.knihajazd.kniha_jazd/rozpoznavanie_aktivity_udalosti"
    private val requestPovolenia = 481

    private var eventSink: EventChannel.EventSink? = null
    private var cakajuciVysledokPovolenia: MethodChannel.Result? = null
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
                    )
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

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
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

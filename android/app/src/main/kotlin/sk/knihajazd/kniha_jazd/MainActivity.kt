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
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.DetectedActivity
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray

class MainActivity : FlutterActivity() {
    private val methodChannelName = "sk.knihajazd.kniha_jazd/rozpoznavanie_aktivity"
    private val eventChannelName = "sk.knihajazd.kniha_jazd/rozpoznavanie_aktivity_udalosti"
    private val requestActivityRecognition = 481

    private var eventSink: EventChannel.EventSink? = null
    private var cakajuciVysledokPovolenia: MethodChannel.Result? = null
    private var prijimacZaregistrovany = false

    private val prijimacStavu = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != RozpoznavanieAktivityReceiver.AKCIA_STAV_AKTIVITY) return
            eventSink?.success(
                mapOf(
                    "vAute" to intent.getBooleanExtra(
                        RozpoznavanieAktivityReceiver.EXTRA_V_AUTE,
                        false,
                    ),
                ),
            )
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
            "aktivne" to preferencie.getBoolean("aktivne", false),
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
                add(
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
                    ),
                )
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

    private fun maPovolenie(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) ==
                PackageManager.PERMISSION_GRANTED

    private fun povolitASpustit(result: MethodChannel.Result) {
        if (!maPovolenie()) {
            cakajuciVysledokPovolenia = result
            requestPermissions(
                arrayOf(Manifest.permission.ACTIVITY_RECOGNITION),
                requestActivityRecognition,
            )
            return
        }
        spustitRozpoznavanie(result)
    }

    /**
     * Android po vynútenom zastavení aplikácie zruší PendingIntent pre
     * rozpoznávanie aktivity. Pri ďalšom otvorení ho preto ticho obnovíme,
     * ak používateľ už raz udelil potrebné povolenie.
     */
    private fun obnovitAkJeAktivne(result: MethodChannel.Result) {
        val preferencie = getSharedPreferences(
            RozpoznavanieAktivityReceiver.PREFERENCIE,
            Context.MODE_PRIVATE,
        )
        if (!maPovolenie() || !preferencie.getBoolean("aktivne", false)) {
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
        if (requestCode != requestActivityRecognition) return

        val result = cakajuciVysledokPovolenia ?: return
        cakajuciVysledokPovolenia = null
        if (!maPovolenie()) {
            result.error("POVOLENIE_ZAMIETNUTE", "Povolenie Fyzická aktivita nebolo udelené.", null)
            return
        }
        spustitRozpoznavanie(result)
    }

    private fun spustitRozpoznavanie(result: MethodChannel.Result) {
        val transitions = listOf(
            ActivityTransition.Builder()
                .setActivityType(DetectedActivity.IN_VEHICLE)
                .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_ENTER)
                .build(),
            ActivityTransition.Builder()
                .setActivityType(DetectedActivity.IN_VEHICLE)
                .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_EXIT)
                .build(),
        )
        val request = ActivityTransitionRequest(transitions)
        ActivityRecognition.getClient(this)
            .requestActivityTransitionUpdates(request, pendingIntent())
            .addOnSuccessListener {
                getSharedPreferences(
                    RozpoznavanieAktivityReceiver.PREFERENCIE,
                    Context.MODE_PRIVATE,
                ).edit().putBoolean("aktivne", true).apply()
                result.success(null)
            }
            .addOnFailureListener { chyba ->
                result.error("ROZPOZNAVANIE_CHYBA", chyba.message, null)
            }
    }

    private fun zastavit(result: MethodChannel.Result) {
        ActivityRecognition.getClient(this)
            .removeActivityTransitionUpdates(pendingIntent())
            .addOnCompleteListener {
                getSharedPreferences(
                    RozpoznavanieAktivityReceiver.PREFERENCIE,
                    Context.MODE_PRIVATE,
                ).edit().putBoolean("aktivne", false).apply()
                result.success(null)
            }
    }

    private fun pendingIntent(): android.app.PendingIntent {
        val intent = Intent(this, GpsSledovanieService::class.java)
            .setAction(GpsSledovanieService.AKCIA_SPRACOVAT_AKTIVITU)
        val flags = android.app.PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                android.app.PendingIntent.FLAG_MUTABLE
            } else {
                0
            }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.PendingIntent.getForegroundService(this, 0, intent, flags)
        } else {
            android.app.PendingIntent.getService(this, 0, intent, flags)
        }
    }

    private fun zaregistrovatPrijimac() {
        if (prijimacZaregistrovany) return
        val filter = IntentFilter(RozpoznavanieAktivityReceiver.AKCIA_STAV_AKTIVITY)
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

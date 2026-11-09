package sk.knihajazd.kniha_jazd

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.DetectedActivity
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

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
                    "zastavit" -> zastavit(result)
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
        )
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

    private fun pendingIntent() = android.app.PendingIntent.getBroadcast(
        this,
        0,
        Intent(this, RozpoznavanieAktivityReceiver::class.java),
        android.app.PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                android.app.PendingIntent.FLAG_MUTABLE
            } else {
                0
            },
    )

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

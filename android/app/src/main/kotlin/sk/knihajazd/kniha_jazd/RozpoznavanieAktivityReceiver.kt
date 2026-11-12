package sk.knihajazd.kniha_jazd

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import com.google.android.gms.location.ActivityRecognitionResult
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity

/** Uloží posledný stav aj keď obrazovka aplikácie práve nie je otvorená. */
class RozpoznavanieAktivityReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (ActivityTransitionResult.hasResult(intent)) {
            spracovatPrechody(context, intent)
        } else if (ActivityRecognitionResult.hasResult(intent)) {
            spracovatPriebeznuAktivitu(context, intent)
        }
    }

    private fun spracovatPrechody(context: Context, intent: Intent) {
        val result = ActivityTransitionResult.extractResult(intent) ?: return
        for (event in result.transitionEvents) {
            if (event.activityType != DetectedActivity.IN_VEHICLE) continue

            val vAute = event.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER
            context.getSharedPreferences(PREFERENCIE, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KLUC_V_AUTE, vAute)
                .apply()

            if (vAute && GpsSledovanieService.maPovoleniePolohyNaPozadi(context)) {
                runCatching {
                    ContextCompat.startForegroundService(
                        context,
                        Intent(context, GpsSledovanieService::class.java)
                            .setAction(GpsSledovanieService.AKCIA_SPUSTIT),
                    )
                }
            } else if (!vAute) {
                // Ak služba práve beží, pošleme jej riadne ukončenie. Tak sa
                // dokončí a uloží aj trasa pri telefonovaní či zamknutom displeji.
                runCatching {
                    context.startService(
                        Intent(context, GpsSledovanieService::class.java)
                            .setAction(GpsSledovanieService.AKCIA_ZASTAVIT),
                    )
                }
            }

            context.sendBroadcast(
                Intent(AKCIA_STAV_AKTIVITY)
                    .setPackage(context.packageName)
                    .putExtra(EXTRA_V_AUTE, vAute),
            )
        }
    }

    /**
     * Poistka pre telefóny, ktoré občas nepošlú udalosť prechodu „v aute“.
     * Google Play služby doručia aj priebežný odhad pohybu; ak má jazda autom
     * dostatočnú istotu, spustíme rovnaké sledovanie ako pri prechode.
     */
    private fun spracovatPriebeznuAktivitu(context: Context, intent: Intent) {
        val result = ActivityRecognitionResult.extractResult(intent) ?: return
        val vAute = result.probableActivities.any {
            it.type == DetectedActivity.IN_VEHICLE && it.confidence >= MINIMALNA_ISTOTA_VOZIDLA
        }
        if (!vAute) return

        context.getSharedPreferences(PREFERENCIE, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KLUC_V_AUTE, true)
            .apply()
        if (GpsSledovanieService.maPovoleniePolohyNaPozadi(context)) {
            runCatching {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, GpsSledovanieService::class.java)
                        .setAction(GpsSledovanieService.AKCIA_SPUSTIT),
                )
            }
        }
        context.sendBroadcast(
            Intent(AKCIA_STAV_AKTIVITY)
                .setPackage(context.packageName)
                .putExtra(EXTRA_V_AUTE, true),
        )
    }

    companion object {
        const val PREFERENCIE = "rozpoznavanie_aktivity"
        const val KLUC_V_AUTE = "v_aute"
        const val AKCIA_STAV_AKTIVITY = "sk.knihajazd.kniha_jazd.STAV_AKTIVITY"
        const val AKCIA_AKTUALIZACIA_AKTIVITY =
            "sk.knihajazd.kniha_jazd.AKTUALIZACIA_AKTIVITY"
        const val EXTRA_V_AUTE = "v_aute"
        private const val MINIMALNA_ISTOTA_VOZIDLA = 50
    }
}

package sk.knihajazd.kniha_jazd

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity

/** Uloží posledný stav aj keď obrazovka aplikácie práve nie je otvorená. */
class RozpoznavanieAktivityReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!ActivityTransitionResult.hasResult(intent)) return

        val result = ActivityTransitionResult.extractResult(intent) ?: return
        for (event in result.transitionEvents) {
            if (event.activityType != DetectedActivity.IN_VEHICLE) continue

            val vAute = event.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER
            context.getSharedPreferences(PREFERENCIE, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KLUC_V_AUTE, vAute)
                .apply()

            context.sendBroadcast(
                Intent(AKCIA_STAV_AKTIVITY)
                    .setPackage(context.packageName)
                    .putExtra(EXTRA_V_AUTE, vAute),
            )
        }
    }

    companion object {
        const val PREFERENCIE = "rozpoznavanie_aktivity"
        const val KLUC_V_AUTE = "v_aute"
        const val AKCIA_STAV_AKTIVITY = "sk.knihajazd.kniha_jazd.STAV_AKTIVITY"
        const val EXTRA_V_AUTE = "v_aute"
    }
}

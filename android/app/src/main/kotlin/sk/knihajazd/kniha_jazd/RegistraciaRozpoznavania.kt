package sk.knihajazd.kniha_jazd

import android.Manifest
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.DetectedActivity

/**
 * Registrácia Android rozpoznávania „v aute“. Je oddelená od MainActivity,
 * aby ju vedel obnoviť aj [SpustenieTelefonuReceiver] po reštarte telefónu.
 */
object RegistraciaRozpoznavania {
    const val KLUC_AKTIVNE = "aktivne"
    private const val INTERVAL_AKTUALIZACIE_AKTIVITY_MILLIS = 30_000L

    fun jeZapnute(context: Context): Boolean =
        context.getSharedPreferences(RozpoznavanieAktivityReceiver.PREFERENCIE, Context.MODE_PRIVATE)
            .getBoolean(KLUC_AKTIVNE, false)

    private fun nastavitZapnute(context: Context, zapnute: Boolean) {
        context.getSharedPreferences(RozpoznavanieAktivityReceiver.PREFERENCIE, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KLUC_AKTIVNE, zapnute)
            .apply()
    }

    fun maPovolenieAktivity(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACTIVITY_RECOGNITION) ==
            PackageManager.PERMISSION_GRANTED

    /** [onHotovo] dostane null pri úspechu, inak chybu. */
    fun zaregistrovat(context: Context, onHotovo: (Exception?) -> Unit) {
        val aplikacia = context.applicationContext
        val klient = ActivityRecognition.getClient(aplikacia)
        val request = ActivityTransitionRequest(
            listOf(
                ActivityTransition.Builder()
                    .setActivityType(DetectedActivity.IN_VEHICLE)
                    .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_ENTER)
                    .build(),
                ActivityTransition.Builder()
                    .setActivityType(DetectedActivity.IN_VEHICLE)
                    .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_EXIT)
                    .build(),
            ),
        )

        fun zaregistrovatAktualne() {
            try {
                klient.requestActivityTransitionUpdates(request, pendingIntent(aplikacia))
                    .addOnSuccessListener {
                        klient.requestActivityUpdates(
                            INTERVAL_AKTUALIZACIE_AKTIVITY_MILLIS,
                            aktualizaciaAktivityPendingIntent(aplikacia),
                        )
                            .addOnSuccessListener {
                                nastavitZapnute(aplikacia, true)
                                onHotovo(null)
                            }
                            .addOnFailureListener { chyba ->
                                klient.removeActivityTransitionUpdates(pendingIntent(aplikacia))
                                onHotovo(chyba)
                            }
                    }
                    .addOnFailureListener { chyba -> onHotovo(chyba) }
            } catch (chyba: SecurityException) {
                onHotovo(chyba)
            }
        }

        // Staršia verzia aplikácie prijímala tie isté udalosti cez BroadcastReceiver.
        // Pred novou registráciou ho odstránime, aby nevznikli duplicitné spustenia.
        val stary = staryPendingIntent(aplikacia)
        if (stary == null) {
            zaregistrovatAktualne()
        } else {
            klient.removeActivityTransitionUpdates(stary)
                .addOnCompleteListener { zaregistrovatAktualne() }
        }
    }

    fun odregistrovat(context: Context, onHotovo: () -> Unit) {
        val aplikacia = context.applicationContext
        val klient = ActivityRecognition.getClient(aplikacia)
        nastavitZapnute(aplikacia, false)
        klient.removeActivityTransitionUpdates(pendingIntent(aplikacia))
            .addOnCompleteListener {
                klient.removeActivityUpdates(aktualizaciaAktivityPendingIntent(aplikacia))
                    .addOnCompleteListener { onHotovo() }
            }
    }

    private fun menitelnyFlag(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, GpsSledovanieService::class.java)
            .setAction(GpsSledovanieService.AKCIA_SPRACOVAT_AKTIVITU)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or menitelnyFlag()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(context, 0, intent, flags)
        } else {
            PendingIntent.getService(context, 0, intent, flags)
        }
    }

    private fun aktualizaciaAktivityPendingIntent(context: Context): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            1,
            Intent(context, RozpoznavanieAktivityReceiver::class.java)
                .setAction(RozpoznavanieAktivityReceiver.AKCIA_AKTUALIZACIA_AKTIVITY),
            PendingIntent.FLAG_UPDATE_CURRENT or menitelnyFlag(),
        )

    private fun staryPendingIntent(context: Context): PendingIntent? =
        PendingIntent.getBroadcast(
            context,
            0,
            Intent(context, RozpoznavanieAktivityReceiver::class.java),
            PendingIntent.FLAG_NO_CREATE or menitelnyFlag(),
        )
}

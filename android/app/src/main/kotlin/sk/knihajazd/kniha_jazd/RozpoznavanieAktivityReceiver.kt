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
            Diagnostika.zapisat(
                context,
                "Prechod (prijímač): ${if (vAute) "nastúpil do auta" else "vystúpil z auta"}",
            )
            context.getSharedPreferences(PREFERENCIE, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KLUC_V_AUTE, vAute)
                .apply()

            if (vAute && GpsSledovanieService.maPovoleniePolohyNaPozadi(context)) {
                spustitSledovanie(context, "prechod")
            } else if (vAute) {
                Diagnostika.zapisat(context, "Sledovanie nespustené: chýba poloha na pozadí")
            } else {
                // Ak služba práve beží, pošleme jej riadne ukončenie. Tak sa
                // dokončí a uloží aj trasa pri telefonovaní či zamknutom displeji.
                try {
                    context.startService(
                        Intent(context, GpsSledovanieService::class.java)
                            .setAction(GpsSledovanieService.AKCIA_ZASTAVIT),
                    )
                } catch (chyba: Exception) {
                    Diagnostika.zapisat(
                        context,
                        "Ukončenie sledovania odmietnuté: ${Diagnostika.popisChyby(chyba)}",
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
        ulozitPoslednyOdhad(context, result)
        zapisatOdhad(context, result)
        val vAute = result.probableActivities.any {
            it.type == DetectedActivity.IN_VEHICLE && it.confidence >= MINIMALNA_ISTOTA_VOZIDLA
        }
        if (!vAute) return

        context.getSharedPreferences(PREFERENCIE, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KLUC_V_AUTE, true)
            .apply()
        if (GpsSledovanieService.maPovoleniePolohyNaPozadi(context)) {
            if (!GpsSledovanieService.maRozpracovaneSledovanie(context)) {
                spustitSledovanie(context, "priebežný odhad")
            }
        } else {
            Diagnostika.zapisat(context, "Sledovanie nespustené: chýba poloha na pozadí")
        }
        context.sendBroadcast(
            Intent(AKCIA_STAV_AKTIVITY)
                .setPackage(context.packageName)
                .putExtra(EXTRA_V_AUTE, true),
        )
    }

    private fun spustitSledovanie(context: Context, zdroj: String) {
        try {
            ContextCompat.startForegroundService(
                context,
                Intent(context, GpsSledovanieService::class.java)
                    .setAction(GpsSledovanieService.AKCIA_SPUSTIT),
            )
            Diagnostika.zapisat(context, "Žiadosť o spustenie GPS ($zdroj) odoslaná")
        } catch (chyba: Exception) {
            // Android 12+ zakazuje spustiť službu z pozadia pri priebežnom
            // odhade. Sledovanie sa potom spustí pri najbližšej udalosti
            // „nastúpil/vystúpil“, ktorú Android povoľuje. Do záznamu to
            // stačí napísať raz za 10 minút.
            val preferencie = context.getSharedPreferences(PREFERENCIE, Context.MODE_PRIVATE)
            val teraz = System.currentTimeMillis()
            if (teraz - preferencie.getLong(KLUC_POSLEDNE_ODMIETNUTIE, 0L) >= 10 * 60_000L) {
                preferencie.edit().putLong(KLUC_POSLEDNE_ODMIETNUTIE, teraz).apply()
                Diagnostika.zapisat(
                    context,
                    "Spustenie GPS ($zdroj) odmietnuté systémom, počkám na udalosť auta: " +
                        Diagnostika.popisChyby(chyba),
                )
            }
        }
    }

    /** Posledný odhad „v aute“ s časom; GPS služba podľa neho posudzuje „vystúpil z auta“. */
    private fun ulozitPoslednyOdhad(context: Context, result: ActivityRecognitionResult) {
        val istotaAuta = result.probableActivities
            .firstOrNull { it.type == DetectedActivity.IN_VEHICLE }
            ?.confidence ?: 0
        context.getSharedPreferences(PREFERENCIE, Context.MODE_PRIVATE)
            .edit()
            .putInt(KLUC_ODHAD_AUTO_ISTOTA, istotaAuta)
            .putLong(KLUC_ODHAD_CAS, System.currentTimeMillis())
            .apply()
    }

    /**
     * Do záznamu ide odhad len vtedy, keď sa zmení najpravdepodobnejšia
     * činnosť alebo keď telefón tipuje auto. Inak by záznam zaplnilo státie
     * hlásené každých 30 sekúnd.
     */
    private fun zapisatOdhad(context: Context, result: ActivityRecognitionResult) {
        val najpravdepodobnejsia = result.mostProbableActivity
        val auto = result.probableActivities
            .firstOrNull { it.type == DetectedActivity.IN_VEHICLE }
        val preferencie = context.getSharedPreferences(PREFERENCIE, Context.MODE_PRIVATE)
        val posledna = preferencie.getInt(KLUC_POSLEDNY_ODHAD, -1)
        val tipujeAuto = auto != null && auto.confidence >= 30
        if (najpravdepodobnejsia.type == posledna && !tipujeAuto) return
        preferencie.edit().putInt(KLUC_POSLEDNY_ODHAD, najpravdepodobnejsia.type).apply()
        Diagnostika.zapisat(
            context,
            "Odhad pohybu: ${Diagnostika.nazovAktivity(najpravdepodobnejsia.type)} " +
                "${najpravdepodobnejsia.confidence} %" +
                (auto?.takeIf { it.type != najpravdepodobnejsia.type }
                    ?.let { ", v aute ${it.confidence} %" } ?: ""),
        )
    }

    companion object {
        private const val KLUC_POSLEDNY_ODHAD = "posledny_odhad"
        private const val KLUC_POSLEDNE_ODMIETNUTIE = "posledne_odmietnutie"
        const val KLUC_ODHAD_AUTO_ISTOTA = "odhad_auto_istota"
        const val KLUC_ODHAD_CAS = "odhad_cas"
        const val PREFERENCIE = "rozpoznavanie_aktivity"
        const val KLUC_V_AUTE = "v_aute"
        const val AKCIA_STAV_AKTIVITY = "sk.knihajazd.kniha_jazd.STAV_AKTIVITY"
        const val AKCIA_AKTUALIZACIA_AKTIVITY =
            "sk.knihajazd.kniha_jazd.AKTUALIZACIA_AKTIVITY"
        const val EXTRA_V_AUTE = "v_aute"
        private const val MINIMALNA_ISTOTA_VOZIDLA = 50
    }
}

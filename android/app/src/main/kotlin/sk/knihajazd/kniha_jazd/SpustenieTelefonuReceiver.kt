package sk.knihajazd.kniha_jazd

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Android po reštarte telefónu (a po aktualizácii aplikácie) zabudne
 * registráciu rozpoznávania „v aute“. Obnovíme ju bez otvorenia aplikácie,
 * ak ju používateľ predtým zapol.
 */
class SpustenieTelefonuReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        if (!RegistraciaRozpoznavania.jeZapnute(context) ||
            !RegistraciaRozpoznavania.maPovolenieAktivity(context)
        ) {
            return
        }
        val cakajuciVysledok = goAsync()
        RegistraciaRozpoznavania.zaregistrovat(context) { cakajuciVysledok.finish() }
    }
}

package sk.knihajazd.kniha_jazd

import android.content.Context
import com.google.android.gms.location.DetectedActivity
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Trvalý záznam toho, čo sa deje na pozadí (posledných [MAX_RIADKOV] udalostí).
 * Systémový logcat si telefón pamätá len krátko; tento záznam prežije aj
 * hodiny a dá sa zobraziť a skopírovať v Nastaveniach aplikácie.
 */
object Diagnostika {
    private const val PREFERENCIE = "diagnostika"
    private const val KLUC = "zaznam"
    private const val MAX_RIADKOV = 400
    private val format = SimpleDateFormat("dd.MM. HH:mm:ss", Locale.ROOT)

    @Synchronized
    fun zapisat(context: Context, sprava: String) {
        val preferencie = context.applicationContext
            .getSharedPreferences(PREFERENCIE, Context.MODE_PRIVATE)
        val riadky = preferencie.getString(KLUC, "").orEmpty()
            .lines()
            .filter { it.isNotBlank() }
            .toMutableList()
        riadky.add("${format.format(Date())}  $sprava")
        preferencie.edit()
            .putString(KLUC, riadky.takeLast(MAX_RIADKOV).joinToString("\n"))
            .apply()
    }

    @Synchronized
    fun nacitat(context: Context): String =
        context.applicationContext
            .getSharedPreferences(PREFERENCIE, Context.MODE_PRIVATE)
            .getString(KLUC, "")
            .orEmpty()

    @Synchronized
    fun vymazat(context: Context) {
        context.applicationContext
            .getSharedPreferences(PREFERENCIE, Context.MODE_PRIVATE)
            .edit()
            .remove(KLUC)
            .apply()
    }

    fun nazovAktivity(typ: Int): String = when (typ) {
        DetectedActivity.IN_VEHICLE -> "v aute"
        DetectedActivity.ON_BICYCLE -> "bicykel"
        DetectedActivity.ON_FOOT -> "pešo"
        DetectedActivity.WALKING -> "chôdza"
        DetectedActivity.RUNNING -> "beh"
        DetectedActivity.STILL -> "stojí"
        DetectedActivity.TILTING -> "naklonenie"
        else -> "neznáme"
    }

    fun popisChyby(chyba: Throwable): String =
        "${chyba.javaClass.simpleName}: ${chyba.message.orEmpty().take(160)}"
}

package sk.knihajazd.kniha_jazd

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofenceStatusCodes
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices

/**
 * Geoplot (geofence) okolo miesta, kde auto naposledy parkovalo.
 *
 * Google nerozpozná krátku jazdu po meste (neposiela „nastúpil do auta“).
 * Keď telefón opustí okruh 150 m okolo miesta parkovania, služby Google
 * spustia [GpsSledovanieService] a GPS overí, či ide o jazdu autom.
 * Okruh strážia služby Google cez Wi-Fi a mobilnú sieť, batériu takmer nemíňa.
 */
object Geoplot {
    private const val PREFERENCIE = "geoplot"
    private const val KLUC_LATITUDE = "latitude"
    private const val KLUC_LONGITUDE = "longitude"
    private const val ID_GEOPLOTU = "miesto_parkovania"
    private const val KOD_PENDING_INTENTU = 2
    const val POLOMER_METRE = 150f

    /** Služby Google smú udalosť oneskoriť až o toľko (šetrí batériu). */
    private const val ONESKORENIE_MILLIS = 30_000

    /**
     * Udalosť príde s oneskorením (okruh treba opustiť a služby Google ju
     * doručia neskôr). Toľko pred udalosťou zhruba auto odišlo.
     */
    const val ODHAD_ONESKORENIA_MILLIS = 60_000L

    /** Uložené miesto parkovania (stred geoplotu), alebo null. */
    fun miestoParkovania(context: Context): Pair<Double, Double>? {
        val preferencie = context.getSharedPreferences(PREFERENCIE, Context.MODE_PRIVATE)
        if (!preferencie.contains(KLUC_LATITUDE)) return null
        return Pair(
            java.lang.Double.longBitsToDouble(preferencie.getLong(KLUC_LATITUDE, 0L)),
            java.lang.Double.longBitsToDouble(preferencie.getLong(KLUC_LONGITUDE, 0L)),
        )
    }

    /** Nastaví geoplot na nové miesto parkovania. */
    fun nastavit(context: Context, latitude: Double, longitude: Double, onHotovo: () -> Unit = {}) {
        context.getSharedPreferences(PREFERENCIE, Context.MODE_PRIVATE).edit()
            .putLong(KLUC_LATITUDE, java.lang.Double.doubleToRawLongBits(latitude))
            .putLong(KLUC_LONGITUDE, java.lang.Double.doubleToRawLongBits(longitude))
            .apply()
        pridat(context.applicationContext, latitude, longitude, onHotovo)
    }

    /**
     * Obnoví geoplot (po reštarte telefónu, aktualizácii aplikácie alebo pri
     * zapnutí sledovania). Ak miesto parkovania ešte nepoznáme, použije
     * poslednú známu polohu telefónu.
     */
    fun obnovit(context: Context, onHotovo: () -> Unit = {}) {
        val aplikacia = context.applicationContext
        val miesto = miestoParkovania(aplikacia)
        if (miesto != null) {
            pridat(aplikacia, miesto.first, miesto.second, onHotovo)
            return
        }
        if (!GpsSledovanieService.maPovoleniePolohyNaPozadi(aplikacia)) {
            onHotovo()
            return
        }
        try {
            LocationServices.getFusedLocationProviderClient(aplikacia).lastLocation
                .addOnSuccessListener { poloha ->
                    if (poloha == null) {
                        Diagnostika.zapisat(aplikacia, "Geoplot: poloha telefónu zatiaľ neznáma, nastaví sa po prvej jazde")
                        onHotovo()
                    } else {
                        nastavit(aplikacia, poloha.latitude, poloha.longitude, onHotovo)
                    }
                }
                .addOnFailureListener { onHotovo() }
        } catch (_: SecurityException) {
            onHotovo()
        }
    }

    /** Zruší geoplot (keď používateľ vypne automatické sledovanie). */
    fun zrusit(context: Context) {
        val aplikacia = context.applicationContext
        aplikacia.getSharedPreferences(PREFERENCIE, Context.MODE_PRIVATE).edit().clear().apply()
        LocationServices.getGeofencingClient(aplikacia).removeGeofences(pendingIntent(aplikacia))
    }

    private fun pridat(context: Context, latitude: Double, longitude: Double, onHotovo: () -> Unit) {
        if (!GpsSledovanieService.maPovoleniePolohyNaPozadi(context)) {
            Diagnostika.zapisat(context, "Geoplot nenastavený: chýba poloha „vždy“")
            onHotovo()
            return
        }
        val geoplot = Geofence.Builder()
            .setRequestId(ID_GEOPLOTU)
            .setCircularRegion(latitude, longitude, POLOMER_METRE)
            .setExpirationDuration(Geofence.NEVER_EXPIRE)
            .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_EXIT)
            .setNotificationResponsiveness(ONESKORENIE_MILLIS)
            .build()
        // Bez úvodnej udalosti: telefón je pri nastavení zvyčajne vnútri okruhu.
        val poziadavka = GeofencingRequest.Builder()
            .setInitialTrigger(0)
            .addGeofence(geoplot)
            .build()
        try {
            LocationServices.getGeofencingClient(context)
                .addGeofences(poziadavka, pendingIntent(context))
                .addOnSuccessListener {
                    Diagnostika.zapisat(context, "Geoplot nastavený na miesto parkovania")
                    onHotovo()
                }
                .addOnFailureListener { chyba ->
                    val popis = if (chyba is ApiException &&
                        chyba.statusCode == GeofenceStatusCodes.GEOFENCE_NOT_AVAILABLE
                    ) {
                        "služba nedostupná (zapni polohu a „Presnosť polohy Google“)"
                    } else {
                        Diagnostika.popisChyby(chyba)
                    }
                    Diagnostika.zapisat(context, "Geoplot ZLYHAL: $popis")
                    onHotovo()
                }
        } catch (chyba: SecurityException) {
            Diagnostika.zapisat(context, "Geoplot ZLYHAL: ${Diagnostika.popisChyby(chyba)}")
            onHotovo()
        }
    }

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, GpsSledovanieService::class.java)
            .setAction(GpsSledovanieService.AKCIA_GEOPLOT)
        // Služby Google do intentu dopĺňajú údaje udalosti, preto MUTABLE.
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(context, KOD_PENDING_INTENTU, intent, flags)
        } else {
            PendingIntent.getService(context, KOD_PENDING_INTENTU, intent, flags)
        }
    }
}

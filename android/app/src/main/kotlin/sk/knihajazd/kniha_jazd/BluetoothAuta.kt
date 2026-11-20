package sk.knihajazd.kniha_jazd

import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Pamätá si, kedy sa telefón pripojil k Bluetooth auta a kedy sa odpojil.
 * Pri konci jazdy podľa toho služba určí, či išlo o vlastné auto (inak
 * napríklad autobus alebo cudzie auto).
 */
object BluetoothAuta {
    private const val PREFERENCIE = "bluetooth_auta"
    private const val KLUC_ADRESA = "adresa_auta"
    private const val KLUC_PRIPOJENE = "pripojene"
    private const val KLUC_PRIPOJENIE = "posledne_pripojenie"
    private const val KLUC_ODPOJENIE = "posledne_odpojenie"

    /** Rezerva na nepresnosť času začiatku jazdy (začiatok z GPS býva neskôr). */
    private const val REZERVA_MILLIS = 2 * 60_000L

    /** Nastaví Bluetooth adresu auta (null = rozpoznávanie auta vypnuté). */
    fun nastavit(context: Context, adresa: String?) {
        val preferencie = context.getSharedPreferences(PREFERENCIE, Context.MODE_PRIVATE)
        val povodna = preferencie.getString(KLUC_ADRESA, null)
        if (povodna == adresa) return
        // Iné auto: stav pripojenia starého auta už neplatí.
        preferencie.edit()
            .putString(KLUC_ADRESA, adresa)
            .putBoolean(KLUC_PRIPOJENE, false)
            .remove(KLUC_PRIPOJENIE)
            .remove(KLUC_ODPOJENIE)
            .apply()
        Diagnostika.zapisat(
            context,
            if (adresa == null) "Rozpoznanie auta cez Bluetooth vypnuté" else "Nastavené Bluetooth auta",
        )
    }

    fun zaznamenat(context: Context, adresa: String, pripojene: Boolean, casMillis: Long) {
        val preferencie = context.getSharedPreferences(PREFERENCIE, Context.MODE_PRIVATE)
        val adresaAuta = preferencie.getString(KLUC_ADRESA, null) ?: return
        if (!adresaAuta.equals(adresa, ignoreCase = true)) return
        preferencie.edit()
            .putBoolean(KLUC_PRIPOJENE, pripojene)
            .putLong(if (pripojene) KLUC_PRIPOJENIE else KLUC_ODPOJENIE, casMillis)
            .apply()
        Diagnostika.zapisat(context, if (pripojene) "Bluetooth auta pripojené" else "Bluetooth auta odpojené")
    }

    /**
     * Bol telefón počas jazdy pripojený k autu? null = auto nie je nastavené.
     * Pripojenie sa ráta, ak trvá ešte teraz, alebo ak sa auto odpojilo až
     * po začiatku jazdy (pri vypnutí motora po príchode).
     */
    fun bolPripojenyPocasJazdy(context: Context, zaciatokMillis: Long, koniecMillis: Long): Boolean? {
        val preferencie = context.getSharedPreferences(PREFERENCIE, Context.MODE_PRIVATE)
        preferencie.getString(KLUC_ADRESA, null) ?: return null
        if (preferencie.getBoolean(KLUC_PRIPOJENE, false)) return true
        val odpojenie = preferencie.getLong(KLUC_ODPOJENIE, 0L)
        val pripojenie = preferencie.getLong(KLUC_PRIPOJENIE, 0L)
        if (odpojenie >= zaciatokMillis - REZERVA_MILLIS) return true
        return pripojenie in (zaciatokMillis - REZERVA_MILLIS)..(koniecMillis + REZERVA_MILLIS)
    }
}

/** Prijíma systémové udalosti pripojenia a odpojenia Bluetooth zariadení. */
class BluetoothAutaReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pripojene = when (intent.action) {
            BluetoothDevice.ACTION_ACL_CONNECTED -> true
            BluetoothDevice.ACTION_ACL_DISCONNECTED -> false
            else -> return
        }
        val zariadenie: BluetoothDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
        }
        val adresa = try {
            zariadenie?.address
        } catch (_: SecurityException) {
            null
        } ?: return
        BluetoothAuta.zaznamenat(context, adresa, pripojene, System.currentTimeMillis())
    }
}

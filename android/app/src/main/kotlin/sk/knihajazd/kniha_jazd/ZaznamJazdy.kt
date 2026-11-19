package sk.knihajazd.kniha_jazd

import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/** Jeden GPS bod jazdy. Čas je z hodín telefónu (GPS čip niektorých telefónov hlási zlý rok). */
data class GpsBod(
    val latitude: Double,
    val longitude: Double,
    val casMillis: Long,
    val presnostMetre: Float,
    val rychlostMetreZaSekundu: Float,
)

data class DokoncenaJazda(
    val zaciatok: GpsBod,
    val koniec: GpsBod,
    val prejdeneMetre: Double,
    val pocetBodov: Int,
) {
    val trvanieMinut: Long get() = (koniec.casMillis - zaciatok.casMillis) / 60_000
}

/** Rozpracovaná jazda, ktorú služba priebežne ukladá, aby prežila reštart procesu. */
data class StavJazdy(
    val prvyBod: GpsBod?,
    val poslednyBod: GpsBod?,
    val pocetBodov: Int,
    val prejdeneMetre: Double,
    val poslednyPohybMillis: Long?,
)

enum class DovodKonca {
    /** Auto sa po spustení sledovania nerozbehlo. */
    ZIADNY_ROZBEH,

    /** Prišlo „vystúpil z auta“ a auto sa do 3 minút znova nerozbehlo. */
    VYSTUPIL,

    /** Auto dlho stojí. */
    BEZ_POHYBU,
}

/**
 * Logika jednej jazdy bez závislosti na Androide: ktoré GPS body sa rátajú,
 * kedy jazda začala a kedy skončila. Služba [GpsSledovanieService] jej len
 * posiela polohy a udalosti; vďaka tomu sa dá celá jazda simulovať v testoch
 * na počítači (pozri ZaznamJazdyTest).
 *
 * @param hodiny aktuálny čas v ms (v aplikácii hodiny telefónu, v testoch simulované)
 * @param zapis zápis do diagnostiky
 */
class ZaznamJazdy(
    private val hodiny: () -> Long,
    private val zapis: (String) -> Unit = {},
) {
    var prvyBod: GpsBod? = null
        private set
    var poslednyBod: GpsBod? = null
        private set
    var pocetBodov = 0
        private set
    var prejdeneMetre = 0.0
        private set

    /** Počet presných a nepresných GPS bodov od spustenia (pre diagnostiku). */
    var prijateBody = 0
        private set
    var odmietnuteBody = 0
        private set

    private var poslednyPohybMillis: Long? = null
    private var spusteneMillis = 0L

    /** Kedy Google naposledy hlásil „v aute“ (pri kontrole konca). */
    private var autoHlaseneMillis: Long? = null
    private var kandidatZaciatku: GpsBod? = null
    private var vystupilMillis: Long? = null
    private var zaciatokZapisany = false

    val jazdaZacala: Boolean get() = prvyBod != null

    /**
     * Úsporný režim: auto sa 5 min nerozbehlo a Google nehlási auto. GPS vtedy
     * stačí raz za minútu; sledovanie sa neukončí hneď, aby neprepásol neskorý
     * rozbeh (Google počas čakania často hlási „stojí“ a ďalšiu udalosť nepošle).
     */
    var uspornyRezim = false
        private set

    /** Prišlo „vystúpil z auta“ a čaká sa, či sa auto znova rozbehne. */
    val cakaPoVystupeni: Boolean get() = vystupilMillis != null

    /** Začiatok (alebo obnovenie) sledovania: odtiaľto sa ráta čakanie na rozbeh. */
    fun spustit() {
        spusteneMillis = hodiny()
        autoHlaseneMillis = null
        uspornyRezim = false
        prijateBody = 0
        odmietnuteBody = 0
        zaciatokZapisany = prvyBod != null
    }

    fun nastupil() {
        vystupilMillis = null
    }

    fun vystupil() {
        if (vystupilMillis == null) vystupilMillis = hodiny()
    }

    /**
     * Spracuje jednu polohu z GPS.
     *
     * @return true, ak sa zmenila rozpracovaná jazda a treba ju uložiť
     */
    fun spracovatPolohu(
        latitude: Double,
        longitude: Double,
        presnostMetre: Float?,
        rychlostMetreZaSekundu: Float?,
    ): Boolean {
        if (presnostMetre == null || presnostMetre > MAXIMALNA_PRESNOST_METRE) {
            odmietnuteBody += 1
            return false
        }
        prijateBody += 1
        val rychlost = if (rychlostMetreZaSekundu != null && rychlostMetreZaSekundu > 0f) {
            rychlostMetreZaSekundu
        } else {
            0f
        }
        val novyBod = GpsBod(latitude, longitude, hodiny(), presnostMetre, rychlost)

        if (prvyBod == null) {
            val predtym = kandidatZaciatku
            if (rychlost < RYCHLOST_START_METRE_ZA_SEKUNDU) {
                val posun = predtym?.let { vzdialenostMetre(it, novyBod) } ?: 0.0
                val autoSaPohlo = predtym != null &&
                    novyBod.casMillis - predtym.casMillis in 0..MAX_VEK_ZACIATKU_MILLIS &&
                    posun > MIN_POSUN_ROZBEHU_METRE + predtym.presnostMetre + novyBod.presnostMetre
                if (!autoSaPohlo) {
                    // Zapamätáme si miesto pred rozbehom, aby jazde nechýbal úvodný úsek.
                    kandidatZaciatku = novyBod
                    return false
                }
                // Medzi dvoma bodmi (v úspornom režime minúta) sa auto rozbehlo
                // a znova zastavilo, napr. na semafore: jazda začala na pôvodnom mieste.
                kandidatZaciatku = null
                prvyBod = predtym
                poslednyBod = novyBod
                pocetBodov = 2
                prejdeneMetre = posun
                poslednyPohybMillis = novyBod.casMillis
                ukoncitUspornyRezim()
                zaciatokZapisany = true
                zapis("Jazda začala (auto sa medzi bodmi posunulo o ${posun.toInt()} m)")
                return true
            }
            val kandidat = kandidatZaciatku
            kandidatZaciatku = null
            if (kandidat != null &&
                novyBod.casMillis - kandidat.casMillis in 0..MAX_VEK_ZACIATKU_MILLIS
            ) {
                prvyBod = kandidat
                poslednyBod = kandidat
                pocetBodov = 1
            }
        }

        if (vystupilMillis != null) {
            // Po „vystúpil z auta“ sa ráta len skutočná jazda; chôdza od auta nie.
            if (rychlost < RYCHLOST_START_METRE_ZA_SEKUNDU) return false
            vystupilMillis = null
            zapis("Jazda pokračuje (${kmh(rychlost)} km/h)")
        }

        val predchadzajuci = poslednyBod
        if (predchadzajuci != null) {
            val vzdialenost = vzdialenostMetre(predchadzajuci, novyBod)
            // Pri státí GPS „poskakuje“ v rámci svojej nepresnosti. Chybu má
            // každý z dvoch bodov, takže skok medzi nimi môže byť až súčtom
            // ich nepresností. Takéto skoky nepripočítavame, inak by zápcha
            // pridávala kilometre.
            val stoji = rychlost < RYCHLOST_POHYB_METRE_ZA_SEKUNDU &&
                vzdialenost < novyBod.presnostMetre + predchadzajuci.presnostMetre
            if (stoji) return false
            prejdeneMetre += vzdialenost
        } else {
            prvyBod = novyBod
        }
        ukoncitUspornyRezim()
        if (!zaciatokZapisany) {
            zaciatokZapisany = true
            zapis("Jazda začala (rýchlosť ${kmh(rychlost)} km/h, presnosť ${presnostMetre.toInt()} m)")
        }
        poslednyBod = novyBod
        pocetBodov += 1
        if (rychlost >= RYCHLOST_POHYB_METRE_ZA_SEKUNDU) poslednyPohybMillis = novyBod.casMillis
        return true
    }

    private fun ukoncitUspornyRezim() {
        if (!uspornyRezim) return
        uspornyRezim = false
        zapis("Rozbeh zachytený v úspornom režime, GPS znova každých 10 s")
    }

    /**
     * Má sa sledovanie ukončiť? Volá sa pravidelne (každých 30 s).
     *
     * @param istotaAuta posledný odhad „v aute“ v % (null = žiadny čerstvý odhad).
     *   Kým Google hlási auto, v zápche sa čaká až 45 min namiesto 20 min.
     *   Na rozbeh sa čaká 30 min; po prvých 5 min bez hláseného auta v [uspornyRezim].
     */
    fun skontrolovat(istotaAuta: Int?): DovodKonca? {
        val teraz = hodiny()
        if (istotaAuta != null && istotaAuta >= MINIMALNA_ISTOTA_AUTA) autoHlaseneMillis = teraz
        // Kratšie limity platia až po čase, keď Google naposledy hlásil auto:
        // keď sa kolóna po dlhej zápche pohne, odhad Googlu môže na chvíľu klesnúť.
        val odHlaseniaAuta = autoHlaseneMillis?.let { teraz - it } ?: Long.MAX_VALUE
        if (prvyBod == null) {
            val cakanie = teraz - spusteneMillis
            if (cakanie >= MAX_CAKANIE_NA_ROZBEH_MILLIS) return DovodKonca.ZIADNY_ROZBEH
            val usporny = minOf(cakanie, odHlaseniaAuta) >= CAKANIE_NA_ROZBEH_MILLIS
            if (usporny != uspornyRezim) {
                uspornyRezim = usporny
                zapis(if (usporny) "Úsporný režim: auto stojí, GPS raz za minútu" else "Google hlási auto, GPS znova každých 10 s")
            }
            return null
        }
        val vystupil = vystupilMillis
        if (vystupil != null && teraz - vystupil >= CAS_PO_VYSTUPENI_MILLIS) return DovodKonca.VYSTUPIL
        val pohyb = poslednyPohybMillis ?: return null
        val bezPohybu = teraz - pohyb
        if (bezPohybu >= MAX_STATIE_MILLIS) return DovodKonca.BEZ_POHYBU
        if (minOf(bezPohybu, odHlaseniaAuta) >= CAS_ZASTAVENIA_MILLIS) return DovodKonca.BEZ_POHYBU
        return null
    }

    /** Uzavrie jazdu. Vráti ju, ak má aspoň 2 body; inak null. Stav sa vynuluje. */
    fun dokoncit(): DokoncenaJazda? {
        val zaciatok = prvyBod
        val koniec = poslednyBod
        val jazda = if (zaciatok != null && koniec != null && pocetBodov >= 2) {
            DokoncenaJazda(zaciatok, koniec, prejdeneMetre, pocetBodov)
        } else {
            null
        }
        prvyBod = null
        poslednyBod = null
        pocetBodov = 0
        prejdeneMetre = 0.0
        poslednyPohybMillis = null
        kandidatZaciatku = null
        vystupilMillis = null
        zaciatokZapisany = false
        uspornyRezim = false
        autoHlaseneMillis = null
        return jazda
    }

    fun stav(): StavJazdy =
        StavJazdy(prvyBod, poslednyBod, pocetBodov, prejdeneMetre, poslednyPohybMillis)

    /**
     * Obnoví uloženú rozpracovanú jazdu. Ak je stará (posledný bod pred viac
     * ako 20 min, napr. po reštarte telefónu), uzavrie ju a vráti ako dokončenú,
     * aby sa nespojila s novou jazdou.
     */
    fun obnovit(stav: StavJazdy): DokoncenaJazda? {
        prvyBod = stav.prvyBod
        poslednyBod = stav.poslednyBod
        pocetBodov = stav.pocetBodov
        prejdeneMetre = stav.prejdeneMetre
        poslednyPohybMillis = stav.poslednyPohybMillis
        zaciatokZapisany = prvyBod != null
        val posledny = poslednyBod ?: return null
        if (hodiny() - posledny.casMillis < CAS_ZASTAVENIA_MILLIS) return null
        zapis("Starší nedokončený záznam uzavretý ako samostatná jazda")
        return dokoncit()
    }

    companion object {
        const val RYCHLOST_START_METRE_ZA_SEKUNDU = 12 / 3.6f
        const val RYCHLOST_POHYB_METRE_ZA_SEKUNDU = 3 / 3.6f
        const val MAXIMALNA_PRESNOST_METRE = 35f
        const val MINIMALNA_ISTOTA_AUTA = 50
        /** Po tomto čase bez rozbehu (a bez hláseného auta) prejde GPS do úsporného režimu. */
        const val CAKANIE_NA_ROZBEH_MILLIS = 5 * 60 * 1_000L
        const val MAX_CAKANIE_NA_ROZBEH_MILLIS = 30 * 60 * 1_000L
        const val CAS_PO_VYSTUPENI_MILLIS = 3 * 60 * 1_000L
        const val CAS_ZASTAVENIA_MILLIS = 20 * 60 * 1_000L
        const val MAX_STATIE_MILLIS = 45 * 60 * 1_000L

        /**
         * Posun „stojaceho“ auta (nad súčet nepresností bodov), ktorý znamená,
         * že sa medzi dvoma GPS bodmi pohlo, hoci pri oboch stojí (semafor).
         */
        const val MIN_POSUN_ROZBEHU_METRE = 150.0

        /** Posledná poloha pred rozbehom sa použije ako začiatok jazdy, ak je čerstvá. */
        const val MAX_VEK_ZACIATKU_MILLIS = 3 * 60 * 1_000L

        private const val POLOMER_ZEME_METRE = 6_371_008.8

        /** Vzdialenosť po povrchu Zeme (haversine); na úsekoch medzi GPS bodmi presné na centimetre. */
        fun vzdialenostMetre(a: GpsBod, b: GpsBod): Double {
            val lat1 = Math.toRadians(a.latitude)
            val lat2 = Math.toRadians(b.latitude)
            val dLat = lat2 - lat1
            val dLon = Math.toRadians(b.longitude - a.longitude)
            val h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
            return 2 * POLOMER_ZEME_METRE * asin(sqrt(h.coerceIn(0.0, 1.0)))
        }

        private fun kmh(rychlostMetreZaSekundu: Float): Int = (rychlostMetreZaSekundu * 3.6f).toInt()
    }
}

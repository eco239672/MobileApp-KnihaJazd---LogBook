package sk.knihajazd.kniha_jazd

import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Random
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Simulácie jázd na počítači, bez telefónu. Logika [ZaznamJazdy] dostáva
 * rovnaké vstupy, aké jej posiela GpsSledovanieService v telefóne: GPS body
 * každých 10 s, udalosti „nastúpil/vystúpil z auta“, odhad „v aute“ v %
 * a kontrolu konca každých 30 s. Čas je simulovaný, takže hodinová jazda
 * prebehne za zlomok sekundy.
 *
 * Spustenie (v priečinku android): .\gradlew.bat :app:testDebugUnitTest
 * Priebeh jázd sa zapíše do build\simulacia-jazdy.txt v koreni projektu.
 */
class ZaznamJazdyTest {

    @Test
    fun `Šaľa - Bratislava, odjazd po 17 min čakania, zápcha, tunel, falošné vystúpenia`() {
        val sim = Simulacia("Šaľa → Bratislava, odjazd po 17 min čakania", LocalDateTime.of(2026, 11, 20, 7, 40))
        val trasa = SALA_BRATISLAVA

        // 07:40 sadneš do auta, motor beží, Google hlási „v aute“, ale ešte stojíš.
        sim.istotaAuta = 70
        sim.nastupil()
        sim.cakat(minuty = 17, poloha = trasa.poloha(0.0))
        assertTrue("Kým Google hlási auto, sledovanie má na rozbeh počkať", sim.sleduje)
        val odjazd = sim.teraz

        sim.jazdit(
            trasa,
            zapchaPoMetroch = 0.62 * trasa.dlzkaMetre, // pred Sencom
            zapchaMinut = 12,
            tunelOdMetrov = 0.85 * trasa.dlzkaMetre, // 2 km bez signálu
            falosneVystupenia = setOf(30, 120, 230), // Google hlási „vystúpil“, odhad hlási auto
            vystupenieBezOdhadu = 180, // „vystúpil“ bez čerstvého odhadu, auto ide ďalej
        )
        val prichod = sim.teraz

        // V Bratislave zaparkuješ a odídeš pešo.
        sim.istotaAuta = 5
        sim.vystupil()
        sim.ist(pesoMinut = 2, od = trasa.poloha(trasa.dlzkaMetre))
        sim.cakat(minuty = 5, poloha = null)

        sim.vypisat()
        assertEquals("Má vzniknúť práve jedna jazda", 1, sim.jazdy.size)
        assertEquals(listOf(DovodKonca.VYSTUPIL), sim.dovody)
        val jazda = sim.jazdy.single()
        assertCasPriblizne("začiatok jazdy", odjazd, jazda.zaciatok.casMillis, toleranciaSekund = 20)
        assertCasPriblizne("koniec jazdy", prichod, jazda.koniec.casMillis, toleranciaSekund = 20)
        assertBlizko("začiatok na parkovisku v Šali", trasa.poloha(0.0), jazda.zaciatok, maxMetrov = 30.0)
        assertBlizko("koniec v Bratislave", trasa.poloha(trasa.dlzkaMetre), jazda.koniec, maxMetrov = 30.0)
        assertKilometre(trasa.dlzkaMetre, jazda.prejdeneMetre, toleranciaPercent = 1.5)
    }

    @Test
    fun `čakanie 17 min, Google hlási státie - úsporný režim zachytí celú jazdu`() {
        val sim = Simulacia("Odjazd po 17 min, Google počas čakania hlási státie", LocalDateTime.of(2026, 11, 20, 7, 40))
        val trasa = SALA_BRATISLAVA

        sim.istotaAuta = 10
        sim.nastupil()
        sim.cakat(minuty = 17, poloha = trasa.poloha(0.0))
        assertTrue("Sledovanie má bežať ďalej v úspornom režime", sim.sleduje)
        assertTrue("Po 5 min bez odhadu auta má byť GPS v úspornom režime", sim.usporne)
        assertTrue(sim.dovody.isEmpty())
        val odjazd = sim.teraz

        // Google počas jazdy nič nepošle; rozbeh musí zachytiť samotné GPS.
        sim.jazdit(trasa, istotaPocasJazdy = 10)
        assertFalse("Po rozbehu má GPS bežať znova každých 10 s", sim.usporne)
        val prichod = sim.teraz
        sim.istotaAuta = 5
        sim.vystupil()
        sim.cakat(minuty = 5, poloha = null)

        sim.vypisat()
        assertEquals("Má vzniknúť práve jedna jazda", 1, sim.jazdy.size)
        val jazda = sim.jazdy.single()
        assertCasPriblizne("začiatok jazdy", odjazd, jazda.zaciatok.casMillis, toleranciaSekund = 70)
        assertCasPriblizne("koniec jazdy", prichod, jazda.koniec.casMillis, toleranciaSekund = 20)
        assertBlizko("začiatok na parkovisku v Šali", trasa.poloha(0.0), jazda.zaciatok, maxMetrov = 30.0)
        assertKilometre(trasa.dlzkaMetre, jazda.prejdeneMetre, toleranciaPercent = 1.5)
    }

    @Test
    fun `zápcha 25 min s motorom v chode - jazda sa nerozdelí`() {
        val sim = Simulacia("Zápcha 25 min, Google hlási auto", LocalDateTime.of(2026, 11, 20, 16, 0))
        val trasa = SALA_BRATISLAVA
        sim.istotaAuta = 80
        sim.nastupil()
        sim.jazdit(trasa, zapchaPoMetroch = 0.5 * trasa.dlzkaMetre, zapchaMinut = 25, istotaVZapche = 60)
        sim.istotaAuta = 5
        sim.vystupil()
        sim.cakat(minuty = 5, poloha = null)

        sim.vypisat()
        assertEquals("Zápcha s hláseným autom nesmie jazdu rozdeliť", 1, sim.jazdy.size)
        assertKilometre(trasa.dlzkaMetre, sim.jazdy.single().prejdeneMetre, toleranciaPercent = 1.5)
    }

    @Test
    fun `zápcha 25 min bez odhadu auta - po 20 min státia sa jazda ukončí`() {
        val sim = Simulacia("Zápcha 25 min, Google auto nehlási", LocalDateTime.of(2026, 11, 20, 16, 0))
        val trasa = SALA_BRATISLAVA
        sim.istotaAuta = 80
        sim.nastupil()
        sim.jazdit(trasa, zapchaPoMetroch = 0.5 * trasa.dlzkaMetre, zapchaMinut = 25, istotaVZapche = null)

        sim.vypisat()
        assertEquals(DovodKonca.BEZ_POHYBU, sim.dovody.first())
        val prvaJazda = sim.jazdy.first()
        assertKilometre(0.5 * trasa.dlzkaMetre, prvaJazda.prejdeneMetre, toleranciaPercent = 1.5)
    }

    @Test
    fun `auto na parkovisku - GPS rozptyl nevytvorí jazdu`() {
        val sim = Simulacia("Iba státie na parkovisku", LocalDateTime.of(2026, 11, 20, 12, 0))
        sim.istotaAuta = 60
        sim.nastupil()
        sim.istotaAuta = null
        sim.cakat(minuty = 35, poloha = SALA_BRATISLAVA.poloha(0.0), presnost = 25f)

        sim.vypisat()
        assertTrue(sim.jazdy.isEmpty())
        assertEquals("Po 30 min bez rozbehu sa sledovanie ukončí", listOf(DovodKonca.ZIADNY_ROZBEH), sim.dovody)
        assertTrue("Väčšina čakania má byť v úspornom režime (GPS raz za minútu)", sim.gpsBodov < 60)
    }

    @Test
    fun `stará rozpracovaná jazda sa pri obnove uzavrie, čerstvá pokračuje`() {
        var teraz = 1_800_000_000_000L
        val zaznam = ZaznamJazdy(hodiny = { teraz })
        val a = GpsBod(48.15, 17.88, teraz - 60_000, 8f, 20f)
        val b = GpsBod(48.16, 17.85, teraz, 8f, 20f)
        val stav = StavJazdy(a, b, 2, 2_500.0, teraz)

        assertEquals("Čerstvý stav sa má obnoviť", null, zaznam.obnovit(stav))
        assertTrue(zaznam.jazdaZacala)

        teraz += 25 * 60_000L
        val uzavreta = ZaznamJazdy(hodiny = { teraz }).obnovit(stav)
        assertEquals(2_500.0, uzavreta!!.prejdeneMetre, 0.001)
    }

    // ---------------------------------------------------------------------

    private class Trasa(private val body: List<Pair<Double, Double>>) {
        private val useky = body.zipWithNext { a, b -> vzdialenost(a, b) }
        val dlzkaMetre = useky.sum()

        /** Poloha po prejdení [metre] od začiatku trasy. */
        fun poloha(metre: Double): Pair<Double, Double> {
            var zostava = metre.coerceIn(0.0, dlzkaMetre)
            for (i in useky.indices) {
                if (zostava <= useky[i]) {
                    val t = if (useky[i] == 0.0) 0.0 else zostava / useky[i]
                    val (lat1, lon1) = body[i]
                    val (lat2, lon2) = body[i + 1]
                    return Pair(lat1 + (lat2 - lat1) * t, lon1 + (lon2 - lon1) * t)
                }
                zostava -= useky[i]
            }
            return body.last()
        }
    }

    private class Simulacia(val nazov: String, start: LocalDateTime) {
        var teraz: Long = start.atZone(ZONA).toInstant().toEpochMilli()
        val zapisy = mutableListOf<String>()
        val jazdy = mutableListOf<DokoncenaJazda>()
        val dovody = mutableListOf<DovodKonca>()

        /** Posledný odhad „v aute“ v % od Googlu (null = žiadny čerstvý odhad). */
        var istotaAuta: Int? = null
        var sleduje = false
            private set
        val usporne: Boolean get() = zaznam.uspornyRezim

        /** Koľko GPS bodov telefón vyrobil (pre odhad spotreby batérie). */
        var gpsBodov = 0
            private set
        private var odGps = 0L

        private var odKontroly = 0L
        private val nahoda = Random(42)
        private val zaznam = ZaznamJazdy(hodiny = { teraz }, zapis = { zapisy += "${cas(teraz)}  $it" })

        private fun spustitSledovanie() {
            if (sleduje) return
            zaznam.spustit()
            sleduje = true
            odGps = 0
            zapisy += "${cas(teraz)}  [GPS sledovanie spustené]"
        }

        /** To isté ako GpsSledovanieService pri „nastúpil do auta“. */
        fun nastupil() {
            zapisy += "${cas(teraz)}  Google: nastúpil do auta"
            zaznam.nastupil()
            spustitSledovanie()
        }

        /** To isté ako GpsSledovanieService pri „vystúpil z auta“. */
        fun vystupil() {
            val istota = istotaAuta
            zapisy += "${cas(teraz)}  Google: vystúpil z auta (odhad auta: ${istota ?: "-"} %)"
            if (istota != null && istota >= ZaznamJazdy.MINIMALNA_ISTOTA_AUTA) {
                zaznam.nastupil()
                spustitSledovanie()
                return
            }
            if (sleduje) zaznam.vystupil()
        }

        /** 10 sekúnd: GPS bod (ak je signál) a každých 30 s kontrola konca, ako v telefóne. */
        fun krok(poloha: Pair<Double, Double>?, kmh: Double, presnost: Float) {
            teraz += 10_000
            odGps += 10_000
            // V úspornom režime služba žiada GPS raz za minútu, inak každých 10 s.
            val intervalGps = if (zaznam.uspornyRezim) 60_000L else 10_000L
            if (sleduje && odGps >= intervalGps) {
                odGps = 0
                if (poloha != null) {
                    gpsBodov++
                    val (lat, lon) = gpsChyba(poloha, presnost)
                    zaznam.spracovatPolohu(lat, lon, presnost, (kmh / 3.6).toFloat())
                }
            }
            odKontroly += 10_000
            if (sleduje && odKontroly >= 30_000) {
                odKontroly = 0
                val dovod = zaznam.skontrolovat(istotaAuta) ?: return
                dovody += dovod
                zaznam.dokoncit()?.let { jazda ->
                    jazdy += jazda
                    zapisy += "${cas(teraz)}  [JAZDA ULOŽENÁ: ${"%.2f".format(jazda.prejdeneMetre / 1000)} km, " +
                        "${cas(jazda.zaciatok.casMillis)} – ${cas(jazda.koniec.casMillis)}]"
                }
                sleduje = false
                zapisy += "${cas(teraz)}  [koniec sledovania: $dovod]"
            }
        }

        fun cakat(minuty: Int, poloha: Pair<Double, Double>?, presnost: Float = 12f) {
            repeat(minuty * 6) { krok(poloha, kmh = 0.0, presnost = presnost) }
        }

        fun ist(pesoMinut: Int, od: Pair<Double, Double>) {
            var poloha = od
            repeat(pesoMinut * 6) {
                poloha = Pair(poloha.first + 14.0 / 111_320.0, poloha.second)
                krok(poloha, kmh = 5.0, presnost = 10f)
            }
        }

        /**
         * Jazda po trase každých 10 s. Každý 15. bod je nepresný (60 m) a má sa zahodiť.
         * Vráti, koľko metrov bolo prejdených pri jednotlivých krokoch s udalosťou.
         */
        fun jazdit(
            trasa: Trasa,
            zapchaPoMetroch: Double? = null,
            zapchaMinut: Int = 0,
            istotaVZapche: Int? = null,
            tunelOdMetrov: Double? = null,
            falosneVystupenia: Set<Int> = emptySet(),
            vystupenieBezOdhadu: Int? = null,
            istotaPocasJazdy: Int? = 85,
        ): Map<Int, Double> {
            val udalosti = mutableMapOf<Int, Double>()
            var prejdene = 0.0
            var krokJazdy = 0
            var zapchaBola = false
            while (prejdene < trasa.dlzkaMetre) {
                krokJazdy++
                if (zapchaPoMetroch != null && !zapchaBola && prejdene >= zapchaPoMetroch) {
                    zapchaBola = true
                    zapisy += "${cas(teraz)}  [zápcha $zapchaMinut min]"
                    istotaAuta = istotaVZapche
                    cakat(zapchaMinut, trasa.poloha(prejdene), presnost = 10f)
                }
                val kmh = when {
                    prejdene < 2_000 -> 40.0 // Šaľa
                    prejdene > trasa.dlzkaMetre - 4_000 -> 45.0 // Bratislava
                    else -> 85.0
                }
                prejdene = min(prejdene + kmh / 3.6 * 10, trasa.dlzkaMetre)
                istotaAuta = istotaPocasJazdy
                if (krokJazdy in falosneVystupenia) {
                    udalosti[krokJazdy] = prejdene
                    vystupil()
                }
                if (krokJazdy == vystupenieBezOdhadu) {
                    udalosti[krokJazdy] = prejdene
                    istotaAuta = null
                    vystupil()
                }
                val vTuneli = tunelOdMetrov != null && prejdene in tunelOdMetrov..(tunelOdMetrov + 2_000)
                val presnost = if (krokJazdy % 15 == 0) 60f else 8f
                krok(if (vTuneli) null else trasa.poloha(prejdene), kmh, presnost)
            }
            zapisy += "${cas(teraz)}  [príjazd do cieľa, trasa ${"%.2f".format(trasa.dlzkaMetre / 1000)} km]"
            return udalosti
        }

        /** GPS chyba: náhodný posun v kruhu s polomerom 80 % udanej nepresnosti. */
        private fun gpsChyba(p: Pair<Double, Double>, presnost: Float): Pair<Double, Double> {
            val polomer = 0.8 * presnost * sqrt(nahoda.nextDouble())
            val uhol = nahoda.nextDouble() * 2 * Math.PI
            val dy = polomer * sin(uhol)
            val dx = polomer * cos(uhol)
            return Pair(
                p.first + dy / 111_320.0,
                p.second + dx / (111_320.0 * cos(Math.toRadians(p.first))),
            )
        }

        fun vypisat() {
            PRIEBEH += "=== $nazov ==="
            PRIEBEH += zapisy
            PRIEBEH += ""
        }
    }

    private fun assertCasPriblizne(co: String, ocakavany: Long, skutocny: Long, toleranciaSekund: Int) {
        assertTrue(
            "$co: očakávané ${cas(ocakavany)}, je ${cas(skutocny)}",
            abs(skutocny - ocakavany) <= toleranciaSekund * 1_000L,
        )
    }

    private fun assertBlizko(co: String, ocakavane: Pair<Double, Double>, bod: GpsBod, maxMetrov: Double) {
        val vzdialenost = vzdialenost(ocakavane, Pair(bod.latitude, bod.longitude))
        assertTrue("$co: ${"%.0f".format(vzdialenost)} m od očakávaného miesta", vzdialenost <= maxMetrov)
    }

    private fun assertKilometre(ocakavaneMetre: Double, skutocneMetre: Double, toleranciaPercent: Double) {
        val odchylka = abs(skutocneMetre - ocakavaneMetre) / ocakavaneMetre * 100
        assertTrue(
            "Kilometre: očakávané ${"%.2f".format(ocakavaneMetre / 1000)} km, " +
                "zaznamenané ${"%.2f".format(skutocneMetre / 1000)} km (odchýlka ${"%.2f".format(odchylka)} %)",
            odchylka <= toleranciaPercent,
        )
    }

    companion object {
        private val ZONA = ZoneId.of("Europe/Bratislava")
        private val PRIEBEH = mutableListOf<String>()

        /** Šaľa – Galanta – Sládkovičovo – Senec – D1 – Bratislava (zjednodušená trasa). */
        private val SALA_BRATISLAVA = Trasa(
            listOf(
                48.1497 to 17.8812, // Šaľa, parkovisko
                48.1585 to 17.8530, // Šaľa, výjazd
                48.1880 to 17.7350, // Galanta
                48.2010 to 17.6390, // Sládkovičovo
                48.2230 to 17.4020, // Senec
                48.1860 to 17.2560, // Ivanka pri Dunaji
                48.1650 to 17.1600, // Bratislava, Trnavská
                48.1486 to 17.1077, // Bratislava, centrum
            ),
        )

        private fun vzdialenost(a: Pair<Double, Double>, b: Pair<Double, Double>): Double =
            ZaznamJazdy.vzdialenostMetre(
                GpsBod(a.first, a.second, 0, 0f, 0f),
                GpsBod(b.first, b.second, 0, 0f, 0f),
            )

        private fun cas(ms: Long): String =
            DateTimeFormatter.ofPattern("HH:mm:ss").format(Instant.ofEpochMilli(ms).atZone(ZONA))

        @JvmStatic
        @AfterClass
        fun ulozitPriebeh() {
            // Priebeh jázd do build\simulacia-jazdy.txt v koreni projektu KnihaJazd.
            val subor = File("../../build/simulacia-jazdy.txt")
            subor.parentFile?.mkdirs()
            subor.writeText(PRIEBEH.joinToString("\n"))
        }
    }
}

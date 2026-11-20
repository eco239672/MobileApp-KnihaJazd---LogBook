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
 * Náhodné jazdy používajú 500 obcí zo src/test/resources/obce_sk.csv.
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
    fun `reštart sledovania počas jazdy - jazda pokračuje ako jedna`() {
        val sim = Simulacia("Android zastaví sledovanie na 4 min počas jazdy", LocalDateTime.of(2026, 11, 20, 9, 0))
        val trasa = SALA_BRATISLAVA
        sim.istotaAuta = 85
        sim.nastupil()
        sim.cakat(minuty = 1, poloha = trasa.poloha(0.0))
        var prejdene = sim.jazditUsek(trasa, 0.0, 20_000.0)
        sim.prerusit()
        val prerusenieOd = prejdene
        prejdene = sim.jazditUsek(trasa, prejdene, prejdene + 85 / 3.6 * 240) // 4 min bez GPS
        sim.obnovitPoPreruseni()
        val prerusenieDo = prejdene + 85 / 3.6 * 10
        sim.jazditUsek(trasa, prejdene, trasa.dlzkaMetre)
        sim.istotaAuta = 5
        sim.vystupil()
        sim.ist(pesoMinut = 2, od = trasa.poloha(trasa.dlzkaMetre))
        sim.cakat(minuty = 5, poloha = null)

        sim.vypisat()
        assertEquals("Reštart nesmie jazdu rozdeliť", 1, sim.jazdy.size)
        assertEquals(listOf(DovodKonca.VYSTUPIL), sim.dovody)
        // Počas prerušenia sa ráta priama čiara medzi poslednými bodmi.
        val strata = (prerusenieDo - prerusenieOd) -
            vzdialenost(trasa.poloha(prerusenieOd), trasa.poloha(prerusenieDo))
        assertKilometre(trasa.dlzkaMetre - strata, sim.jazdy.single().prejdeneMetre, toleranciaPercent = 1.5)
    }

    @Test
    fun `pád telefónu v zápche - s hláseným autom jazda pokračuje, bez neho sa rozdelí`() {
        val trasa = SALA_BRATISLAVA
        val zapcha = 0.6 * trasa.dlzkaMetre

        // 1) Telefón spadne, Google pošle „vystúpil“, ale ďalej hlási auto:
        //    vystúpenie sa ignoruje a jazda pokračuje.
        val sAutom = Simulacia("Pád telefónu v zápche, Google ďalej hlási auto", LocalDateTime.of(2026, 11, 20, 7, 0))
        sAutom.istotaAuta = 85
        sAutom.nastupil()
        sAutom.cakat(minuty = 1, poloha = trasa.poloha(0.0))
        sAutom.jazditUsek(trasa, 0.0, zapcha)
        sAutom.istotaAuta = 70
        sAutom.vystupil()
        sAutom.cakat(minuty = 10, poloha = trasa.poloha(zapcha), presnost = 10f)
        sAutom.jazditUsek(trasa, zapcha, trasa.dlzkaMetre)
        sAutom.istotaAuta = 5
        sAutom.vystupil()
        sAutom.ist(pesoMinut = 2, od = trasa.poloha(trasa.dlzkaMetre))
        sAutom.cakat(minuty = 5, poloha = null)
        sAutom.vypisat()
        assertEquals(1, sAutom.jazdy.size)
        assertKilometre(trasa.dlzkaMetre, sAutom.jazdy.single().prejdeneMetre, toleranciaPercent = 1.5)

        // 2) Známe obmedzenie: Google po páde hlási „vystúpil“ bez odhadu auta
        //    a auto stojí v zápche dlhšie ako 3 min. Jazda sa ukončí a ďalšia
        //    začne, až keď Google znova hlási „nastúpil“ (tu po 2 min jazdy).
        //    Kilometre medzi zápchou a týmto hlásením chýbajú.
        val bezAuta = Simulacia("Pád telefónu v zápche, Google auto nehlási", LocalDateTime.of(2026, 11, 20, 7, 0))
        bezAuta.istotaAuta = 85
        bezAuta.nastupil()
        bezAuta.cakat(minuty = 1, poloha = trasa.poloha(0.0))
        bezAuta.jazditUsek(trasa, 0.0, zapcha)
        bezAuta.istotaAuta = null
        bezAuta.vystupil()
        bezAuta.cakat(minuty = 10, poloha = trasa.poloha(zapcha), presnost = 10f)
        val znovaZachytene = bezAuta.jazditUsek(trasa, zapcha, zapcha + 85 / 3.6 * 120)
        bezAuta.istotaAuta = 85
        bezAuta.nastupil()
        bezAuta.jazditUsek(trasa, znovaZachytene, trasa.dlzkaMetre)
        bezAuta.istotaAuta = 5
        bezAuta.vystupil()
        bezAuta.ist(pesoMinut = 2, od = trasa.poloha(trasa.dlzkaMetre))
        bezAuta.cakat(minuty = 5, poloha = null)
        bezAuta.vypisat()
        assertEquals("Bez hláseného auta sa jazda rozdelí na dve", 2, bezAuta.jazdy.size)
        assertKilometre(zapcha, bezAuta.jazdy[0].prejdeneMetre, toleranciaPercent = 1.5)
        assertKilometre(trasa.dlzkaMetre - znovaZachytene, bezAuta.jazdy[1].prejdeneMetre, toleranciaPercent = 2.0)
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

    /**
     * 500 jázd medzi náhodne vybranými obcami a mestami SR (src/test/resources/obce_sk.csv).
     * Trasa je zjednodušená (lomená čiara so zákrutami, nie skutočné cesty), podmienky
     * sú náhodné, ale vždy také, pri ktorých má vzniknúť práve jedna správna jazda.
     * Rovnaké semienko = vždy rovnaké jazdy, takže každá chyba sa dá zopakovať.
     */
    @Test
    fun `500 náhodných jázd medzi obcami Slovenska`() {
        val obce = nacitatObce()
        assertEquals("Súbor obce_sk.csv má mať 500 obcí", 500, obce.size)
        val nahoda = Random(SEMIENKO_NAHODNYCH_JAZD)
        val chyby = mutableListOf<String>()
        val prehlad = mutableListOf<String>()
        var najvacsiaOdchylka = 0.0
        var spoluKm = 0.0
        var uspornych = 0

        obce.forEachIndexed { i, odkial ->
            val cislo = i + 1
            val kam = vybratCiel(odkial, obce, nahoda)
            val plan = PlanJazdy.nahodny(odkial, kam, nahoda)
            val start = LocalDateTime.of(2026, 1, 1, 6, 0).plusMinutes(nahoda.nextInt(60 * 24 * 300).toLong())
            val sim = Simulacia("#$cislo ${odkial.nazov} → ${kam.nazov}", start, semienko = 1_000L + cislo)
            val vysledok = try {
                sim.jazditPodlaPlanu(plan)
            } catch (chyba: AssertionError) {
                chyba.message ?: "chyba"
            }
            if (sim.usporneBolo) uspornych++
            val jazda = sim.jazdy.singleOrNull()
            val odchylka = jazda?.let { (it.prejdeneMetre - plan.trasa.dlzkaMetre) / plan.trasa.dlzkaMetre * 100 }
            if (odchylka != null) najvacsiaOdchylka = maxOf(najvacsiaOdchylka, abs(odchylka))
            spoluKm += plan.trasa.dlzkaMetre / 1000
            val riadok = "#$cislo ${odkial.nazov} → ${kam.nazov}: trasa ${"%.2f".format(plan.trasa.dlzkaMetre / 1000)} km, " +
                (jazda?.let { "zaznamenané ${"%.2f".format(it.prejdeneMetre / 1000)} km (${"%+.2f".format(odchylka)} %)" } ?: "bez jazdy") +
                " | ${plan.popis}"
            if (vysledok == null) {
                prehlad += "OK    $riadok"
            } else {
                prehlad += "ZLE   $riadok\n      $vysledok"
                chyby += "$riadok\n      $vysledok"
                if (chyby.size <= 5) sim.vypisat()
            }
        }

        PRIEBEH += "=== 500 náhodných jázd: ${500 - chyby.size} OK, ${chyby.size} zlyhalo ==="
        PRIEBEH += "Spolu ${"%.0f".format(spoluKm)} km, najväčšia odchýlka kilometrov ${"%.2f".format(najvacsiaOdchylka)} %, " +
            "úsporný režim GPS použitý v $uspornych jazdách"
        PRIEBEH += prehlad
        PRIEBEH += ""
        assertTrue(
            "${chyby.size} z 500 jázd zlyhalo:\n" + chyby.take(10).joinToString("\n"),
            chyby.isEmpty(),
        )
    }

    private class Obec(val nazov: String, val okres: String, val lat: Double, val lon: Double) {
        val poloha get() = Pair(lat, lon)
    }

    private fun nacitatObce(): List<Obec> {
        val subor = javaClass.getResourceAsStream("/obce_sk.csv")
            ?: File("src/test/resources/obce_sk.csv").takeIf { it.exists() }?.inputStream()
            ?: error("Chýba src/test/resources/obce_sk.csv")
        return subor.bufferedReader(Charsets.UTF_8).readLines()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { riadok ->
                val (nazov, okres, lat, lon) = riadok.split(";")
                Obec(nazov, okres, lat.toDouble(), lon.toDouble())
            }
    }

    /** Každá piata jazda je krátka (do susednej obce), ostatné kamkoľvek po Slovensku. */
    private fun vybratCiel(odkial: Obec, obce: List<Obec>, nahoda: Random): Obec {
        val ostatne = obce.filter { it !== odkial && vzdialenost(it.poloha, odkial.poloha) >= 2_000 }
        if (nahoda.nextInt(5) == 0) {
            val najblizsie = ostatne.sortedBy { vzdialenost(it.poloha, odkial.poloha) }.take(6)
            return najblizsie[nahoda.nextInt(najblizsie.size)]
        }
        return ostatne[nahoda.nextInt(ostatne.size)]
    }

    /** Zastávka na trase: semafor, krátke zastavenie alebo zápcha. */
    private class Zastavka(val poMetroch: Double, val sekund: Int, val istotaAuta: Int?, val nazov: String)

    private class PlanJazdy(
        val trasa: Trasa,
        val cakanieMinut: Int,
        val istotaPriCakani: Int?,
        val istotaPocasJazdy: Int?,
        val rychlostMimoMesta: Double,
        val zastavky: List<Zastavka>,
        val tunely: List<ClosedFloatingPointRange<Double>>,
        /** Android zastaví sledovanie (napr. nedostatok pamäte) na daný počet sekúnd. */
        val restarty: List<Pair<Double, Int>>,
        val falosneVystupenia: List<Double>,
        val vystupeniaBezOdhadu: List<Double>,
        val podielNepresnych: Double,
    ) {
        val popis: String
            get() = buildList {
                add("čakanie $cakanieMinut min (Google ${istotaPriCakani?.let { "$it %" } ?: "-"})")
                add("jazda Google ${istotaPocasJazdy?.let { "$it %" } ?: "-"}")
                add("${rychlostMimoMesta.toInt()} km/h")
                zastavky.groupBy { it.nazov }.forEach { (nazov, z) -> add("$nazov ${z.size}× (${z.joinToString(",") { formatSekund(it.sekund) }})") }
                if (tunely.isNotEmpty()) add("tunely ${tunely.size}× (${tunely.joinToString(",") { "%.1f km".format((it.endInclusive - it.start) / 1000) }})")
                if (restarty.isNotEmpty()) add("reštart sledovania ${restarty.size}× (${restarty.joinToString(",") { formatSekund(it.second) }})")
                if (falosneVystupenia.isNotEmpty()) add("falošné vystúpenie ${falosneVystupenia.size}×")
                if (vystupeniaBezOdhadu.isNotEmpty()) add("vystúpenie bez odhadu ${vystupeniaBezOdhadu.size}×")
                add("nepresné body ${(podielNepresnych * 100).toInt()} %")
            }.joinToString(", ")

        companion object {
            private const val MESTO_METRE = 3_000.0

            fun nahodny(odkial: Obec, kam: Obec, n: Random): PlanJazdy {
                val trasa = trasaSoZakrutami(odkial.poloha, kam.poloha, n)
                val dlzka = trasa.dlzkaMetre
                val istotaPriCakani = listOf(70, 70, 10, null)[n.nextInt(4)]
                val istotaPocasJazdy = listOf(85, 85, 60, 10, null)[n.nextInt(5)]
                val rychlost = listOf(70.0, 90.0, 110.0, 130.0)[n.nextInt(4)]

                // Úseky, kde nesmie byť nič iné (zastávka, tunel, udalosť), aby sa neprekrývali.
                val obsadene = mutableListOf<ClosedFloatingPointRange<Double>>()
                fun volne(od: Double, po: Double) = od >= 500 && po <= dlzka - 1_500 &&
                    obsadene.none { it.start < po + 1_500 && od < it.endInclusive + 1_500 }
                fun najstMiesto(dlzkaUseku: Double, od: Double = 0.0, po: Double = dlzka): Double? {
                    repeat(30) {
                        val m = od + n.nextDouble() * (po - od)
                        if (volne(m, m + dlzkaUseku)) {
                            obsadene += m..(m + dlzkaUseku)
                            return m
                        }
                    }
                    return null
                }

                val zastavky = mutableListOf<Zastavka>()
                // Semafory v meste na začiatku a na konci.
                repeat(n.nextInt(4)) {
                    val vMeste = if (n.nextBoolean()) 0.0 to MESTO_METRE else (dlzka - MESTO_METRE) to dlzka
                    najstMiesto(0.0, vMeste.first.coerceAtLeast(0.0), vMeste.second)?.let {
                        zastavky += Zastavka(it, 20 + n.nextInt(100), istotaPocasJazdy, "semafor")
                    }
                }
                // Zápchy: s hláseným autom až 40 min, bez neho do 17 min (po 20 min sa jazda ukončí).
                if (dlzka > 10_000) {
                    repeat(n.nextInt(3)) {
                        val istota = listOf(80, 60, 10, null)[n.nextInt(4)]
                        val max = if (istota != null && istota >= ZaznamJazdy.MINIMALNA_ISTOTA_AUTA) 40 else 17
                        najstMiesto(0.0)?.let { zastavky += Zastavka(it, 60 * (2 + n.nextInt(max - 1)), istota, "zápcha") }
                    }
                }
                val tunely = mutableListOf<ClosedFloatingPointRange<Double>>()
                if (dlzka > 30_000) {
                    repeat(n.nextInt(3)) {
                        val dlzkaTunela = 300.0 + n.nextDouble() * 1_700
                        najstMiesto(dlzkaTunela, 5_000.0, dlzka - 5_000)?.let { tunely += it..(it + dlzkaTunela) }
                    }
                }
                // Android zastaví sledovanie na 10 s až 5 min (hra, nedostatok pamäte)
                // a po chvíli ho znova spustí; jazda má pokračovať ako jedna.
                val restarty = mutableListOf<Pair<Double, Int>>()
                if (dlzka > 10_000) {
                    repeat(n.nextInt(3)) {
                        val sekund = 10 + 10 * n.nextInt(30)
                        val dlzkaUseku = sekund * (rychlost + 10) / 3.6
                        najstMiesto(dlzkaUseku, 3_000.0, dlzka - 3_000)?.let { restarty += it to sekund }
                    }
                }
                val falosne = List(n.nextInt(4)) { najstMiesto(0.0) }.filterNotNull()
                val bezOdhadu = List(n.nextInt(3)) { najstMiesto(0.0) }.filterNotNull()

                return PlanJazdy(
                    trasa = trasa,
                    cakanieMinut = 1 + n.nextInt(25),
                    istotaPriCakani = istotaPriCakani,
                    istotaPocasJazdy = istotaPocasJazdy,
                    rychlostMimoMesta = rychlost,
                    zastavky = zastavky.sortedBy { it.poMetroch },
                    tunely = tunely,
                    restarty = restarty.sortedBy { it.first },
                    falosneVystupenia = falosne.sorted(),
                    vystupeniaBezOdhadu = bezOdhadu.sorted(),
                    podielNepresnych = listOf(0.0, 0.05, 0.1)[n.nextInt(3)],
                )
            }

            /** Lomená čiara z A do B: body každé 2–5 km, odklon ako pri skutočnej ceste. */
            private fun trasaSoZakrutami(a: Pair<Double, Double>, b: Pair<Double, Double>, n: Random): Trasa {
                val priama = vzdialenost(a, b)
                val pocet = maxOf(2, (priama / (2_000 + n.nextDouble() * 3_000)).toInt())
                val ohyb = (n.nextDouble() - 0.5) * 0.3 // celkový oblúk cesty
                val kosLat = cos(Math.toRadians(a.first))
                val dy = (b.first - a.first) * 111_320.0
                val dx = (b.second - a.second) * 111_320.0 * kosLat
                val body = (0..pocet).map { i ->
                    val t = i.toDouble() / pocet
                    if (i == 0) return@map a
                    if (i == pocet) return@map b
                    val bocne = ohyb * priama * sin(Math.PI * t) + (n.nextDouble() - 0.5) * minOf(600.0, priama / pocet * 0.4)
                    val y = dy * t + (-dx / priama) * bocne
                    val x = dx * t + (dy / priama) * bocne
                    Pair(a.first + y / 111_320.0, a.second + x / (111_320.0 * kosLat))
                }
                return Trasa(body)
            }
        }
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

    private class Simulacia(val nazov: String, start: LocalDateTime, semienko: Long = 42) {
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
        private val nahoda = Random(semienko)
        private var zaznam = novyZaznam()

        /** Rozpracovaná jazda uložená službou, kým ju Android zastavil. */
        private var ulozenyStav: StavJazdy? = null

        private fun novyZaznam() = ZaznamJazdy(hodiny = { teraz }, zapis = { zapisy += "${cas(teraz)}  $it" })

        /** Android zastaví službu (napr. nedostatok pamäte); stav jazdy ostane uložený. */
        fun prerusit() {
            if (!sleduje) return
            ulozenyStav = zaznam.stav()
            sleduje = false
            zapisy += "${cas(teraz)}  [Android zastavil sledovanie]"
        }

        /** Android službu znova spustí (START_STICKY) a tá obnoví uloženú jazdu. */
        fun obnovitPoPreruseni() {
            if (ulozenyStav != null) spustitSledovanie()
        }

        private fun ulozitJazdu(jazda: DokoncenaJazda) {
            jazdy += jazda
            zapisy += "${cas(teraz)}  [JAZDA ULOŽENÁ: ${"%.2f".format(jazda.prejdeneMetre / 1000)} km, " +
                "${cas(jazda.zaciatok.casMillis)} – ${cas(jazda.koniec.casMillis)}]"
        }

        private fun spustitSledovanie() {
            if (sleduje) return
            val stav = ulozenyStav
            if (stav != null) {
                // To isté ako GpsSledovanieService.obnovitStavJazdy po reštarte.
                ulozenyStav = null
                zaznam = novyZaznam()
                zaznam.obnovit(stav)?.let(::ulozitJazdu)
                zapisy += "${cas(teraz)}  [sledovanie obnovené po reštarte]"
            }
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
            if (sleduje || ulozenyStav != null) {
                // Služba sa pri udalosti spustí a obnoví uloženú jazdu.
                spustitSledovanie()
                zaznam.vystupil()
            }
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
                zaznam.dokoncit()?.let(::ulozitJazdu)
                sleduje = false
                zapisy += "${cas(teraz)}  [koniec sledovania: $dovod]"
            }
        }

        /** Jazda po úseku trasy stálou rýchlosťou; vráti, kde auto skončilo. */
        fun jazditUsek(trasa: Trasa, odMetrov: Double, poMetrov: Double, kmh: Double = 85.0): Double {
            var prejdene = odMetrov
            while (prejdene < poMetrov) {
                prejdene = min(prejdene + kmh / 3.6 * 10, poMetrov)
                krok(trasa.poloha(prejdene), kmh, presnost = 8f)
            }
            return prejdene
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

        var usporneBolo = false
            private set

        /**
         * Celá jazda podľa náhodného plánu, vrátane čakania pred odjazdom a odchodu od auta.
         * Vráti null, ak vznikla správna jazda, inak popis chyby.
         */
        fun jazditPodlaPlanu(plan: PlanJazdy): String? {
            val trasa = plan.trasa
            val dlzka = trasa.dlzkaMetre
            istotaAuta = plan.istotaPriCakani
            nastupil()
            repeat(plan.cakanieMinut * 6) {
                krok(trasa.poloha(0.0), kmh = 0.0, presnost = 12f)
                if (usporne) usporneBolo = true
            }
            if (!sleduje) return "Sledovanie skončilo počas čakania na odjazd (${dovody.joinToString()})"
            val odjazd = teraz

            var prejdene = 0.0
            var dalsiaZastavka = 0
            var dalsieFalosne = 0
            var dalsieBezOdhadu = 0
            var dalsiRestart = 0
            var zostavaPrerusenie = 0
            var metrePrerusenia = 0.0
            var cakaNaPrvyBod = false
            // Počas prerušenia GPS nebeží; jazda pokračuje priamou čiarou od
            // posledného bodu, takže zaznamená o rozdiel oblúka a tetivy menej.
            var strataPrerusenim = 0.0
            var poslednyKrok = false
            while (!poslednyKrok) {
                val restart = plan.restarty.getOrNull(dalsiRestart)
                if (restart != null && prejdene >= restart.first && zostavaPrerusenie == 0 && !cakaNaPrvyBod) {
                    dalsiRestart++
                    prerusit()
                    metrePrerusenia = prejdene
                    zostavaPrerusenie = restart.second / 10
                }
                val zastavka = plan.zastavky.getOrNull(dalsiaZastavka)
                if (zastavka != null && prejdene >= zastavka.poMetroch) {
                    dalsiaZastavka++
                    istotaAuta = zastavka.istotaAuta
                    repeat(zastavka.sekund / 10) { krok(trasa.poloha(prejdene), kmh = 0.0, presnost = 10f) }
                }
                val vMeste = prejdene < 3_000 || prejdene > dlzka - 3_000
                val kmh = if (vMeste) 30.0 + nahoda.nextInt(21) else plan.rychlostMimoMesta - 10 + nahoda.nextInt(21)
                prejdene = min(prejdene + kmh / 3.6 * 10, dlzka)
                poslednyKrok = prejdene >= dlzka
                istotaAuta = plan.istotaPocasJazdy
                var vynutitPresny = poslednyKrok
                if (zostavaPrerusenie > 0) {
                    zostavaPrerusenie--
                    if (zostavaPrerusenie == 0) {
                        obnovitPoPreruseni()
                        cakaNaPrvyBod = true
                        vynutitPresny = true
                    }
                }
                if (dalsieFalosne < plan.falosneVystupenia.size && prejdene >= plan.falosneVystupenia[dalsieFalosne]) {
                    dalsieFalosne++
                    istotaAuta = 85
                    vystupil()
                    istotaAuta = plan.istotaPocasJazdy
                }
                if (dalsieBezOdhadu < plan.vystupeniaBezOdhadu.size && prejdene >= plan.vystupeniaBezOdhadu[dalsieBezOdhadu]) {
                    dalsieBezOdhadu++
                    istotaAuta = null
                    vystupil()
                    istotaAuta = plan.istotaPocasJazdy
                    vynutitPresny = true
                }
                val vTuneli = plan.tunely.any { prejdene in it }
                val presnost = if (!vynutitPresny && nahoda.nextDouble() < plan.podielNepresnych) 40f + nahoda.nextInt(60) else 5f + nahoda.nextInt(15)
                krok(if (vTuneli) null else trasa.poloha(prejdene), kmh, presnost)
                if (cakaNaPrvyBod) {
                    cakaNaPrvyBod = false
                    val oblukMetre = prejdene - metrePrerusenia
                    strataPrerusenim += oblukMetre - vzdialenost(trasa.poloha(metrePrerusenia), trasa.poloha(prejdene))
                }
            }
            val prichod = teraz

            istotaAuta = 5
            vystupil()
            ist(pesoMinut = 2, od = trasa.poloha(dlzka))
            cakat(minuty = 5, poloha = null)

            if (jazdy.size != 1) return "Očakávaná 1 jazda, vzniklo ${jazdy.size} (dôvody konca: ${dovody.joinToString()})"
            if (dovody != listOf(DovodKonca.VYSTUPIL)) return "Nesprávny dôvod konca: ${dovody.joinToString()}"
            val jazda = jazdy.single()
            val tolerancia = maxOf(0.015 * dlzka, 150.0)
            val ocakavane = dlzka - strataPrerusenim
            if (abs(jazda.prejdeneMetre - ocakavane) > tolerancia) {
                return "Kilometre: očakávané ${"%.2f".format(ocakavane / 1000)} km, zaznamenané ${"%.2f".format(jazda.prejdeneMetre / 1000)} km"
            }
            if (abs(jazda.zaciatok.casMillis - odjazd) > 70_000) return "Začiatok ${cas(jazda.zaciatok.casMillis)}, odjazd bol ${cas(odjazd)}"
            if (abs(jazda.koniec.casMillis - prichod) > 20_000) return "Koniec ${cas(jazda.koniec.casMillis)}, príchod bol ${cas(prichod)}"
            val odStartu = vzdialenost(trasa.poloha(0.0), Pair(jazda.zaciatok.latitude, jazda.zaciatok.longitude))
            if (odStartu > 30) return "Začiatok ${"%.0f".format(odStartu)} m od miesta odjazdu"
            val odCiela = vzdialenost(trasa.poloha(dlzka), Pair(jazda.koniec.latitude, jazda.koniec.longitude))
            if (odCiela > 30) return "Koniec ${"%.0f".format(odCiela)} m od cieľa"
            return null
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
        /** Rovnaké semienko = vždy rovnaké jazdy. Iné jazdy: zmeň 2026 na iné číslo. */
        private val SEMIENKO_NAHODNYCH_JAZD = System.getProperty("semienko")?.toLongOrNull() ?: 2026L

        private fun formatSekund(sekund: Int): String =
            if (sekund >= 60) "${sekund / 60} min" else "$sekund s"

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

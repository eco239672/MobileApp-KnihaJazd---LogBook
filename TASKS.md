# Úlohy — Kniha jázd

## Produktová myšlienka

Automatická, offline-first a vysvetliteľná kniha jázd pre jednotlivca alebo malú firmu. Aplikácia nemá predstierať dokonalú presnosť: pri každej jazde má jasne ukázať pôvod a spoľahlivosť zaznamenaných údajov.

## Prioritné úlohy

- [ ] Nahradiť ukážkové jazdy lokálnou databázou v telefóne.
- [ ] Zaznamenať začiatok, koniec, trasu, kilometre a čas každej jazdy.
- [ ] Rozdeliť jazdy na služobné a súkromné.
- [ ] Automaticky rozpoznať pravdepodobnú jazdu autom pomocou polohy a pohybových senzorov.
- [ ] Ukladať dáta aj bez internetu a zosynchronizovať ich až po návrate pripojenia.
- [ ] Pri každej jazde evidovať zdroj a mieru istoty: GPS presné, odhadnutý úsek alebo potrebuje kontrolu.
- [ ] Pri krátkom výpadku GPS použiť inerciálne senzory len ako dočasný odhad a po návrate GPS trasu opraviť.
- [ ] Označiť dlhé alebo neisté výpadky na manuálnu kontrolu namiesto falošne presného výpočtu.
- [ ] Naučiť sa často používané miesta a trasy lokálne v telefóne.
- [ ] Pridať voliteľnú detekciu pripojenia k Bluetooth v aute.
- [ ] Preskúmať voliteľnú podporu OBD-II adaptéra ako presnejšieho zdroja rýchlosti a tachometra.
- [ ] Pridať export do Excelu a PDF s vlastnou šablónou pre účtovníka.
- [ ] Viesť históriu úprav jazdy pre dôveryhodný auditný záznam.
- [ ] Pridať voliteľnú šifrovanú zálohu; cloud nesmie byť povinný.

## Zásady návrhu

- [ ] Údaje o polohe majú byť štandardne uložené lokálne.
- [ ] Používateľ musí vedieť, prečo aplikácia jazdu vytvorila a aká je jej presnosť.
- [ ] Automatika má navrhovať a upozorňovať, nie skryto vymýšľať neisté údaje.
- [ ] Ručné doplnenie jazdy ponechať ako nenápadnú záložnú možnosť, nie ako hlavné tlačidlo na domovskej obrazovke.

## Overenie pred vydaním

- [ ] Testovať na rôznych Android telefónoch a iPhonoch.
- [ ] Testovať jazdu bez internetu, v tuneli, v garáži a pri slabom GPS.
- [ ] Zmerať spotrebu batérie počas celodenného automatického sledovania.
- [ ] Overiť export so slovenským účtovníkom a reálnou Excel šablónou.

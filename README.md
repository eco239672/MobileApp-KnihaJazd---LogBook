# Kniha jázd – Drive Log Cloud

Mobilná Flutter aplikácia pre jednoduchú evidenciu jázd. Projekt je navrhnutý ako offline-first: jazdy a GPS body budú ukladané priamo v telefóne, zatiaľ čo cloudová záloha zostane voliteľná.

## Aktuálne funkcie

- slovenský kalendár od začiatku aktuálneho roka;
- detail vybraného dňa;
- úprava trasy, času, kilometrov a typu jazdy;
- mesačný odhad spotreby paliva podľa nastavenej priemernej spotreby;
- Android rozpoznanie stavu „v aute“; po jeho jednorazovom povolení v Nastaveniach zapne GPS sledovanie iba pri jazde;
- GPS sledovanie počas otvorenej aplikácie s kontrolou oprávnení, kvality polohy a 20-minútovou toleranciou státia v zápche;
- čistý záznamník pripravený na reálne jazdy.

## Overenie

```powershell
flutter analyze
flutter test
flutter run -d <id-zariadenia>
```

## Ďalší krok

Pridať lokálnu databázu, aby upravené a zaznamenané jazdy ostali zachované aj po ukončení aplikácie, a dokončiť samostatnú Android službu pre sledovanie po zavretí aplikácie. Úplný plán je v [TASKS.md](TASKS.md).

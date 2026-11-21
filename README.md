# BRAW Preview

Bélyegképek és Gyorsnézet-előnézet **Blackmagic RAW (`.braw`)** klipekhez a macOS Finderben.

- **Bélyegkép** a Finder ikon-, lista-, oszlop- és galérianézetében (a klip kb. 1. másodpercéből).
- **Lejátszás szóközzel**: a Gyorsnézet-ablakban a klip azonnal elindul, hanggal, ismétlődve.
  Kattintás a képre (vagy a ▶︎ gombra): szünet / folytatás; a csúszkával lehet tekerni.
  Szünetben élesebb állókép jelenik meg. A Finder keskeny előnézeti paneljén állókép marad,
  kattintásra indul.
- **Kinézet** (bélyegképen és lejátszáskor ugyanaz):
  - ha a klipben van LUT (a kamera beágyazta), azt használja;
  - ha nincs, és a felvétel log (Blackmagic Design Film), Extended Video / Rec.709 kinézetre
    alakítja, ahogy a kamera monitorján látszik;
  - minden más (Video, Extended Video, egyedi görbe) úgy jelenik meg, ahogy felvették.

  A lejátszó felső sorában látszik, melyik történt (pl. `LUT: …` vagy `Film → Extended Video`).

*English summary: Finder thumbnails and Quick Look previews for Blackmagic RAW clips. Run
`./install.sh` on a Mac that has the free Blackmagic RAW package installed.*

## Mi kell hozzá

| | |
|---|---|
| macOS | 12 Monterey vagy újabb (Apple Silicon és Intel is) |
| **Blackmagic RAW** | ingyenes, Blackmagic oldaláról: <https://www.blackmagicdesign.com/products/blackmagicraw> – ebben van a Player és az SDK, ami a dekódoláshoz kell |
| Xcode Command Line Tools | ha nincs fent, a telepítő felajánlja (pár perc) |

## Telepítés

1. Telepítsd a **Blackmagic RAW** csomagot (ha még nincs fent).
2. Töltsd le ezt a repót: zöld **Code** gomb → **Download ZIP**, majd csomagold ki.
   (Vagy: `git clone https://github.com/ranczandras/BRAW_thumbnail.git`)
3. Terminálban:

   ```bash
   cd ~/Downloads/BRAW_thumbnail-main
   ```

   ```bash
   bash install.sh
   ```

A szkript lefordítja az appot, felteszi ide: `/Applications/BRAW Preview.app`, regisztrálja a
bővítményeket, törli a régi bélyegkép-gyorsítótárat, és egyszer elindítja az appot – egy ablak
jelzi, hogy kész.

### „Automatikus indulás”

Nincs mit beállítani: ez **nem háttérben futó program**. A Gyorsnézet-bővítményeket a macOS maga
indítja el, amikor a Findernek bélyegkép vagy előnézet kell, és utána leállítja őket. Újraindítás
után is működik, nem kell bejelentkezési elem.

Ellenőrzés / ki-be kapcsolás: **Rendszerbeállítások → Általános → Bejelentkezési elemek és
bővítmények → Gyorsnézet** (régebbi macOS-en: Rendszerbeállítások → Bővítmények → Gyorsnézet).

### Frissítés

Ha frissíted a Blackmagic RAW csomagot (új kamerákhoz új SDK kell), vagy ennek a repónak új
verziója van, futtasd újra a `bash install.sh` parancsot.

### Eltávolítás

```bash
bash uninstall.sh
```

## Ha nem jelenik meg a bélyegkép

1. Zárd be és nyisd meg újra a Finder-ablakot (a már megjelenített ikonokat a Finder tárolja).
2. Futtasd a diagnosztikát egy klippel:

   ```bash
   bash scripts/doctor.sh /útvonal/a/klip.braw
   ```

   Ez kiírja, hogy a bővítmény regisztrálva és bekapcsolva van-e (`+` jel), milyen fájltípusnak
   látja a macOS a klipet (`com.blackmagic-design.braw-movie` kell legyen), legenerál egy
   bélyegképet, és mutatja a dekóder naplóját.
3. Ha a fájltípus más, nyiss egy issue-t a `doctor.sh` kimenetével.

## Hogyan működik

- `BRAW Preview.app` egy kis gazda-app két Quick Look bővítménnyel:
  `BRAWThumbnail.appex` (`QLThumbnailProvider`) és `BRAWPreview.appex` (`QLPreviewProvider`).
- A dekódolás a Blackmagic RAW SDK-val történik CPU-n, a kért mérethez illő csökkentett
  felbontáson (1/8, 1/4, 1/2), így egy bélyegkép tört másodperc alatt kész.
- Lejátszáskor a képkockák menet közben dekódolódnak (6K-nál 1/4, 12K-nál 1/8 felbontáson), az
  óra a klip saját hangja, így kép és hang szinkronban marad. Ha a gép nem bírja a tempót, a
  lejátszó magától kisebb felbontásra vált, és inkább kockát ejt, mint hogy lemaradjon.
- A `BlackmagicRawAPI.framework` a gépedre telepített Blackmagic RAW-ból kerül a bővítményekbe a
  telepítéskor – a repó nem tartalmazza és nem terjeszti. A fordítás ugyanannak az SDK-nak a
  fejlécével történik, így a verziók mindig egyeznek.
- Az app helyben, ad-hoc aláírással készül, ezért nem kell Apple fejlesztői fiók, és a
  Gatekeeper sem állítja meg.
- A Quick Look-bővítmények sandboxban futnak, ezért a klip melletti `.sidecar` fájlban tárolt
  utólagos beállításokat (ISO, fehéregyensúly stb.) nem látják – a bélyegkép a kamerában
  rögzített beállításokkal készül.

Fejlesztés: `scripts/build.sh [kimeneti-mappa]` csak fordít, nem telepít. A GitHub Actions
minden pushnál lefordítja a projektet macOS-en kétféle SDK-fejléccel (SDK 4/5 és SDK 6).

## Licenc

MIT – lásd [LICENSE](LICENSE). A Blackmagic RAW SDK a Blackmagic Design tulajdona, saját
licenccel.

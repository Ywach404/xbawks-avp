# Original Xbox hardware reference

Gathered 2026-10-29 for the in-space console model. Everything here is
secondary sourced and the sources are named, because no Microsoft spec
sheet or service manual was locatable.

## Physical dimensions

| | width | height | depth |
|---|---|---|---|
| design figures, Wikipedia | 320 mm | 100 mm | 260 mm |
| measured, dimensions.com | 320 mm | 91 mm | 259.1 mm |
| xemu's own 3D model, shell | 323.3 mm | 93.4 mm | 259.4 mm |

The height disagreement is whether the rubber feet and the raised rear lip
are counted. Working values: **320 wide, 260 deep, 100 tall including
feet**, about 91 mm for the shell alone. Mass about 3.9 kg.

Duke controller: 177.8 x 139.7 x 68.6 mm, 0.55 kg (dimensions.com, the
2001 original). The 203 x 109 x 171 mm figure that circulates traces to a
retailer's customer question rather than a spec table and probably
includes packaging.

Sources: `en.wikipedia.org/wiki/Xbox_technical_specifications`,
`dimensions.com/element/xbox`, `dimensions.com/element/xbox-controller`.

## Colourways

The standard jewel is a translucent green dome with a chrome X. Rows note
a jewel difference where one exists. No source anywhere gives hex values,
so colours would have to be sampled from reference photographs; Wikimedia
Commons has freely licensed ones.

### Retail, wide release

| variant | finish | jewel | where and when | units |
|---|---|---|---|---|
| Standard | opaque matte black | standard | global, from 2001-11-15 | millions |
| Crystal | translucent clear | standard | NA, EU, JP, AU, 2004 | 100k to 1M |
| Translucent Green "First Year" | translucent green | standard | EU and CA, 2002-05-02 | 20,000 |
| Classic Crystal Green | crystal green | standard, plain Xbox logo | EU, May 2004 | 50k to 100k |
| Halo Special Edition | translucent green, "Halo Special Edition" printed on the front | standard | US, 2004-04-13 | 200,000 |
| Clear Green Halo 2 | translucent clear green | Halo 2 branding | HK and SG, late 2004 | 1k to 5k |
| Crystal Ice Blue | translucent clear blue | **white** | Canada, 2004 | 5,000 |
| Crystal Clear Halo 2 | crystal clear | standard | Europe, 2004 | 10k to 50k |

### Retail, Japan only

| variant | finish | jewel | when | units |
|---|---|---|---|---|
| Skeleton, "Dark Crystal" | translucent **smoke black** | standard | Feb 2004 | 50,000 made, ~10,000 sold |
| Pure White Limited Edition 2004 | opaque white | **grey, engraved "Limited Edition 2004"** | Feb 2004, order window of one week | 1,000 |
| Panzer Dragoon Orta | opaque **white**, Orta artwork around the jewel, logo lower left | standard | 2002-12-19, Sega Direct pre-order | 999 |
| Dead or Alive "Kasumi-chan Blue" | translucent clear blue | **white** | 2004-03-25 | 5,000 |

### Promotional

| variant | finish | jewel | where | units |
|---|---|---|---|---|
| Mountain Dew | bright green | **Mountain Dew** | US, Apr to Aug 2004 | 5,100 |
| Pepsi "Hulk" | bright green | **Hulk** | UK cinema scratch card | 36 |
| Launch Team | clear and green, signed by Bill Gates | standard | Microsoft staff only | 1k to 5k |
| Partners | green and clear | standard | component suppliers, 2001 | 500 to 1,000 |
| Hello Kitty "Mission Rescue" | clear | **pink Hello Kitty X** | Singapore, 2005 | 550 |
| 50 Cent Bulletproof | white and gold, signed | standard | Australia, 2005 | 50 |
| Ed Fries Special Edition | white | "Ed Fries - Special Edition" | retirement gift, 2004 | 1 |

Roughly thirty further one-off press and contest units exist, each a
retail shell painted or airbrushed, typically 1 to 50 made. Index at
`consolevariations.com/database/microsoft-xbox/page-2`.

Also relevant to a swappable jewel: the Japanese **"X" Dress-up** jewels,
six designer replacement jewels given out by lottery at TGS 2003, around
100 to 500 of each.

### Claimed but not real

- **No Final Fantasy XI original Xbox.** FFXI shipped on PS2, PC and Xbox
  360. The white FFXI bundle people remember is the Japanese Xbox 360
  launch bundle of 2005-12-10. The white original Xboxes are Panzer
  Dragoon Orta (999) and Pure White Limited Edition 2004 (1,000).
- **No "Blue Electric".** The original Xbox blues are Crystal Ice Blue
  (Canada) and Kasumi-chan Blue (Japan).
- **No official red.** Any red original Xbox is an aftermarket shell.
  Same for most translucent oranges, purples and chromes on the
  secondhand market.
- **Debug kits were not green.** They were retail hardware with internal
  differences; the development kit wiki records no exterior colour
  difference. The Alpha kits were off-the-shelf PC parts in a silver case.
- The orange "Halo Special Orange" is a prototype with fewer than five
  known, and only one is confirmed to carry the Halo wording, so some
  circulating orange units are probably aftermarket shells.

Primary source throughout: `consolevariations.com/database/microsoft-xbox`,
cross-checked against `altarofgaming.com` and `xboxdevwiki.net`. Where
those disagreed, the disagreement is noted above rather than resolved
silently.

## A model to put in the space

xemu's own website carries exactly the right asset, and it cannot be used
without asking.

`https://xemu.app/xbox.glb`, 355,964 bytes, glTF 2.0 binary, Draco
compressed. Verified by reading the file: 23 meshes, 27 nodes, **zero
materials and zero textures**, `copyright: xemu Project`, generated by
the Blender glTF exporter. The parts are separated and named along
exactly the seams a colourway swap needs: `Shell Combined`, `Jewel Gloss
-- Opaque`, `Eject Button`, `Eject Button Ring Light`, `DVD Tray Text`,
`Rear Long Fins`, `Rear Short Fins`, `Feet`, `Internal Shield`,
`Controller Port Numbers`, the power, AV and RJ45 port groups. It is
already modelled to real-world scale in metres.

**Licence: none.** `xemu-project/xemu-website` has no licence file at all
(no LICENSE, COPYING or CREDITS, and the GitHub API reports none), the
footer asserts `Copyright (c) 2020 - present xemu Project`, and the
emulator's GPL does not reach a separate website repository. Treat it as
all rights reserved. It was added in a single commit, `c32a3f77`,
2024-06-14, by Matt Borgerson, xemu's lead developer, who set the
copyright field himself.

The route is to ask him, which is a reasonable ask given this project is
a port of his emulator.

**If the answer is no:** there is no CC0 original Xbox anywhere, verified
against the Sketchfab API across seven query variants, Poly Pizza, the
Khronos sample assets, GitHub, Thingiverse and Printables. The best
freely licensed option is rubikreef's "Xbox", CC-BY 4.0, 12,172
triangles, correct retail silhouette:
`sketchfab.com/3d-models/xbox-6ded51a4060d49198bc80ed5403718ff`. It would
need its parts split by hand in Blender before any colourway swap works.

Two traps found while looking: the Sketchfab models titled "Xbox Original
Prototype" are the X-shaped GDC 2000 reveal unit rather than the retail
console, and several of the nicest looking results are not downloadable
and carry no licence despite search summaries calling them free.

**RealityKit does not read `KHR_draco_mesh_compression`**, so any Draco
glTF needs decompressing, with `gltf-transform` or a Blender round trip,
before conversion to USDZ.

## Typeface

**None of the three real ones can be used, for three different reasons.**

- The **XBOX wordmark** is custom lettering based on Bronzo, a commercial
  Thirstype face from the 1990s, with the B redrawn to echo the O. The
  drawing is also a Microsoft trademark. Source:
  `fontsinuse.com/uses/19153/xbox-logo-2001-05-2008-10`.
- The **green blades dashboard** used two faces commissioned from Steve
  Matteson, **Xbox Display** for headings and **Xbox Book** for text, to a
  brief calling for "very aggressive looking typography, typical of a
  hardcore gaming environment". They were never released in any normal
  font format: they exist only as `Xbox.xtf` and `XBox Book.xtf` inside
  the retail dashboard, in XTF, a proprietary vector mesh format used
  nowhere else. Sources: `mattesontypographics.com/typefaces/xbox`,
  `xboxdevwiki.net/Xtf`.
- The **boot sequence has no text at all.** It is geometry and textures
  from the BIOS, and the only typographic element in it is the wordmark
  artwork, which is the first case again.

So anything calling itself "the Xbox font" is a rip or a trace.

### What is installed

**Oxanium**, SIL Open Font License 1.1, by Severin Meyer,
`github.com/sevmeyer/oxanium`. Six weights at
`~/Library/Fonts`, licence at `~/Library/Fonts/_licences/Oxanium-OFL.txt`.
Closest match of everything compared against a real dashboard capture:
squared bowls, flat terminals, generous x height, single storey g. Covers
both dashboard roles from one family, Regular or Medium for body and
SemiBold or Bold tracked out for headings. **No Reserved Font Name**, so
it can be subset or modified without renaming.

**Quantico**, SIL OFL 1.1, by Matthew Desmond, as the backup. Squarer and
more military; its Bold is arguably the better heading face, its Regular
the weaker body face. **Has** a Reserved Font Name, so a modified version
must be renamed.

OFL 1.1 permits commercial use, embedding in an application and
redistribution. The only duty is to ship the licence text beside the
font. It also does not conflict with the GPL: per the SIL FAQ 1.3,
bundling an OFL font with software under another licence is aggregation,
and only the font stays OFL.

### Traps, all verified and all failing

| what | why it fails |
|---|---|
| "XBOX Original" (online-fonts and mirrors) | its own page says non-commercial, private use only, all rights reserved. A 2020 third party redraw of Microsoft's face, with the uploader asserting rights over someone else's design. The most common search hit. |
| "XBold" by 629Fonts | personal use only, and it traces the logo rather than being its source: made in 2017, long after the logo. |
| "Dashbroken" (FontStruct) | FontStruct Non-Commercial Licence, and openly described as based on the dashboard's own font. |
| Handel Gothic | a commercial URW retail face, about 35 USD a style. Sites offering it free are distributing it without a licence. |
| "Xbox Logo Font" (DeviantArt) | a hobbyist trace with no licence at all. |
| Segoe, Convection | never freely licensed, and Convection is the 360 era, not the 2001 blades. Both are nonetheless live and downloadable, with their real Microsoft EULA strings intact, on font.download and fontsgeek, which makes those unauthorised copies rather than traces. |
| **"X360" by Redge** | **the worst of them. See below.** |

### X360 is a stripped Verdana, and it is the most downloaded of all

413,000 downloads on dafont, badged "100% Free", and hyperpix states
plainly "You can use the font in your personal and commercial projects".
The file says otherwise. Parsed against Verdana as Apple ships it at
`/System/Library/Fonts/Supplemental/Verdana.ttf`:

| field | X360.ttf | Verdana.ttf |
|---|---|---|
| `head.created` | `00000000aa7e4429` | `00000000aa7e4429` **identical** |
| PANOSE | `2 11 6 4 3 5 4 4 2 4` | `2 11 6 4 3 5 4 4 2 4` **identical** |
| vendor ID | `MS  ` | `MS  ` **identical** |
| unitsPerEm | 2048 | 2048 **identical** |
| advance widths | 845 of 910 slots equal, first 20 exact | |
| copyright (name 0) | **absent** | "(c) 2006 Microsoft Corporation. All Rights Reserved." |
| trademark (name 7) | **absent** | present |
| licence (name 13) | **absent** | the Microsoft EULA reference |
| fsType embedding | **0, unrestricted** | 8, restricted |

A creation timestamp cannot coincide between two independently drawn
fonts. The outlines were redrawn blocky, so the drawings are not
Verdana's, but the binary is, with the copyright, trademark and licence
records removed and the embedding restriction cleared. Shipping that in a
public repository would be the one thing here that is both unlicensed and
trivially provable by anyone who parses the file, exactly as this table
was produced. The sites also have the fact wrong: X360 is not the Xbox
One font either. That was Segoe.

### The aggregators say it themselves

Printed under the download buttons on blogfonts and dafontfree:

> The licence mentioned above the download button is just an indication.
> ... If no author/licence is indicated that's because we don't have
> information, that doesn't mean it's free.


Domains to treat as non-results for this search: font.download,
cdnfonts.com, fontsgeek.com, ffonts.net, cufonfonts.com, fonts2u.com,
fontmeme.com, fontbolt.com, hyperpix.net, blogfonts.com, dafontfree.net,
dafontfree.io, dafontdl.com, dafont.live, dafonttop.com, fontsme.com,
fontlot.com, yufont.com, onlinewebfonts.com, freefonts.co,
freefontsdownload.net, freefontdownload.org, maisfontes.com,
freefontsfamily.com, whatfontis.com, famfonts.com, gamingfonts.com,
online-fonts.com, azfonts.net, freeforfonts.com.

One tier up, dafont and fontspace do label licences and host genuinely
free work, but the labels are uploader declared, and X360 proves a
"100% Free" badge on dafont can sit on a stripped proprietary binary.

Handel Gothic, for the record, is Linotype, designed by Donald Handel,
sold on MyFonts from 40.99 USD a style and 109.99 USD for the family of
three. There is no free cut of it.

### Two practical notes

Both faces are Latin only: Oxanium covers 364 codepoints, Quantico 266.
Accented Latin and the bullet are there, arrows are not, and anything
outside the set falls back silently to the system font. Keep icons as SF
Symbols or vector assets rather than typed characters.

The XBOX wordmark is a Microsoft trademark, which is a separate question
from font licensing. Use the OFL face for the interface, and do not set
the word in it as a logo.

# Profil D2 — attribution par fonction et par poste du tic courant

Mesure du 2026-09-15 sur `c2c784d` (moteur inchangé depuis la passe de
calcul `49f2a66`), Scarb/Cairo 2.16.0, profil `proving` (`unsafe-panic`,
annotations `statements_functions`). Exécutable `step_tic` mesuré :
SHA-256 `eb156f65712f5b50f816ac9553b3e6f47a5ffb7bb1c1ad1c8ed223bdf9b582e5`,
108 505 mots ; `run_segment` 107 018 mots (D29 : +7 018 au-dessus de la cible).

Les cinq replays du corpus donnent **2 946 tics, moyenne 48 543,68, p99 122 942,
maximum 166 315** : exactement les chiffres publiés dans `docs/STATUS.md` et
`docs/design/cairo-calculation-costs.md`, ce qui identifie le programme mesuré.
D2 demande **12 000 en moyenne et 25 000 au p99**.

## 1. Méthode

`cairo-profiler` n'est pas installé sur la machine et n'est pas téléchargeable
depuis le bac à sable ; le script `bench/attribute_tics.py` (nouveau) refait son
travail directement sur la trace VM que Scarb sauvegarde :

1. `scarb execute --executable-name step_tic --save-profiler-trace-data` sur des
   chunks de 35 tics, en chaînant l'état sérialisé exactement comme
   `bench/trace_profile.py` ;
2. chaque `pc` de la trace est ramené à son statement Sierra par les offsets de
   `infra/sierra_words` (la chaîne `cairo-execute` exacte), puis à sa **pile
   d'inlining** (`statements_functions`) ;
3. la **pile d'appels dynamique** est reconstruite depuis `fp` (un `call` pousse
   une frame de `fp` supérieur, un `ret` revient au `fp` de l'appelant) ; la
   pile complète d'un step est sa pile d'inlining suivie de celle du site
   d'appel de chaque ancêtre ;
4. les tics sont séparés par les frames récursives de la boucle de commandes de
   `step_tic_impl`, comme `trace_profile.py` ; tout ce qui est hors de ces
   frames est la **frontière** (parseur d'arguments, `from_felts`, `serialize`,
   `snapshot`, sortie, squashes de dictionnaire) et est attribué séparément.

Chaque step est compté une fois dans trois vues **disjointes** — `flat`
(fonction source la plus interne, helpers core compris), **propriétaire**
(fonction `doom_*` la plus interne de la pile, à qui sont rattachés ses helpers
core/fixed/bam inlinés ou appelés) et **poste** (catégorie du propriétaire) — et
une vue **cumulative** (chaque fonction de la pile, une fois par step), qui se
recouvre et ne s'additionne pas. Les libfuncs exécutés par propriétaire
(`store_temp` par type, `u128_safe_divmod`, `into_box`…) sont aussi comptés.

Contrôles : sur trois tics de marche, les échantillons par tic sont identiques
à ceux de `trace_profile.py` (`[34 590, 31 281, 30 113]`, frontière 266 562) ;
sur les 2 946 tics, la moyenne, le p99 et le maximum reproduisent au step près
la référence publiée. Le chunk de 35 limite la mémoire de trace et ne lisse
aucun quantile ; le p99 est le rang supérieur `ceil(0,99·N)`.

```sh
export PATH=<scarb 2.16.0>/bin:$PATH RAYON_NUM_THREADS=1 ASDF_SCARB_VERSION=2.16.0
scarb --manifest-path cairo/Scarb.toml --profile proving build -p doom_run
(cd infra/sierra_words && cargo build --release)
cd cairo/doom/doom_game/bench
python3 attribute_tics.py --all --chunk 35 --out /tmp/d2-profile     # ≈ 30 s par chunk
python3 d2_tables.py /tmp/d2-profile --top 15 > /tmp/d2-tables.md    # tableaux ci-dessous
```

Sur la machine partagée, un processus par replay (`--scenario`) tient en
~1,5 Go ; quatre en parallèle ont déclenché un OOM cgroup une fois, le replay
`fight` a été relancé seul. Aucune preuve n'a été générée ; aucune source du
moteur, aucun golden ni budget n'a été modifié. Les JSON complets (échantillons,
chunks, tables par fonction) sont dans le scratchpad de la session
(`prof/d2/{idle,walk,door,fight,death}.json`).

## 2. Distribution par tic, frontière exclue

| Replay | Tics | Moyenne | p50 | p90 | p99 | Max | Frontière/appel |
|---|---:|---:|---:|---:|---:|---:|---:|
| idle | 700 | 26 386 | 26 175 | 28 716 | 29 541 | 29 593 | 266 508 |
| walk | 350 | 50 504 | 48 439 | 75 037 | 91 352 | 112 154 | 272 706 |
| door | 350 | 64 931 | 65 530 | 92 613 | 127 084 | 165 417 | 278 430 |
| fight | 700 | 63 228 | 55 092 | 102 802 | 153 484 | 166 315 | 275 662 |
| death | 846 | 47 137 | 46 993 | 71 227 | 91 873 | 123 631 | 269 278 |
| **agrégat** | 2 946 | **48 544** | 45 571 | 77 764 | **122 942** | 166 315 | |

Le tic le moins cher du corpus coûte 26 175 steps (idle p50), soit déjà 2,2× la
cible moyenne ; aucun tic n'est sous 25 000. En combat, 88 tics sur 700
dépassent 100 000 et 283 dépassent 60 000.

## 3. Répartition par poste (propriétaire disjoint, steps/tic)

| Poste | idle | walk | door | fight | death | agrégat | part |
|---|---:|---:|---:|---:|---:|---:|---:|
| monstres/IA (`doom_monsters`) | 15 954 | 16 427 | 17 813 | 21 977 | 16 867 | 17 924 | 36,9 % |
| physique/collision (`doom_physics` hors `sight`) | 5 210 | 16 754 | 23 681 | 28 141 | 18 636 | 18 080 | 37,2 % |
| boucle `doom_game` (`tic`, `level`) | 2 541 | 12 535 | 18 305 | 9 433 | 7 141 | 8 560 | 17,6 % |
| `check_sight` (`doom_physics::sight`) | 450 | 1 917 | 1 628 | 632 | 1 999 | 1 253 | 2,6 % |
| joueur (`doom_player`) | 1 206 | 1 325 | 1 515 | 1 249 | 1 288 | 1 291 | 2,7 % |
| spéciaux/secteurs (`doom_specials`) | 388 | 914 | 1 366 | 842 | 585 | 731 | 1,5 % |
| tables carte (`doom_map`, `doom_things`) | 482 | 477 | 470 | 799 | 467 | 551 | 1,1 % |
| wrapper `doom_run` (boucle de commandes) | 154 | 154 | 154 | 154 | 154 | 154 | 0,3 % |
| sérialisation/hachage, snapshot | 0 | 0 | 0 | 0 | 0 | 0 | 0 (frontière, §6) |

p99 par poste (steps/tic) :

| Poste | idle | walk | door | fight | death |
|---|---:|---:|---:|---:|---:|
| physique/collision | 7 102 | 42 258 | 64 597 | 95 919 | 45 546 |
| monstres/IA | 16 891 | 18 021 | 35 178 | 28 694 | 32 081 |
| boucle doom_game | 2 541 | 23 643 | 30 072 | 24 076 | 23 624 |
| check_sight | 768 | 6 888 | 7 108 | 5 976 | 7 142 |
| spéciaux/secteurs | 1 106 | 3 329 | 5 552 | 3 523 | 3 171 |
| joueur | 1 210 | 1 525 | 1 816 | 2 488 | 1 603 |

Le poste « physique » agrège ce que les monstres éveillés et le joueur
appellent (`check_position`, `try_move`, `lines_in_cell`…) ; le poste
« monstres » contient le ticker lui-même, ses balayages de liste et l'IA. Vue
par **étape séquentielle** de `step_tic` (cumulatif de chaque étape, disjoint
entre étapes) :

| Étape de `tic.cairo` | idle | walk | door | fight | death | agrégat |
|---|---:|---:|---:|---:|---:|---:|
| 7. `monsters_ticker_with_defense` | 21 582 | 33 264 | 35 893 | 47 943 | 35 811 | 35 020 |
| 6. `rebuild_list` (patches + clip) | 0 | 8 761 | 13 577 | 5 749 | 4 004 | 5 170 |
| 5. `player_mobj_thinker_boxed` | 288 | 2 279 | 7 693 | 1 178 | 2 059 | 2 125 |
| 3. `player_think` | 1 235 | 1 347 | 1 568 | 3 453 | 1 312 | 1 837 |
| 9. `specials_ticker` | 216 | 1 181 | 2 036 | 691 | 594 | 768 |
| `ctx_of` (contexte du tic) | 517 | 517 | 517 | 517 | 517 | 517 |
| 8. `apply_monster_events_boxed` | 187 | 195 | 221 | 1 001 | 199 | 389 |
| 9. `refresh_heights` | 33 | 471 | 836 | 252 | 214 | 285 |
| 2. `player_in_special_sector` | 238 | 222 | 222 | 230 | 232 | 231 |
| 4. `apply_player_events_boxed` | 198 | 198 | 203 | 217 | 198 | 203 |
| `moving_sectors`, `place_drops`, `height_clip`, `reconcile_player` | 254 | 360 | 445 | 307 | 299 | 316 |
| reste (`step_tic` propre, boucle `step_tic_impl`) | 1 638 | 1 708 | 1 717 | 1 689 | 1 697 | 1 685 |

## 4. Top 15 des fonctions par replay (propriétaire disjoint, steps/tic)

Agrégat des cinq replays (2 946 tics) :

| # | Fonction | steps/tic | part |
|---:|---|---:|---:|
| 1 | `doom_monsters::think::monsters_ticker_in` (boucle propre) | 4 326 | 8,9 % |
| 2 | `doom_monsters::think::next_actor` | 4 185 | 8,6 % |
| 3 | `doom_monsters::think::awake_count` | 3 819 | 7,9 % |
| 4 | `doom_physics::mobj::has` | 3 815 | 7,9 % |
| 5 | `doom_game::tic::clip_patches` | 2 416 | 5,0 % |
| 6 | `doom_monsters::actions::look_for_players_in` | 1 510 | 3,1 % |
| 7 | `doom_game::level::contains` | 1 389 | 2,9 % |
| 8 | `doom_game::tic::step_tic` (propre) | 1 377 | 2,8 % |
| 9 | `doom_game::tic::copy_patched` | 1 311 | 2,7 % |
| 10 | `doom_physics::mobj::first_free` | 1 255 | 2,6 % |
| 11 | `doom_physics::maputl::rd32` | 1 184 | 2,4 % |
| 12 | `doom_monsters::think::mobj_thinker_in` | 1 075 | 2,2 % |
| 13 | `doom_physics::movement::check_position_in` | 848 | 1,7 % |
| 14 | `doom_physics::movement::lines_in_cell` | 844 | 1,7 % |
| 15 | `doom_physics::maputl::rd` | 829 | 1,7 % |

Par replay :

| # | idle | walk | door | fight | death |
|---:|---|---|---|---|---|
| 1 | `monsters_ticker_in` 4 625 | `monsters_ticker_in` 4 559 | `clip_patches` 7 139 | `mobj::has` 4 229 | `monsters_ticker_in` 4 468 |
| 2 | `next_actor` 4 182 | `clip_patches` 4 399 | `monsters_ticker_in` 4 366 | `next_actor` 4 190 | `next_actor` 4 188 |
| 3 | `awake_count` 3 794 | `next_actor` 4 180 | `next_actor` 4 181 | `awake_count` 3 862 | `awake_count` 3 813 |
| 4 | `mobj::has` 3 572 | `awake_count` 3 799 | `level::contains` 4 127 | `monsters_ticker_in` 3 720 | `mobj::has` 3 715 |
| 5 | `look_for_players_in` 1 704 | `mobj::has` 3 682 | `mobj::has` 3 848 | `mobj_thinker_in` 3 241 | `clip_patches` 1 820 |
| 6 | `tic::step_tic` 1 328 | `level::contains` 2 512 | `awake_count` 3 815 | `lines_in_cell` 2 589 | `first_free` 1 739 |
| 7 | `maputl::rd32` 759 | `copy_patched` 1 771 | `copy_patched` 2 200 | `check_position_in` 2 274 | `look_for_players_in` 1 603 |
| 8 | `a_look_in` 754 | `look_for_players_in` 1 662 | `Occupancy::nofit` 1 605 | `copy_patched` 2 204 | `tic::step_tic` 1 369 |
| 9 | `run_chain` 478 | `first_free` 1 483 | `look_for_players_in` 1 541 | `clip_patches` 2 200 | `sight_cell` 1 320 |
| 10 | `check_sight_cached` 322 | `tic::step_tic` 1 396 | `first_free` 1 460 | `first_free` 1 710 | `maputl::rd32` 1 160 |
| 11 | `player_mobj_thinker_boxed` 288 | `sight_cell` 1 259 | `maputl::rd32` 1 419 | `line_box_rejects` 1 666 | `crossing_fraction` 1 160 |
| 12 | `calc_height_in` 269 | `crossing_fraction` 1 258 | `tic::step_tic` 1 409 | `maputl::rd32` 1 576 | `copy_patched` 1 098 |
| 13 | `map::reject_of` 255 | `maputl::rd32` 1 077 | `maputl::rd` 1 154 | `tic::step_tic` 1 408 | `level::contains` 1 047 |
| 14 | `level::ctx_of` 226 | `maputl::rd` 880 | `check_position_in` 1 151 | `check_things_in_cell` 1 393 | `maputl::rd` 1 030 |
| 15 | `specials_ticker` 202 | `Occupancy::nofit` 845 | `lines_in_cell` 1 084 | `level::contains` 1 262 | `line_box_misses` 926 |

Coûts cumulatifs utiles (recouvrants, steps/tic) :

| Fonction | idle | walk | door | fight | death |
|---|---:|---:|---:|---:|---:|
| `a_look_in` (dormants qui regardent) | 3 812 | 12 439 | 10 061 | 3 869 | 13 237 |
| `check_sight_cached` | 1 217 | 9 930 | 8 173 | 2 830 | 10 829 |
| `sight_trace` (traversée réelle) | 571 | 9 260 | 7 533 | 2 347 | 10 188 |
| `a_chase_in` | 0 | 0 | 2 970 | 18 597 | 928 |
| `p_move_in` | 0 | 0 | 2 120 | 15 945 | 772 |
| `new_chase_dir_in` | 0 | 0 | — | 9 724 | — |
| `check_position_in` (tous appelants) | 0 | 1 547 | 6 432 | 14 773 | 1 961 |
| `lines_in_range` / `lines_in_cell` | 0 | — | 2 974 / 2 498 | 7 398 / 6 290 | 784 / — |
| `things_in_range` | — | — | — | 2 987 | — |
| `xy_movement` (joueur, marche/glissade) | 0 | 1 699 | 7 659 | — | 1 923 |
| `slide_move_in` | 0 | 0 | 3 767 | — | 0 |
| `rebuild_list` → `clip_patches` | 0 | 6 896 | 11 250 | 3 448 | 2 853 |
| `awake_count` | 5 532 | 5 537 | 5 557 | 5 613 | 5 556 |
| `next_actor` | 6 043 | 6 035 | 6 028 | 6 048 | 6 038 |
| `first_free` | 0 | 2 080 | 2 048 | 2 397 | 2 439 |
| `player::weapon::shoot` / `aim_line_attack` | — | — | — | 2 235 / 1 803 | — |

(« — » : hors du top 60 conservé par le script, donc < ~600 steps/tic.)

## 5. Lecture par poste : causes et optimisations

### 5.1 Le balayage complet de la liste, à chaque tic — le poste dominant

Les quatre premières lignes de l'agrégat (`monsters_ticker_in`, `next_actor`,
`awake_count`, `has`) plus la part de `rd32` qu'elles appellent font
**≈ 17 000 steps sur chaque tic**, idle compris (16 900 des 26 400 steps d'un tic
idle, 64 %). Ce ne sont ni des attaques ni des raycasts : ce sont deux passes sur
les 210 slots de la liste, à ~40 steps le slot, pour 29 monstres et ~180 slots
passifs (décors, objets, cadavres) :

- `awake_count` (3 819 + ~1 200 de `has`/`rd32`) : `pop_front`, trois lectures
  (`flags`, `state`, `health`) et `rd32(action_id)` sur chacun des 210 slots pour
  compter les éveillés avant de placer la fenêtre D3 ; 424 `store_temp<Span>`,
  423 `RangeCheck`, 601 `jump` par tic.
- `next_actor` (4 185) : recopie de chaque slot passif (`pop_front`, test
  `kind == KIND_NONE`, `has(flags, COUNTKILL|MISSILE)` = builtin bitwise + `!= 0`,
  `append`), avec 482 `store_temp<Span<Box<Mobj>>>` et 482 `store_temp<Array>`
  par tic : la boucle est une fonction qui repousse ses deux conteneurs vivants à
  chaque itération.
- `monsters_ticker_in` propre (4 326) : ~21 steps par slot de plomberie de boucle
  (2 223 `store_temp`, dont 750 de `Mobj` et 242 de `Span<Box<Mobj>>`, 821
  `into_box` pour les dormants dont le countdown change).
- `has` (3 815) : ≈ 600 tests de bit par tic, 6 steps chacun (`u32_bitwise` 932
  + `u32_is_zero` 466 + `store_temp` 1 665).

D33 a supprimé la **copie des 27 felts** des acteurs inchangés (−24 % sur idle),
mais pas le **parcours** : chaque tic touche encore les 210 pointeurs deux fois,
plus une troisième fois dans `first_free` dès qu'un monstre est éveillé
(1 255 en moyenne, 2 400 en combat : recherche d'un slot libre pour un missile
qui, la plupart du temps, ne sera jamais tiré), et une quatrième dans
`clip_patches`/`contains` dès qu'un plan bouge (§5.3).

**Optimisation O1 — liste d'acteurs dérivée et copie par tranches.** Dériver à
`from_felts` (et maintenir au fil des tics : spawn/retrait de missile, mort)
une liste interne des indices « à nous » (`MF_COUNTKILL | MF_MISSILE`,
~30 entrées) et la porter dans `GameState` sans la sérialiser (état dérivé,
comme les hauteurs de secteur). Le ticker n'itère plus que sur ces indices, dans
l'ordre des slots ; la liste de sortie est reconstruite par `append_span` des
tranches inchangées (le coût mesuré de `copy_patched` : ~2 200 steps pour 210
pointeurs, ~10 steps/pointeur) ; `awake_count` ne lit que les ~30 acteurs ;
`first_free` peut être porté par la même structure dérivée (premier slot
`KIND_NONE`). Gain estimé : 17 000 → ~3 500 (copie 2 200 + 30 acteurs × ~40),
**−13 000 à −14 000 steps/tic sur tous les tics**, −1 200 de plus en moyenne
pour `first_free`. Effet : moyenne 48,5 k → ~34 k ; idle 26,4 k → ~12,5 k ; p99
122,9 k → ~109 k. Risque déterminisme : nul si la liste dérivée est exactement
l'ensemble des acteurs en ordre d'index (c'est la définition de `next_actor`) ;
le schéma 2, la grille, les patches et les événements ne changent pas. Risque
taille : une structure de plus dans l'état et un adaptateur de reconstruction
(+1 à 2 k mots à mesurer, D29). Variante O1b : scinder en interne la liste en
« slots statiques » (décors jamais modifiés) et « slots dynamiques » pour que la
copie des statiques soit une copie de `Span` (2 felts) : −2 000 de plus, mais un
index indirect dans `read_mobj`, la grille et le rendu — plus intrusif.

### 5.2 Les monstres éveillés : `A_Chase` → `P_Move` → `check_position`

En combat, la fenêtre D3 place jusqu'à huit `A_Chase` par tic ; `a_chase_in`
coûte 18 600 steps/tic cumulés, dont `p_move_in` 15 900 et `new_chase_dir_in`
9 700 (jusqu'à six `try_walk`, chacun un `check_position` complet, quand la
direction courante est bloquée). Sous eux, `check_position_in` 14 800/tic :
`lines_in_range`/`lines_in_cell` 7 400 (une à quatre cellules du blockmap, tous
leurs linedefs testés : `rd(l_box)` + `line_box_rejects` 1 900, avec 869
`u128_safe_divmod` par tic pour déballer les boîtes empaquetées, puis
`box_on_line_side`, `line_opening`) et `things_in_range` 3 000. La boucle
`lines_in_cell` porte un `LineFold` de douze felts : 2 038 `store_temp` par tic
(dont 665 `u32`, 321 `UnitBox`, 279 `Fixed`) pour 101 comparaisons de ligne.
`mobj_thinker_in` (3 241 propre) paie 542 `store_temp<Mobj>` et 452
`store_temp<Fixed>` par tic pour ouvrir/refermer la boîte de l'acteur autour de
`xy_movement`/`z_movement`. Le p99 du poste physique en combat est 95 900 :
c'est **le** poste du p99 (tics où plusieurs monstres cherchent une direction).

**O2 — micro-optimisations physiques (équivalentes).** (a) Tester la boîte
empaquetée en arithmétique de corps plutôt qu'en `u128_safe_divmod` (quatre
divisions par ligne aujourd'hui), ou déballer une fois par cellule les champs
lus plusieurs fois ; (b) réduire l'état vivant de `lines_in_cell` (porter
`LineFold` dans une `Box` et n'en extraire que le blocage/les quatre bornes) ;
(c) éviter le rebox de `mobj_thinker_in` quand rien ne bouge. Gain estimé : 20 à
30 % de `lines_in_cell` + `line_box_rejects` + `rd` + `mobj_thinker_in`, soit
**−2 000 à −3 000 steps/tic en combat, −1 000 en moyenne**. Risque : nul sur les
résultats si les prédicats restent identiques (les S7/S14 imposent l'oracle sur
tout le domaine) ; taille neutre à légèrement négative.

**A1 — algorithmique : fenêtre D3.** Le coût des éveillés est ~26 000 steps/tic
en combat (47 900 de ticker contre 21 600 idle). Passer la fenêtre de 8 à 4
diviserait ce coût par ~2 : −13 000 en moyenne sur `fight`, −40 000 à −50 000
sur son p99. **C'est un changement de gameplay** (D3 fixe huit éveillés ;
la vanille les pense tous), pas une optimisation équivalente : goldens, D14 et
identités de replay changent.

### 5.3 `rebuild_list` pendant un mouvement de plan : `clip_patches` et `contains`

Dès qu'une porte ou un ascenseur bouge, `rebuild_list` appelle `clip_patches`,
qui lit le secteur des 210 slots et appelle `contains(clip, sector)` (une boucle
sur un `Span<u32>` de 1–3 éléments, 6 steps/slot rien qu'en `store_temp<Span>`)
pour chacun : 11 250 steps/tic cumulés sur `door`, 6 900 sur `walk` (ascenseur),
2 400 + 1 400 en moyenne. `Occupancy::nofit`, posé par `specials_ticker` par
plan en mouvement, rebalaye aussi la liste (1 600 sur `door`). Ce sont
`P_ChangeSector` transcrits par balayage complet alors que vanilla passe par le
blockmap (`P_BlockThingsIterator` sur la boîte du secteur).

**O3 — clip et `nofit` par cellules.** Précalculer par secteur (table `doom_map`,
~182 entrées empaquetées) la plage de cellules de sa boîte, et ne visiter que
`things_in(cell)` de la grille, avec le même test « centre dans le secteur ».
Gain : 11 250 → ~1 500 sur `door`, **−3 500 à −4 000 steps/tic en moyenne**,
−10 000 sur le p99 de `door`/`walk`. Risque déterminisme : **à vérifier** — la
version actuelle clippe aussi les objets hors blockmap (`MF_NOBLOCKMAP`) s'il en
existe dans un secteur mobile ; il faut contrôler sur E1M1 que l'ensemble visité
est identique (sinon les goldens `door`/`walk` changent, ce qui serait une
correction de fidélité, à décider, pas une optimisation). Variante minimale sans
table : remplacer `contains` par un test sur un masque de secteurs construit une
fois par tic et fusionner le balayage dans la passe du ticker (qui visite déjà
chaque slot) : −2 500 en moyenne, aucune question de sémantique.

### 5.4 Les dormants qui regardent : `A_Look` et `check_sight`

29 dormants avec cadence 1/4 = ~7 `A_Look` par tic ; le cache R2-A3 (TTL 8)
laisse une traversée par dormant tous les 8 tics, soit ~3,6 `sight_trace` par
tic dès que le joueur est dans le champ possible : 9 300–10 200 steps/tic sur
`walk`/`death` (REJECT ne répond « non » qu'en idle : 571). Une traversée coûte
~2 500–3 000 steps : `sight_cell` (`rd`, `line_box_misses`, `crosses_sight`,
`crossing_fraction` avec 431 `u128_safe_divmod`/tic, `line_opening`, deux
`fixed::div`). Le poste est petit en moyenne (1 250 propre, ~10 000 cumulés
sur deux replays) mais il est incompressible sans changer l'algorithme, comme
D29 l'avait noté.

**O4 — micro (équivalent)** : mêmes leviers qu'O2 sur `sight_cell` (déballage,
état vivant) : −20 % ≈ **−2 000 steps/tic sur `walk`/`death`, −1 000 en
moyenne**. **A2 — algorithmique** : cadence 1/8 ou TTL 16 divise le poste par
deux (−5 000 sur `walk`/`death`, −2 500 en moyenne), mais retarde le réveil des
monstres : changement de gameplay, comme A1. Un cache exact « positions et
hauteurs inchangées ⇒ verdict inchangé » serait équivalent, mais il ne sert que
quand le joueur ne bouge pas, c'est-à-dire en idle où REJECT répond déjà.

### 5.5 Joueur, spéciaux, boucle

Le joueur coûte 1 300 propre / 1 800 cumulés (3 450 en combat : `shoot`
2 235, `aim_line_attack` 1 800) ; `player_mobj_thinker_boxed` monte à 7 700 sur
`door` à cause de `slide_move_in` (3 800) et `xy_movement` (7 700 cumulés) contre
les murs. `specials_ticker` + `refresh_heights` + `player_in_special_sector`
restent ≤ 3 100 même sur `door`. Le propre de `step_tic` (1 377 : 801
`store_temp`, dont `Mobj` 148, `Player` 144, `SpecialsState` 135, et 253
`into_box`) + `ctx_of` (517) + la boucle `step_tic_impl` (~300) forment un
**plancher d'environ 2 200 steps/tic** de plomberie. Rien de dominant ici :
tout gain y est < 1 000.

## 6. Coût de `step_tic` hors tic : sérialisation, parseur, snapshot

Un appel `step_tic` paie **266 500 (idle) à 278 400 (door) steps hors tic**, soit
5 à 10 tics de calcul utile, quel que soit le nombre de tics du chunk :

| Fonction (cumulatif, steps/appel) | idle | door | Fonction (propriétaire disjoint) | idle | door |
|---|---:|---:|---|---:|---:|
| `__executable_wrapper__step_tic` (dont parseur d'arguments ≈ 20 000) | 266 469 | 278 391 | `state::read_mobj` | 32 970 | 33 001 |
| `state::from_felts` | 149 298 | 157 320 | `grid::canonical_order` | 27 447 | 27 393 |
| `state::read_mobjs` (210 × 27 felts validés) | 76 263 | 76 454 | `state::fixed_of` (7 × 210 conversions `u64`) | 21 060 | 21 104 |
| `state::read_grid` (`read_members` 31 250, `mark_member` 11 594) | 49 395 | 48 981 | `render::push_mobjs` | 20 211 | 20 108 |
| `state::serialize` | 52 230 | 52 155 | `wire::append_block` (sortie par blocs de 64) | 17 536 | 17 498 |
| `render::snapshot` | 39 755 | 41 073 | `state::read_members` | 15 036 | 14 902 |
| `level::materialise_heights` (+ `specials::moving`/`floor_of`/`ceiling_of`) | 20 237 | 28 384 | `state::valid_mobj` | 13 230 | 13 231 |
| `wire::FeltsSerde::serialize` | 19 675 | 19 732 | `mobj::push_felts` | 12 180 | 12 194 |
| `ThingGridDestruct` (squash du dictionnaire) | 5 047 | 7 646 | `mobj::is_removed` / `render::count_live` | 5 248 / 2 559 | 5 235 / 2 557 |

Pour le programme prouvé `run_segment`, `snapshot` et la sortie wire sont
remplacés par deux hachages Poseidon de l'état (~120 000 chacun, S8), soit
≈ 150 000 (`from_felts`) + 52 000 (`serialize`) + 240 000 (hash) ≈ **440 000
steps par segment** : à 32 tics par segment, c'est ~13 800 steps/tic — plus que
la cible D2 elle-même ; à 128 tics, ~3 400. D2 ne compte pas cette frontière ;
le prouveur, si. Les leviers sont connus (lecteurs spécialisés qui gardent les
contrôles : `fixed_of` fait un `u64` `try_into` puis une comparaison par felt ;
`canonical_order` reparcourt la grille ; `read_members` valide chaque cellule)
et valent 20–30 % de `from_felts`, mais ne touchent pas D2.

## 7. Conclusion : D2 à 12 000 / 25 000 est-il atteignable ?

Bilan des micro-optimisations **équivalentes** (résultats, goldens, D14 et
règles inchangés), en steps/tic sur l'agrégat de 2 946 tics :

| Piste | Moyenne | p99 (dominé par `fight`/`door`) | Risque |
|---|---:|---:|---|
| O1 liste d'acteurs dérivée + copie par tranches (+ `first_free`) | −14 000 | −14 000 | déterminisme nul ; +1–2 k mots à mesurer |
| O3 clip/`nofit` par cellules (ou masque + fusion dans la passe) | −3 500 (−2 500) | −10 000 sur `door`, ~−3 000 agrégat | sémantique `NOBLOCKMAP` à vérifier |
| O2 micro physique (`lines_in_cell`, boîtes, rebox) | −1 000 | −3 000 | nul |
| O4 micro `sight_cell` | −1 000 | −2 000 | nul |
| §5.5 plomberie boucle/joueur | −500 | −500 | nul |
| **Total micro** | **≈ −20 000 → ~28 500** | **≈ −30 000 → ~93 000** | |

Le moteur micro-optimisé resterait donc **2,4× au-dessus de la moyenne D2 et
3,7× au-dessus de son p99**. Le plancher structurel d'un tic après O1–O4 est
d'environ 8 000–9 000 steps (copie 2 200, plomberie 2 200, joueur 1 300,
spéciaux/contexte 1 000, ~7 `A_Look` avec REJECT 1 500) : un tic idle peut
descendre vers 12 000, mais **tout tic où un monstre marche coûte ≥ 3 300 steps
par pas** (`P_Move` mesuré) et jusqu'à ~20 000 quand il cherche une direction ;
avec huit éveillés, le p99 ne peut pas passer sous ~60 000 sans changer
l'algorithme ou la cadence.

Pistes **algorithmiques** et ce qu'elles peuvent donner, en plus des micros :

| Piste | Moyenne | p99 | Nature |
|---|---:|---:|---|
| A1 fenêtre D3 8 → 4 éveillés | −5 000 (−13 000 sur `fight`) | −40 000 à −50 000 | gameplay (D3), goldens changent |
| A2 cadence `A_Look` 1/4 → 1/8 ou TTL 16 | −2 500 | −3 000 | gameplay (réveil retardé) |
| A3 blockmap plus fin (64 u) ou listes par cellule dédupliquées | −3 000 à −5 000 | −10 000 à −15 000 | équivalent si l'ensemble de lignes testé est le même ; tables plus grosses (D29) |
| A4 REJECT / `check_sight` : déjà utilisé ; un LUT secteur-secteur n'est pas exact | ~0 | ~0 | — |
| D33 liste boxée : déjà intégrée ; le reste est O1 | — | — | — |

Avec O1–O4 + A1 + A2 + A3 : moyenne **≈ 18 000–20 000**, p99 **≈ 40 000–
50 000**. D2 tel qu'écrit (12 000 / 25 000) **n'est atteignable ni par
micro-optimisations ni par les changements algorithmiques listés sans réduire
davantage le gameplay** (fenêtre ≤ 3, cadence ≤ 1/8) ou sans réécrire la
collision (par exemple un `check_position` incrémental qui ne reteste que les
lignes des cellules changées, ~2× sur la physique, non chiffré ici). La
recommandation est double : (1) engager O1 puis O3, qui rendent −17 000 à
−18 000 steps/tic à gameplay strictement identique et ramènent idle sous
13 000 ; (2) soumettre à décision soit la révision de D2 vers une cible
mesurable après O1/O3 (de l'ordre de 25 000 en moyenne / 70 000 au p99 avec
la fenêtre à 8), soit un changement explicite de D3 (fenêtre, cadence) avec
regénération des goldens comme changement de gameplay assumé. Le coût de
frontière par segment (§6) doit entrer dans le même arbitrage : à 32 tics par
segment il pèse autant qu'un tic entier de la cible D2.

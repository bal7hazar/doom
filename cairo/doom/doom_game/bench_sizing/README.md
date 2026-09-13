# Réduction du consommateur et des frontières — 2026-09-13

Base immuable `50e3c2f933c15ddce2ffef08f0c1e26235ed6eb6`, sources mesurées
`f8f7417` (`2e37ad0` lecteur, `f2c8dbc` contextes, `f8f7417` ABI/genesis).
Cette passe n'intègre pas la branche d'optimisation du ticker monstres.
Aucun budget, golden, règle de jeu, fréquence, plafond d'éveillés, schéma 2,
ordre de grille ou champ D14 ne change.

**Gain partiel : −4 966 mots proving sur run_segment (−4,27 %) et −13 025
steps sur la frontière vide (−4,52 %).** La cible D29 de 100 000 mots reste
manquée de 11 321 mots. Le plafond dur de 120 000 est respecté. La passe
reste 34 mots sous l'objectif indicatif de 5 000 mots retirés et loin de
−25 % de frontière ; aucun seuil n'a été déplacé. D2 et R5 restent ouverts.

## Changements et expériences

Les essais successifs utilisent le même état initial et les mêmes entrées
opaques des vrais exécutables, dans le profil proving Scarb 2.16.0. La table
indique les totaux, pas la taille d'un microprogramme spécialisé.

| État successif | run_segment, mots | step_tic vide, steps | step_tic 4 marches, steps |
|---|---:|---:|---:|
| Base | 116 287 | 288 048 | 569 048 |
| Retours privés Option<Box<Player/SpecialsState/GameState>> | 115 733 | 288 221 | 569 221 |
| Reader avec Span restant, multi_pop_front du Mobj | 114 799 | 278 755 | 559 755 |
| Blocs joueur/lumières/movers et bornes étroites de valid_specials | 113 920 | 278 319 | 559 319 |
| Contextes partagés Box<Ctx/MonsterCtx/World> | 111 741 | 278 319 | 554 935 |
| Patches étroits, blocs ABI et genesis sans sérialisation répétée | **111 321** | **275 023** | **551 751** |

Le lecteur ne garde plus de compteur `pos` à vérifier/incrémenter à chaque
felt. `multi_pop_front` vérifie les longueurs de 36/27/8/7 felts ; toutes les
conversions u32, bool, Fixed, santé signée et validations croisées demeurent.
La longueur totale, la taille déclarée des specials et l'absence de reste
sont toujours contrôlées. Les trois retours privés sont boxés pour que les
sorties d'erreur ne transportent plus de larges variantes Option. Leur taxe
isolée de 173 steps est explicitement incluse dans le gain combiné.

Les boucles d'événements partagent les contextes immuables créés une fois au
début du tic. Les fonctions publiques conservent leurs paramètres par valeur
et adaptent vers les helpers privés. Les patches gardent le même tri et la
même règle « le dernier remplacement gagne ». Le boxing d'un patch ajoute
28 steps au cas simple observé d'un tic qui reconstruit le roster ; le gain
de programme de cet essai est 420 mots et les cinq replays complets restent
plus rapides au total. Le microbenchmark d'une reconstruction passe de
13 698 à 13 680 steps ; ces mesures décrivent des chemins différents.

Le transport `[len, felts...]` utilise directement `multi_pop_front::<64>`
pour copier ses blocs. `genesis_impl` calcule son hash sur la sérialisation
qu'il retourne déjà. Le hash d'état reste Poseidon ; ceci ne modifie ni le
hash du programme Blake ni les paramètres du prover.

Deux essais ont été abandonnés, avec copies et mesures sous
`/tmp/hellproof-game-boundary-sizing` :

- Validation de chaque Mobj via un helper Box non inliné : **+12 mots et
  +2 520 steps par lecture** par rapport à l'essai contextes. Aucun bénéfice.
- État complet boxé autour du runner générique et de sa boucle de tics :
  seulement **−10 mots run_segment**, mais **+486 steps sur quatre tics** et
  un `Destruct<Box<GameState>>` explicite nécessaire pour le dict. Le gain
  ne justifie pas cette nouvelle interface et ce ralentissement.

## Tailles et appels réels

| Exécutable | Dev avant | Dev après | Proving avant | Proving après |
|---|---:|---:|---:|---:|
| run_segment | 136 861 | 130 254 | 116 287 | 111 321 |
| step_tic | 137 102 | 130 379 | 117 839 | 112 807 |
| genesis | 52 036 | 51 742 | 47 563 | 47 426 |

Le runner exact `prover/sim` (cairo-lang 2.19.4) renvoie trois steps de moins
que Scarb 2.16 sur ces appels proving. Les sorties sont intégralement
égales. Les chiffres ci-dessous viennent de SimProgram, sans bootloader :

| Appel proving | Steps avant | Steps après |
|---|---:|---:|
| genesis | 819 777 | 763 489 |
| step_tic, 0 mot | 288 045 | 275 020 |
| step_tic, 1 idle | 344 673 | 330 763 |
| step_tic, 1 marche | 360 965 | 346 872 |
| step_tic, 4 marches | 569 045 | 551 748 |
| run_segment, 0 mot | 412 320 | 402 591 |
| run_segment, 1 idle | 468 975 | 458 361 |
| run_segment, 4 marches | 693 422 | 679 421 |

Mesures différentielles du harnais existant (`n=4/8`, scène idle tic 300) :
hash **120 814 inchangé**, snapshot **39 495 inchangé**, sérialisation +
lecture **226 638 → 216 909**, tic entier de cette scène **53 006**.
Le benchmark complet des 22 opérations retourne 1, uniquement pour les
trois dépassements historiques : hash idle, serde idle, hash fight
(122 986 steps). Les seuils restent inchangés ; aucune nouvelle opération
ne dépasse sa limite enregistrée.
Même l'idle marginal reste très au-dessus de D2 (12 000 steps/tic moyen).
La p99 exacte du nouveau code n'est pas remesurée par cette passe : les
moyennes de chunks ne sont pas une p99. S8 garde le profil exact de la base.

À un appel natif par tic, un idle coûte encore **330 763 × 35 = 11 576 705
steps/s**, hors rendu navigateur. Ce résultat ne valide pas R5. Aucune
preuve lourde n'a été exécutée ni aucun résultat AIR extrapolé des steps VM.

## Attribution du programme proving

`attribute.py` compile seulement la correspondance Sierra→CASM avec l'outil
épinglé `infra/sierra_words`. Attribution à la fonction source la plus
interne ; constantes partagées et en-tête comptés séparément.

| Source interne | Avant | Après |
|---|---:|---:|
| core | 45 642 | 45 167 |
| doom_game | 13 960 | 9 550 |
| doom_physics | 11 561 | 11 561 |
| doom_player | 6 693 | 6 618 |
| doom_monsters | 6 388 | 6 388 |
| doom_specials | 5 306 | 5 302 |
| doom_run | 86 | 86 |
| Autres génériques / fonctions non attribuées | 3 685 | 3 683 |
| Constantes partagées et en-tête | 22 966 | 22 966 |
| **Total** | **116 287** | **111 321** |

Les différences player/specials viennent de leur code inliné par game ;
leurs sources ne changent pas. Sur les 45 642 mots core de la base, **9 092**
ont effectivement un appelant game/run dans leur pile d'inlining. Cette
part passe à **8 617**. Le reste est atteint depuis les autres composants,
et ne peut pas être retiré par une simple retouche du lecteur d'état.

Avant : next_u32 1 606 mots core, next 1 183, read_mobj 607, step_tic 468,
fixed_of 450, next_fixed 384. Après : read_player 884, fixed_of 855,
step_tic 781, read_mobj 549, read_state 423, next_u32 420. Le déplacement
d'une partie des validations vers les lecteurs de blocs change leur
appelant attribué ; ces valeurs sont du bytecode, pas des temps de calcul.
Les JSON conservent les répartitions complètes.

## Journal long et chantier suivant

Le journal reste non sérialisé et sans accumulation entre segments. Dans
un segment très long, son coût reste linéaire. Le harnais `journal.py`
répète unlink/link dans la cellule singleton du joueur : l'ordre final et
le hash restent rigoureusement identiques. Le coût de construction est
mesuré séparément, puis soustrait avant d'attribuer le coût au hash.

| Paires unlink/link supplémentaires | Construction, steps | Hash à la frontière, steps |
|---|---:|---:|
| 0 | 628 746 | 120 800 |
| 64 | 638 026 | 124 000 |
| 1 000 | 773 746 | 170 800 |
| 10 000 | 2 078 746 | 620 800 |

Cela donne **25 steps par entrée historique supplémentaire**, même si elle
ne modifie finalement aucune donnée engagée. La taille du journal n'est
pas bornée ici : le planificateur doit comptabiliser cette dette dans son
coût de frontière. Une compaction périodique devrait payer un parcours et
une nouvelle squash dans un tic ; elle nécessite un profil de latence
avant d'être retenue. Cette passe ne remplace pas silencieusement le
journal par un ordre normalisé, qui casserait C2.

Le prochain levier proposé par l'orchestrateur, hors de cette passe, est
un roster interne `Span<Box<Mobj>>`. Les 210 × 27 felts restent requis à la
sérialisation, mais les tics pourraient recopier seulement 210 pointeurs et
matérialiser les acteurs modifiés. `Box<Mobj>` est Copy/Drop. L'obstacle est
la propagation de `Span<Mobj>` dans toutes les APIs physique/joueur/monstres,
les patches et les tests : matérialiser le roster avant chaque appel
annulerait le gain. Il faut migrer les lectures et retours ensemble, puis
comparer les sorties brutes événements/grille/RNG en plus des replays.
Baisser le nombre d'éveillés ne supprimerait pas la taxe des slots inactifs.

## Validation et reproduction

- 60 tests game (57 existants + 3 tests systématiques de domaines/troncatures
  joueur et specials), 7 run, 31 physics : verts.
- 35 cas SimProgram avant/après par profil **dev et proving**, plus les
  quatre enveloppes ABI invalides rejetées dans les deux versions.
- Cinq replays : idle 700, walk 350, fight 700, door 350, death 846 tics
  effectivement exécutés. Chaque felt des états, snapshots, statuts et D14
  est comparé ; 48 frontières sérialisées 29/113/47 et les runs entiers
  atteignent les mêmes sorties. 70 appels par profil, aucun golden réécrit.
- Format Cairo, compilation Python et garde de taille exécutés. Le garde D29
  retourne 1 au seuil inchangé. REUSE couvre tous les nouveaux fichiers ;
  le lint global de cette base signale trois expressions SPDX préexistantes
  dans `gen_things.py`, `doomruns_model.py` et `real_batch.py`, hors périmètre.
- Aucun paramètre de budget ni fichier physique ne change.

Depuis le dépôt :

```sh
ASDF_SCARB_VERSION=2.16.0 scarb --manifest-path cairo/Scarb.toml test -p doom_game
ASDF_SCARB_VERSION=2.16.0 scarb --manifest-path cairo/Scarb.toml test -p doom_run
ASDF_SCARB_VERSION=2.16.0 scarb --manifest-path cairo/Scarb.toml test -p doom_physics
python3 cairo/doom/doom_run/bench/size.py  # doit rester rouge au seuil D29
SIM_PROBE=/chemin/sim-probe-lines python3 cairo/doom/doom_game/bench_boundary/measure.py \
  --executables cairo/target/proving --reference /chemin/reference/proving --json /tmp/abi.json
python3 cairo/doom/doom_game/bench_sizing/compare.py --reference /chemin/reference \
  --profile proving --json /tmp/replays.json  # répéter avec --profile dev
python3 cairo/doom/doom_game/bench_sizing/attribute.py \
  --sierra cairo/target/proving/run_segment.executable.sierra.json \
  --executable cairo/target/proving/run_segment.executable.json \
  --tool infra/sierra_words/target/release/sierra_words --json /tmp/words.json
python3 cairo/doom/doom_game/bench_sizing/journal.py --json /tmp/journal.json
```

La référence est une copie préalable des exécutables et de leur Sierra
sous `reference/dev` et `reference/proving`. Le comparateur exécute ces
copies avec `--no-build` et un `SCARB_TARGET_DIR` distinct ; il ne reconstruit
pas la base. Ne pas compiler vers un target en cours de comparaison.

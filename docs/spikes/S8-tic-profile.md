# S8 — jeu assemblé, frontières réelles et preuve feuille

Audit du 13 septembre 2026. Les chiffres de référence ci-dessous portent sur
`df1888dc5871c49c6991e9690073e2807a1b8048` : jeu réel, correction C2/schema 2,
optimisations de style monstres et joueur intégrées. Le manifest d'annotation
Sierra `34325ff` ne change pas le code. Les optimisations de frontière et le
correctif d'armure par impact sont une seconde ligne, à mesurer séparément.

**D2 n'est pas atteint** : le tic complet coûte 52–105 k steps en moyenne
selon le replay, et les p99 dépassent 25 k. **D29 n'est pas atteint** : le
programme prouvé fait 117 531 mots pour un budget de 100 000. Une preuve
native et une preuve WASM réelles ont été vérifiées localement avec Blake,
mais leurs claims exigent log21 : le registre de production log20 ne convient
pas. L'expérience séparée `doom_21` ne change aucun paramètre de production.
La cadence reste 35 Hz et le plafond reste huit monstres éveillés.

## 1. Contrats et corrections de validité

Les trois exécutables sont `genesis`, `step_tic`, `run_segment`. Leur ABI
plate est documentée dans `cairo/doom/doom_run/README.md` et implémentée par
le codec JS sans dépendance `doom_run/client/codec.mjs`. Un segment reçoit
l'état sérialisé initial, les commandes, le tic initial et sa limite. Ses
dix felts publics restent D14. Le seam client qui ne passe encore que `hIn`
doit être étendu à l'état sérialisé aux frontières choisies par le planner.

Les domaines d'entrée sont vérifiés avant l'exécution : versions, longueur,
indices des tables, slots, RNG, compteurs, armes, clock, specials et grille.
Un état invalide, une commande invalide ou une limite de clock atteinte
produisent ABORT par les helpers publics. Une enveloppe ABI tronquée est une
erreur de transport distincte ; elle ne doit pas être présentée comme un
ABORT du jeu. Les tests comprennent notamment une longueur felt extrême qui
faisait déborder l'ancien calcul `n + 3`, et la conservation du statut
terminal dans l'exécution vide de `step_tic_impl`.

**C2 : la grille n'était pas entièrement dérivée.** Un test synthétique avec
stimpack et bonus simultanés à santé 99 démontre 101 en continu contre 100
après reconstruction en ordre d'indice. L'ordre des listes d'une cellule est
observé par la physique et doit donc être engagé par le hash. Le schéma 2
sérialise les cellules dans un ordre canonique et préserve l'ordre historique
de leurs membres. La grille journalise ses mutations et compacte ce journal
à la frontière ; le journal lui-même n'est pas sérialisé. Un aller-retour
réel `serialize/from_felts` préserve désormais 101, et un combat de 700 tics
traverse 28 frontières sans divergence. Doublon, omission, mauvais indice et
mauvaise cellule sont rejetés explicitement.

L'état genesis passe de 5 829 à **6 362 felts** (+533, soit 9,14 %). Les cinq
hashes de schéma 1 restent des assertions secondaires des anciens champs ;
les cinq pins de schéma 2 sont un changement de format explicite, jamais une
régénération automatique. Les cinq replays de cette référence sont conservés.
Le test initial de `bring_up_weapon` prouve également que l'élévation du
pistolet ne modifie pas le mobj du joueur : il n'y a pas de désynchronisation
initiale sur ce chemin.

**D3 : domaine large.** `8 * tic` est maintenant calculé sans troncature
low32 avant modulo du nombre d'éveillés. Des références arithmétiques
indépendantes avec neuf monstres testent `tic >= 2^29` et `MAX_TIC`.

## 2. Mesure exacte du tic, sans amortissement du p99

`bench/trace_profile.py` exécute le vrai `step_tic` Scarb et lit les frames
VM de sa boucle récursive de commandes. Pour chaque frame, le coût inclusif
de l'enfant récursif est soustrait : chaque échantillon contient exactement
un tic, tous ses sous-appels et le retour/passage des arguments de boucle.
La désérialisation initiale, le rendu et la sérialisation finale, ainsi que
les squashes de dictionnaire hors de ces frames, restent un coût de frontière.
Les chunks de 35 limitent la mémoire de trace ; ils ne lissent pas le p99.
La quantile est le rang supérieur `ceil(0,99*N)`. Une calibration avec un
chunk de deux tics et deux chunks d'un tic donne exactement `[56 185, 52 762]`
dans les deux cas. Le nombre de frames est contrôlé contre la clock réelle.

| Replay | Tics exécutés | Moyenne | p99 | Maximum | Frontière moyenne/appel |
|---|---:|---:|---:|---:|---:|
| idle | 700 | 52 414 | 56 260 | 56 312 | 528 577 |
| walk | 350 | 87 126 | 131 418 | 199 288 | 534 672 |
| door | 350 | 105 347 | 208 981 | 234 466 | 540 175 |
| fight | 700 | 102 196 | 194 236 | 205 137 | 537 914 |
| death | 846 (DEAD) | 79 851 | 145 099 | 210 963 | 531 398 |

Les 2 946 tics réunis donnent moyenne **82 535**, p99 **167 516**. Le replay
death contient 1 200 commandes disponibles et s'arrête réellement à 846 ;
compter les commandes restantes aurait sous-estimé son coût. Les cinq hashes
finaux ont été comparés aux assertions du jeu. L'exécutable `step_tic`
mesuré a SHA-256 `ae5c7ed37313fc3d8414cba47c16596096b2a8e19c3ed0251d0c6da0c89d7434`.

Rapport détaillé local : `/tmp/game-p19-real-tic-baseline.json`, avec tous les
échantillons, tailles des chunks, empreinte d'exécutable et hashes finaux.
`profile.py` offre aussi une mesure différentielle en soustrayant un appel
vide ; ses coûts incluent les variations de frontière. Un p99 calculé sur
des moyennes de chunks n'est pas un p99 de tic et reste affiché « n/a ».

## 3. Frontières et leviers sans changement de gameplay

L'appel `step_tic` vide de référence coûte **528 157 steps Scarb** (528 143
via le runner natif du Worker). Son profil attribue, de manière disjointe,
115 864 steps à la boucle de lecture des mobjs, 75 775 à la boucle de
désérialisation Array de l'ABI, 63 166 à sa boucle de sérialisation,
32 675 à la lecture des listes de grille et 31 376 aux squashes de dict.
Les coûts cumulatifs, qui se recouvrent, sont : `from_felts` 215 425,
`read_grid` 51 624, `canonical_order` 25 207, `materialise_heights` 20 235,
`push_mobjs` 25 669 et `push_sectors` 10 109.

Une mesure différentielle des sous-systèmes sur la même référence donne
`hash` 125 276, `snapshot` 61 085, `serialize + from_felts` 302 297 steps.
Ces chiffres ne sont pas à additionner au tableau précédent : les appels et
leur plomberie diffèrent. C2 renchérit réellement la frontière ; masquer ce
coût avec une liste réduite ou en retirant son engagement serait incorrect.
`rebuild_list` avec une seule modification passe de l'ancienne référence
93 956 à 13 698 steps en copiant les plages inchangées via `append_span`.

Le profil du ticker doit conserver une profondeur suffisante : la valeur
100 par défaut de cairo-profiler tronque les appels sous les boucles
récursives qui parcourent 210 slots. `hot_functions.py` lit les échantillons
pprof par sous-arbre ; `statement_costs.py` compte directement les PCs CASM
d'une fonction pour distinguer copies et autres libfuncs, sans y inclure ses
appels enfants.

Les profils ci-dessous utilisent profondeur 512 ; le maximum réellement
observé dans le sous-arbre est 219 frames pour idle et 218 pour fight, donc
aucun appel de ce sous-arbre n'est tronqué. Les coûts sont attribués au premier
appelant du jeu dans la pile, en y rattachant ses helpers core : les lignes
sont disjointes. Il s'agit de deux tics réels, pas de moyennes de replay.

| Cinq premiers postes | idle, tic 300 | fight, tic 493 (pic du replay) |
|---|---:|---:|
| ticker hors sous-appels du jeu | 29 485 | 30 113 |
| awake_count | 6 732 | 6 833 |
| mobj::has | 4 540 | 6 566 |
| look_for_players_in | 2 088 | 1 160 |
| a_look_in | 927 | — |
| lines_in_cell | — | 13 732 |
| line_box_rejects | — | 9 778 |
| check_position_in | — | 8 384 |
| **Sous-arbre monsters complet** | **46 291** | **135 550** |

Les cinq premiers postes du pic fight sont donc ticker, lines_in_cell,
line_box_rejects, check_position_in, awake_count. Ses coûts cumulatifs,
non additionnables, sont `a_chase_in` 79 379, `p_move_in` 74 262 et `try_move`
70 726 steps. Les déplacements et traversées réels dominent le pic combat ;
le poste propre du ticker reste proche de 30 k. Les rapports pprof et JSON
sont conservés dans `/tmp/game-p19-hotfunctions/`.

Sur la boucle monstres du tic idle 300, les compteurs CASM directs donnent
**19 834 `store_temp`** et **5 670 `array_append`** (=210×27 felts). Les copies
`store_temp/local` comprennent Mobj 6 696, Env 2 508, ThingGrid 1 230, trois
en-têtes Array 2 442 et Span<Mobj> 438 steps. World/LevelMap sont déjà derrière
un Box sur ce chemin. La passe `awake_count` coûte encore 8 701 steps
cumulés. Cela désigne d'abord des copies et des scans de liste complète,
avant les attaques ou les raycasts.

Leviers prioritaires à mesurer : copies par plages des objets statiques
inchangés ; réduction des valeurs portées par la boucle/Box d'Env ; éviter
des scans redondants tout en conservant le classement initial D3 ; paramètres
étroits aux lecteurs de frontière ; encodage ABI par blocs. Ce sont des
postes observés, pas une promesse que toutes leurs instructions peuvent être
supprimées. Réduire le plafond d'éveillés ou changer la visée n'est pas une
optimisation équivalente et n'a pas été appliqué.

## 4. ABI native et preuve feuille réelle

Le vrai exécutable Scarb **2.16.0** charge et s'exécute dans le `SimProgram`
de `prover/sim`, dépendant de cairo-lang **2.19.4**, cairo-vm **3.2.0**. Il
n'y a pas d'incompatibilité ABI constatée sur ces exécutables. Le probe
`doom_run/bench/sim_probe.rs` utilise directement cette API et les felts
32 octets little-endian, sans remplacer le runner par un simulateur jouet.
Son wrapper Bootloader paie 14 steps de moins que le wrapper Scarb standalone.

L'expérience utilise les quatre premières commandes du vrai replay fight,
qui sont encore des commandes de marche. Le programme est exécuté par le
**leaf simple bootloader** de `proving@cd7bc5f`, avec les paramètres feuille
du dépôt. Le préimage public est exactement `[program_hash, dix felts D14]` ;
les dix sorties sont identiques entre standalone et bootloader, puis entre
hash programme Poseidon et Blake. Les engagements d'état restent Poseidon.

| Variante du hash programme | Steps VM bootloader | Poseidon total / uniques | Preuve |
|---|---:|---:|---|
| Poseidon historique D4/D29 | 1 499 208 | 65 138 / 65 136 | timeout 180 s ; ~32 GiB RSS observés, aucune preuve valide |
| Blake, code navigateur réel / D31 | 2 681 208 | 6 368 / 6 366 | native vérifiée, 53,50 s, RSS max 12 598 771 712 octets |

La preuve Blake fait **765 202 felts**. La même exécution dans le WASM réel
à quatre threads a également produit une preuve vérifiée en **42,225 s**,
avec **12 374 245 376 octets** de mémoire linéaire. Son bincode fait
4 343 870 octets. Il ne s'agit pas d'une mesure navigateur avec renderer
simultané : cette intégration reste à vérifier.

L'ancien script utilisait Poseidon contrairement au code WASM qui emploie
déjà Blake (`prover/wasm/src/core.rs`). Le script est maintenant aligné sur
Blake et conserve Poseidon comme comparaison explicite. Le chemin Poseidon
explose les composants auxiliaires : agrégateur paddé à 65 536, 27 chaînes
partielles et 107 entrées cube par agrégateur ; cube atteint log23. Le chemin
Blake abaisse cube à log20 mais **blake_g atteint log21**. Les claims réels
donnent `trace_lifting_log_size=22`, `log_blowup_factor=1`, donc trace log21.
`resources()` annonçait log20/fit=true : c'est un faux positif confirmé.
Les tailles lifting ne sont pas sérialisées dans CairoSerde ; le vérificateur
les reconstruit, d'où la lecture des vrais ProofStats/claims bincode.

Le registre de production log20 ne peut pas replier cette preuve. Une
expérience séparée de l'orchestrateur avec `doom_21` a construit un circuit
conforme à son hash (75,83 s, RSS max 19 222 069 248 octets), en attente de
validation complète et de décision explicite. Aucune modification de registre
ni augmentation implicite du budget n'est incluse dans cette ligne.

Artefacts locaux : `/tmp/game-p19-native-segment/` (comparaison Poseidon),
`/tmp/hellproof-audit-20260913/hash-cost/blake-*` et `wasm-blake-*` (preuves,
préimages, temps, ressources et claims). Le script conserve l'empreinte des
binaires, vérifie le pin des clones, tient `.proof-lock` avec son PID et tue
le groupe de preuve entier au timeout. Il ne retire jamais un verrou tiers.

## 5. Reproduction et critères restants

```sh
ASDF_SCARB_VERSION=2.16.0 scarb --manifest-path cairo/Scarb.toml --profile proving build -p doom_run
python3 cairo/doom/doom_game/bench/trace_profile.py --all --chunk 35 --out /tmp/tic-profile.json
python3 cairo/doom/doom_game/bench/measure.py --json /tmp/subsystems.json
python3 cairo/doom/doom_run/bench/size.py
node --test cairo/doom/doom_run/client/codec.test.mjs
PROOF_TIMEOUT=180 cairo/doom/doom_run/bench/prove_segment.sh /tmp/doom-leaf fight 4
```

Les budgets de régression du harnais récupéré sont des références historiques
pré-C2 ; ils restent distincts de D2 et les dépassements sont signalés. Aucun
`--update` n'a été exécuté. `size.py` échoue au-delà de 100 000 mots, même
si le plafond dur de 120 000 n'est pas dépassé. Une preuve locale vérifiée
n'établit ni le fit du registre ni la cadence 35 Hz. Les preuves ci-dessus
portent sur la référence nommée : il faudra revalider l'exécutable final
après intégration des corrections de frontière et de dégâts.

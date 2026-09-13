<!-- SPDX-License-Identifier: Apache-2.0 -->
# S11 — comparaison isolée Poseidon / BLAKE9-v1

Le prototype réduit fortement les composants Poseidon, mais **augmente le coût VM et le
bytecode**, sans réduire la hauteur AIR maximale des segments mesurés. Il ne justifie pas
une migration en production. Aucune preuve, mesure de preuve ou prédiction de RAM n'est
produite par cette phase.

La base commune est `f306c6afa3af652d1c91e579d940d7af94d57cbd` ; son arbre `cairo/` est
identique à D33 `aa16f2b952b0df29366597f3b4970ed790266f06`. D29 n'est pas incorporée.
Le hash d'état de production demeure Poseidon. L'encodage expérimental, les limites de
domaine, la réduction des 256 bits et sa portée de sécurité sont définis dans [SPEC.md](SPEC.md).
Les interfaces publiques, D13, D14, le schéma 2, les règles, les goldens et les plafonds du
produit sont inchangés.

## Artefacts et séparation des coûts

Scarb 2.16.0, profil `proving` du manifeste du spike ; même configuration Cairo que la
production de référence (`unsafe-panic` préexistant). Les neuf exécutables ont été figés,
puis reconstruits : **les neuf JSON sont identiques octet par octet**, hints compris.
Tous les SHA-256 figurent dans [results.json](results.json).

| Exécutable proving | Mots complets | SHA-256 |
|---|---:|---|
| Production D33 `run_segment` | 110 015 | `24672e9db90cf22502d2a69c50ea5d428fad5d45039acdc034d736b33b7b2b65` |
| Wrapper `segment_poseidon` | 110 368 | `c790fd1c676974d960f09f0fb5f2e119d6f741ef1c6d66463013684ec9b5e9f4` |
| Wrapper `segment_blake9` | 111 085 | `6af8f28a60839aa7e87425dc9fc9c3d08207a1506c262343f4758eb08d8ec223` |
| `inspect_poseidon` / `inspect_blake9` | 112 638 / 113 355 | Voir JSON |
| `genesis_poseidon` / `genesis_blake9` | 47 200 / 47 826 | Voir JSON |
| `hash_poseidon` / `hash_blake9` | 182 / 833 | Voir JSON |
| `vector_blake9` | 863 | Voir JSON |

Le wrapper Poseidon coûte **353 mots de plus** que la production ; changer le hash dans
ce wrapper coûte **717 mots de plus**. Le garde D29 de 100 000 mots n'est satisfait par
aucun des trois exécutables de segment. `doom_run` ne proposant pas de bibliothèque,
`lib.cairo` reproduit seulement sa petite admission commune ; le jeu et le segment générique
restent les vrais modules de production. Les cibles `inspect_*` retournent aussi l'état et
le rendu pour vérifier l'équivalence ; leurs coûts ne sont jamais utilisés comme coût du
programme à dix sorties D14.

## Exécution native directe

Steps de l'exécutable, sans le bootloader leaf. Les états avancés sont reconstruits à partir
du genesis D33 et des logs de `doom_game/bench/profile.py`, sans fixture modifiée. `idle300_1`
signifie un tic partant de l'état au tic 300 ; `fight493_4`, quatre tics partant du tic 493.
Le tic demandé après la mort au tic 846 conserve l'état terminal.

| Scénario | Production D33 | Wrapper Poseidon | Wrapper BLAKE9 |
|---|---:|---:|---:|
| Frontière vide | 393 283 | 393 357 | 1 661 619 |
| Marche 1 | 432 551 | 432 625 | 1 700 887 |
| Marche 4 | 540 264 | 540 338 | 1 808 600 |
| Idle300 + 1 | 423 143 | 423 217 | 1 691 479 |
| Combat493 + 1 | 563 338 | 563 412 | 1 835 880 |
| Combat493 + 4 | 716 413 | 716 487 | 1 988 955 |
| Terminal846 + 1 | 393 249 | 393 323 | 1 665 531 |
| Tag invalide | 67 142 | 67 227 | 67 227 |
| `tic_start` incohérent | 221 397 | 221 482 | 221 482 |
| Champ état hors neuf octets | 67 315 | 67 400 | 67 400 |
| Genesis | 763 118 | 812 689 | 1 446 810 |

Sur les états de 6 362 felts, BLAKE9 ajoute **1 268 262 steps** par frontière de segment ;
le supplément est le même pour 0, 1 et 4 tics. Les exécutables de hash seul sur les
6 362 felts du genesis mesurent **66 867 steps Poseidon / 700 997 BLAKE9**
(+634 130 pour un hash complet), ce qui isole ce surcoût du ticker. Le supplément
par segment atteint 1 272 468 sur l'état de combat
(6 383 felts). Le jeu simulé et son coût entre frontières ne changent pas : l'écart est
celui des hashes d'entrée/sortie. Les deux wrappers ont le même chemin ABORT Poseidon et
le même coût natif sur les entrées refusées. Genesis révèle également le coût propre de
son wrapper : +49 571 steps avant tout changement de hash, car sa sortie utilise le Serde
standard alors que la production a son adaptateur d'encodage étroit.

## Exécution leaf et ressources AIR

Node **24.16.0**, `ProverCore` AIR complet de main (calcul `core.rs` à `4309399`), copie
locale figée. WASM mono SHA-256
`3e94a4c0cd8a2e24af374bab733f77e2988b4b93731adea6a0a1b937009479a5`, 45 034 502 octets.
Les paramètres par défaut sont enregistrés sans modification : `blake2s_m31`,
`canonical_small`, lifting `at_least_preprocessed`, 16 composants big-memory forcés.
Le hash du **programme** reste Blake dans les deux variantes. La colonne ci-dessous
inclut le bootloader, le hash du programme et celui des sorties publiques.

| Scénario | Production D33 | Wrapper Poseidon | Wrapper BLAKE9 |
|---|---:|---:|---:|
| Frontière vide | 2 113 239 | 2 118 523 | 3 398 305 |
| Marche 1 | 2 152 507 | 2 157 791 | 3 437 573 |
| Marche 4 | 2 260 220 | 2 265 504 | 3 545 286 |
| Idle300 + 1 | 2 143 099 | 2 148 383 | 3 428 165 |
| Combat493 + 1 | 2 283 294 | 2 288 578 | 3 572 566 |
| Combat493 + 4 | 2 436 369 | 2 441 653 | 3 725 641 |
| Terminal846 + 1 | 2 113 205 | 2 118 489 | 3 402 217 |
| Tag invalide | 1 787 098 | 1 792 393 | 1 803 913 |
| `tic_start` incohérent | 1 941 353 | 1 946 648 | 1 958 168 |
| Champ état hors neuf octets | 1 787 271 | 1 792 566 | 1 804 086 |
| Genesis | 1 606 326 | 1 652 621 | 2 296 924 |

Le supplément wrapper Poseidon / production est de **5 284 steps leaf** sur les états
admis (+5 295 sur ABORT) ; il n'est pas crédité au changement de hash. Le supplément
BLAKE9 / wrapper Poseidon atteint **1 279 782 steps** sur marche4 (+56,49 %).

Les **33** appels `execute` puis `resources` couvrent les trois variantes de chacune des
11 lignes ci-dessus. Chaque résultat conserve les **43 types de composants variables**,
leurs comptes bruts et leurs hauteurs après padding, ainsi que tous les compteurs originaux.
Pour les big-memory splittés, la table présente le chunk maximal et le compteur de composants
séparément ; elle ne signifie pas qu'il n'existe que 43 instances AIR. Les labels builtin
sont ceux de l'adaptateur (`pedersen_builtin` utilise les fenêtres étroites avec ces paramètres).

Extrait marche4, **comptes bruts / log2 des lignes après padding** :

| Composant | Wrapper Poseidon | Wrapper BLAKE9 |
|---|---:|---:|
| `blake_compress_opcode` | 15 399 / 14 | 17 296 / 15 |
| `blake_g` | 1 231 920 / 21 | 1 383 680 / 21 |
| `blake_round` | 153 990 / 18 | 172 960 / 18 |
| `triple_xor_32` | 123 192 / 17 | 138 368 / 18 |
| `poseidon_aggregator` | 6 366 / 13 | 4 / 4 |
| `poseidon_3_partial_rounds_chain` | 221 184 / 18 | 432 / 9 |
| `poseidon_full_round_chain` | 65 536 / 16 | 128 / 7 |
| `cube_252` | 876 544 / 20 | 1 712 / 11 |
| `range_check_252_width_27` | 679 936 / 20 | 1 328 / 11 |
| `range_check_builtin` (segment builtin déjà paddé) | 262 144 / 18 | 524 288 / 19 |
| `memory_address_to_id` | 158 949 / 18 | 234 412 / 18 |
| `memory_id_to_small` | 578 905 / 20 | 633 389 / 20 |
| `memory_id_to_big` (chunk maximal) | 51 403 / 16 | 27 835 / 15 |

Les instances Poseidon **VM non paddées** sont 6 368 contre 4 ; les utilisations de range-check
VM sont 134 958 contre 510 059. Elles sont distinctes des 8 192 / 16 instances Poseidon
paddées de l'adaptateur. Avec `P(n)=next_pow2(max(n,16))`, l'agrégateur propage `A=P(U)` :
`cube=107A`, partial-chain `27A`, full-chain `8A`, range252 `83A`. Blake propage les
comptes actifs : round `10B`, G `80B`, XOR `8B`. Ces formules sont celles du code épinglé
`proving@cd7bc5f`, reprises par `resources()` ; aucune hauteur n'est assimilée à un nombre
de colonnes ou à de la RAM.

Marche4 contient deux hashes d'état de `ceil((32+9×6362)/64)=896` compressions chacun.
Le supplément Blake total est 1 897 compressions : **1 792 pour les états et 105 pour
l'exécutable plus grand**. Le dernier supplément reste visible sur ABORT, où les hashes
d'état demeurent Poseidon. Les corps de programme diffèrent ; leurs hashes publics et
ceux du bootloader diffèrent donc également, en plus des deux champs D14 autorisés.

Pour tous les segments de cette campagne, `max_component=blake_g`, hauteur **2^21**,
`fits_leaf_registry=false` pour le registre actuel log20 ; fixed-floor et Seq maximal
restent **log20**. Les trois genesis restent log20 et leur simple contrôle de hauteur
renvoie `true`. Ce résultat d'estimation n'est ni une admission par le planner ni une
preuve de compatibilité cryptographique. Aucun registre ni plafond n'a été changé.

## Équivalence vérifiée et limites

- 17 tests Cairo préexistants verts à la reprise, logs inspectés ; aucune valeur attendue
  régénérée. Les neuf exécutables proving reconstruits sont identiques aux références.
- 16 vecteurs `hashlib.blake2s` relus et exécutés en natif, avec comparaison des **huit mots
  du digest** et de la réduction modulo Stark p : endian, zéro final, longueurs autour
  des blocs et bloc final exactement plein (32 et 96 felts).
- Domaine refusé : `2^72` et `p-1` par `vector_blake9` et `hash_blake9` ; Python refuse
  aussi les valeurs négatives. Le contrôle statique de longueur évite le débordement du
  compteur u32 ; aucun tableau de 477 millions d'éléments n'est alloué pour le tester.
- 142 appels natifs au total, dont 19 comparaisons complètes entre wrappers et production : tous les felts d'état et de
  rendu sont égaux, donc notamment les 27 champs des acteurs, les compteurs, le RNG et
  l'ordre canonique de grille. Les dix sorties D14 Poseidon sont celles de production ;
  pour les états admis, seules `h_in` et `h_out` peuvent différer pour BLAKE9, et chaque
  valeur est vérifiée par Python sur l'état complet.
- Les refus du tag, d'un état tronqué, de `tic_start` et d'un champ hors domaine produisent
  le même ABORT à dix felts, avec le hash Poseidon exact de l'entrée et sans état/rendu.
- Découpes marche4 `1+3`, `1+1+1+1`, combat493 `2+2` : états et rendus finaux identiques au
  segment entier ; chaque raccord `h_out→h_in` est exact dans les deux variantes.
- 33 exécutions leaf WASM ont la même sortie de tâche que les exécutions natives. Les
  SHA des préimages complètes sont conservés ; les sorties de segments sont publiées.

Les replays avancés sont reconstruits en natif (9 404 898 / 33 840 174 / 44 043 558 steps
pour idle300 / combat493 / mort846), mais ne font pas l'objet de grosses exécutions leaf.
La campagne mesure seulement les petites frontières sélectionnées. Elle ne couvre pas
exhaustivement les états atteignables ni une campagne de fuzz. Les durées mono-observation
conservées dans le JSON sont diagnostiques : chargement du processus et contention ne
sont pas contrôlés. Aucun gain de latence de preuve, de RSS ou de mémoire linéaire n'est
déduit des baisses de colonnes/hauteurs Poseidon. L'incident FFT V8/Memory64 en cours de
validation impose en outre de vérifier toute preuve future séparément.

Une éventuelle suite devrait d'abord réduire et profiler le coût VM du hash et de son
encodage. Cette livraison s'arrête à la comparaison/exécution/resources ; elle n'active
pas un nouveau hash, et elle ne lance ni preuve ni Docker.

## Reproduction

Depuis cette base, avec Scarb 2.16.0, Node 24.16.0 et un prouveur WASM AIR complet déjà
construit. Les répertoires d'artefacts sont séparés et ne sont pas committés. Les scripts
exécutent les jobs séquentiellement, avec 120 s de timeout par exécution ; au plus deux
jobs CPU peuvent être employés en préparant la campagne.

```sh
ASDF_SCARB_VERSION=2.16.0 RAYON_NUM_THREADS=2 scarb --manifest-path spikes/s11/Scarb.toml --profile proving build
ASDF_SCARB_VERSION=2.16.0 RAYON_NUM_THREADS=2 scarb --manifest-path cairo/Scarb.toml --profile proving build -p doom_run
ASDF_SCARB_VERSION=2.16.0 scarb --manifest-path spikes/s11/Scarb.toml fmt --check
ASDF_SCARB_VERSION=2.16.0 RAYON_NUM_THREADS=2 scarb --manifest-path spikes/s11/Scarb.toml test
python3 spikes/s11/vectors.py
cairo/doom/doom_run/bench/build_sim_probe.sh /tmp/s11-sim-probe

python3 spikes/s11/freeze.py --executables spikes/s11/target/proving \
  --production cairo/target/proving --wasm-pkg /absolute/path/to/AIR-complete/prover/wasm/pkg \
  --output /tmp/s11/reference
python3 spikes/s11/measure.py --executables /tmp/s11/reference/proving \
  --production /tmp/s11/reference/production --runner /tmp/s11-sim-probe \
  --output /tmp/s11/measure
node spikes/s11/resources.mjs /tmp/s11/reference/wasm/pkg/dist/core.js \
  /tmp/s11/reference /tmp/s11/measure 120000
python3 spikes/s11/summarize.py /tmp/s11/measure /tmp/s11/reference /tmp/s11/results.json
```

`freeze.py` refuse d'écraser une référence, vérifie les douze exécutables contre les SHA
publiés et refuse un arbre Cairo différent de D33. Le runner natif est construit à partir du `SimProgram` épinglé ; un cache existant peut
être indiqué par `SIM_TARGET_DIR`. `measure.py` n'a besoin d'aucun état externe : il prépare
les siens depuis la production figée. La campagne de référence conserve aussi une copie
figée `reference/wasm/pkg/{dist,wasm,package.json}` et son `reference/manifest.json` (SHA des
sources initiales, exécutables et WASM). Le JSON publié ajoute les SHA des sources
finales ; seul le générateur de tests a reçu une correction de reconnaissance REUSE,
sans changer un octet des tests qu'il produit. `summarize.py MEASURE_DIR REFERENCE_DIR OUTPUT_JSON` réduit
ces logs en l'artefact léger publié sans copier les états entiers ; il exige cette provenance.

Artefacts locaux de cette campagne : `/tmp/hellproof-state-hash-spike/`, notamment
`native.log`, `resources.log`, `rebuild.log`, `rebuild-equivalence.json`, `measure/native/`,
`measure/resources/`, `reference/manifest.json` et `report.md`. Les comparaisons utilisent
les tableaux complets ; leurs empreintes SHA-256 sont une trace de reproductibilité,
pas un substitut à ces comparaisons.

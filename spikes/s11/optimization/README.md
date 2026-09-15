<!-- SPDX-License-Identifier: Apache-2.0 -->
# S11 — réduction du coût VM, après la référence 4936c23

La variante retenue ramène le hash seul de **700 997 à 373 349 steps (−46,74 %)**.
Sur marche4, elle économise **655 303 steps natifs** et **655 901 steps leaf**.
Le format BLAKE9-v1, chaque bit du message et du digest, les états, les sorties et les
oracles sont inchangés. Cette passe reste un spike : aucun changement de production,
de registre, de profil ou de budget ; aucune preuve ni conclusion sur la RAM.

## Attribution exacte

Le profiler standard avec une profondeur de pile limitée regroupe les itérations
récursives profondes sous `digest` et sous-compte leur détail. `profile.py` attribue
**chaque PC exécuté** à l'intervalle CASM de son statement Sierra et à son libfunc.
Les 701 000 steps du profil Scarb sont intégralement comptés ; le probe natif mesure
700 997 steps, avec trois instructions d'enveloppe en moins. Les mêmes trois instructions
séparent le résultat final Scarb (373 352) du probe (373 349).

| Source ou opération | Avant | Retenue |
|---|---:|---:|
| Encodage `digest`, attribution source plate | 679 221 | 351 569 |
| Boucle `digest_words` | 21 655 | 21 655 |
| Dont compress/finalize intrinsèques | 895 + 1 | 895 + 1 |
| Autres wrappers, réduction, fin de tableau et enveloppe | 124 | 128 |
| `u128_mul_guarantee_verify`, tous appels | 256 082 | 0 |
| `u128_safe_divmod`, tous appels | 127 240 | 0 |
| `store_temp`, tous appels | 113 907 | 160 037 |
| `array_append`, tous appels | 14 341 | 14 341 |
| Conversions `u128s_from_felt252` | 12 724 | 25 448 |
| Conversions `downcast` | 42 948 | 19 089 |
| Conversions `u32_try_from_felt252` | 4 | 31 816 |
| Bitwise / divisions dans le corps felt | 0 / 0 | 25 448 / 12 724 |

Les quatre premières lignes forment une partition du total ; les lignes par libfunc
sont un autre classement et **ne s'ajoutent pas** aux lignes de source. Le détail complet,
y compris les contrôles de domaine et les branchements, est dans les JSON de profil.

Dans l'encodage initial, les vérifications de multiplication u128 représentent 36,53 %
du total, les divisions u128 18,15 %. Les appels d'append écrivent le même tampon de
14 323 mots (8 mots de domaine/en-tête + 14 315 mots de données) avant et après.
La réduction porte donc sur l'arithmétique et ses temporaires, sans éviter un champ ni
cacher une allocation. Les `store_temp` augmentent même dans la variante retenue :
152 732 se trouvent encore dans la boucle d'encodage. Les 896 compressions coûtent
896 instructions VM, **ce qui ne mesure pas leur coût AIR ou de preuve**.

## Trois variantes mesurées

| Variante cumulative | Hash seul | Segment vide | Marche4 | Mots hash / segment |
|---|---:|---:|---:|---:|
| Référence 4936c23 | 700 997 | 1 661 619 | 1 808 600 | 833 / 111 085 |
| V1 : produit/somme et facteur dans felt, conversion contrôlée | 422 647 | 1 104 919 | 1 251 900 | 788 / 111 040 |
| **V2 : V1 + extraction bitwise et reconstruction exacte des hauts** | **373 349** | **1 006 316** | **1 153 297** | **804 / 111 052** |
| V3 : V2 + helper non inliné à trois arguments | 456 045 | 1 171 708 | 1 318 689 | Voir JSON |

V3 est rejetée : +82 696 steps par hash contre V2, dont +63 612 `store_temp` et
+12 724 instructions d'appel/retour. Le calcul est identique ; le déplacement vers
une fonction séparée augmente ici les transferts de valeurs. Aucune quatrième variante
n'a été entreprise. Les patches `variants/v*.patch` s'appliquent au `hash9.cairo` initial
et reproduisent exactement les sources mesurées (`git apply --unidiff-zero`, depuis
la référence initiale).

Une tentative préalable d'employer `core::num::traits::Split` a échoué à la compilation :
ce trait est privé dans Cairo 2.16. Un enchaînement shell a ensuite exécuté par erreur
les anciens binaires V1 ; ce dossier est explicitement invalidé
(`unusable-private-split-stale-run/INVALID.txt`) et **exclu de tous les résultats**.
Le harnais refuse désormais un source plus récent que l'exécutable. La variante bitwise
V2 a ensuite été compilée normalement et reconstruite avec neuf JSON identiques.
Aucune API privée, modification du core ou option de compilation supplémentaire n'est utilisée.

## Conservation exacte des neuf octets

Le contrôle d'entrée reste `value.try_into::<u128>()` puis `value < 2^72`.
Le facteur suit toujours `1, 2^8, 2^16, 2^24`. Par induction, les retenues avant ces
quatre phases sont respectivement `<1, <2^8, <2^16, <2^24`. Ainsi :

`packed = value × factor + carry < 2^96 < p`.

Le produit et la somme felt sont donc les entiers ordinaires, sans réduction effective
modulo p. Une conversion contrôlée vers u128 précède les bitwise. Ensuite :

- `lower = packed & (2^64−1)` ; `upper = (packed−lower) / 2^64` dans le corps felt.
- `w0 = lower & (2^32−1)` ; `w1 = (lower−w0) / 2^32` dans le corps felt.
- Les différences sont non négatives et divisibles par la puissance de deux ; les
  quotients entiers sont `<2^32`, donc uniques dans le corps. Les deux mots bas sont
  convertis vers u32 ; la partie haute est réinjectée comme retenue ou troisième mot.

Ces masques servent à **décomposer** les mots : les parties hautes sont conservées,
sans aucune troncature d'entrée ou de digest. Le domaine, la longueur maximale, les
compteurs Blake, le padding, le dernier bloc et `reduce()` sont inchangés. Il n'existe
aucun hint nouveau ni résultat de quotient fourni comme donnée de confiance.

## Exécution leaf et les 43 types AIR

Même WASM AIR complet figé que la référence, Node24.16.0 mono, SHA-256
`3e94a4c0cd8a2e24af374bab733f77e2988b4b93731adea6a0a1b937009479a5`.
Six appels bornés `execute` puis `resources`, avec sorties de tâche identiques au natif :

| Cas | Steps leaf avant → après | Maximum variable avant → après |
|---|---:|---|
| Hash seul | 716 571 → 388 389 | range-check log18 → assert-eq-double-deref log17 |
| Frontière vide | 3 398 305 → 2 742 404 | Blake G log21 → log21 |
| Marche4 | 3 545 286 → 2 889 385 | Blake G log21 → log21 |

Les 43 types et tous leurs comptes bruts/hauteurs figurent dans `results.json` pour
chacun des six appels. Extrait marche4 :

| Composant ou compteur | Avant | Après |
|---|---:|---:|
| Compressions Blake | 17 296 | 17 290 |
| Blake G brut / log | 1 383 680 / 21 | 1 383 200 / 21 |
| Poseidon VM | 4 | 4 |
| Cube252 brut / log | 1 712 / 11 | 1 712 / 11 |
| Range-check VM | 510 059 | 223 728 |
| Range-check AIR, déjà paddé / log | 524 288 / 19 | 262 144 / 18 |
| Bitwise VM | 3 116 | 28 564 |
| Bitwise AIR, déjà paddé / log | 4 096 / 12 | 32 768 / 15 |
| Memory address-to-id brut / log | 234 412 / 18 | 195 935 / 18 |
| Memory id-to-small brut / log | 633 389 / 20 | 645 127 / 20 |
| Memory id-to-big, chunk maximal brut / log | 27 835 / 15 | 27 116 / 15 |

Il y a un échange mesuré entre range-checks et bitwise ; les petites valeurs mémoire
augmentent aussi de 11 738. Cela ne démontre aucune baisse de RAM. Les deux hashes
seuls passent le contrôle de hauteur du registre20 grâce au plancher fixe20 ; tous les
segments avant/après restent log21 et `fits_leaf_registry=false`. Seq reste20 partout.
Les paramètres de lifting, les 16 composants big-memory forcés et les plafonds produit
restent identiques.

Le programme final fait **111 052 mots**, toujours au-dessus du garde100k, et le hash
reste 5,58 fois plus coûteux en steps natifs que Poseidon (66 867). Marche4 leaf demeure
au-dessus du wrapper Poseidon (2 265 504 steps). La passe apporte un gain au prototype,
sans justifier une migration ni un relèvement des budgets.

## Validation et reproduction

17 tests Cairo exécutés et verts. Chaque variante a passé les 16 vecteurs indépendants
(huit mots du digest + réduction complète), ainsi que les refus de `2^72` et `p−1` par
les deux APIs. La campagne finale a effectué 60 appels : ces 20 cas, le hash seul,
19 paires segment/inspect et genesis. Les sorties complètes sont identiques à la
référence, y compris les états/rendus, D14, les états avancés idle300/combat493/mort846,
les refus d'état et les trois découpes avec raccords de hash. Aucun oracle n'a été
régénéré. Les quatre exécutables Poseidon sont inchangés octet par octet.

Les neuf exécutables finaux reproduisent V2 exactement. SHA-256 principaux :

- `hash_blake9` : `6ba604873e491fbcc966fd3b6687545403d4a4155ee13861ef181e455a09e951`
- `segment_blake9` : `0575166c7759c1d6084753ef49e8a9a1fc0eb744c2875d68b27d186a778d7e08`
- `inspect_blake9` : `2408563dfe19431a5dddfeb7ba28cdfdf5ee9502caf6221ee47908f982859273`

Préparer les données immuables avec le harnais de la référence `4936c23`, dans un
checkout séparé. Ici `BASE_MEASURE` désigne son dossier `measure/` et `BASE_PROGRAMS`
les neuf exécutables initiaux. `AIR_CORE` pointe vers le `core.js` AIR complet figé.

```sh
ASDF_SCARB_VERSION=2.16.0 RAYON_NUM_THREADS=2 scarb --manifest-path spikes/s11/Scarb.toml --profile proving build
ASDF_SCARB_VERSION=2.16.0 RAYON_NUM_THREADS=2 scarb --manifest-path spikes/s11/Scarb.toml test
python3 spikes/s11/vectors.py
python3 spikes/s11/optimization/measure.py --programs spikes/s11/target/proving \
  --baseline-measurement "$BASE_MEASURE" --runner "$SIM_PROBE" --output /tmp/s11-opt-final --full
python3 spikes/s11/optimization/resources.py --baseline-programs "$BASE_PROGRAMS" \
  --candidate-programs /tmp/s11-opt-final --baseline-measurement "$BASE_MEASURE" \
  --core "$AIR_CORE" --node "$NODE24" --output /tmp/s11-opt-resources
```

Pour l'attribution, exécuter `hash_blake9` avec `--save-profiler-trace-data`, puis
`profile.py TRACE_JSON HASH_SIERRA_JSON SIERRA_WORDS_BINARY OUTPUT_JSON`.
Le mapper est `infra/sierra_words` épinglé Cairo2.16 ; le script vérifie que tous les
steps de la trace sont comptés, enveloppe comprise. Les JSON de profil et les patches
suffisent à contrôler les tableaux sans reconstruire des profils protobuf.

Artefacts lourds et logs : `/tmp/hellproof-state-hash-optimization/` ; notamment
`reference/`, `v1/`, `v2/`, `v3/`, `final/`, `resources/`, `profile-*.json`,
`build-final.log`, `rebuild-final.json`, `tests.log`, `measure-final.log`, `resources.log`.
Les timings ponctuels conservés sont diagnostiques et ne constituent pas un benchmark
statistique. Aucun test de preuve ni de mémoire physique n'a été exécuté. Le prochain
levier éventuel reste le transport des valeurs et les conversions dans l'encodeur ;
la troisième variante montre qu'extraire un helper n'y suffit pas. Cette passe s'arrête
après les trois variantes autorisées.

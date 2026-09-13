# Optimisation des calculs Cairo — passe mesurée

## Périmètre et méthode

Passe du 2026-09-13 sur Scarb/Cairo 2.16.0, base `bb9efb3` de
`codex/game-integration` (moteur `0c8a3a8`). Les comparaisons portent sur les steps
VM, les compteurs de builtins et les mots CASM, en dev et proving. Les arguments
des microbenchmarks doivent être opaques ; les sorties doivent être équivalentes
sur tout le domaine de l’API, y compris les bornes et arrondis signés.

La cadence 35 Hz, le gameplay, les RNG, D3, le format d’état, les dix sorties D14,
les tables et les plafonds de ressources ne changent pas. Les goldens ne sont
jamais réenregistrés pour accepter une optimisation. Les gains de microbench ne
sont pas présentés comme des gains par tic ou de temps de preuve.

## Principes vérifiés dans les sources

- Le builtin bitwise fournit AND/XOR/OR dans un bloc de cinq cellules. Ce n’est
  pas une boucle logicielle bit par bit. Source primaire :
  [Cairo Book, Bitwise](https://www.starknet.io/cairo-book/ch204-02-04-bitwise.html).
- Les builtins ajoutent leurs propres contraintes à l’AIR : diminuer les steps
  ne suffit pas à conclure à une diminution de la preuve. Source primaire :
  [Cairo Book, Builtins](https://www.starknet.io/cairo-book/ch204-00-builtins.html).
- La forme source doit être confrontée au lowering de la version utilisée :
  [corelib integer.cairo, v2.16.0](https://github.com/starkware-libs/cairo/blob/v2.16.0/corelib/src/integer.cairo).
  Une division de felt est une division dans le corps ; elle ne remplace pas
  une division entière avec quotient tronqué. Les masques ne reproduisent un
  modulo que pour le domaine et les puissances de deux appropriés.

Les règles S7 restent un historique utile, mais une préférence universelle
« division plutôt que bitwise » ou l’inverse n’est pas justifiée. Tester un
ensemble déjà empaqueté par un masque peut économiser un parcours ; construire
cet ensemble ou son masque à chaque appel peut annuler le bénéfice. Les copies,
le travail répété et la largeur des arguments peuvent coûter davantage que
l’opération arithmétique visée.

## Résultats

Les trois candidats sont assemblés sur `ee5f819` ; le formatage ultérieur
`ae2feac` produit six exécutables SHA256 strictement identiques après reconstruction.

| Modification | Avant | Après | Périmètre de mesure |
|---|---:|---:|---|
| `bam::sin_cos`, pliage partagé |109 steps / 12 RC|76 / 8|microbench différentiel, net|
| Cadence IA modulo 4 → masque 3 |13 249,95 steps|13 128,95|29 dormants, coût par tic brut du harnais|
| Rotation IA modulo 8 → masque 7 |3 874 steps|3 869|A_Chase avec cache|
| Hauteur de secteur inchangée |4 055 steps|242|microbench plafond, proving|
| Hauteur changée, copie prefix/suffix |4 055 steps|2 095|même microbench|
| Exécutable complet proving |106 855 mots|107 018|**+163 mots**, pas un succès D29|

Les gains de masques déplacent des ressources du range-check vers le bitwise.
Le tableau de modules ne s’additionne pas pour calculer le gain global.

Root recompile puis rejoue le micro-harnais S14 : 258 exécutions opaques,
références Python exactes, dev et proving. Exemple proving, coût **brut d’appel** :
`x % 256` : 39–40 steps et 5 RC ; `x & 255` : 35 steps, 1 RC et 1 bitwise. Le couple `/` + `%`
coûte 51–53 steps contre 40–41 pour un seul `DivRem` ; le remplacement d’un modulo
constant isolé par `NonZero` est neutre. Ces résultats sont spécifiques aux
formes mesurées. Les 16 384 angles testés couvrent les deux extrémités de chacun
des 8 192 intervalles, en conservant les anciennes fonctions comme oracle.

## Mesure du jeu assemblé

Profil exact de 2 946 frames VM, hors frontières de sérialisation et de hachage,
même protocole et même hash final pour chaque scénario :

| Indicateur | Avant | Après |
|---|---:|---:|
| Moyenne steps/tic |49 524,87|48 543,68 (**−1,98 %**)|
| p50 |45 943|45 571|
| p90 |81 483|77 764|
| p99 |125 157|122 942|
| Maximum |167 756|166 315|

Aucun tic mesuré ne régresse. Moyennes par scénario : idle −0,46 %, walk −3,20 %,
door −3,92 %, fight −1,44 %, death −1,60 %. Ces pourcentages ne sont pas des mesures
FPS, de vitesse native ou de génération de preuve. D2 reste manqué.

Le bench global confirme des opérations améliorées ou identiques ; les trois
dépassements historiques ci-dessous restent exactement inchangés. 573 tests Cairo
sur 23 cibles passent sans test ignoré ; format, graphe et REUSE passent.

## Arbitrage coût fixe / calcul utile

Le programme grandit de 163 mots, soit environ 2 404,25 steps de hachage Blake
supplémentaires par segment dans le modèle existant. Les exécutions WASM réelles,
sans génération de preuve, donnent :

| Même préfixe de marche, ancien/nouveau programme | Avant | Après |
|---|---:|---:|
|4 tics, steps execute |2 193 266|2 195 222 (**+1 956**)|
|32 tics, steps execute |3 083 596|3 081 268 (**−2 328**)|
|4 tics, bytes entrée prouveur |46 863 352|46 907 448|
|32 tics, bytes entrée prouveur |62 676 788|62 975 556|

Les dix sorties D14 sont identiques dans chaque paire. Le task hash change,
log 21 reste nécessaire et le registre log 20 refuse les deux versions. Le nombre
de steps et la taille d’entrée du prouveur peuvent évoluer en sens opposés.
Aucun gain mémoire, durée de preuve, ou seuil universel d’amortissement n’est
inféré de ces deux mesures. La passe optimise le calcul du jeu, avec une petite
régression explicite sur ce segment très court ; elle ne résout pas l’admission.

La migration client fige les nouveaux SHA et le task hash mesuré par execute.
Les identités de preuve de 0c8a3a8 restent distinctes et refusées lors d’un import
incompatible ; les exports existants ne sont pas réétiquetés comme nouveaux.


## Référence avant modification

Le bench global `doom_game/bench/measure.py` sur `bb9efb3` termine en 163,81 s.
Trois seuils historiques sont déjà dépassés avant cette passe : hash idle
120 441 steps (budget 76 686), sérialisation/restauration 207 974 (172 573), hash
fight 122 618 (76 684). La sortie est donc 1 ; ces seuils restent visibles et ne
seront pas réenregistrés. Les comparaisons de cette passe utilisent aussi le
baseline exact, pour distinguer dette existante et régression nouvelle.

Le profil de référence par frames VM porte sur 2 946 tics : moyenne 49 524,87,
p99 125 157, maximum 167 756 ; run_segment proving 106 855 mots. Les 26 goldens
passent dans les deux profils, et le fuzz ponctuel de 10 000 tics est vert.

Artefacts de cette passe : `/tmp/hellproof-cairo-pass/` ; le profil de référence
figé est `/tmp/hellproof-idle-integrated-checks/tics.json` (identité exécutable
contrôlée avant comparaison). Les ressources et sorties observées restent
séparées des estimations de frais ou de temps de preuve.

## Pistes écartées et portée de la passe

- Fusionner les flags dans `is_ours` n’améliore pas le ticker : ce helper n’y est
  pas utilisé. Les tests d’armes possédées et d’intercepts utilisent déjà des masques.
- `doom_map::reject_of` expose son tableau de diviseurs publiquement. Remplacer
  arbitrairement division/modulo par AND modifierait le comportement pour un
  diviseur non puissance de deux. Aucune restriction implicite de l’API n’est ajoutée.
- Les divisions signées, arrondis de `fixed`, ordre des acteurs, index de grille
  et appels RNG restent exacts. Ni précision réduite ni cadence abaissée.
- Réduire davantage le coût de preuve nécessite encore de traiter les coûts
  fixes et les postes dominants. Le compactage de carte S13 a été rejeté sur
  mesure ; le réintroduire sans résoudre son coût de chargement serait une
  régression. Cette passe ne change ni le format de preuve ni son registre.

## Intégration et validation finale

La fusion `49f2a66` intègre la passe dans `codex/game-integration`, avec les
identités client migrées explicitement. `main` conserve les squelettes du jeu.
Le corpus complet passe en 1 365,78 s : 26 cas dans chacun des deux profils,
7 575 tics logiques, 149 coupes, 123 frontières sérialisées et 175 enveloppes D14
indépendantes par profil. Les goldens et les six identités exécutables restent
inchangés pendant la campagne. EXIT atteint le tic 677 avec 29 points de vie
et quatre objets. Le fuzz de référence de 10 000 tics concerne l’ancien moteur.

Le client passe 259 tests sans cas ignoré, dix smokes Chromium headed et le
replay EXIT677 dans le navigateur. Ces contrôles utilisent le nouveau moteur
et ne génèrent aucune preuve. Les plafonds, D2/D29 et C3 restent ouverts.

# STATUS — point d'avancement

> Mis à jour le 2026-09-13 : jeu réel assemblé sur `codex/game-integration` (`49f2a66`), moteur `ee5f819` ; `main` conserve les squelettes du jeu.
> P1.9 : **573 tests Cairo**, **107 018 mots** ; moyenne exacte **48 543,68 steps/tic**, p99 **122 942**. D2/D29 restent manqués.
> P1.10 : **26/26 replays dans chacun des deux profils** sur ce moteur, EXIT677 compris ; fuzz 10 000 tics validé sur le moteur précédent `0c8a3a8`. Nightly durable restant.
> Client : rendu v1, contrôles, sauvegarde et F4 preuve réelle raccordés ; **259 tests unitaires verts**, migration explicite des identités. Psprites et partie complète prouvée restent ouverts.
> Preuve réelle historique quatre tics (`0c8a3a8`) : **41,55 s**, vérification WASM/native verte. Nouveau moteur contrôlé par execute, sans nouvelle preuve ; log21 reste incompatible avec le registre log20. Aucun GO C3/16 GiB.
> Dernière CI générale vérifiée verte : `34d7b93` (run `34769473077`) ; garde runtime WASM couverte par CI verte `34764805318`.
> **Reprise par un autre orchestrateur : lire `docs/ORCHESTRATOR-HANDOFF.md` en premier.**
> Le sponsor confirme l'arrêt de tous les agents Claude pour quota. Leurs commits et modifications
> non commitées sont conservés ; reprise par des agents Codex dans des worktrees distincts.

## Audit de reprise — 2026-09-13

Contrôles locaux sur `82e52db` (Scarb 2.16.0 / contrats 2.18.0, Foundry 0.61.0, Node 22.22.2) :

| Suite | Résultat |
|---|---|
| Cairo : format, build, tests, graphe, 16 benches | **511 tests / 23 cibles**, verts ; seuils de non-régression respectés |
| Contrats, fixtures décompressées | **147 tests** : phases 68, routeur 6, recomposition 20, DoomRuns 53 ; verts |
| Client, assets et fixtures Freedoom présents | **183 tests**, verts ; build vert |
| Client Playwright, rendu et leaderboard | **7 tests**, verts ; rendu SwiftShader 640×400 à 49,4 fps, CPU 0,29 ms/frame (sans jeu Cairo ni preuve simultanée) |
| WAD | **133 tests**, typecheck vert |
| Soumission | **73 tests**, 1 intégration devnet ignorée ; typecheck vert |
| Indexeur | **24 tests**, 1 intégration devnet ignorée ; typecheck vert |
| Rust sim | **7 tests**, format vert ; **Clippy rouge** (`is_multiple_of` exige Rust 1.87, MSRV déclaré 1.85) |
| Rust wrapper | **65 tests**, 5 tests de pipeline réel ignorés ; format et Clippy verts. Un échec intermittent de `metrics_and_health_are_exposed` au premier passage, puis test isolé et suite complète verts |
| REUSE 6.2.0 local | **4 expressions SPDX invalides**, dans des chaînes de générateurs Python ; la CI REUSE ne reproduit pas ce résultat |

Les premières erreurs de cache Scarb et de serveurs locaux provenaient du sandbox ; les relances
avec les accès nécessaires passent. Les validations supplémentaires sont détaillées ci-dessous ;
aucun déploiement Sepolia/mainnet n'a été lancé. Logs initiaux : `/tmp/hellproof-audit-20260913/`.

Écarts relevés sur la base d'audit (corrections intégrées détaillées plus bas) :

- [CI générale](https://github.com/bal7hazar/doom/actions/runs/34745984783) verte sur `82e52db`, mais
  [CI WASM](https://github.com/bal7hazar/doom/actions/runs/34707523047) en échec : build Docker réussi,
  comparaison `SHA256SUMS.linux` échouée, test Chromium non exécuté. **R11 reste ouvert.**
- La CI ne lance pas directement `doom_runs`, `recursion_outputs`, `infra/submit` ou `infra/indexer` ;
  Clippy est non bloquant. Les tests client dépendant des assets peuvent être ignorés silencieusement.
- **D28 n'est pas appliquée au défaut client/CLI** : `planPhasesAuto` choisit encore 6 transactions
  (`[1,3]`) ; le vérifieur optimisé et l'émetteur Python recommandent 5 (`[2]`).
- **R2 reste prioritaire** : les benches verts gardent les mesures existantes, pas les objectifs
  D2/D29. Mesuré sur ce `main` : physique 35 873 mots (32 678 sans slide vanilla), monstres 33 046,
  joueur 36 631 selon les harnais actuels ; tir de pistolet 100 790 steps, vue 6 172–8 059 steps.
  Ces contributions ne doivent pas être additionnées pour prédire la taille du programme intégré.
- `doom_game`/`doom_run` sont encore des squelettes sur `main` ; profil `proving` et test de taille
  du programme réel sont dans P1.9. Les ≥ 20 replays et le fuzz nocturne restent P1.10.
- **C2 / R4 : défaut confirmé dans P1.9 en cours** : deux ordres de listes `ThingGrid` donnent le
  même état sérialisé, mais le tic de ramassage donne 101 points de santé sans frontière et 100
  après reconstruction. Correction en cours : engager et restaurer l'ordre exact des listes ;
  nouveau schéma d'état version 2, sans changer le format public D14 à 10 felts.
- Les chiffres anciens des documents de pilotage sont historiques : D26 fixe les segments par AIR
  (plafonds de précaution 1,5 M steps avec threads / 2,3 M mono), D29 le programme à 100 k mots
  (plafond dur 120 k), D28 le vérifieur à 5 tx / 1,54e9 gas. Les ≈ 47 STRK sont au prix S5,
  pas une cotation actuelle. **C3 : critère PLAN ≤ 10 min, objectif opérationnel D2 ≤ 5 min** après partie.
- R1/R5 : mesures favorables sur M2 Max 64 GB et programmes de référence ; le vrai jeu, la contention
  jeu/preuve et le matériel 16 GB restent à valider en P3.7. Pas de nouveau changement de gameplay
  avant les leviers du profil S8. D30 clarifie seulement les métriques de bytecode.

Branches récupérées :

| Branche / worktree Claude | État | Suite |
|---|---|---|
| `s7-monsters-bytecode` / `agent-a6ac67f3ed7fc7f8f` | **intégrée par `8471b7e`** ; 55 tests et replay 700 tics inchangé validés ; ticker 14 209 mots sous `proving` | format/build/511 tests/graphe verts après merge ; limite de domaine D3 à `tic ≥ 2^29` confiée à P1.9 |
| `s8-player-bytecode` / `agent-ae639d60352cb6412` | **intégrée par `06058b1`**, HEAD récupéré/finalisé `273cb1a` ; 132 tests et checksum 350 tics inchangés | attribution source 18 830 mots proving ; différence historique harnais 20 354 (+354 sur 20 k), publiée séparément (D30) |
| `worktree-agent-a3f0a4e676dba3186` | `b11fd7f` assemble C2, garde D3, frontières optimisées et armure par impact | repris sur `codex/game-integration` (`8e1d041`) : 554 tests / 23 cibles, format/build/graphe et REUSE 1 609 fichiers verts ; taille 116 287 mots, cible 100 k encore manquée |

Vague UI/fuzz terminée côté implémentation : le panneau réel et les corrections
Worker (`e5cac03`) sont revus et fusionnés par **`3cb97c1`** sur
`codex/game-integration`. Le rendu v1 `f188fc8` et l’adaptateur `1b9816a` y étaient
déjà assemblés par `ffdabf0`. Le micro-harnais S13 est archivé sans migration du moteur.

La nouvelle campagne complète sur `0c8a3a8` passe **26/26 dans chacun des deux
profils**, en 1 411,36 s : 7 575 tics logiques, 371 mots terminaux non consommés,
une mort et une sortie au tic677. Par profil, 202 sorties d’état et 201 snapshots
sont comparés, dont 26 frontières vides. Les 26 pins restent inchangés. Le fuzz
suivant, sur le même moteur figé et le profil proving, termine **10 000 tics** en
**1 040,04 s** (seed20260913) : 158 cas, 11 épisodes, trois morts, zéro divergence.
158 contrôles D14 complets et 40 coupes ; 493 sorties d’état / 492 snapshots,
20 frontières vides comprises. Les 57 mots après état terminal sont exclus.
Les felts décodés restent <2^72 ; contrôle aux frontières publiques, pas de toutes
les cellules VM. Cette campagne ponctuelle ne constitue pas un historique nightly.

L’assemblage indépendant passe **243 tests client et 10 tests Chromium**, sans skip
dans cette sélection (Cairo, apparences, contrôles et rendu). Le niveau atteint
EXIT677 avec le nouveau rendu, sans erreur console ; écran final inspecté. Les
six exécutables reconstruits du moteur sont identiques au candidat. Avant cet
assemblage, 222 tests client et 12 E2E passaient (un E2E de preuve stub ignoré).

L’adaptateur prépare les frontières réelles depuis genesis dans un Worker distinct,
contrôle SHA/identité/D14/D13 et préserve le journal antérieur à F4. Root revalide
six frontières exactes et le pipeline réel : refus AIR, zéro preuve lancée,
export/import conservé, ancienne identité rejetée, Workers libérés et préparation
recréée au retry. F4 raccorde désormais cette API à l’écran de jeu ; les frontières
de départ déjà terminales sont explicitement refusées. Aucune admission ni
certification de partie n’est déduite de ces validations.

**Parcours des acteurs passifs** : 106 878 → **106 855 mots**, 567 tests Cairo,
35 ABI et 70 comparaisons de replays/coupes par profil verts. Root a revalidé
EXIT677 avec 17 mots terminaux exclus et 14 coupes par profil. Deux frames exactes :
idle300 **30 012 → 26 298 steps** (−12,37 %), fight493 **170 333 → 166 596**
(−2,19 %). Frontières et allocations inchangées. Petit roster de 29 monstres
dormants : **+3,07 %** de coût brut, dans les seuils existants. Les quantiles
complets ont été mesurés par frames VM sur 2 946 tics, puis root a remesuré
la référence D29 avec le même protocole : moyenne **53 245,88 → 49 524,87**
(−6,99 %), p99 **128 871 → 125 157**, maximum **171 470 → 167 756**. Tous
les tics gagnent 3 699–3 737 steps ; frontières de chaque chunk et cinq hashes
finaux strictement identiques. D2 reste dépassé. La référence D33 historique
53 309,24 ne servait pas à isoler cette dernière optimisation.

Preuve root du même exécutable SHA256 `5a3817dc…57b28`, quatre tics de marche :
**2 193 266 steps** selon execute, **41,553 s**, **11 643 256 832 B** linéaires,
**4 375 790 B** de preuve, **log21**. Vérification WASM et native/bzip2 réussies ;
altération et mauvais bootloader rejetés ; dix sorties D14 identiques à D29.
La preuve précédente mesurait 2 208 390 steps selon le même compteur execute
(2 208 389 dans le compteur antérieurement cité). Le temps isolé ne constitue pas
une accélération statistique. D29 dépasse toujours la cible de **6 855 mots** ;
registre, plafonds et validation de partie complète C3 restent inchangés.

Worker/journal et contrôles après fusion : **222 tests client sans skip**, 13 tests
du harnais, types/build/REUSE et **neuf smokes Chromium verts**, dont vrai verrou
souris, sauvegarde/reload exact, import/export et récupération après état importé
rejeté par Cairo. La revue visuelle et l’écran « Level complete » au tic 677 sont
également vérifiés. Ce premier lot précédait le raccord F4 décrit ci-dessus ;
les psprites restent incomplets et aucun succès de preuve complète n’est revendiqué.

Root a aussi revalidé 386 tics exacts par mode d’isolation, reprise de huit mots
après reload, refus busy/order et ABORT. Maximum 465 436 672 B de mémoire linéaire.
Test prolongé : 10 000 tics neutres / mots acquittés en 172,47 s, 39 mesures toutes
à 258 801 664 B, restauration état/rendu exacte. Ce contrôle idle n’est ni le fuzz,
ni un oracle par tic, ni une mesure RSS/16 GiB/preuve concurrente.

La CI générale **`34764805296`** (sept jobs) et WASM **`34764805318`** (deux jobs)
sont vertes sur `7415869`. L’artefact GitHub confirme **1 200 072 assertions**
runtime, zéro erreur, puis les deux modules reconstruits identiques aux SHA
commités et inchangés après réapplication de la transformation Memory64. Le run
suivant `34766545806` sur `ce964a0` a échoué uniquement sur le test Rust
`identical_leaves_are_proven_once` : deux feuilles prouvées comme attendu, mais
compteur de cache 3 au lieu de 2. Le réordonnancement asynchrone est à auditer ;
relance ciblée annulée par le push suivant. CI `34767083328` entièrement verte
sur `c281684`, sans assimiler ce vert à une correction. Le correctif test-only
`e715fb3` est intégré par `525eced` : 77 tests wrapper verts, ancienne assertion
réfutée déterministement, 60 répétitions sans retry ; root revalide les 12 tests
service après fusion. Le scheduler de production est inchangé.


**S12 résolu localement, intégré `e274bec`** : quatre chargements SIMD tronquaient
les adresses Memory64 dans Liftoff des versions V8 de Node testées. Chromium 153
exécute correctement le binaire original. Une transformation structurée du build
préserve les adresses et la sémantique ; les deux modules Docker reconstruits en
763 s sont identiques aux copies validées par de vraies preuves. Root a revalidé
les tests Rust, 400 024 contrôles runtime et REUSE après merge. Aucune modification
AIR, paramètres, registre ou plafonds. [Matrice S12](spikes/S12-wasm-proof-triage.md).

**D29 assemblée `8ae7f1c`** : 110 015 → **106 878 mots**, cible 100k toujours rouge.
565 tests Cairo / 23 cibles, cinq tests Python, build dev/proving, graphe et REUSE
verts ; les six exécutables root sont identiques aux candidats de l’agent.
35 comparaisons ABI proving et quatre enveloppes malformées revalidées par root ;
l’agent a aussi validé 70 comparaisons de replays et 35 ABI par profil.
Contreparties publiées : replays proving −0,83 % à +0,25 %, dev +1,01 % à +1,75 % ;
aucune accélération générale revendiquée. Preuve du nouveau programme : **2 208 389
steps**, **42,16 s**, **11 643 518 976 octets** linéaires à quatre threads ;
vérification native indépendante/bzip2 vertes et dix sorties D14 exactes.
Ce segment de quatre tics reste RUNNING et log21 ; ce n’est pas P3.7.

La passe D29 suivante n’a retenu aucun des trois candidats : flags −301 mots
mais fort surcoût VM ; hauteurs −702 mots mais deux budgets specials dépassés ;
admission −24 mots pour +17 steps/tic. Sources restaurées et six exécutables
reproduits à l’identique. Le programme reste à 106 878 mots. L’audit suivant
examine les domaines et conversions des coordonnées Doom ; aucun gain n’est
encore mesuré et aucun changement de représentation n’est approuvé par ce constat.
L’audit des coordonnées a ensuite écarté une migration globale : les domaines
admis et fallbacks sont plus larges que les positions habituelles. Sur idle300,
les comparaisons ciblées ne représentent que 62/30 012 instructions ; la passe
suivante vise le parcours/classification des acteurs, sans résultat retenu à ce stade.

**P1.10 livré `a7aadad` + `38d8993`**, non promu sur main : 25 scénarios dans chacun
des profils dev/proving, 6 898 tics logiques par profil, 24 états finaux distincts,
couverture mort/ramassage/combat ; pas d’EXIT. Fuzz : **10 000 tics réellement
avancés**, 158 cas / 11 épisodes, trois morts, 57 mots non consommés exclus,
zéro panique/ABORT/divergence. Contrôles aux frontières : 493 états et 492 rendus
exposés, pas 10 000 snapshots intermédiaires. Onze tests du harnais verts.
La campagne finale D29 a passé 25/25 cas dans chaque profil en 1 244 s,
avec six empreintes exécutables inchangées et sans réécrire les pins ; le garde CI 100k
reste strict et rouge, le workflow ne le contourne pas.

**Trajet EXIT677 confirmé**, sans injection d’état : 29 PV, 0 kill / 4 items /
0 secret. Replay intégral Scarb dev/proving, dix sorties D14 contre oracle
Poseidon et six empreintes exécutables inchangées. Root reproduit les 677 mots
dans Chromium avec ABI complète identique, refus d’un input après EXIT et
restauration complète exacte. Ce trajet ferme l’absence de sortie légale ; son
ajout comme 26e golden est intégré par `e998e52` / `7df2520`. Les 25 anciens
pins restent inchangés ; les 17 mots après EXIT sont exclus de D13/du compteur.
Un refus de statut conserve un contre-exemple complet et reproductible. Aucune preuve cryptographique de la partie
complète n’a été produite. Référence `/tmp/hellproof-exit-route/report.md`.

**S11 livré puis optimisé `4936c2` / `0e3ca8c`**, isolé sans migration : le hash
BLAKE9 passe de 700 997 à **373 349 steps**, contre 66 867 pour Poseidon.
Marche4 leaf : **2 889 385 steps** après optimisation, maximum toujours log21 ;
bytecode wrapper 111 052 mots. Le format, le digest complet et les sorties de jeu
restent exacts. Malgré la réduction des auxiliaires Poseidon, ce candidat dépasse
les plafonds et accroît le coût VM ; **Poseidon reste le hash d’état de production**.
Aucune preuve S11 ni économie RAM/temps de preuve n’a été mesurée.

Les compteurs AIR et l’admission wrapper sont intégrés sur `main` ; les deux passes frontière
et le parcours monstres sont assemblés dans `codex/game-integration`.
Les passes frontière et armure sont relues et assemblées sur la branche
d’intégration ; `main` conserve encore les squelettes. Le complément P1.9 `50e3c2f` ajoute six
régressions de frontières : **57 tests game verts** après intégration, smoke CI `genesis 0`,
codec et actionlint verts ; aucun changement de code de production après `b11fd7f`.
L'orchestrateur tranche les leviers R2 à partir du programme complet. Ensuite : P1.10 et Worker/contrôles/écrans client,
puis P3.7. Sepolia nécessite toujours une décision explicite du sponsor.

Mesures monstres intégrées : API complète **21 220 mots dev / 17 963 proving** ; chemin ticker
**16 241 dev / 14 209 proving**. Les 55 tests et leurs références n'ont pas été modifiés par la passe
de style. Moyennes des micro-scénarios : 13 359 steps/tic à 5 éveillés, 30 711 à 8 et 61 425 à 20 ;
29 dormants sans cible : 10 183. Ces mesures ne représentent pas un tic complet du jeu.

Corrections d'audit intégrées par **`375f092`** : Clippy Rust devient bloquant après correction du
MSRV et d'un formatage redondant ; les métriques wrapper sont attendues jusqu'à publication avec
une échéance bornée. Revalidation sur `main` : format/Clippy verts, sim **7 tests**, wrapper **65
tests** (5 pipelines lourds ignorés). `actionlint` vert. La CI ajoute `doom_runs`,
`recursion_outputs`, submit et indexeur, et prépare les assets/fixtures avant les tests client.
Trois générateurs SPDX sont corrigés sans changer leur AST ni leurs sorties : REUSE 6.2.0 ne
signalait plus que le générateur joueur ; **REUSE est entièrement vert après `06058b1`** (1 578 fichiers).
Complément intégré par **`30f8d77`** : oracle `poseidon-py==0.1.5` installé dans le job submit,
image Rust épinglée par digest et runner Docker Linux ARM64 conforme à la référence. Rebuild local
754 s, **les deux hashes Linux existants sont reproduits bit à bit**, sans les remplacer. Avec ces
artefacts : Node mono/4 threads **37,82/11,99 s**, Chromium mono/4 threads **33,09/10,19 s**,
sans isolation repli mono **33,4 s** ; **cinq preuves vérifiées**, 755 280 felts chacune (programme
arithmétique k14). Chromium utilise 1,83/1,96 GiB. Le smoke construit désormais son exécutable Cairo
et rapporte le hash du fichier réellement chargé. `actionlint`, syntaxe JS et REUSE verts.
**CI générale entièrement verte sur `83af5dd`**, run `34749101091` : les six jobs passent,
y compris les nouvelles suites et E2E. **Workflow WASM [34749101097](https://github.com/bal7hazar/doom/actions/runs/34749101097) entièrement vert** : build ARM64 reproductible, smokes Node et Chromium, repli sans isolation. L’échec de démarrage sans job `34748732776` n’est pas reproduit.

Joueur intégré par **`06058b1`** : 132 tests inchangés, checksum **4760390154965462** sur 350 tics,
couverture agent **93,7 %** (hors adaptateur `player_tic`, dont les tests ordinaires passent),
11 benchmarks et 4 tests du garde. Revalidation workspace après merge : format/build/511 tests/graphe
verts. Idle 1 303,5 steps, marche 1 671,5, tir cible 9 309, tir manqué 98 944. La visée est inchangée.
La contribution réelle du joueur dans `doom_run` reste à mesurer ; l'attribution du harnais
n'établit pas à elle seule la conformité du programme complet.

**S8 provisoire, avant optimisation des frontières** (`df1888d`) : `run_segment` proving **117 531
mots**, cible 100 k manquée, seulement 2 469 mots sous le plafond dur. État genesis **6 362 felts**
(+533 pour préserver la grille). L'ABI Scarb 2.16 → SimProgram cairo-lang 2.19.4 est exécutée en natif.
Avant intégration du dernier joueur : appel `step_tic(state,[])` **528 143 steps**, un idle **585 777**,
marche **601 998** ; huit idle en `run_segment` ajoutent **53 725 steps/tic**, taxe bootloader exclue.
Ces chiffres ne sont pas un p99 ni une mesure navigateur. Le coût fixe place **R5** sur le chemin
critique : une ligne dédiée optimise sérialisation, parseur et snapshot sans réduire la validation,
changer les hashes ou le gameplay. C2 : cas 101/101 et replay de combat avec 28 frontières passent.

**R1 requalifié sur le jeu réel** : preuve native de quatre tics de marche, programme de 117 531 mots,
paramètres feuille du navigateur mais **hash de programme Poseidon**. Cet essai suit l'ancienne
hypothèse D4/D29 ; le WASM actuel emploie déjà **Blake** (`prover/wasm/src/core.rs`). Exécution directe **850 629 steps**, bootloader
**1 499 208**, dont **65 138 instances Poseidon** (6 367 hors bootloader). La preuve atteint
**environ 32 GiB RSS observés** et expire à **180 s**, groupe arrêté et verrou libéré ; **aucune preuve
vérifiée produite**. Logs : `/tmp/game-p19-native-segment/`. Le plafond de steps D26 et les seules
hauteurs estimées par `resources()` ne garantissent pas la mémoire : les composants auxiliaires et
la largeur totale des traces doivent être mesurés. Pas de relance identique. Comparaison **Blake réussie (D31)** : même programme et mêmes arguments,
**2 681 208 steps**, **6 368 Poseidon**, **53,50 s**, **11,73 GiB RSS max**, **765 202 felts**, preuve
native vérifiée. Les dix sorties publiques sont identiques. Le WASM actuel exécute ces mêmes
compteurs en 1,49 s sous Node (mémoire d'exécution 0,673 GiB, hors preuve). Les traces auxiliaires
omises par `resources()` expliquent le mauvais dimensionnement. **WASM Node 4 threads : preuve
vérifiée en 42,225 s / 11,524 GiB linéaires**, mais `trace_log_size = 21` réel contre 20 annoncé par
`resources()`. Le composant fautif est **`blake_g`**, confirmé par décodage de la preuve bincode ;
**incompatible avec le registre `doom` actuel** malgré validité locale. Le registre expérimental
`doom_21` construit le circuit correspondant (75,83 s / 17,90 GiB RSS max ; 25,99 GiB empreinte
mémoire macOS). **Repli final vérifié** : racine 95 325 felts, vérifieur Cairo existant
5 333 257 steps, recomposition indépendante des huit sorties exacte. D32 réouvre la voie log21,
sans modifier les défauts produit ni les plafonds. Détails dans [S9](spikes/S9-proof-sizing.md). Logs Blake :
`/tmp/hellproof-audit-20260913/hash-cost/`.

**P1.9 assemblé, après les corrections** (`b11fd7f`) : `run_segment` **116 287 mots proving**,
`step_tic` 117 839, genesis 47 563. Frontière sans tic **288 045 steps** contre 528 154 avant
optimisation (−45,5 %), même ABI/felts et validations conservées. Profil exact de **2 946 tics**,
frontière exclue : moyenne **83 003**, p99 **168 038**. Par replay (moyenne/p99) : idle
52 850/56 703, marche 87 569/131 720, porte 105 811/209 329, combat 102 731/194 790,
mort 80 303/145 561. D2 (12 k/p99 25 k) et D29 (100 k mots) restent hors cible.
Campagne root complète : seul `doom_game` échoue sur trois budgets hash/sérialisation ;
les autres crates passent. Aucune rebaseline pour masquer ces dépassements.

**C2 et armure corrigés sur la branche d’intégration** : ordre exact de grille engagé/restauré,
garde haute horloge D3, absorption avant douleur/mort à chaque impact. Les tests couvrent deux
attaquants, épuisement, arrondis, attaques suivantes et RNG. Deux pins du replay porte corrigent
un défaut distinct : un puff de mur attribuait à tort le dernier attaquant au joueur. Comparaison
indépendante : un seul felt d’état change (attaquant 132 → 64), les quatre autres replays sont stables.

**Chromium réel (S9)** : trois preuves à quatre threads vérifiées **40,167–48,128 s / 11,524 GiB**,
préimages exacts. Mono : premier essai arrêté à 150 s ; second vérifié **136,425 s / 11,449 GiB**
avec échéance plus longue. Hôte 64 GiB, aucun jeu concurrent ; les plafonds ne changent pas.

**Correction AIR intégrée par `d848951`** (`4309399`, `5ed01d0`, `962cbb4`, `97a2443`) : 43 hauteurs variables confrontées aux
claims de preuve, 11 tests Rust dont VM réelle. `blake_g` est correctement annoncé à log21,
`fits_leaf_registry=false`, prétraitement admissible. Planificateur corrigé pour utiliser les
compteurs auxiliaires bruts et rester conservateur sur un maximum inconnu. Les anciens compteurs
sont refusés ; chaque preuve, reprise comprise, réexécute et revalide ses ressources. Un refus
conserve le segment sans lancer `prove` ni essayer un autre nombre de threads. **193 tests client
verts sans saut et build vert**, revérifiés par l’orchestrateur sur `main`. Rebuild Docker ARM64
779,2 s : nouveaux hashes Linux mono `3e94a4c0…479a5`, threads `fdb977ad…4277c`, vérifiés par
l’orchestrateur ; hashes macOS historiques conservés. Les deux nouveaux modules reproduisent
les compteurs du programme réel et ses 43 hauteurs. Cinq preuves k14 vérifiées : Node mono/4 threads,
Chromium mono/4 threads et fallback sans isolation. **Reconstruction GitHub indépendante verte** :
[run 34751692540](https://github.com/bal7hazar/doom/actions/runs/34751692540), sur `d4924d9`,
reproduit les deux hashes ARM64 et vérifie les smokes Node/Chromium et le repli sans isolation.

**Parcours monstres optimisé en intégration** (`a2343cb`, merge `883efbb`) : ticker idle
46 802 → **34 765 steps** (−25,7 %), combat au tic 493 136 183 → **123 418** (−9,4 %).
Le programme intégré passe à **115 814 mots** ; `step_tic` 117 366. Les gros contextes passent
par pointeur, sans changer les règles de jeu. Équivalence exacte sur **247 comparaisons par profil**
dev/proving, dont cinq replays et 118 frontières sérialisées. Revalidation root : **56 tests monstres
et 57 tests game verts**, build proving vert. Les copies de chaque Mobj restent un levier distinct.

**Fuzz ponctuel de frontière réussi**, référence immuable `b11fd7f` : **10 000 tics réellement
avancés**, 157 séquences, dix épisodes, seed `20260913`, Scarb 2.16/proving, 900 s. Exécution entière
contre découpage aléatoire : état, rendu et statut exactement identiques ; tous les felts état/rendu
restent < 2^72. Contrôles périodiques de frontière vide et de chaînage D14 verts, aucun ABORT.
Ce passage porte sur la référence antérieure à l’optimisation du parcours monstres, conserve cinq
replays et n’installe pas encore le fuzz nocturne P1.10. Traces : `/tmp/hellproof-audit-20260913/fuzz/`.

**Seconde passe frontière assemblée** (`f3858bb`, intégration finale `91719f8`) : lecteur consommant
un span, lecture de blocs contrôlés, contextes partagés par pointeur et sérialisation genesis réutilisée.
Seule : run 111 321 mots, frontière native 275 020 steps ; avec les monstres : **run 110 848,
step 112 334, genesis 47 426 mots**. Revalidation root : **563 tests / 23 cibles**, format, build
dev/proving, graphe et REUSE **1 638 fichiers** verts. La passe conserve les cinq goldens et les
70 comparaisons ABI par profil (48 frontières), plus les enveloppes invalides. Les trois échecs
historiques hash/serde et le dépassement D29 de 10 848 mots restent visibles. La dette du journal
de grille croît de 25 steps par entrée ; elle est remise à plat aux frontières, pas bornée dans le tic.

**Simulation navigateur réelle (S10)** : sur l’intégration finale, 386 appels dans un Worker Chromium
mesurent **46,6–57,8 ms moyens/tic, soit 17,3–21,4 tics/s**. Les cinq sorties finales complètes
correspondent exactement aux références Scarb, mort au tic 846 comprise. Tous les appels dépassent
28,57 ms ; la copie JS prend moins de 0,1 ms en moyenne. Mémoire linéaire ~67 MiB, sans rendu ni
preuve simultanés. La frontière reste dominante ; un prototype de VM conservée entre tics est lancé
sans modifier les entrypoints prouvés. [S10](spikes/S10-live-simulation.md) détaille méthode et limites.

**Admission wrapper intégrée par `14cce87`** : pin du task obligatoire en subprocess/from_proof,
pin du bootloader dérivé du fichier configuré, décodeur D14 commun aux deux routes, ancien layout
disponible uniquement via configuration explicite. Une reprise revalide le fichier de preuve réellement
envoyé au circuit, même si un ancien enregistrement disait `verified=true`. Les felts hors du corps et
le faux hex Unicode sont rejetés sans panic. Le lock autonome leaf-verify retrouve les dépendances Git
épinglées et un nouveau job CI le compile/teste. Revalidation root : **76 tests wrapper + 2 leaf-verify +
195 client**, Clippy/format/build/actionlint et REUSE **1 590 fichiers** verts. Preuve réelle S9 vérifiée
en ~25 ms ; bzip2 admis, corruption et mauvais bootloader rejetés. Aucune preuve nouvelle ni modification
de registre/paramètres. Ce contrôle d’identité ne certifie pas à lui seul l’admissibilité AIR/mémoire.
La [CI générale 34752596592](https://github.com/bal7hazar/doom/actions/runs/34752596592), sur
`73d0c0e`, est entièrement verte : **sept jobs**, dont compilation, Clippy et tests du vérifieur
autonome avec le lock et le nightly épinglés.

**Taxe fixe encore bloquante** : sur l’intégration `91719f8` de 110 848 mots, le WASM Blake exécute
**2 134 627 / 2 194 469 / 2 363 470 steps pour 0 / 1 / 4 tics** (ressources seules, sans nouvelle preuve).
Même sans tic, il dépasse le plafond threads 1,5 M ; quatre tics dépassent aussi 2,3 M mono.
Les 15 456 compressions Blake imposent log21
à `blake_g`. Une migration de registre seule ne résout donc ni le découpage ni le temps réel.

**D28 appliquée sur `main` par `b00c90b`** (`06b4394`) : `[2]` devient le défaut client/CLI,
soit **cinq transactions vérifieur, plus une transaction consommateur**. Coupes explicites,
replis calldata/gaz et marges R7-A1 conservés ; `--single` reste `register_member` après repli.
La coupe FRI est sauvegardée avant envoi, liée à l’id/routeur/appelant, puis restaurée avant
estimation. Une reprise ancienne sans coupe identifiable est refusée avant envoi ; son tag seul
ne suffit pas à choisir les couches FRI restantes. Revalidation root : **95 tests submit + 195
client**, typecheck/build et REUSE **1 593 fichiers** verts ; calldata complète comparée à Python
sur trois racines réelles, dont `n4` P4.1. Le test devnet reste ignoré, aucune nouvelle transaction.
Les reçus P4.1 existants totalisent 1 540 234 480 L2 gas ; pire consommation 38,55 % du cap,
borne dérivée ×1,15 à 44,33 %. Ces mesures exigent le vérifieur optimisé ; une classe ancienne
reste soumise à sa propre simulation. La [CI 34753506939](https://github.com/bal7hazar/doom/actions/runs/34753506939) est entièrement verte
sur `c383f14` : les sept jobs passent.

**D33 et continuation assemblées en `f306c6a`**, sans promotion du jeu complet sur `main` :
les acteurs inchangés conservent leur boîte entre les passes. Le vrai tic idle300 baisse de
39 433 à **29 833 steps** (−24,35 %), fight493 de 190 594 à **168 845** (−11,41 %).
Run **110 015 mots**, step 111 502, genesis 47 415 ; les six exécutables dev/proving sont
reproduits bit à bit après merge. Root : **565 tests / 23 cibles**, format/build/graphe verts,
**70 comparaisons proving de replays/D14/découpes**, **35 cas ABI** et quatre enveloppes invalides
vérifiés ; pins et sorties inchangés. Les allocations supplémentaires des dormants sont incluses.
Le profil root complet des **2 946 tics** donne désormais **53 309 steps moyens, p99 128 207**,
frontière exclue : amélioration cumulée de 35,8 % en moyenne contre `b11fd7f`, mais D2 reste dépassée.
Ressources Blake seules : **2 113 239 / 2 152 507 / 2 260 220 steps pour 0 / 1 / 4 tics** ;
15 355 compressions, `blake_g` log21, refus registre maintenu. Quatre tics passent sous 2,3 M mono,
aucun des trois cas sous 1,5 M threads ; aucune nouvelle preuve de cet exécutable.

La continuation R5 (`b51cefe`, `350d6db`) conserve le vrai moteur Cairo entre les mots.
Root a reproduit la référence puis la combinaison D33 : **386 tics exacts**, **11 tests Rust**,
Clippy/format verts. Chromium combiné : **8,8–16,6 ms moyens/tic** maintenance comprise,
**512 MiB** linéaires, p99 **38,2–45,4 ms**, onze appels sur 386 dépassant 28,57 ms. L’export puis
recréation de VM tous les 32 tics est compris dans ces mesures. Le client reste à brancher,
le journal doit commencer au premier tic, et la contention/longue durée/16 GiB restent à mesurer.
Voir [S10](spikes/S10-live-simulation.md) ; aucun changement de gameplay, de hash ou de budget.
Le [branchement client](design/real-game-session.md) reste à livrer ; l’audit précise notamment
le journal F4 incomplet, le checkpoint absent des arguments et les différences de snapshot/flags.

## Terminé (mergé sur `main`)

- Phase 0 : spikes S0–S5 + S4b (tous GO), revue G0, décisions D1–D24 (`docs/G0.md`, `docs/DECISIONS.md`).
- Socle : workspace Cairo (18 crates), licences REUSE, CI 7 jobs + `prover-wasm.yml`, graphe de dépendances.
- Crates génériques (10) : `fixed`, `bam`, `geom2d`, `bsp`, `blockmap`, `prng`, `ticcmd`, `fsm`, `state_hash`,
  `segment` — 238+ tests, budgets de steps mesurés.
- Crates Doom : `doom_map` (E1M1, 18,3 k mots, `CELL_NODE`), `doom_things` (mobjinfo/états/rndtable).
- Outils : `@hellproof/wad` (133 tests, accélérateur conservatif), workspaces npm.
- Client : renderer WebGL2 + assets Freedoom + `RenderSnapshot` (79 tests, Playwright).
- Prouveur : `prover/sim` (cairo-vm wasm temps réel), `@hellproof/prover-wasm` (WASM64, threads, `resources()`),
  `prover/wrapper` (feuilles, arbre, lots, mode `from_proof` avec patch `leaf_prover`, Docker).
- On-chain : vérifieur de circuit résumable en calldata (5–6 tx, 3,81e9 gas), `DoomRuns` (53 tests),
  validation bout en bout sur devnet avec de vraies racines à 10 felts (116,96 STRK ≈ 3,35 $ par lot).

## Reprise du 2026-09-13

Mergés et poussés le matin : `doom_specials`, `doom_physics` (+ suppression des shims `compat`), pipeline de
preuve client (P3.2/P2.5), orchestration on-chain (P4.3, 73 tests). Workspace Cairo vert (23 cibles), client
138 tests, `infra/submit` 73 tests. Worktrees des branches mergées nettoyés.

Vague lancée le 2026-09-13 :

| Ligne | Modèle | Objet |
|---|---|---|
| S7 | Fable | `doom_physics` : bytecode 56 961 → ≤ 12 000 mots, `check_sight` ≤ 2 500 steps, sans changer l'API ni les résultats |
| P1.7 `doom_player` | Opus | mouvement joueur, armes, ramassages, dégâts, mort ; budget 4 000 mots |
| P1.8 `doom_monsters` | Opus | IA des 5 types, cadencement D3 (8 éveillés/tic, `A_Look` 1/4) ; budget 5 000 mots |
| Wrapper | Sonnet | upload par segment reprenable (D27) |
| P4.1 | Fable | −30 % de gas on-chain (inversion par lots, QM31 paresseux) sous tests d'équivalence |

Rendus dans la journée : wrapper par segment (mergé, client basculé par défaut), `doom_monsters`
(mergé : 55 tests, 93 % de couverture, `monsters_ticker` avec la fenêtre D3 ; **mais 34 014 mots de
bytecode et 17 540 steps/tic à 5 monstres éveillés, 81 311 à 20**, presque tout dans la physique :
un tir de zombieman ≈ 14 400 steps, une traversée de vue 7 700–9 700, un pas de chasse ≈ 4 300).

**Risque principal actualisé (R2)** : physique + monstres = 91 k mots (budget 32 k tout compris) et
≈ 30 k steps/tic à 8 éveillés contre 12 k visés. Réponse : (1) S7 en cours sur la physique (mots et
`check_sight`), puis la même passe de style sur `doom_monsters` ; (2) profil d'un tic complet dès
`doom_game` ; (3) leviers si insuffisant : plafond de 4–6 éveillés, hitscan borné en portée/cellules,
17,5 Hz (R2-A7). Décision à prendre après S7.

Après-midi : `doom_player` (132 tests, mais 39 890 mots ; un tir de pistolet manqué = 114 k steps),
P4.1 (**gas on-chain −60 % : 1,54e9, 47 STRK/fait, 5 tx**), S7 (physique 57 k → 36 k mots, outillage
d'attribution `infra/sierra_words`, règles de code S7 §8) — tous mergés. **D29** : budget programme révisé
à 100 k mots avec profil `unsafe-panic`. Lancés : passes de style sur `doom_monsters` et `doom_player`,
P1.9 `doom_game` + `doom_run` avec profil d'un tic complet, P4.4 indexeur + leaderboard.

Ensuite : `doom_game` + `doom_run` (P1.9), replays dorés (P1.10), Worker sim client (P2.3/P2.4), E2E C3.

### Dernier contrôle CI

Le run `34768352897` est entièrement vert sur `92edde5`, correctif déterministe
cache wrapper inclus. Les preuves lourdes historiquement ignorées ne sont pas
réactivées par ce test ; le garde runtime WASM reste couvert par le dernier run
WASM vert `34764805318`.

### S13 : compactage de carte écarté après mesure

L’audit identifie 8 613 mots de payload compressibles, mais `load()` est rappelé
par tic et aux frontières : aucune intégration directe n’est retenue. Le premier
micro-harnais isolé BM_ITEMS (`19a869e`, archivé sur l’intégration) reproduit
exactement 2 064 ids ; 14 cas limites et quatre paires de rejets passent.
**2 196 → 757 mots**, mais **20 694 → 86 111 steps** : +65 417 au chargement
contre seulement ~21 225 économisés selon le modèle Blake. Root reproduit ces
mesures après fusion du spike isolé. **NO-GO pour cette variante**, arrêt sans
élargissement ni modification de load/ctx_of, de l’état ou du moteur. Une sortie
zéro du harnais signifie exactitude, pas succès du filtre de performance.

### Panneau de preuve réel et revue des arrêts

La livraison `e5cac03`, fusionnée par `3cb97c1`, capture chaque objet journal dès
le début de partie, pause le jeu sur F4 et conserve export/reprise et anciennes
parties. Le contrôle réel AIR refuse toujours log21 face au registre log20 ;
arguments, onze felts de préimage et ressources restent dans le `.hellproof`.
Aucune preuve ni soumission automatique : les smokes interdisent l’appel prove.

La revue indépendante a reproduit puis clos trois défauts : Worker perdu sur
rejet d’init, vérificateur local survivant au retrait, retry de preuve après arrêt
dur. Les Workers sont détenus dès création ; l’arrêt dur invalide les réponses
tardives, l’arrêt doux termine le segment. **259 tests client passent** sur le
client identique à l’intégration, dont les régressions d’annulation. Les budgets
D2/D29, le registre et C3/P3.7 restent ouverts ; les psprites animés restent à faire.

Après fusion, root valide **13 smokes Chromium headless** (12 dans la sélection
principale, un d’apparence séparé), build TypeScript/Vite et REUSE **1 772/1 772**.
Le test de pointeur natif conditionnel est exercé en headed : F4 libère le verrou,
le pointeur tourne/tire dans Cairo. Un favicon absent, visible uniquement dans ce
contrôle headed, est déclaré explicitement (`eb76557`) ; les assertions console
restent intactes. Une collision de fichiers temporaires entre campagnes root a
été corrigée en rejouant séquentiellement avec des sorties isolées.

Le correctif favicon est fusionné par `48b9dc7` ; root revalide le test d’apparence
headed en 8,1 s, sans erreur console. Tous les agents de cette vague ont terminé.
Prochain chemin critique : réduire D29/D2 et rendre l’admission AIR compatible
avec le registre, puis mesurer la partie complète et la concurrence sur 16 GiB.
Aucun changement de plafond, de cadence ou de gameplay n’est adopté ici.


### Préparation Sepolia signalée par le sponsor

Le sponsor indique disposer de 350 STRK sur un compte Sepolia et des variables
`SEPOLIA_ACCOUNT_ADDRESS`, `SEPOLIA_PRIVATE_KEY`, `SEPOLIA_RPC_URL` (Infura)
dans `~/.hellproof`. Solde non vérifié par l’orchestrateur ; aucun accès aux
credentials ni transaction dans cette passe d’optimisation Cairo. Cette
information prépare P4.5, sans lever les gates techniques du jeu prouvé.

### Passe de calculs Cairo S14 intégrée

Fusion `49f2a66` sur `codex/game-integration`, après revue croisée et validation
complète. Trois changements : pliage partagé de `sin_cos`, masques sur deux
modulos de cadence/rotation IA, copies de hauteurs évitées ou réduites. Le détail
et les sources sont dans [le rapport de calculs](design/cairo-calculation-costs.md).

Sur 2 946 tics mesurés, chacun améliore son coût ; moyenne −1,98 %, p99 122 942.
Le programme proving passe de 106 855 à 107 018 mots (+163). Le segment de marche
à quatre tics coûte 1 956 steps de plus ; à 32 tics, 2 328 de moins. Les entrées
prouveur grandissent dans les deux cas. Aucun gain de durée de preuve n’est déduit.

Validation : 573 tests Cairo, 258 micro-exécutions avec oracle, 259 tests client,
10 smokes Chromium headed et replay navigateur EXIT677. Corpus complet terminé
en 1 365,78 s : 26 cas par profil, 7 575 tics logiques, 149 coupes et 175 enveloppes
D14 indépendantes par profil ; goldens et six SHA exécutables inchangés. Le
formatage reconstruit les mêmes exécutables. Les trois dépassements de budgets
historiques du bench global sont inchangés, sans réenregistrement des seuils.

La cadence reste 35 Hz. D2/D29, admission AIR et C3 restent ouverts ; aucun
relèvement de plafond ni déploiement. Tous les agents de cette passe ont terminé.

Après fusion, les 259 tests client sont rejoués sans cas ignoré ; build
TypeScript/Vite et REUSE 1 785/1 785 passent. L’arbre suivi est identique à
l’assemblage validé avant ajout des documents de pilotage.

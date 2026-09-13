# STATUS — point d'avancement

> Mis à jour le 2026-09-13 : monstres `8471b7e`, contrôles CI `375f092`, joueur `06058b1` intégrés.
> CI : oracle Python installé explicitement ; reproductibilité WASM ARM64 réparée (`30f8d77`).
> CI générale et WASM GitHub vertes ; chaîne de preuve du jeu réel validée via le registre expérimental log21.
> AIR complet et admission des reprises intégrés (`d848951`), 193 tests client verts ; nouvelle reconstruction GitHub à vérifier.
> P1.9 en intégration : workspace 554 tests verts, puis suite game portée à 57 tests verts ; budgets D2/D29 non atteints.
> Fuzz ponctuel : 10 000 tics réels sans divergence sur la référence `b11fd7f` ; campagne nocturne P1.10 restante.
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

Vague active : nouvelle passe frontière/bytecode (`codex/game-boundary-sizing`) et admission du
wrapper (`codex/wrapper-admission` : hash programme, D14, vérifieur natif autonome). Les compteurs
AIR sont intégrés sur `main` ; le parcours monstres est assemblé dans `codex/game-integration`.
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
Chromium mono/4 threads et fallback sans isolation. Reconstruction GitHub indépendante restante.

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

**Taxe fixe encore bloquante** : sur cet exécutable intégré, le WASM Blake exécute **2 224 712 /
2 297 659 / 2 505 814 steps pour 0 / 1 / 4 tics**. Même sans tic, il dépasse le plafond threads
1,5 M ; quatre tics dépassent aussi 2,3 M mono. Les 16 137 compressions Blake imposent log21
à `blake_g`. Une migration de registre seule ne résout donc ni le découpage ni le temps réel.

## Terminé (mergé sur `main`)

- Phase 0 : spikes S0–S5 + S4b (tous GO), revue G0, décisions D1–D24 (`docs/G0.md`, `docs/DECISIONS.md`).
- Socle : workspace Cairo (18 crates), licences REUSE, CI 6 jobs + `prover-wasm.yml`, graphe de dépendances.
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

# CONTEXT — Hellproof, un Doom prouvable (Cairo + Stwo + Starknet)

> État de l'art et résultats de l'étude de faisabilité. Document de référence à maintenir :
> Étude initiale du **2026-09-12** ; mesures de reprise actualisées le **2026-09-13** ci-dessous.
> Le plan d'exécution qui en découle est dans [PLAN.md](PLAN.md).

## État mesuré à la reprise du 2026-09-13

Cette section et les décisions D26–D33 remplacent les hypothèses de dimensionnement initiales
dans les sections suivantes. L'audit détaillé et les contrôles sont dans [STATUS](docs/STATUS.md).

- `main` après intégration monstres `8471b7e` : **511 tests Cairo** ; la suite spécifique conserve
  ses 55 tests et son replay de 700 tics. Le ticker compile à **14 209 mots proving / 16 241 dev** ;
  l'API complète à **17 963 / 21 220**. À 5, 8 et 20 éveillés, les micro-scénarios mesurent
  respectivement **13 359, 30 711 et 61 425 steps/tic**. Le programme réel reste à mesurer en P1.9.
- Joueur intégré par `06058b1` : **132 tests** et checksum 350 tics inchangés, source **18 830 mots
  proving / 20 671 dev** ; différence historique entre harnais **20 354 / 23 591**, qui inclut du
  code du harnais et des écarts de dépendances (D30). Tir avec cible 9 309 steps, manqué 98 944.
  Le total du programme consommateur demeure le garde final ; ces chiffres ne s'additionnent pas.
- Mesure provisoire P1.9 `df1888d` après C2 : `run_segment` **117 531 mots proving** (cible 100 k
  manquée). Le passage état/rendu sans tic coûte **528 143 steps** dans le runner réel natif,
  confirmés à 14 steps d'enveloppe près par Scarb. ABI Scarb 2.16 / cairo-lang 2.19.4 compatible sur
  ces exécutables ; la recommandation générale de version identique du README sim est conservatrice.
  R2/R5 nécessitent une optimisation des frontières avant validation navigateur à 35 Hz.
- D29 : programme prouvé cible **100 k mots**, plafond dur 120 k, profil `proving`, bootloader
  **Blake après D31** (l'hypothèse Poseidon de D29 est abandonnée). Les coûts par crate partagent
  des dépendances et ne s'additionnent pas.
- D26 : découpage selon le plus gros composant AIR (≤ 2^20 lignes, cible 80 %), avec plafonds de
  précaution de 1,5 M steps avec threads / 2,3 M mono. Le nombre de tics par segment reste dynamique.
- P4.1 / D28 : vérifieur à **5 transactions et 1,540234480e9 L2 gas**, pire transaction à 38,5 % du
  plafond mesuré. Les ≈ 47 STRK utilisent le prix historique S5. L'audit relève encore un défaut à
  6 transactions dans le client/CLI ; l'optimisation du contrat est déjà intégrée.
- Les 7 E2E rendu/leaderboard passent. Les performances de rendu seul et les références de preuve
  sur M2 Max 64 GB ne valident pas encore une partie complète avec preuve concurrente sur 16 GB.
  **C3 PLAN : ≤ 10 min** résiduelles après partie de 3 min ; **D2 : objectif opérationnel ≤ 5 min**.
- Reproductibilité WASM corrigée par `30f8d77` : build ARM64 sur image épinglée, les deux hashes
  Linux existants sont reproduits bit à bit. Cinq smokes locaux vérifiés avec ces artefacts : Node
  mono/4 threads 37,82/11,99 s ; Chromium 33,09/10,19 s (1,83/1,96 GiB), repli sans isolation 33,4 s.
  Workflows GitHub générale `34749101091` et WASM `34749101097` entièrement verts ; oracle Python
  du nouveau contrôle submit corrigé.
- **Jeu réel : R1 reste ouvert.** Quatre tics avec `run_segment` 117 531 mots et **hash programme
  Poseidon** (hypothèse D4/D29, différente du WASM actuel en **Blake**) donnent
  1 499 208 steps sous bootloader et 65 138 instances Poseidon. Preuve native interrompue à 180 s,
  RSS observé proche de 32 GiB, aucune preuve vérifiée. Les microprogrammes S2 ne prédisent pas
  ce coût ; `resources()` estime des hauteurs, sans encore borner toute la largeur ni les composants
  auxiliaires des traces. Comparaison **Blake** avec mêmes sorties publiques : **2 681 208 steps,
  53,50 s, 11,73 GiB RSS max, 765 202 felts**, preuve native vérifiée. Le WASM emploie déjà Blake
  et reproduit exactement ces compteurs (1,49 s d'exécution Node, 0,673 GiB hors preuve). D31 aligne
  les décisions et scripts sur le code. WASM Node 4 threads : **42,225 s / 11,524 GiB**, preuve
  vérifiée. **Le `blake_g` réel atteint log21**, contre log20 estimé par `resources()` : incompatible
  avec `doom`, faux positif confirmé. `doom_21` expérimental construit le circuit feuille, puis le
  repli produit **95 325 felts**, validés par le vérifieur Cairo existant (**5 333 257 steps**) ;
  recomposition indépendante des sorties exacte ([S9](docs/spikes/S9-proof-sizing.md), D32). Le NO-GO universel de S4b §3.2 est infirmé : l'absence de `seq_21`
  bloque certains composants seulement, et notre preuve `canonical_small` log21 est valide.
- P1.9 assemblé `b11fd7f` (branche `codex/game-integration`, pas encore `main`) : ordre `ThingGrid`
  engagé/restauré, armure par impact avant douleur/mort, frontière sans tic **288 045 steps** (−45,5 %),
  `run_segment` **116 287 mots proving**. Validation root : **554 tests Cairo / 23 cibles**, format,
  build, graphe et REUSE verts. Profil VM exact 2 946 tics : moyenne **83 003**, p99 **168 038**,
  frontière exclue ; D2 et D29 demeurent hors cible. Les budgets historiques hash/serde restent rouges.
- Confirmation Chromium 153 sur le programme réel de référence : **3/3 preuves à quatre threads**
  en **40,167–48,128 s / 11,524 GiB**. Mono : un essai interrompu à 150 s, puis une preuve vérifiée
  en **136,425 s / 11,449 GiB**. Préimages identiques, machine 64 GiB, sans partie concurrente.
  Cette campagne isolée ne justifie pas de relever les plafonds de précaution ([S9](docs/spikes/S9-proof-sizing.md)).
- Programme intégré `91719f8`, bootloader Blake : **2 134 627 / 2 194 469 / 2 363 470 steps pour 0 / 1 / 4 tics**.
  Exécution et ressources seules, sans nouvelle preuve. La taxe fixe dépasse à elle seule 1,5 M steps.
  `blake_g` atteint log21 (15 456 × 80 lignes),
  donc registre candidat et correction du planificateur sont nécessaires, sans suffire à lever R2/R5.
  Les plafonds actuels et les paramètres cryptographiques restent inchangés.
- Correction AIR intégrée `d848951` : les nouveaux WASM Linux reproduisent les **43 hauteurs**
  de la preuve réelle ; `blake_g` est annoncé log21 et refusé par le registre courant. Les anciens
  compteurs incomplets sont refusés, y compris avant une preuve reprise. **193 tests client et build
  verts** sur `main` ; cinq smokes k14 vérifiés après rebuild ARM64 (779,2 s). Les hashes Linux
  correspondent au changement de source ; [reconstruction GitHub indépendante 34751692540](https://github.com/bal7hazar/doom/actions/runs/34751692540)
  et smokes Node/Chromium/fallback verts sur `d4924d9`.
- Intégration monstres `883efbb` : idle du ticker **34 765 steps** (−25,7 %), combat tic 493
  **123 418** (−9,4 %), programme **115 814 mots**. 247 comparaisons exactes par profil ; tests
  root monstres 56/game 57 et build proving verts. D2/D29 restent ouverts.
- Fuzz ponctuel de la référence `b11fd7f` : **10 000 tics**, 157 séquences, dix épisodes, seed
  `20260913`, aucun écart état/rendu/statut entre exécution continue et frontières aléatoires.
  Felts état/rendu < 2^72, aucun ABORT ; campagne nocturne et vingt goldens encore à livrer en P1.10.
- Intégration finale des passes locales `91719f8` : **563 tests / 23 cibles verts** ; run
  **110 848 mots**, step 112 334, genesis 47 426. D29 encore dépassé de 10 848 mots ; trois
  budgets hash/serde restent rouges. D33 lance une représentation boxée des acteurs sans changer le wire.
- [S10](docs/spikes/S10-live-simulation.md) : même programme `step_tic` dans un Worker Chromium,
  386 tics, cinq sorties finales complètes exactes face à Scarb ; **17,3–21,4 tics/s** contre 35 visés,
  **46,6–57,8 ms moyens/tic**, ~67 MiB linéaires. La VM domine, le JS prend <0,1 ms. Un prototype
  conserve l’exécution Cairo entre les tics ; aucune baisse de cadence ni regroupement d’inputs.
- Wrapper `14cce87` : identité task/bootloader, D14 et reprises contrôlées avant circuit ; lock du
  vérifieur autonome réparé et gate CI ajoutée. **76 tests service, 2 leaf-verify, 195 client verts**
  sur main. Preuve réelle existante vérifiée en ~25 ms, version corrompue et mauvais bootloader rejetés.
  [CI générale 34752596592](https://github.com/bal7hazar/doom/actions/runs/34752596592) verte sur
  `73d0c0e` : sept jobs, dont le nouveau vérifieur autonome épinglé.
- D28 appliquée `b00c90b` : cinq transactions vérifieur `[2]` par défaut, puis consommateur séparé.
  Coupes et marges conservées, reprise de la coupe sauvegardée ou refus d’une ancienne reprise
  ambiguë avant envoi. **95 tests submit + 195 client**, build/typecheck/REUSE verts ; trois
  racines réelles comparées intégralement à Python. Aucun nouveau reçu réseau ; P4.1 reste
  1 540 234 480 L2 gas, pire consommation 38,55 % et borne calculée ×1,15 à 44,33 % du cap.

- D33 + continuation assemblées `f306c6a` : **565 tests Cairo**, run **110 015 mots** ;
  revalidation root 70 comparaisons proving et 35 cas ABI, pins inchangés. Profil exact 2 946 tics :
  **53 309 steps moyens / p99 128 207**. Les budgets D2/D29 restent dépassés.
- Ressources du programme boxé : **2 113 239 / 2 152 507 / 2 260 220 steps** pour 0/1/4 tics,
  15 355 compressions Blake, log21 refusé par le registre courant. Nouvelle preuve native valide
  (59,14 s) et ancien WASM valide (51,44 s), mais nouveau WASM en échec, mono et quatre threads.
  Échec initial désormais corrigé ([S12](docs/spikes/S12-wasm-proof-triage.md), actualisation ci-dessous) ; aucune promotion du jeu complet.
- Simulation combinée dans Chromium : **386 tics exacts**, **8,8–16,6 ms moyens/tic** maintenance
  comprise, **512 MiB** linéaires, p99 **38,2–45,4 ms** ; onze dépassements sur 386. Onze tests Rust
  verts. Le client et la concurrence avec preuve restent à réaliser ; détails dans S10.
- [CI D28 34753506939](https://github.com/bal7hazar/doom/actions/runs/34753506939) : sept jobs verts
  sur `c383f14`, sans déploiement ni nouveau reçu réseau.

- Actualisation D29/S12 : intégration jeu `8ae7f1c`, **106 878 mots** ; 565 tests Cairo,
  cinq Python et six exécutables reconstruits identiques. Preuve quatre tics :
  **2 208 389 steps / 42,16 s / 11 643 518 976 B linéaires**, vérifiée indépendamment.
  Correctif runtime WASM intégré `e274bec`, reconstruction Docker bit-identique ;
  incident décrit dans S12 résolu localement. D2/D29 et registre log20 restent ouverts.
- Corpus/fuzz `a7aadad` + `38d8993` livrés sur branche : 25 replays × deux profils,
  10 000 tics fuzz, trois morts, zéro divergence ; revalidation D29 25/25 par profil, six empreintes inchangées.
  L’absence d’EXIT dans ce premier corpus a ensuite été résolue : trajet légal de 677 tics, 29 PV,
  dev/proving/D14-oracle et ABI complète Worker Chromium identiques. 26e cas intégré (`e998e52` / `7df2520`), 17 mots terminaux exclus.
- S11 optimisé isolément : BLAKE9 **373 349 steps/hash** contre Poseidon 66 867,
  marche4 leaf **2 889 385 steps**, maximum log21. Aucun changement du hash de production,
  aucune mesure de preuve/RAM justifiant une migration.

- Worker/journal intégrés `3e21031`, correction lifecycle `d027b0f` : 209 tests client
  sans skip et six smokes Chromium après fusion. Root : 386 tics exacts par mode
  d’isolation, mémoire linéaire maximale 465 436 672 B ; 10 000 tics idle en 172,47 s
  avec 39 mesures stables à 258 801 664 B et restauration exacte. Pas de mesure RSS
  ou 16 GiB, ni de preuve concurrente. Contrôles utilisateur intégrés `8cf6d97` : 222 tests client et neuf smokes verts.

- Parcours passif intégré `0c8a3a8` (candidat `9b130df`) : **106 855 mots**, 567 tests
  Cairo ; ABI et replays exacts deux profils. Root revalide EXIT677 et ses coupes.
  idle300 26 298 steps (−12,37 %), fight493 166 596 (−2,19 %) ; frontières inchangées,
  contrepartie petit roster dormant +3,07 %. Sur les mêmes 2 946 tics, référence
  D29 remesurée 53 245,88 → **49 524,87** steps moyens (−6,99 %), p99
  128 871 → **125 157**, maximum 171 470 → **167 756** ; toutes frontières
  et cinq états finaux inchangés. D2 demeure dépassé.
  Preuve quatre tics : **2 193 266 steps execute, 41,553 s, 11 643 256 832 B**
  linéaires, **4 375 790 B**, log21. Vérifications native/bzip2 et négatifs verts ;
  dix sorties D14 exactes. Ce succès isolé ne ferme ni D2/D29 ni C3/16 GiB.

- Client assemblé `5cf5474` : rendu v1 exact des acteurs/effets et HUD compact,
  adaptateur réel depuis genesis avec identité et D14 vérifiés. **243 tests + dix
  smokes Chromium**, zéro skip dans cette sélection ; EXIT677 rendu sans erreur.
  L’admission AIR échoue comme attendu, conserve l’export et libère les Workers.
  F4 est désormais raccordé par `3cb97c1` (UI `e5cac03`) ; trois défauts
  de cycle de vie sont corrigés et revus, 259 tests client verts. Les psprites
  animés restent à terminer ; pas de GO C3.

- S13 BM_ITEMS (`19a869e`) : packing exact de 2 064 ids, gain net **1 439 mots**,
  surcoût mesuré **65 417 steps**, économie Blake modélisée **21 225,25**.
  Root reproduit le résultat : variante rejetée, aucune intégration du décodeur
  dans le moteur. Le potentiel brut de carte ne constitue pas un gain accepté.

- Fuzz du moteur `0c8a3a8`, proving, seed20260913 : **10 000 tics**, 158 cas,
  11 épisodes, trois morts, zéro divergence en **1 040,04 s**. D14 : 158 vérifications
  complètes / 40 coupes ; 493 états et 492 snapshots aux frontières publiques,
  57 mots terminaux exclus. Les contrôles <2^72 portent sur les felts décodés.

- Passe de calculs S14 intégrée par `49f2a66`, moteur `ee5f819` : **573 tests Cairo**,
  profil exact de 2 946 tics **49 524,87 → 48 543,68 steps/tic (−1,98 %)**,
  p99 **125 157 → 122 942** ; aucun tic mesuré ne régresse. Le formatage `ae2feac`
  conserve strictement les six SHA d’exécutables.
  Proving **106 855 → 107 018 mots (+163)** : coût fixe Blake accru.
  Execute réel : quatre tics de marche **2 193 266 → 2 195 222** ; 32 tics
  **3 083 596 → 3 081 268**, D14 exact, log21 et refus registre inchangés.
  Pas de gain de temps de preuve revendiqué ; tailles d’entrée du prouveur en
  hausse malgré certains gains VM. Revue croisée, 259 tests client, 10 smokes
  headed et EXIT677 navigateur verts.
  [Méthode, mesures et limites](docs/design/cairo-calculation-costs.md).

## 1. Vision et périmètre

Objectif : une version de Doom dont le **cœur de jeu (simulation) est réécrit en Cairo**, jouable
dans un **client web** qui génère **localement** (prouveur Stwo en WebAssembly) une **preuve
d'exécution** de la partie, que le joueur peut ensuite faire **vérifier on-chain sur Starknet**.

Périmètre du premier jalon (MVP) :

- un **seul niveau** jouable de bout en bout (assets **Freedoom**, décision du 2026-09-12) ;
- une partie complète = de l'apparition du joueur jusqu'au switch de sortie (ou la mort) ;
- toute la chaîne testée de bout en bout : jeu → journal d'inputs → preuve → vérification locale →
  simulation du coût on-chain → choix utilisateur (soumettre / garder hors-chaîne) → fait enregistré
  on-chain et consultable (leaderboard).

Hors périmètre MVP : multijoueur, son, sauvegardes, autres niveaux, fidélité pixel-perfect du rendu.

## 2. Verdict de faisabilité (résumé)

**Faisable**, avec trois zones de risque à lever par des spikes avant tout développement de fond :

| # | Risque | Pourquoi | Levée |
|---|--------|----------|-------|
| R1 | **Mémoire du prouveur dans le navigateur** | Stwo-cairo a un coût mémoire fixe élevé (mesuré localement : ~17 GB RSS via `scarb prove`, ~7,9 GB natif sur une petite preuve « bootloader » chez modeofO). Le navigateur impose WASM64 (Memory64) et ~16 GB max. | Spike S2 : build WASM64 custom, mesure sur traces de 2^18 à 2^21 steps. |
| R2 | **Budget de steps Cairo par tic** | Doom tourne à 35 tics/s ; une partie de 3 min = 6 300 tics. À 5 000 steps/tic on est à ~32 M steps : impossible en une seule preuve navigateur → **preuve par segments** + agrégation récursive. | Spike S1 : prototype mouvement + collision sur la map Freedoom, mesure steps/tic. |
| R3 | **Vérification on-chain d'une preuve Stwo** | Aucun vérifieur Stwo « officiel » déployé sur Starknet pour des programmes arbitraires. La seule route praticable aujourd'hui est la **route récursive** (circuit verifier), démontrée sur Sepolia par le projet `modeofO/stwo-starknet-verifier` (3 tx, ~1,7e9 L2 gas par fait). Elle exige une étape de « wrap » native (13–22 GB RAM) → un **service wrapper** (sans confiance à accorder : il ne peut pas forger). | Spike S4 : reproduire la route sur le monorepo `proving` actuel avec N segments. |

Le reste (port du gameplay en Cairo, renderer TS, contrats Starknet, estimation de frais) est du
travail d'ingénierie classique, sans inconnue bloquante.

## 3. Chaîne technique cible

```
┌────────────────────────── Navigateur (Chrome desktop, Memory64) ──────────────────────────┐
│                                                                                            │
│  Inputs clavier/souris ──► ticcmd (35 Hz) ──► Worker "sim" : cairo-vm WASM exécute         │
│                                              step_tic(state, cmd) → state' (source de vérité)│
│                                                     │                                       │
│                     Renderer WebGL (TS) ◄── état ───┘        Journal d'inputs (IndexedDB)   │
│                                                                                            │
│  Fin de partie ──► découpage en segments de K tics ──► Worker "prover" (Stwo WASM64)        │
│                    run_segment(state_in, cmds[K]) → proof_i  (h_in, h_out, status, stats)   │
│                    vérification locale (verify WASM) ──► UI : « preuve valide »              │
└──────────────────────────────────────────┬─────────────────────────────────────────────────┘
                                           │ proofs[i] + sorties publiques (pas de secret)
                                           ▼
┌──────────────── Service "wrapper" (Rust, natif, ≥32 GB RAM, sans confiance) ───────────────┐
│  leaf_prover : preuve Cairo_i → preuve de circuit « j'ai vérifié proof_i »                  │
│  recursive_tree : N feuilles → 1 preuve racine (multiverifier)  ≈ 36 k felts                │
└──────────────────────────────────────────┬─────────────────────────────────────────────────┘
                                           │ felts racine + préimages des sorties
                                           ▼
┌────────────────────────────── Starknet (Sepolia puis mainnet) ─────────────────────────────┐
│  starknet_simulateTransactions ──► coût affiché (STRK, fiat) ──► l'utilisateur choisit      │
│  StwoFactRegistry : stage_proof → verify_phase1 → verify_phase2  (3 tx, ~1,7e9 L2 gas)      │
│  DoomRuns : submit_run(…) : is_valid(fact) ∧ chaîne h_in/h_out ∧ status = EXIT              │
│             → enregistre {joueur, niveau, tics, kills, items, secrets, score} + événement   │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

## 4. Stack de preuve : Stwo / stwo-cairo (état septembre 2026)

### 4.1 Dépôts et versions

- **`starkware-libs/proving`** : monorepo qui unifie depuis fin juillet 2026 `stwo` (prouveur Circle
  STARK générique, corps M31), `stwo-cairo` (AIR du CPU Cairo, prouveur Rust, vérifieur Cairo),
  `stwo-circuits` (DSL de circuits + prouveur/vérifieur de circuits), `proving-utils`
  (orchestration : `stwo-run-and-prove`, `leaf_prover`, `stwo_run_and_prove_recursive_tree`,
  `cairo-program-runner`, `vm_runner`) et `stwo-air-infra` (génération de code AIR).
  `stwo` et `stwo-cairo` restent lisibles mais tout le développement se fait dans `proving`.
- Production : Stwo-cairo est le prouveur de SHARP depuis 2025/2026 (sécurise Starknet mainnet).
  Paramètres par défaut : 96 bits de sécurité conjecturée, `pow_bits = 26`, `log_blowup_factor = 1`,
  `n_queries = 70`. Canaux de hachage : Blake2s (défaut), Blake2sM31, Poseidon252.
- Toolchains épinglées : `stwo-cairo` → Rust nightly-2025-06-23, Scarb 2.15.0, Foundry 0.33.0 ;
  `proving` → Scarb 2.18.0 (`cairo_execute = "2.18.0"`) ; `modeofO/stwo-starknet-verifier` → Scarb 2.18.0.
  Localement : Scarb 2.16.0 (asdf, versions 2.8 → 2.16 disponibles), snforge 0.45–0.57, Dojo/Katana/Torii.
- Tags `stwo-cairo` : v1.0.0 … **v1.3.0** ; le monorepo `proving` n'a pas encore de release taggée.
- **Vérifieurs Cairo** (`stwo_cairo_verifier/`) : le vérifieur « CPU-AIR complet » (`cairo_verifier`,
  `cairo_air`) est **gelé** (branche `cairo-verifier-frozen`). Le livrable maintenu est
  **`stwo_circuit_verifier`** : un programme Cairo qui vérifie les preuves de **circuit** (route
  récursive). C'est celui qu'il faut viser pour l'on-chain.

### 4.2 Workflow de preuve d'un programme Cairo

Cible Scarb `executable` (`#[executable] fn main(args…) -> outputs`), `enable-gas = false`,
dépendance `cairo_execute`. Puis :

```bash
scarb execute --arguments-file args.json --print-resource-usage   # trace + stats (steps, builtins)
scarb prove --execution-id N                                        # → target/execute/<pkg>/executionN/proof/proof.json
scarb verify --execution-id N
```

Contraintes : une exécution qui **panique n'est pas prouvable** ; pas de syscalls Starknet ; les
arguments sont des felts sérialisés ; la sortie est le tableau de felts retourné par `main`.
Le prouveur via Scarb est « significativement plus lent » qu'un build natif (`-C target-cpu=native`).
Les binaires du monorepo : `stwo-run-and-prove --program compiled.json --proof_path p.json --verify`.

### 4.3 Mesures locales (M2 Max, 12 cœurs, 64 GB, Scarb 2.16.0 / stwo-cairo `9175316`)

Micro-benchmarks d'une boucle d'arithmétique « façon Doom » (5–6 opérations par itération) :

| Variante d'arithmétique | steps / itération | builtins / itération |
|---|---|---|
| `u64` + masques `& 0xFFFFFFFF` (émulation wrap 32 bits) | **57** | 6 range_check + 6 bitwise |
| `u32` avec `wrapping_add` / `wrapping_mul` | **61** | 12 range_check |
| `felt252` pur (add/mul/sub, pas de comparaison) | **14** | 0 |

Conclusion : en Cairo, **additions/multiplications sur felt252 coûtent ~1–3 steps ; comparaisons,
divisions, masques et conversions coûtent 10–20 steps**. Le cœur Doom doit être écrit « felt-first »
(réduction modulo / range-check uniquement aux points de comparaison, division, indexation de table).

Preuves (`scarb prove`, variante `u32`) :

| Trace | Temps mur | CPU | RSS max | Taille `proof.json` |
|---|---|---|---|---|
| 610 k steps | 7,4 s | 61 s | **17,2 GB** | 8,8 MB |
| 6,07 M steps | 13,0 s | 110 s | **25,5 GB** | 9,6 MB |

Lecture : coût **fixe ~17 GB** (trace pré-traitée « canonique ») + **~1,5 GB par million de steps** ;
temps ≈ 6 s fixe + ~1 s par million de steps en natif SIMD 12 cœurs. Un prouveur WASM
(pas de SIMD portable garanti, threads via SharedArrayBuffer) sera plausiblement 5–20× plus lent.

Anomalies observées avec le prouveur embarqué dans Scarb 2.16 (à re-tester avec le monorepo) :

- panique `Cannot convert F252 to u128` (`adapter/src/memory.rs:291`) dès qu'une **valeur négative
  (felt ≥ 2^128) est écrite en mémoire** — même sur une trace de 177 steps ;
- panique `index out of bounds` (`memory.rs:96`) sur la variante utilisant le builtin **bitwise**.

Règle de conception provisoire : **ne jamais produire de felts négatifs / ≥ 2^128 en mémoire** et
**éviter le builtin bitwise** tant que S0 n'a pas confirmé le comportement du prouveur courant.

Prouveur natif du monorepo (`proving` @ `cd7bc5f`, Cairo 2.19.4) : `cargo build --release -p
stwo-run-and-prove` compile en **3 min 14 s** sur cette machine (nightly téléchargé automatiquement).
Ce binaire n'accepte que des programmes **Cairo 0 compilés** (`instruction_locations` requis) ; les
exécutables Scarb passent par le chemin **bootloader** (`cairo-program-runner-lib::Task::Cairo1Program`,
`cairo_lang_execute_utils::program_and_hints_from_executable`) — c'est aussi le chemin exigé par la
route récursive. Établir ce pipeline « exécutable Scarb → preuve » avec le monorepo courant est la
première tâche du spike S0 ; les chiffres de temps/mémoire ci-dessus (Scarb 2.16) sont à refaire avec lui.

### 4.3 bis Résultats du spike S0 (2026-09-12, `proving@cd7bc5f`, Scarb 2.19.4, voir `docs/spikes/S0.md`) — GO

- **Chemin de preuve d'un exécutable Scarb** : `stwo-run-and-prove --program privacy_simple_bootloader_compiled.json
  --program_input bl_input.json` avec la tâche `Cairo1Executable` (args = tableau JSON de felts hex,
  `program_hash_function: blake`, `output_preimage_dump_path` obligatoire, chemins absolus). Le chemin
  « standalone » (`run_and_prove --program_type executable`, sans bootloader) est **cassé** pour tout
  exécutable Scarb (`extract_public_segments` lit les valeurs de retour comme pointeurs de builtins).
- **Mémoire avec `canonical_small`** : RSS ≈ **2,2 GiB + 1,8 GiB par million de steps** → 2^20 steps =
  **4,05 GiB** (2^21 = 6 GiB) contre 16 GiB avec `canonical` (tout l'écart est dans
  « Compute preprocessed trace commitment »). Temps : 3–7 s mur, 18–58 s CPU sur 12 cœurs.
- **Taille de preuve** : plate, ≈ 4,33 MB / **290 k felts** quel que soit k (357 k felts avec les params
  du registre récursif, `include_all_preprocessed_columns = true`).
- **Coût du bootloader** : pas un forfait de 30 k steps mais **2 340 + 14,7 × mots de bytecode** (hash
  blake du programme ; 5,5 × avec poseidon) : un programme de 16 k mots coûte 240 k steps par segment.
  La taille du bytecode du cœur devient un paramètre de K.
- `canonical_small` n'est **pas** plafonné à 2^20 par lui-même (2^21 prouve et vérifie) ; le plafond 2^20
  vient du **lifting fixe du registre récursif** (`fixed(20)`), contrainte portée par S4.
- **Paniques** : ni les felts ≥ 2^128 en mémoire ni le builtin bitwise ne posent problème sur le chemin
  bootloader (les paniques de Scarb 2.16 étaient des symptômes du chemin standalone). Seuil de **coût**
  à **2^72** (`MemoryConfig::small_max`) : au-delà, +33 % sur `range_check_9_9`, rien d'autre.
- Leviers mémoire (k = 19) : `fold_step = 4` → −0,29 GiB et −12 % de taille de preuve (à valider avec le
  vérifieur de circuit, S4) ; `store_polynomials_coefficients = true` → +0,36 GiB pour rien.

### 4.4 Origine du coût mémoire fixe : la trace pré-traitée

`crates/common/src/preprocessed_columns/preprocessed_trace.rs` définit trois variantes :

| Variante | Cellules M31 | Colonnes | Trace max | Usage |
|---|---|---|---|---|
| `Canonical` | **543 100 528** (dont tables Pedersen `PedersenPoints::<18>`) | 161 | 2^25 | défaut Scarb / SHARP |
| `CanonicalWithoutPedersen` | 73 338 480 | 105 | 2^25 | — |
| `CanonicalSmall` | **10 161 776** | 156 | **2^20** | route récursive « privacy », navigateur |

Le coût fixe de ~17 GB mesuré avec Scarb provient de `Canonical` (2,2 GB de M31 bruts avant blow-up
et Merkle). WASM64 est plafonné à **16 GB** par la spécification (Chrome 133+) : `Canonical` est
inutilisable dans un navigateur ; `CanonicalSmall` borne les segments à **2^20 steps** (bootloader compris).

### 4.5 Registres de circuits (route récursive)

`circuit_registry_definitions/` : `production` = feuilles de trace **log 25 à 29** (paramètres SHARP,
`canonical`) ; `canonical_small` = **log 20 exactement** avec cibles de padding (`eq` 2^20, `qm31_ops` 2^23,
`m31_to_u32` 2^21, `triple_xor` 2^20, `blake_g_gate` 2^23). `leaf_prover` choisit le circuit selon la
taille de trace et padde au gabarit commun du registre (condition de l'arbre `recursive_tree`).
Un registre dédié au projet doit être généré (`circuit_params --registry`). Le vérifieur Cairo on-chain
est générique : il recalcule `circuit_hash` depuis l'engagement pré-traité et sort
`blake2s(circuit_hash ‖ outputs)` ; le contrat consommateur épingle le hash du multiverifier du registre.

## 5. Preuve côté navigateur

### 5.1 Existant

- **`stwo-cairo` (npm) = `clealabs/stwo-cairo-ts` v1.1.1** (dernier commit 2025-09-21) : wrapper
  WASM64 de l'ancien CLI `cairo-prove` (stwo-cairo ~`335de15`, forks `fix-wasm64` de stwo-cairo et du
  compilateur Cairo). API : `init()`, `execute(executableJson, ...args) → proverInput`, `prove(proverInput)
  → proof`, `verify(proof, withPedersen)`. Exige les en-têtes `Cross-Origin-Embedder-Policy: require-corp`
  et `Cross-Origin-Opener-Policy: same-origin` (SharedArrayBuffer).
  Issue ouverte #2 : panique `invalid degree` sur Chrome macOS arm64 → **le paquet tel quel n'est pas
  fiable** ; il sert de modèle pour un build WASM64 maison épinglé sur le monorepo `proving`.
- Le CI du monorepo impose la compilation `wasm64-unknown-unknown` du prouveur (`stwo-cairo-prover`)
  et `wasm32` no_std du vérifieur (`cairo-air`) : la cible WASM est **supportée officiellement**.
- Autres démos : `Okm165/stwo-web-stark` (démo web, WIP), `AbdelStark/stwo-wasm-demo` (Fibonacci).
- Retour d'expérience modeofO (messagezk) : `prove` natif d'un petit programme sous bootloader =
  3,3 s / **7,9 GB** ; `wrap` = 13 s / **13,6–21,9 GB** ; « wasm32 est mort (4 GB), le chemin navigateur
  est un build WASM64 custom de la pile épinglée ».

### 5.2 Support navigateur Memory64

Chrome ≥ 133 (sans flag), Firefox ≥ 143 (flag selon version), Safari en retard/non engagé.
→ **Cible MVP : Chrome desktop**, machine ≥ 16 GB RAM. Prévoir un **fallback « prouveur distant »**
(les inputs d'une partie de Doom ne sont pas secrets : déléguer la preuve ne dégrade pas la
sécurité, seulement la décentralisation) et/ou un client natif (Tauri/egui) ultérieur.

### 5.2 bis Résultats du spike S2 : prouveur WASM64 (2026-09-12, voir `docs/spikes/S2.md`) — GO mesuré

- `prover/wasm/` : cdylib compilant le prouveur du monorepo (`cd7bc5f`) + runner Cairo 1 + bootloader de
  feuille en `wasm64-unknown-unknown` (nightly-2026-01-15, `build-std`, `+simd128`, 16 GiB max) ; ABI
  manuelle sans wasm-bindgen (`execute` → `ProverInput` bincode, `prove`, `verify`, `proof_to_felts`).
  Build reproductible **bit à bit** depuis un clone frais (`build.sh` + `SHA256SUMS`) ; 4 patches ≤ 12 lignes
  (`prover/wasm/patches/`) : dump de préimage sans fs, feature getrandom sur wasm32 seulement, pools rayon
  privés exécutés inline sans threads, `xxhash-rust` SIMD sur wasm32 seulement. Artefact 43 MB (8,1 MB gz).
  Node 22 ne charge pas Memory64 (Node ≥ 24 requis).
- **Mesures Chrome 152 headless, mono-thread, params de feuille** :

  | steps | preuve (s) | mémoire wasm | vérif |
  |---:|---:|---:|---|
  | 2^16 | 27,0 | 1,87 GiB | 3/3 |
  | 2^18 | 26,7 | 2,15 GiB | 3/3 |
  | 2^19 | 29,2 | 2,43 GiB | 3/3 |
  | **2^20** | **35,6** | **3,05 GiB** | 3/3 |

  Natif même chemin : 26,6 s mono-thread (wasm ≈ 1,3× natif), 4,2 s sur 12 threads. Execute 0,45 s,
  verify 55 ms. Aucune panique (le bug `invalid degree` du paquet npm ne se reproduit pas).
- Coût dominé par la part fixe (~27 s / 1,85 GiB pour toute trace ≤ 2^18) → dimensionner les segments
  près du plafond 2^20. Machines 16 GB non mesurées (attendu 60–80 s). Threads (`SharedArrayBuffer`) :
  ~6× de marge à aller chercher. Écart de convention de comptage des felts avec S0 (688 k vs 290 k, même
  taille en MB) à trancher.

### 5.2 ter Résultats de P3.1 : paquet `@hellproof/prover-wasm` (2026-09-12, `prover/wasm/README.md`)

- **Threads** (rayon sur `+atomics` + mémoire partagée, Workers pré-démarrés, sans wasm-bindgen) : 2^20 steps
  en **11,7 s à 4 threads** (36,5 s mono), 2 M steps en 15,6 s ; mémoire 3,05–4,6 GiB. Au-delà de 4 threads
  l'écriture de trace régresse (spin-lock de l'allocateur std) → `auto` plafonne à 4. Repli mono-thread
  vérifié quand `crossOriginIsolated` est faux. 6 patches au total (PR upstream rédigées).
- **Plafond de segment** : ~2,3 M steps pour le programme de test (le composant `memory_id_to_small`
  dépasse 2^20 lignes, panique upstream « Seq(21) missing ») ; `resources()` le prédit exactement
  (`fits_leaf_registry`) → le client coupe les segments par ressources, pas par steps.
- **Felts** : un leaf proof 2^20 avec les params du registre = **755 500 felts cairo-serde / 4,2 MB bincode**,
  plat de 2^14 à 2,3 M steps ; l'écart S0/S2 venait du bootloader (le bootloader de feuille active ~3×
  plus de composants AIR).
- Artefact 45 MB / 8,1 MB gzip ; pas de trim possible (`cairo-lang-executable` entraîne tout le compilateur).
  CI `prover-wasm.yml` : build conteneur reproductible **par hôte** (hash différent entre macOS et Linux),
  tests Playwright 1 et 4 threads, repli sans isolation.
- Risque ouvert : 2 blocages sur ~16 runs avec threads sur des segments ≥ 2 M steps (R1-A8).

### 5.3 Résultats du spike S3 : exécution temps réel (2026-09-12, voir `docs/spikes/S3.md`) — GO

- `prover/sim` (`hellproof-sim`, wasm32 + wasm-bindgen, cairo-vm 3.2 / cairo-lang 2.19.4) : programme
  parsé une fois, `CairoRunner` + VM recréés à chaque appel (3–5 µs), aucune fuite sur 10 000 appels,
  6,6 MB de mémoire linéaire (pas besoin de Memory64 pour la sim).
- Débit cairo-vm en wasm : **9,1–9,4 M steps/s** (2,2× plus lent que le natif). Dans un Worker Chromium :
  **2 289 tics/s** à 4 k steps/tic (p99 0,5 ms), 936 tics/s à 10 k, **179 tics/s** avec un état complet de
  1 500 felts (52,6 k steps). Empreintes de sortie identiques natif / Node / Chromium.
- Re-parser l'exécutable à chaque appel (approche du paquet npm `stwo-cairo`) coûte 4× à 18× selon la
  taille du programme ; même en cache, `CairoRunner::initialize` recopie le bytecode à chaque run
  (0,22 → 0,83 ms de 4 kB à 778 kB) — suivi cairo-vm.
- **Coût de sérialisation Cairo** : `Serde` coûte ~22 steps par felt d'état (aller-retour), soit
  `steps(n) = 35 n + 69` pour un état de n felts : 1 500 felts ≈ 33 k steps. Conséquence pour la preuve :
  l'état doit rester en structures Cairo pendant tout le segment et n'être (dé)sérialisé qu'aux bornes.
- Artefact wasm : 12,6 MB (2,0 MB brotli), dominé par `cairo-lang-executable` qui entraîne le compilateur ;
  plan de réduction dans S3.md §6.1. Architecture Worker proposée : triple buffer `SharedArrayBuffer`
  sous seqlock, snapshot de rendu réduit, ordonnanceur 35 Hz à rattrapage borné (max 4 tics).

## 6. Vérification on-chain sur Starknet

### 6.1 Options comparées

| Option | État (09/2026) | Verdict |
|---|---|---|
| **SNIP-36** (vérification Stwo en protocole, v0.14.2) | Ne vérifie que des exécutions « virtual-SNOS » (allowlist de 2 hashes de programme) | ✗ programmes custom impossibles |
| **Integrity** (Herodotus) | Vérifieur **Stone** uniquement (layouts recursive/starknet…), inactif depuis 09/2025 ; FactRegistry mainnet `0xcc63…f00b` | ✗ pas de Stwo |
| **Atlantic** (Herodotus, prouveur managé) | S-two supporté « uniquement pour vérification L1 » (wrapper Groth16 EVM) | ✗ pas de Starknet |
| **Vérifieur Cairo complet en contrat** (« lane 2 » modeofO) | 26–34 M steps, preuve 300 k felts, 41–60 tx, ~21–30e9 L2 gas ; classes découpées ; **bloqué par le rejet des libfuncs qm31 au declare** (absentes de `audited.json`) | ✗ trop cher, bloqué |
| **Route récursive / circuit verifier** (« lane 1 » modeofO) | **Livrée sur Sepolia le 2026-07-03** : preuve racine ≈ 36 k felts, vérification 3,8 M steps, **3 tx / fait** | ✓ **retenue** |

### 6.2 Route récursive : ce qui est démontré

Pipeline (code public, `proving` + `stwo-starknet-verifier`) :

1. le programme applicatif (`.executable.json` Scarb + args) tourne **sous un bootloader** (« privacy
   simple bootloader », `Task::Cairo1Program`) qui donne à toute exécution la forme à 11 segments de
   builtins attendue par le circuit ; preuve Cairo avec le canal `Blake2sM31`, config PCS « privacy »
   (pow 27, trace pré-traitée `CanonicalSmall`) ;
2. `leaf_prover` : un circuit ré-implémentant le vérifieur Stwo vérifie cette preuve ; on prouve le
   circuit → **preuve de feuille** ;
3. `stwo_run_and_prove_recursive_tree` : replie N feuilles deux à deux via le circuit `multiverifier`
   (arbre équilibré, profondeur ⌈log2 N⌉, plus de bootloader ni de wrap) → **preuve racine** au
   canal Blake2s, sérialisée en flux felt252 pour le vérifieur Cairo ; sort aussi `program_output`
   (mots u32 de la racine) et un arbre `packed_output` (préimages des sorties de chaque feuille) ;
4. on-chain : `stwo_circuit_verifier` (Cairo) — topologie fixe → coût **constant** ~3,8 M steps quelle
   que soit la taille du programme prouvé.

Mesures modeofO (fixture `poseidon_chain(100)`, Sepolia) :

| Élément | Valeur |
|---|---|
| Preuve racine | 36 022 felts, packée 7 u32/felt → 5 147 slots |
| Contrat | 3 classes (Phase1 46 805 Sierra, Phase2 11 677, Registry 1 707) ; libfuncs audités ; plafonds Sierra 81 920 felts / 4 089 446 octets / CASM 81 920 felts respectés |
| Transactions par fait | `stage_proof` (156 slots) + `verify_phase1` **873 757 120** L2 gas + `verify_phase2` **815 669 840** L2 gas |
| Plafond par invoke (empirique) | **1,21e9 L2 gas** (le séquenceur rejette au-delà) ; calldata ≤ 5 000 felts (dont ~4 felts d'enveloppe `__execute__`) |
| Coût observé | ~49 STRK par fait à prix Sepolia « spiky » ; declares ~180 STRK (une fois) |
| Registry Sepolia | `0x0194f44002b4af71e58ba7d30667ed565f1d420d3fb1e7c578de35170309c6aa` ; fait `0x640299e8…615c` → `is_valid == true` |
| Wrap (natif, M-series) | prove 3,3 s / 7,9 GB ; wrap 13 s / 13,6–21,9 GB ; chaîne complète 2–3 min |
| Fait | `fact = poseidon(blake2s(multiverifier_root ‖ outputs))`, `outputs` = chaîne blake2s finissant par `[n_tasks, output_len, app_program_hash, app_outputs…]` ; `stwo_fact_binding.compute_fact(program_hash, outputs, inner_root)` la recalcule côté consommateur (~0,8 M gas) |

**Résultats du spike S4 (2026-09-12, `proving@cd7bc5f`, voir `docs/spikes/S4.md`) — verdict GO :**

| Élément | Valeur mesurée |
|---|---|
| Registre `doom` (log 20 = 20, `canonical_small`, pow 26) | hash multiverifier **identique à `production`** (`a5989715…973f680f`) → constantes du vérifieur on-chain inchangées ; génération 6,9 s / 8 GB |
| Feuille (stub 145 k steps sous bootloader) | 22 s, **32,5 GB RSS** (2 s preuve Cairo + 18 s preuve de circuit), 546 KB |
| Repli d'une paire | 23–36 s, 32 GB |
| Racine (N = 1…4) | **93,5–96 k felts** ; vérifieur Cairo **5,26–5,37 M steps** (golden upstream : 5,31 M / 94,7 k felts) — soit +40 % de steps et ×2,6 felts par rapport aux mesures modeofO de juillet (3,8 M / 36 k) |
| Recomposition Cairo des sorties (`spikes/s4/recursion_outputs`) | 14 tests verts ; N = 4 : 5 645 steps ; N = 50 : 68 315 steps (≈ 7,5 M gas) |
| Extrapolation wrap séquentiel | N = 8 ≈ 6,5 min ; N = 50 ≈ 43 min ; serveur ≥ 48–64 GB requis |

**Résultats du spike S4b (2026-09-12, voir `docs/spikes/S4b.md`) :**

- **Le plafond n'est pas 2^20 steps par segment.** La taille de trace du registre vient du **plus gros
  composant AIR** (`prover.rs:134`), pas du nombre de steps : un segment de **1,59 M steps** passe de bout
  en bout avec le registre `doom` inchangé (feuille 22,5 s / 33,5 GB, racine 96 k felts, vérifieur 5,37 M
  steps) et des exécutions de 3,2 / 4,4 / **5,4 M steps** gardent `trace_log_size = 20`. Les contraintes
  réelles : RSS du prouveur navigateur (≈ 4–5 M steps sous 12 GB d'après S0) et la règle du plus gros
  composant (à mesurer sur `doom_run`). Un registre à lifting 2^21/2^22 est accepté par `circuit-params`
  mais **inatteignable** (`canonical_small` s'arrête à `seq_20` ; `canonical` ne démarre qu'à log 23).
- **Hachage poseidon du programme : GO.** Bootloader de feuille : blake = 2 340 + 14,75 × mots ;
  **poseidon = 1 969 + 5,5 × mots** (32 k mots : 177 k steps au lieu de 471 k). Route complète inchangée
  (même circuit, même hash), seul `preimage[0]` change : `DoomRuns` doit épingler la *fonction* de hachage
  avec le hash du programme.
- **`fold_step = 4`** : accepté de bout en bout mais sans gain sous le padding production ; avec un
  padding minimal (`doom_fold4_min`) : **feuille 21,9 GB / 13,3 s (−33 % RSS, −41 % temps)**, repli
  21,4 GB / 13,5 s — au prix d'un **hash de multiverifier différent de production** (`02b34360…`) qui
  exige de régénérer les constantes du vérifieur on-chain. `include_all_preprocessed_columns = false`
  est **refusé** par `leaf_prover` (le registre l'accepte silencieusement : piège).

Le bootloader de feuille (`leaf_simple_bootloader_compiled.json`) n'est fourni que compilé (source interne
StarkWare) : il est épinglé par hash. Plage 19–20 impossible (`canonical_small` est en colonnes log 20).

Points d'attention :

- **Couplage de versions** : la topologie du multiverifier codée en dur dans le vérifieur Cairo doit
  correspondre à la révision `stwo-circuits` qui a produit la preuve (épinglages modeofO :
  proving-utils `b6fe5d3b`, stwo-cairo `68b4af6d`/`92bfd1d3`, stwo-circuits `0451681a`, stwo `5ea05973`).
  Le monorepo a depuis remplacé le wrap par `recursive_tree` : **à re-valider (spike S4)**.
- Le multiverifier de modeofO prend 2 entrées (la même preuve deux fois pour un seul payload) ; pour
  N segments, `recursive_tree` fournit l'arbre et `packed_output` ; la **recomposition on-chain de la
  chaîne des sorties de feuilles** (digests blake2s de l'arbre) est à implémenter et mesurer (S4).
- snforge sous-estime le gas de production d'environ **1,6×** ; **starknet-devnet 0.9** reproduit
  Sepolia au gas près → l'oracle go/no-go est devnet, pas snforge.
- Storage : chaque écriture ≈ 495 k gas ; lecture packée ≈ 120 k gas/slot de *traitement* ; le
  state-diff par bloc est plafonné (4 000 entrées, 2 par écriture) → < 2 000 slots par tx de staging.
- Les preuves Stwo ne sont **pas zero-knowledge** (le witness n'est pas caché) : sans importance ici,
  les inputs d'une partie sont publics par construction (replay).

## 7. Modèle de coûts Starknet (v0.14.x)

- **L2 gas** : 1 step Cairo = 100 L2 gas ; builtins : range_check 70, pedersen 4 050, poseidon 491,
  bitwise 583, ec_op 4 085, keccak 136 189 ; calldata 5 120 gas/felt ; données d'événement 5 120/felt,
  clés 10 240/felt. Plafond invoke 1,21e9 (empirique) ; bloc 6e9 ; `__validate__` 1e8.
- **Prix L2 gas** : marché EIP-1559 (v0.14.0) avec **minimum 3 gFri = 3e-9 STRK/gas** ; depuis
  v0.14.3 (mainnet 2026-06-22) base fee dynamique indexée sur le prix du STRK, cible bloc réduite de 30 %.
- **L1 data gas** : state diff uniquement (32 octets par felt, `ℓ + 2(n-1) + 2(m-1)` mots), prix =
  moyenne blob L1 × 0,135. Les événements ne coûtent pas de DA.
- **Ordre de grandeur d'un fait Doom** : ≈ 1,7e9 L2 gas → **~5 STRK au prix plancher**, ~50 STRK à
  ~30 gFri (observé sur Sepolia). Storage/DA négligeable (< 500 felts de state diff). Mesure réelle
  prévue en S5 via `starknet_simulateTransactions` (liste de tx appliquées en séquence → frais par tx),
  conversion fiat par oracle (Pragma) ou API de prix.
- Alternative UX : paymaster Cartridge (sponsoring), sans changer la mécanique d'affichage du coût.

**Résultats du spike S5 (2026-09-12, starknet-devnet 0.10.0 / Starknet 0.14.4, voir `docs/spikes/S5.md`) — GO sur C5 :**

| Élément | Valeur mesurée |
|---|---|
| Fait de référence (fixture modeofO, 36 k felts) | stage 78,6 M + phase1 **873 757 120** + phase2 815 709 840 = **1,768e9 L2 gas** ; chiffres Sepolia de juillet reproduits au gas près |
| `starknet_simulateTransactions` sur la séquence ordonnée | écart L2 gas **−0,015 %** (pire tx −0,22 %) ; L1 data gas surestimé de 10–49 % (3 felts/clé simulés vs 2 réels, sens sûr) |
| Prix mainnet le 2026-09-12 | **30,5 gFri** = 10,2× le plancher ; 1 STRK = 0,0288 $ → fait ≈ **54 STRK ≈ 1,55 $** (plancher : 5,3 STRK ≈ 0,15 $) |
| Declares (3 classes) | 6,58e9 L2 gas ≈ 200 STRK une fois |
| Marges recommandées | `l2_gas` ×1,15, `l1_data_gas` ×1,30 ; le ×1,5 global de sncast dépasse le plafond 1,21e9 (rejeté) ; phase1 à 83 % du plafond avec ×1,15 |
| Classe de compte | le même `stage_proof` coûte **+19 %** depuis une autre classe de compte Cairo 1 → re-mesurer avec Cartridge Controller avant de figer les bornes |
| Contrat consommateur (stub `DoomRuns`, N×8 felts, 2N Poseidon + N blake2s) | 5,58 M + 86,7 k·N L2 gas → 9,9 M à N = 50 (0,6 % du coût d'un fait) |
| **Extrapolation aux preuves S4** (94–96 k felts, 5,3 M steps) | staging ≈ 4,3e9 L2 gas sur 5 tx ; chaque phase de vérification à 115–204 % du plafond → **≥ 4 invokes**, ≈ **250 STRK ≈ 7,2 $ par fait** au prix courant ; transport **calldata seulement** du flux packé ≈ 6,8e7 gas contre 4,2e9 stocké (**61× moins cher**) → décision de conception avant la Phase 4 |

**Résultats de P4.0 (2026-09-12, `docs/design/onchain-verifier.md`, `cairo/doom_contracts/`) :** vérifieur de
circuit résumable à **sections en calldata** (aucun felt de preuve stocké), vendoring `proving@cd7bc5f`,
3 classes de bibliothèque + routeur (obligatoire : le monolithe dépasse le plafond CASM). Sur devnet 0.10 avec
la racine S4 (96 k felts) : **5 transactions, 3,81e9 L2 gas** (begin 459 M, merkle 391 M, answers 861 M,
fri 1 093 M à 90,4 % du plafond, fri 1 005 M) ; variante 6 tx à 3,82e9 avec pire tx à 84 %. Coût :
**116 STRK ≈ 3,35 $** au prix mainnet du 2026-09-12 (11,4 STRK au plancher), declares ≈ 238 STRK une fois ;
2,15× moins cher que l'extrapolation stockage de S5. 78 % du gas est le calcul du vérifieur (FRI en QM31
émulé : 1,84e9) ; leviers : inversion par lots des twiddles dans le FRI vendu, opcode qm31 si audité.
Constantes du multiverifier **générées depuis le registre** (`tools/gen_multiverifier_consts.py`, vérifié
avec `doom_fold4_min`). Calibrage : blockifier 0.14.4 facture steps VM + builtins ; snforge en mode
sierra-gas sous-estime de 1,4–3,5× → `tracked_resource = "cairo-steps"`. Outils : Foundry 0.61.0.

**Chaîne on-chain complète validée (P4.2b, 2026-09-12)** : deux racines réelles à sorties de 10 felts
(2 parties / 3 segments et 1 partie / 2 segments) vérifiées sur devnet par le routeur P4.0 (5 tx,
3,81e9 gas) puis consommées par `DoomRuns` (`submit_batch` 16,7 M gas = 0,44 % du fait, replay inclus) :
**116,96 STRK ≈ 3,35 $ pour un lot complet** au prix du jour ; classement et rejeu peuplés ; un kill
altéré → `fact not registered` ; les mêmes inputs sous un autre fait → `already registered`. Aucun écart
entre la sérialisation de `cairo/crates/segment` et le contrat.

**P4.1 (2026-09-13) : gas de vérification on-chain −60 %.** Le blockifier facture ces classes au **maximum des
ressources VM** (steps ×100, range_check ×1 600…), et le vérifieur vendu fait un range check tous les 7 steps :
les leviers étaient « moins d'opérations de corps réduites ». Inversion par lots (une par couche FRI, une pour
les 630 dénominateurs), limbes `felt252` non réduits sur trois niveaux de repli, hoisting des puissances
d'alpha, décodeur typé (le coût Merkle était la désérialisation, blake2s est gratuit) : sur devnet
**5 tx, 1,540e9 L2 gas, 47 STRK ≈ 1,35 $ par fait** (était 3,81e9 / 116 STRK), pire tx à 38,5 % du plafond.
Série de patches sur le vendu avec argument d'équivalence par patch ; référence non modifiée conservée ;
13 points d'altération × 2 vérifieurs rejettent à l'identique. Format de calldata et ABI du routeur inchangés.

Les classes déployées par modeofO sont inutilisables pour nous (vérifieur vendu plus ancien, hashes de
phases figés dans le constructeur) : le registry sera redéployé depuis nos sources épinglées.

## 8. Doom : ce qu'il faut savoir pour un port déterministe

### 8.1 Architecture du jeu original (linuxdoom-1.10 / doomgeneric)

- Boucle à **35 tics/s** ; l'input d'un tic est un `ticcmd_t` (`forwardmove`, `sidemove` en int8,
  `angleturn` int16, `buttons` : tir/usage/changement d'arme) — 4 octets/tic dans le format démo LMP.
- **Déterminisme total** : toute la logique (`P_Ticker` → `P_PlayerThink`, thinkers des mobjs,
  spécials de secteurs) ne dépend que de l'état + des ticcmds. Le « hasard » est une **table fixe de
  256 octets** (`M_Random`/`P_Random`) lue séquentiellement (index dans l'état). Les démos LMP sont la
  preuve historique de ce déterminisme.
- Arithmétique : **point fixe 16.16** (`fixed_t` int32, `FRACUNIT = 65536`), `FixedMul`/`FixedDiv`
  via int64 ; **angles BAM** (uint32, wrap naturel) ; tables `finesine`/`finecosine` (10 240 entrées),
  `finetangent`, `tantoangle` (2 049 entrées) ; `R_PointToAngle`.
- Collisions : **blockmap** (grille 128 unités) → `P_TryMove`/`PIT_CheckLine`/`PIT_CheckThing`,
  `P_SlideMove` ; ligne de vue `P_CheckSight` via **traversée BSP** (+ table `REJECT` pour rejet rapide) ;
  hitscan et projectiles via `P_PathTraverse` (intercepts blockmap) ; hauteurs via BSP `R_PointInSubsector`.
- Monstres : machines à états (`info.c` : `states[]`, `mobjinfo[]`) avec actions `A_Look`, `A_Chase`,
  `A_FaceTarget`, `A_PosAttack`, `A_TroopAttack`, etc. Portes/plateformes/lumières : thinkers par secteur.
- Lumps de map : `THINGS`, `LINEDEFS`, `SIDEDEFS`, `VERTEXES`, `SEGS`, `SSECTORS`, `NODES`, `SECTORS`,
  `REJECT`, `BLOCKMAP`.

### 8.2 Licences et assets

- Code source Doom : **GPL-2.0** (id Software, 1999). Un port de la logique de jeu en Cairo qui s'en
  inspire ligne à ligne est un **dérivé → GPL-2.0-only** pour les crates `cairo/doom/*` (linuxdoom-1.10 est GPL-2.0-only, sans clause « or later » ; vérifié en P0.1). Le dépôt est
  aujourd'hui **Apache-2.0** : prévoir un **licensing par répertoire** (core GPL, infra/contrats/client
  Apache) ou une réécriture « clean-room » à partir des specs (Doom wiki, Black Book) — décision à prendre.
- **Assets : Freedoom** (décision utilisateur) — `freedoom1.wad` (Phase 1), licence BSD 3 clauses,
  compatible IWAD Doom : mêmes formats de lumps, maps aux slots `E1M1`… (contenus différents des maps id).
  Textures (`PLAYPAL`, `COLORMAP`, `TEXTURE1`, `PNAMES`, patches, flats) et sprites Freedoom pour le renderer.
- Les données de niveau sont **compilées dans le programme Cairo** (constantes) : le **hash du programme
  épingle le niveau et les règles** ; le fait on-chain n'a pas besoin d'engagement séparé sur la map.

## 9. Budget de calcul et segmentation

Hypothèses de travail (à remplacer par les mesures S1/S2) :

| Grandeur | Estimation | Commentaire |
|---|---|---|
| Steps par tic (cible) | **≤ 4 000** | joueur + ~10 monstres actifs + spécials ; felt-first, REJECT pour la vue, blockmap |
| Partie de 3 min | 6 300 tics → ~25 M steps | |
| Segment | **K ≈ 250 tics ≈ 2^20 steps** | ≈ 8–10 GB estimés dans le navigateur ; 25 segments pour 3 min |
| Preuve d'un segment (WASM) | 30–120 s | à mesurer ; en tâche de fond pendant la partie |
| Wrap N=25 | ~25 × 15 s + 24 × 10 s ≈ 10 min natif | serveur 32 GB ; parallélisable par niveau d'arbre |
| On-chain | 3 tx, ~1,7e9 L2 gas | constant, indépendant de N |

Sorties publiques d'un segment : `[h_in, h_out, tic_start, tic_end, status, kills, items, secrets]`
avec `h = poseidon(état sérialisé)` (~1–2 k felts : joueur, mobjs, secteurs dynamiques, thinkers actifs,
index RNG, compteur de tics). Le contrat `DoomRuns` exige `h_in[0] = genesis(niveau, seed)`, la
continuité `h_out[i] = h_in[i+1]`, et `status = EXIT` sur le dernier segment. Le journal d'inputs
(4 octets/tic, packé 7 tics/felt → ~900 felts pour 3 min) peut être publié en **événement** pour
permettre le replay par des tiers (pas de coût DA).

### 9 bis Résultats du spike S1 : coût par tic (2026-09-12, Freedoom E1M1, voir `docs/spikes/S1.md`) — GO avec repli

| Scénario (350 tics scriptés) | base | optimisé | p99 |
|---|---:|---:|---:|
| joueur seul | 4 078 | **3 439** | 5 252 |
| + 5 monstres dormants | 19 179 | **4 232** | 6 109 |
| + 5 monstres en chasse | 27 845 | **18 432** | 20 346 |
| + 1 hitscan / 10 tics | 28 627 | **19 215** | 27 838 |

Coûts marginaux : **2 999 steps/tic par monstre éveillé**, 159 par monstre dormant, 7 829 par hitscan.
`try_move` = 72 % du tic (dont localisation de secteur par descente BSP 35 %). R2-A2 (REJECT d'abord) vaut
×24,7 sur un test de vue ; R2-A4 ×1,15 ; **R2-A5 (dédup inter-cellules) est une pessimisation** (×4,6 sur un
hitscan) → remplacée. Primitives : add 1, mul 2, comparaison entière 10, felt→u128 6, index de span 11,
poseidon 10,5/felt, `fixed_mul` 18, `fixed_div` 55 ; dépaquetage de 5 champs 16 bits 106 contre 55 en
planaire ; état ≈ 19–24 felts/mobj. Encodage par offset (18) bat les felts négatifs (28) ; rester < 2^72 est gratuit.

**Mur de taille de programme** : le prototype compile en **98 585 mots de bytecode** ; le bootloader
hache le programme à 2 340 + 14,7 × mots → **1,45 M steps par segment, au-delà du plafond 2^20 : le
prototype tel quel n'est pas prouvable.** Mesures : 1 mot par felt de constante, 18 mots par entrée
d'arbre de `if`, +54 mots par site d'appel `#[inline(always)]`, +60–77 par monomorphisation générique.
Prérequis : **programme < ~32 000 mots** (R2-A12), packing des données froides, jamais d'arbres de `if`
comme tables, `cairo-profiler ≥ 0.17` sans `--show-inlined-functions`. Avec R2-A9…A11 (accélérateur
cellule → sous-secteurs, itération blockmap sans tableau, cellule mémorisée dans le mobj) le tic complet
est projeté à ~11 900 steps ; **K ≈ 81–162 tics par segment** (et non 250) ; atteindre 4 000 exige R2-A6
(moins de monstres éveillés) et R2-A7 (17,5 Hz).

**Outil WAD v2 (2026-09-12, `tools/wad`)** : taille des constantes de niveau en mots de bytecode (1 mot/felt),
sans SEGS ni noms de textures, avec sous-secteur → secteur précalculé, prédicats de demi-plan (linedefs et
nœuds) et accélérateur cellule → sous-secteurs (R2-A9 : 2,63 sous-secteurs/cellule en moyenne, max 20) :

| Map Freedoom | Mots (mix recommandé) | | Map | Mots |
|---|---:|---|---|---:|
| **E1M1** | **26 903** (tout packé 17 604, tout planaire 70 075) | | E1M5 | 28 841 |
| E1M2 | 46 956 | | E1M6 | 59 524 |
| E1M3 | 42 533 | | E1M7 | 91 302 |
| E1M4 | 51 011 | | E1M8 | 22 945 |
| E1M9 | 41 244 | | | |

E1M1 est déjà l'une des plus petites maps de Freedoom Phase 1. Les données seules dépassent le budget
D4 de 16 k mots : le coût de hachage bootloader d'un programme de ~30 k mots est ≈ 440 k steps (blake,
42 % d'un segment 2^20) ou ≈ 165 k steps (poseidon, 16 %) ; avec un lifting de registre 2^21 (S4b) ces
parts sont divisées par deux. Stratégie retenue : hachage poseidon + segments 2^21 si S4b les valide,
données froides packées, budget global 32 k mots ; repli : données de niveau fournies en entrée et
engagées par Merkle avec vérification des accès.

## 10. Inconnues à lever (référencées par le PLAN)

1. **U1** Steps/tic réels du cœur Cairo sur la map Freedoom E1M1 (S1).
2. **U2** Mémoire et temps de preuve d'un segment 2^20–2^21 steps en WASM64 Chrome (S2) ; effet de la
   trace pré-traitée `CanonicalSmall` vs `Canonical`.
3. **U3** Débit d'exécution cairo-vm WASM par tic (≥ 100 tics/s visé) avec cache du programme (S3).
4. **U4** Reproduction de la route récursive sur le monorepo `proving` courant, avec N feuilles, et
   recomposition on-chain des sorties de feuilles (S4).
5. **U5** Frais réels des 3 tx sur Sepolia/mainnet et fiabilité de `starknet_simulateTransactions` (S5).
6. **U6** Comportement du prouveur courant face aux felts ≥ 2^128 et au builtin bitwise (S0).
7. **U7** Décision de licence pour `doom_core` (GPL vs clean-room).
8. **U8** Hébergement du wrapper (Cartridge ? auto-hébergé ?) et politique de fallback « prouveur distant ».

L'analyse détaillée des risques et les actions associées sont dans [RISKS.md](RISKS.md).

## 11. Glossaire

- **Tic** : pas de simulation Doom (1/35 s). **ticcmd** : input d'un tic.
- **Segment** : tranche de K tics prouvée comme une exécution Cairo indépendante, chaînée par hash d'état.
- **Feuille / racine** : preuve de circuit d'un segment / preuve agrégée de l'arbre récursif.
- **Fait (fact)** : engagement on-chain « programme P a produit sorties O », consultable via `is_valid`.
- **Wrapper** : service qui transforme des preuves Cairo en preuve racine (ne peut pas forger).

## 12. Sources

- Monorepo proving : https://github.com/starkware-libs/proving (`CLAUDE.md`, `.claude/rules/*-guide.md`,
  `stwo_cairo_verifier/README.md`, `crates/stwo_run_and_prove/src/README.md`,
  `crates/stwo_run_and_prove_recursive_tree/src/lib.rs`, `crates/leaf_prover/src/main.rs`)
- stwo-cairo : https://github.com/starkware-libs/stwo-cairo (README, tags v1.0.0–v1.3.0)
- stwo : https://github.com/starkware-libs/stwo
- Scarb prove/verify : https://docs.swmansion.com/scarb/docs/extensions/prove-and-verify.html
- Cairo Book, executable workflow : https://www.starknet.io/cairo-book/ch01-03-proving-a-prime-number.html
- stwo-cairo-ts (npm `stwo-cairo`) : https://github.com/clealabs/stwo-cairo-ts (issue #2)
- Vérifieur Stwo on-chain (R&D) : https://github.com/modeofO/stwo-starknet-verifier (README,
  `stwostarknetverifierhandoff.md`, `docs/architecture.md`, `docs/lane1-results.md`, `docs/spike2-results.md`,
  `docs/spike3-results.md`, `docs/proof-only-wrapping.md`, `docs/how-it-works.md`)
- Integrity : https://github.com/HerodotusDev/integrity (`deployed_contracts.md`)
- Atlantic / Stwo : https://docs.herodotus.cloud/atlantic-api/stwo
- Recursion circuit (StarkWare, 03/2026) : https://starkware.co/blog/minutes-to-seconds-efficiency-gains-with-recursive-circuit-proving/
- Frais Starknet : https://docs.starknet.io/learn/protocol/fees ; limites : https://docs.starknet.io/resources/chain-info
- Starknet v0.14.3 : https://blog.thirdweb.com/starknet-v0-14-3-explained-dynamic-gas-fees-30-cost-cut-and-what-builders-need-to-know/
- SNIP-36 : https://community.starknet.io/t/snip-36-in-protocol-proof-verification/116123
- Memory64 : https://reintech.io/blog/webassembly-browser-support-2026-compatibility-guide
- Doom : https://doomwiki.org/wiki/Doomgeneric , https://doomwiki.org/wiki/Demo ,
  https://www.gamers.org/docs/FAQ/lmp.faq.html , https://github.com/ozkl/doomgeneric , https://freedoom.github.io/
- awesome-stwo : https://github.com/keep-starknet-strange/awesome-stwo


Validation finale S14 : 26 cas exacts dans chacun des profils dev/proving,
7 575 tics logiques par profil, en 1 365,78 s. Le fuzz de 10 000 tics cité plus
haut porte sur `0c8a3a8`, pas sur ce nouveau moteur.

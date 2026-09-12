# PLAN — Hellproof (Doom prouvable) : plan d'exécution

> Plan de développement, de test et de validation issu de l'étude de faisabilité ([CONTEXT.md](CONTEXT.md)).
> Version du 2026-09-12. Roadmap détaillée, Gantt et chemin critique : [ROADMAP.md](ROADMAP.md). Les identifiants **S*** (spikes), **U*** (inconnues, cf. CONTEXT §10) et
> **C*** (critères) sont stables pour pouvoir être référencés dans les issues et les PR.

## 0. Objectif du MVP et critères de succès globaux

**MVP** : un niveau Freedoom jouable dans Chrome, dont une partie complète est prouvée localement,
vérifiée localement, chiffrée en STRK/fiat, puis (au choix du joueur) enregistrée on-chain sur
Starknet Sepolia via un fait vérifié cryptographiquement, avec leaderboard.

Critères de succès (« definition of done » du MVP) :

- **C1 Jouabilité** : 35 tics/s stables dans Chrome desktop sur un laptop récent ; niveau finissable
  du spawn au switch de sortie ; monstres, armes, portes, objets du niveau fonctionnels.
- **C2 Déterminisme** : rejouer un journal d'inputs reproduit exactement le hash d'état final
  (100 % des replays du corpus de tests, sur navigateur et en natif).
- **C3 Preuve locale** : une partie de 3 min est prouvée dans le navigateur (segments en tâche de fond)
  en moins de **10 min après la fin de partie** sur une machine 16 GB ; la vérification locale passe.
- **C4 On-chain** : le fait est vérifié on-chain (registry Stwo) et `DoomRuns.submit_run` accepte
  la partie ; toute altération (inputs, sorties, chaînage) est rejetée.
- **C5 Coût affiché** : avant soumission, l'UI affiche le coût estimé (STRK + fiat) des transactions
  et l'écart entre estimation et coût réel constaté est < 20 % sur 10 soumissions Sepolia.
- **C6 Hors-chaîne** : « garder hors-chaîne » conserve la partie (inputs + preuves) localement et
  permet une soumission ultérieure ; un reset l'efface, comme demandé.
- **C7 Qualité des crates Cairo** : chaque crate générique a un périmètre documenté, un graphe de
  dépendances acyclique vérifié en CI, une couverture de branches ≥ 90 %, des tests de valeurs de
  référence, de propriétés et de budget de steps (décision A10, §3.1).

## 1. Décisions d'architecture

| # | Décision | Justification (cf. CONTEXT) |
|---|----------|-----------------------------|
| A1 | **Cairo est la source de vérité de la simulation, y compris en temps réel** : le client exécute le même programme `step_tic` via cairo-vm WASM à chaque tic (pas de port TypeScript parallèle). Repli : miroir TS + tests de divergence si S3 échoue. | Supprime toute désynchronisation entre ce qui est joué et ce qui est prouvé. |
| A2 | **Preuve par segments** de K tics (`run_segment`) chaînés par hash d'état Poseidon, agrégés par la **route récursive** (`leaf_prover` + `recursive_tree`) en une preuve racine unique. | Mémoire navigateur (R1) ; coût on-chain constant (§6.2). |
| A3 | **Vérification on-chain via un `StwoFactRegistry`** (code Apache-2.0 de `stwo-starknet-verifier`, ré-épinglé sur le monorepo `proving`) + contrat consommateur `DoomRuns`. | Seule route praticable (§6.1). |
| A4 | **Service wrapper** Rust auto-hébergé (≥ 32 GB) pour feuilles + arbre récursif ; API « proof-only » (il ne reçoit que des preuves et des sorties publiques). Fallback optionnel « prouveur distant » pour machines < 16 GB. | Wrap non faisable en WASM (13–22 GB) ; il ne peut pas forger. |
| A5 | **Niveau et règles compilés dans le programme Cairo** (constantes générées depuis `freedoom1.wad`) ; le hash du programme épingle niveau + règles. | Pas d'engagement séparé à gérer ; fait auto-descriptif. |
| A6 | **Renderer WebGL en TypeScript** (murs/sols/plafonds depuis les secteurs, sprites billboard, textures Freedoom), découplé de la sim via l'état sérialisé. | Le renderer n'a pas besoin d'être prouvé ; approche « map viewer » bien maîtrisée. |
| A7 | **Arithmétique felt-first** en Cairo : add/mul sur felt252, réductions et comparaisons explicites aux frontières ; pas de felts négatifs en mémoire ; pas de builtin bitwise (jusqu'à S0). | Mesures §4.3 (14 vs 57–61 steps/itération). |
| A8 | **Wallet Cartridge Controller** (sessions) + `starknet.js` ; estimation par `starknet_simulateTransactions` ; paymaster possible mais le coût est toujours affiché. | Écosystème de l'équipe ; exigence produit. |
| A9 | Licences : les crates Cairo dérivées de linuxdoom sous **GPL-2.0-or-later**, reste du dépôt Apache-2.0 ; assets Freedoom (BSD). | CONTEXT §8.2 — à confirmer (U7). |
| A10 | **Côté Cairo, tout est bibliothèque générique d'abord** : le workspace Scarb est découpé en **crates à périmètre étroit** (un domaine précis par crate, API publique minimale, zéro dépendance vers le jeu pour les crates génériques), chacune livrée avec une **suite de tests unitaires exhaustive** (valeurs de référence, propriétés, cas limites, tests de budget de steps) qui verrouille l'intégrité et la non-régression. Les crates spécifiques à Doom (règles, IA, niveau) ne font qu'assembler ces briques. Voir §2 et §3.1. | Réutilisabilité dans d'autres jeux prouvables ; changements localisés ; régressions détectées au niveau de la brique fautive. |

## 2. Organisation du dépôt (cible)

```
doom/
├── CONTEXT.md  PLAN.md  LICENSE (Apache-2.0)  LICENSES/GPL-2.0.txt
├── cairo/                    # workspace Scarb (voir §3.1 pour le détail des crates et leurs règles)
│   ├── crates/               # bibliothèques génériques, sans dépendance vers Doom (Apache-2.0)
│   │   ├── fixed/            #   point fixe 16.16 felt-first (mul, div, abs, cmp, sqrt approx)
│   │   ├── bam/              #   angles BAM 32 bits, tables sin/cos/tan, point_to_angle
│   │   ├── prng/             #   générateur à table (256 entrées) indexé, rejouable
│   │   ├── geom2d/           #   segments, boîtes, point_on_side, intersections, distances
│   │   ├── bsp/              #   nœuds/sous-secteurs, point_in_subsector, traversée de rayon
│   │   ├── blockmap/         #   grille spatiale, itération de cellules le long d'un segment
│   │   ├── fsm/              #   machines à états « info.c » génériques (états, tics, actions)
│   │   ├── ticcmd/           #   encodage/décodage des inputs (packing 7 tics / felt)
│   │   ├── state_hash/       #   sérialisation canonique + hash Poseidon d'un état, chaînage
│   │   └── segment/          #   moteur run_segment générique : boucle de tics, sorties publiques
│   ├── doom/                 # crates spécifiques Doom (GPL-2.0-or-later)
│   │   ├── doom_map/         #   données de niveau générées (E1M1 Freedoom) + accès typés
│   │   ├── doom_things/      #   mobjinfo, états, sprites indexés (données `info.c` réduites)
│   │   ├── doom_physics/     #   P_TryMove, P_SlideMove, hauteurs, P_PathTraverse, P_CheckSight
│   │   ├── doom_player/      #   P_PlayerThink, armes, munitions, ramassage, clés
│   │   ├── doom_monsters/    #   A_Look, A_Chase, attaques, dégâts, mort
│   │   ├── doom_specials/    #   portes, plateformes, lumières, switches, sortie
│   │   ├── doom_game/        #   GameState, genesis, step_tic (assemblage des crates ci-dessus)
│   │   └── doom_run/         #   executables : step_tic, run_segment, genesis
│   ├── doom_contracts/       # DoomRuns (+ StwoFactRegistry vendu/épinglé), tests snforge
│   └── fixtures/             # replays dorés, états, preuves de référence
├── tools/
│   ├── wad/                  # TS : freedoom1.wad → constantes Cairo + JSON client (map, textures, sprites)
│   ├── replay/               # CLI : rejouer un journal, dumper états/hashes, générer fixtures
│   └── fidelity/             # (optionnel) harnais doomgeneric headless pour comparaison physique
├── prover/
│   ├── wasm/                 # build WASM64 du prouveur/vérifieur épinglé sur `proving` (Rust)
│   └── wrapper/              # service HTTP : leaf_prover + recursive_tree + emission felts/préimages
├── client/                   # Vite + TS : renderer, workers sim/prover, UI, wallet
└── infra/                    # devnet, scripts declare/deploy, CI
```

## 3. Phases

### Phase 0 — Spikes de dé-risquage (≈ 3 semaines, en parallèle)

Chaque spike produit une note `docs/spikes/S<n>.md` avec mesures reproductibles et un verdict
**GO / GO-avec-repli / NO-GO** ; aucune tâche des phases 1–4 dépendant d'un spike ne démarre avant.

| Spike | Question (inconnue) | Travail | Critère GO | Repli si NO-GO |
|---|---|---|---|---|
| **S0** Pipeline de preuve de référence | U6 | Sur le monorepo `proving` épinglé : prouver un exécutable Scarb via le chemin bootloader (`cairo-program-runner` → prover input → preuve → `--verify`) ; tester felts ≥ 2^128 en mémoire et builtins (bitwise, poseidon) ; mesurer temps/RSS pour 2^18…2^22 steps ; documenter le `prover_params` (canal Blake2sM31, config privacy, `CanonicalSmall`). | Pipeline reproductible en une commande ; comportement documenté ; RSS(2^20) connu. | Fixer les règles A7 en conséquence ; sinon escalader upstream. |
| **S1** Coût par tic | U1 | Prototype Cairo (déjà découpé en crates `fixed`/`bam`/`geom2d`/`blockmap`, jetables mais testés) : map Freedoom E1M1 extraite (blockmap, secteurs, lignes, REJECT), joueur (mouvement, `P_TryMove`, hauteur), 5 monstres avec `A_Look`/`A_Chase` + vue via REJECT + traversée blockmap, 1 hitscan ; `scarb execute --print-resource-usage` sur 350 tics scriptés. | **≤ 4 000 steps/tic** en moyenne (≤ 8 000 acceptable). | Réduire : moins de monstres actifs (skill 1), vue par REJECT + distance, IA toutes les 2 tics, sim à 17,5 Hz avec interpolation. |
| **S2** Preuve dans le navigateur | U2 | Build WASM64 (`wasm64-unknown-unknown`, `-Z build-std`, threads/SharedArrayBuffer) du prouveur épinglé, sur le modèle de `stwo-cairo-ts` ; page de test Chrome ; traces 2^18, 2^19, 2^20, 2^21 steps ; mesurer temps, mémoire (`performance.measureUserAgentSpecificMemory`), stabilité (issue #2). | 2^20 steps prouvés en **< 120 s** et **< 12 GB** sur laptop 16–32 GB ; vérification WASM < 5 s. | Segments 2^19 ; sinon fallback « prouveur distant » par défaut (A4) et client natif en phase 5. |
| **S3** Exécution temps réel | U3 | Wrapper wasm cairo-vm avec **programme mis en cache** ; appel `step_tic(state, cmd)` en boucle ; mesurer latence/tic et coût de (dé)sérialisation de l'état (~1–2 k felts). | **≥ 100 tics/s** soutenus dans un Worker (marge 3× sur 35 Hz). | Miroir TS de la sim + tests de divergence (fixtures dorées) ; Cairo ne sert qu'à la preuve. |
| **S4** Route récursive N feuilles | U4 | Générer un registre de circuits `doom` (`circuit_params --registry`, trace log 20, `canonical_small`) puisque le registre `production` ne couvre que 2^25–2^29 ; reproduire `scripts/prove-and-verify.sh` de `stwo-starknet-verifier` sur le monorepo courant ; N = 1, 2, 4, 8 feuilles avec `recursive_tree` ; exécuter `stwo_circuit_verifier` sur la racine ; écrire la **recomposition Cairo des sorties de feuilles** depuis `packed_output` et la tester en snforge ; mesurer temps/RSS du wrapper. | Racine acceptée (~3,8 M steps) ; chaîne `h_in/h_out` des N feuilles recalculée on-chain à partir des préimages ; wrap N=8 < 5 min sur 32 GB. | Multiverifier 2 entrées + soumission de ⌈N/2⌉ faits (coût on-chain × N/2) ; ou arbre côté serveur en plusieurs passes. |
| **S5** Coûts réels | U5 | Déployer le registry sur devnet + Sepolia ; jouer les 3 tx ; comparer `starknet_simulateTransactions` vs reçus ; estimer les tx `DoomRuns` ; script de conversion STRK→fiat. | Écart estimation/réel < 20 % ; coût par fait documenté en STRK au prix courant. | Marges de sécurité dans l'UI (×1,3) ; paymaster. |
| **S6** Fidélité physique (optionnel) | — | `doomgeneric` headless + démo LMP sur la même map → dump `x, y, z, angle` du joueur par tic ; comparer au prototype S1 sur 350 tics. | Écart nul sur mouvement/collision simple. | Documenter les divergences acceptées (le MVP n'exige pas la fidélité bit-à-bit). |

**Gate G0** (fin de phase 0) : S0, S1, S2, S3, S4 en GO ou GO-avec-repli ; décision consignée sur
K (tics/segment), cible steps/tic, mode d'exécution temps réel, hébergement du wrapper, licence (U7, U8).

### Phase 1 — Cœur de jeu en Cairo (≈ 6–8 semaines)

Livrables : les crates génériques `cairo/crates/*`, les crates `cairo/doom/*`, `doom_run`
(`genesis`, `step_tic`, `run_segment`), `tools/wad`, `tools/replay`.

#### 3.1 Règles d'architecture des crates Cairo (décision A10)

1. **Une crate = un domaine.** Le `README.md` de chaque crate tient en un paragraphe : ce qu'elle
   fait, ce qu'elle ne fait pas, ses invariants. Si l'on hésite à y ajouter une fonction, c'est
   qu'elle appartient à une autre crate (ou à une nouvelle).
2. **Dépendances orientées et minimales.** `crates/*` ne dépendent que de `core` et d'autres
   `crates/*` de niveau inférieur (`fixed` ← `bam` ← `geom2d` ← `bsp`/`blockmap` …) ; jamais de
   `doom/*`. Les `doom/*` dépendent des génériques et entre elles selon un graphe acyclique documenté
   (`doom_game` est la seule à tout agréger). Un test de CI vérifie le graphe (`scarb metadata`).
3. **API publique minimale et typée.** Types nouveaux (`Fixed`, `Angle`, `SectorId`…) plutôt que
   felts nus ; pas de `pub` par défaut ; pas de trait object inutile ; fonctions pures (état en
   entrée, état en sortie) pour rester triviales à tester et à prouver.
4. **Tests unitaires obligatoires et co-localisés** (`src/**/tests.cairo` + `tests/`) :
   - **valeurs de référence** extraites du code C original ou d'un calcul indépendant (tables
     trigonométriques, `FixedMul/Div`, table RNG, résultats de `P_PointOnLineSide`) ;
   - **propriétés** (associativité, bornes, idempotence, symétries) avec générateurs déterministes ;
   - **cas limites** (wrap BAM, zéro, valeurs maximales, lignes verticales/horizontales, cellules
     hors blockmap) ;
   - **budget de steps** : au moins un test par crate mesure le coût d'une opération représentative
     et échoue au-delà du budget (`+10 %`), pour empêcher les régressions de performance de preuve ;
   - **prouvabilité** : les valeurs produites restent < 2^128 (règle A7), vérifié par des asserts de
     sérialisation.
   Objectif : couverture de branches ≥ 90 % par crate générique (`cairo-coverage`), 100 % des
   fonctions publiques testées ; une PR qui baisse la couverture d'une crate est refusée.
5. **Non-régression.** Toute correction de bug ajoute d'abord le test qui la reproduit ; les
   changements de sortie sur les replays dorés exigent une justification et la régénération explicite
   des fixtures (jamais silencieuse).
6. **Versionnage par crate** (`Scarb.toml`), CHANGELOG par crate, publication possible hors du dépôt
   (Cartridge/Dojo) sans emporter le code GPL.

Tâches (ordre suggéré) :

1. **Extraction WAD** : parser `freedoom1.wad` (TS), sélectionner `E1M1`, générer `levels/e1m1.cairo`
   (vertices, linedefs, sidedefs, sectors, things, blockmap, nodes/segs/ssectors, REJECT) et
   `client/public/levels/e1m1.json` ; lister les **types de lignes spéciales et de things réellement
   présents** → périmètre exact du gameplay à implémenter.
2. **Crates génériques** (une PR par crate, tests d'abord) : `fixed`, `bam` (tables `finesine`,
   `tantoangle` générées par script avec test d'égalité au C), `prng` (table de 256), `geom2d`,
   `bsp`, `blockmap`, `fsm`, `ticcmd`, `state_hash`, `segment`.
3. **État et hash** : `doom_game::GameState` (joueur, mobjs, secteurs dynamiques, thinkers, RNG,
   tic) construit sur `state_hash` ; sérialisation canonique ; `genesis(seed)`.
4. **Joueur** : `P_PlayerThink` (ticcmd → momentum, friction), `P_TryMove`/`P_SlideMove`, hauteurs,
   `P_UseLines`, armes (poing, pistolet, fusil à pompe, mitrailleuse : hitscan via `P_PathTraverse`),
   munitions, santé/armure, ramassage d'objets, clés.
5. **Monstres** présents dans la map (a priori zombieman, sergeant, imp ; selon extraction) :
   états `info.c` réduits, `A_Look`, `A_Chase`, `A_FaceTarget`, attaques hitscan et projectile
   (imp), dégâts, mort, `P_CheckSight` (REJECT + BSP), `P_NewChaseDir`.
6. **Spécials** : portes (DR, switch), plateformes/ascenseurs, lumières si présentes, secteurs
   dommageables, switch de sortie → `status = EXIT`, téléporteurs si présents.
7. **`run_segment(state_in, cmds[K]) -> [h_in, h_out, tic_start, tic_end, status, kills, items, secrets]`**
   avec `status ∈ {RUNNING, DEAD, EXIT}` ; `step_tic` partage exactement le même code.
8. **Optimisation steps** : profilage `cairo-profiler`, budget par crate (tests de budget),
   revue felt-first.

Tests :

- unitaires par crate selon §3.1 : fixed/angles/tables **contre des valeurs de référence extraites
  du code C** ; RNG ; BSP `point_in_subsector` sur 1 000 points aléatoires vs implémentation TS ;
  couverture ≥ 90 % sur `crates/*` ;
- propriétés : le joueur ne traverse jamais une ligne bloquante ; la santé reste dans [0, 200] ;
  `run_segment(s, a ++ b) == run_segment(run_segment(s, a), b)` (associativité du chaînage) ;
- **replays dorés** : 20 journaux d'inputs (scriptés + enregistrés) → hash final et stats figés en
  fixture ; toute PR qui change un hash doit le justifier ;
- exécution prouvable : `scarb execute` sans panique sur tous les replays ; **aucun felt ≥ 2^128 en
  mémoire** (assert dans les tests de sérialisation) ;
- performance : test CI qui échoue si steps/tic moyen > budget fixé à G0 (+10 %).

Critères de validation : **C2** en natif ; budget steps tenu ; partie complète scriptée (spawn → sortie)
en fixture ; preuve S0 d'un segment de K tics réussie ; **C7** respecté.

### Phase 2 — Client web (≈ 4–6 semaines, en parallèle de la phase 1 dès l'extraction WAD)

Livrables : `client/` (Vite, TS, Workers), renderer WebGL, boucle de jeu, enregistrement des inputs,
stockage local, écrans de fin de partie.

Tâches :

1. Chargement des assets Freedoom (palette, textures, flats, sprites) et du JSON de niveau.
2. Renderer WebGL : triangulation des secteurs (earcut), murs (lower/middle/upper), sprites billboard,
   éclairage par secteur, HUD (santé, munitions, armes, clés), interpolation entre tics.
3. Worker « sim » : cairo-vm WASM (S3) exécutant `step_tic` ; bus d'état vers le renderer ;
   journal `ticcmd[]` horodaté ; pause/reprise déterministe.
4. Contrôles clavier/souris → `ticcmd` (forward/side/turn/buttons) identiques à Doom.
5. Persistance IndexedDB : journal d'inputs, hashes de segments, preuves ; export/import de fichier.
6. Écrans : titre, partie, fin (mort / niveau terminé avec stats), file d'attente de preuve.
7. En-têtes COOP/COEP servis en dev et prod ; détection Memory64 et RAM disponible.

Tests : unitaires renderer (géométrie), Playwright : partie scriptée par injection de ticcmds → hash
final identique à la fixture Cairo (**C2** navigateur) ; test de charge 35 Hz (frames droppées < 1 %).

Critères : **C1**, **C2** (navigateur), **C6** (persistance).

### Phase 3 — Pipeline de preuve (≈ 4 semaines)

Livrables : `prover/wasm` (npm interne), Worker « prover », `prover/wrapper` (service), CLI de
vérification.

Tâches :

1. Build WASM64 épinglé (S2) : `execute` (prover input depuis `run_segment` + args), `prove`, `verify` ;
   publication comme paquet interne avec hash de version du programme Cairo.
2. Worker « prover » : découpage en segments dès que K tics sont disponibles (preuve **pendant** la
   partie), file de priorités, reprise après rechargement, reporting de progression et de mémoire.
3. Vérification locale de chaque segment + de la cohérence `h_out[i] = h_in[i+1]`.
4. Service wrapper (Rust, axum) : `POST /wrap {leaf_proofs[], outputs[]}` → `{root_felts, packed_output,
   program_output}` ; jobs asynchrones ; limites de taille ; idempotence par hash ; métriques.
5. (Optionnel, A4) endpoint « prove » distant pour machines sous-dimensionnées.
6. Bench continu : temps de preuve par segment (natif/WASM), RSS, taille des preuves.

Tests : e2e « journal → segments → preuves → wrap → racine acceptée par `stwo_circuit_verifier` » sur
les 20 replays dorés (CI, natif) ; test navigateur sur 1 replay complet ; preuves altérées rejetées.

Critères : **C3** ; wrapper N=25 < 15 min ; taux d'échec de preuve navigateur < 1 % sur 50 essais.

### Phase 4 — On-chain et soumission (≈ 4 semaines)

Livrables : `doom_contracts` (registry épinglé + `DoomRuns`), scripts devnet/Sepolia, UI de soumission
avec simulation de coût.

Tâches :

1. Ré-épingler et déployer `StwoFactRegistry` (Phase1/Phase2/Registry) sur devnet puis Sepolia ;
   vérifier `is_valid` sur une racine produite par notre pipeline (S4).
2. `DoomRuns` : `submit_run(program_hash, leaf_outputs[], inner_roots…, proof_id)` : recalcule le fait
   (`compute_fact`), vérifie `is_valid`, `h_in[0] = genesis`, continuité, `status = EXIT`, unicité
   (`proof_id`/fait), puis stocke `Run {player, level_id, tics, kills, items, secrets, score, block}` ;
   événement `RunSubmitted` (+ événement optionnel `Replay(inputs packés)`) ; vues leaderboard.
3. Client : orchestrateur des 4 tx (stage, phase1, phase2, submit) avec sessions Controller ;
   `starknet_simulateTransactions` en séquence → écran « Coût estimé : X STRK (~Y €) — Soumettre /
   Garder hors-chaîne » ; reprise après échec partiel (les phases sont idempotentes par `proof_id`).
4. Indexation (Torii ou événements RPC) et page leaderboard.

Tests : snforge (fait valide/invalide, chaînage cassé, `status ≠ EXIT`, rejeu) ; **drive devnet** avec
reçus réels (oracle gas) ; e2e Sepolia sur 10 parties ; comparaison estimation/réel (**C5**).

Critères : **C4**, **C5** ; toutes les tx sous 90 % du plafond invoke (1,21e9 L2 gas).

### Phase 5 — Intégration, durcissement, mainnet (≈ 3 semaines)

- Parcours complet en conditions réelles (5 testeurs externes, machines variées) ; télémétrie de la
  preuve (opt-in) ; rapport de compatibilité (Chrome/Firefox, 16/32 GB).
- Gel des versions (programme Cairo, prouveur, circuit, contrats) et publication des hashes ; procédure
  de mise à jour (nouveau `program_hash` = nouvelle « saison »).
- Sécurité : revue du chaînage et des préimages ; tests d'altération ; audit léger des contrats ;
  `freeze_routes()` du registry.
- Mainnet : declares (~180 STRK), déploiement, seuils de coût affichés, page de statut.
- Documentation utilisateur et développeur ; runbook du wrapper.

## 4. Stratégie de test transverse

| Niveau | Outil | Ce qui est vérifié |
|---|---|---|
| Unitaire Cairo (par crate) | `scarb test` / snforge, `cairo-coverage` | primitives vs valeurs C de référence, propriétés, cas limites, budget de steps, couverture ≥ 90 % |
| Propriétés / fuzz | snforge + générateurs TS | invariants physiques, associativité des segments |
| Replays dorés | `tools/replay` + fixtures | déterminisme (C2), stabilité des hashes, budget steps |
| Différentiel (opt.) | `tools/fidelity` (doomgeneric) | fidélité mouvement/collision |
| Preuve | monorepo natif + WASM | prouvabilité (pas de panique), temps, mémoire, rejet d'altérations |
| Contrats | snforge, **devnet drive** | logique, gas réel, plafonds |
| E2E | Playwright + Sepolia | parcours complet, C1–C6 |
| CI | GitHub Actions | tout ce qui précède hors Sepolia ; benchmarks publiés en artefacts |

## 5. Planning indicatif et effort

Équipe cible : 1 dev Cairo (cœur + contrats), 1 dev web (renderer/client), 1 dev Rust/infra (prouveur
WASM, wrapper, devnet) ; recouvrement fort sur les spikes.

| Semaine | Jalons |
|---|---|
| 1–3 | Phase 0 (S0–S5), **G0** |
| 4–11 | Phase 1 (cœur) ‖ Phase 2 (client) ‖ Phase 3.1–3.2 (WASM, worker) |
| 8–12 | Phase 3.3–3.6 (wrapper, benchs) ; première preuve d'une partie complète (**C3**) |
| 12–16 | Phase 4 (contrats, soumission, coût) ; **C4/C5** sur Sepolia |
| 16–19 | Phase 5 ; décision mainnet |

Total ≈ **4,5 mois** pour le MVP à 3 personnes ; les phases 1–3 sont les plus incertaines (budget steps
et mémoire navigateur), d'où l'importance de G0.

## 6. Risques et mitigations

L'analyse détaillée (constats chiffrés, causes racines, actions identifiées **R<n>-A<m>** avec effort
et critères de sortie) est dans [RISKS.md](RISKS.md). Résumé :

| Risque | Impact | Probabilité | Mitigation |
|---|---|---|---|
| Mémoire WASM64 > budget navigateur (R1) | fort | moyenne | trace pré-traitée `canonical_small` obligatoire (53× plus petite que `canonical`, plafond 16 GB en WASM64) ; segments ≤ 2^20 ; fallback prouveur distant ; client natif |
| Steps/tic trop élevés (R2) | fort | moyenne | felt-first, REJECT, IA allégée, moins de monstres, 17,5 Hz sim |
| Dérive de versions du monorepo `proving` (topologie multiverifier, formats) et registre de circuits inadapté (production = feuilles 2^25–2^29) | fort | élevée | épinglage strict par commit, registre de circuits `doom` (log 20) généré par `circuit_params`, hash du multiverifier épinglé dans `DoomRuns`, suite de conformité hebdo, vendoring |
| Prouveur/adaptateur : panics sur certaines valeurs/builtins | moyen | moyenne | S0, règles A7, tests « prouvabilité » sur tous les replays |
| Coût on-chain jugé trop élevé par les joueurs | moyen | moyenne | affichage transparent, paymaster/sponsoring par saison, batch de plusieurs parties par fait (arbre) |
| Plafond invoke abaissé ou pricing storage modifié | fort | faible | devnet drive à chaque bump de version Starknet ; marges 10 % |
| Licence GPL du cœur | juridique | — | décision U7 avant phase 1 ; licensing par répertoire |
| Fiabilité Memory64 hors Chrome | UX | élevée | cibler Chrome ; détection et message clair ; fallback distant |
| Wrapper indisponible | UX | moyenne | file locale persistante ; soumission différée (C6) ; possibilité d'auto-héberger |

## 7. Questions ouvertes (décisions attendues)

1. **Licence** du cœur Cairo : GPL-2.0-or-later assumée, ou réécriture clean-room (U7) ?
2. **Hébergement du wrapper** et du fallback « prouveur distant » (U8) ; sponsoring des frais (paymaster) ?
3. **Cible réseau v1** : Sepolia uniquement ou mainnet dès le MVP (declares ~180 STRK + frais par fait) ?
4. **Portée gameplay** : skill par défaut (nombre de monstres) et liste exacte des spécials retenus après
   extraction de la map Freedoom E1M1.
5. **Fidélité** : viser la compatibilité bit-à-bit avec Doom (harnais S6) ou un « Doom-like fidèle » ?

# RISKS — Analyse approfondie des risques et plan d'actions

> Complète [PLAN.md](PLAN.md) §6 et [CONTEXT.md](CONTEXT.md). Version du 2026-09-12.
> Chaque risque : constat chiffré, cause racine, impact, actions concrètes (identifiant **R<n>-A<m>**,
> phase, effort, critère de sortie), risque résiduel et indicateurs de surveillance.
> Efforts en jours-personne (jp). Les phases/spikes renvoient au PLAN.

## Vue d'ensemble

| Id | Risque | Gravité | Probabilité | Priorité | Où il se lève |
|----|--------|---------|-------------|----------|---------------|
| R1 | Mémoire du prouveur dans le navigateur | Bloquant | Élevée sans action, faible avec | **P0** | S0, S2 |
| R2 | Budget de steps par tic | Fort | Moyenne | **P0** | S1, Phase 1 |
| R3 | Route on-chain : dimensionnement des circuits, couplage de versions | Fort | Élevée | **P0** | S4, Phase 4 |
| R4 | Exécutions non prouvables (panics, valeurs hors domaine) | Fort | Moyenne | P1 | S0, Phase 1 |
| R5 | Temps réel : exécution Cairo à 35 Hz dans le navigateur | Moyen | Moyenne | P1 | S3 |
| R6 | UX de la preuve : durée, contention CPU, perte de travail | Moyen | Élevée | P1 | Phase 2–3 |
| R7 | Coûts on-chain et limites protocolaires mouvants | Moyen | Moyenne | P1 | S5, Phase 4 |
| R8 | Service wrapper : disponibilité, abus, coût d'exploitation | Moyen | Moyenne | P2 | Phase 3 |
| R9 | Juridique : licence GPL, marque DOOM | Fort (juridique) | Certaine si ignoré | P1 | Avant Phase 1 |
| R10 | Sémantique du fait : triche assistée, rejeu, intégrité du leaderboard | Moyen | Élevée | P2 | Phase 4 |
| R11 | Toolchain : forks wasm64, nightly, build-std | Moyen | Élevée | P2 | S2, Phase 3 |
| R12 | Soundness du prouveur « non garantie » | Faible (MVP) | Faible | P3 | Phase 5 |
| R13 | Charge et séquencement de l'équipe | Moyen | Moyenne | P2 | Continu |

---

## R1 — Mémoire du prouveur dans le navigateur

### Constat

- Mesure locale (`scarb prove`, Scarb 2.16, params par défaut) : **17,2 GB RSS pour 610 k steps**,
  25,5 GB pour 6,07 M steps. Le coût est **fixe à ~17 GB**, puis ~1,5 GB par million de steps.
- Cause racine identifiée dans le code du monorepo (`crates/common/src/preprocessed_columns/preprocessed_trace.rs`) :
  la **trace pré-traitée** `Canonical` compte **543 100 528 cellules** (161 colonnes, dont les tables
  Pedersen `PedersenPoints::<18>`), soit 2,2 GB de M31 bruts avant blow-up, extension et arbres de Merkle.
  Les variantes : `CanonicalWithoutPedersen` = 73 338 480 cellules (105 colonnes), **`CanonicalSmall` =
  10 161 776 cellules** (156 colonnes, **trace max 2^20**). Ratio 53× entre `Canonical` et `CanonicalSmall`.
- Le plafond WebAssembly Memory64 est **16 GB** (spec JS API, Chrome 133+) : `Canonical` est donc
  **impossible** dans un navigateur, quel que soit le programme.
- modeofO mesure 7,9 GB en natif pour une preuve « privacy » (`CanonicalSmall`, trace 2^20 sous
  bootloader) : cohérent avec un coût dominé par la trace principale et non plus par le pré-traité.

### Impact

Sans action : aucune preuve dans le navigateur. Avec `CanonicalSmall` : segments **≤ 2^20 steps**
bootloader compris, mémoire attendue 6–10 GB → exclut les machines 8 GB et rend les 16 GB fragiles.

### Actions

| Id | Action | Quand | Effort | Critère de sortie |
|----|--------|-------|--------|-------------------|
| R1-A1 | Fixer `preprocessed_trace = canonical_small`, `include_all_preprocessed_columns = false`, canal Blake2sM31 dans le `prover_params` de référence ; interdire Pedersen dans le programme (lint CI sur les builtins utilisés via `--print-resource-usage`). | S0 | 1 jp | Preuve native d'un segment 2^20 avec RSS mesuré ; Pedersen absent des ressources. |
| R1-A2 | Profil mémoire du prouveur natif pour 2^18, 2^19, 2^20 avec `canonical_small`. **Fait (S0) : RSS ≈ 2,2 GiB + 1,8 GiB/M steps, 2^20 = 4,05 GiB ; part fixe < 3 GB atteinte.** | Fait (S0) | 2 jp | Courbe RSS = f(log_steps) documentée ; part fixe < 3 GB. |
| R1-A3 | Build WASM64 et mesure dans Chrome (`performance.measureUserAgentSpecificMemory`, `WebAssembly.Memory` maximum explicite) sur 3 machines (16 GB Apple Silicon, 16 GB x86 Windows, 32 GB). | S2 | 5 jp | 2^20 steps : < 12 GB et < 120 s sur les trois machines ; aucune éviction d'onglet. |
| R1-A4 | Dimensionner K (tics/segment) pour viser **2^19 steps utiles** (marge ×2 sous le plafond 2^20 imposé par le lifting du registre récursif), en déduisant le **coût du bootloader = 2 340 + 14,7 × mots de bytecode** (S0 ; 16 k mots = 240 k steps) et le hash d'état ; K calculé dynamiquement depuis le compteur de steps réel plutôt que fixe ; **la taille du bytecode du cœur est un budget à suivre** (cible ≤ 8 k mots). | S1→Phase 3 | 2 jp | Aucun segment n'excède 2^20 sur les 20 replays dorés ; répartition de taille publiée. |
| R1-A5 | Options prouveur : `store_polynomials_coefficients = false`, `lifting_size_policy` minimal ; vérifier l'effet de `fold_step` sur la mémoire FRI ; proposer upstream un mode « low-memory » si un allocateur transitoire domine. | S0/S2 | 2 jp | Gain mesuré ou écart documenté. |
| R1-A6 | Garde-fou produit : détection `navigator.deviceMemory` / test d'allocation WASM64 au chargement ; si < 12 GB disponibles → basculer automatiquement sur le **prouveur distant** (A4 du PLAN) avec message explicite. | Phase 2 | 2 jp | Aucun crash OOM sur le parc de test ; bascule testée par Playwright. |
| R1-A7 | Persister chaque preuve de segment dans IndexedDB dès qu'elle est produite ; libérer la mémoire WASM entre segments (ré-instancier le module). | Phase 3 | 2 jp | Rechargement de l'onglet en cours de preuve → reprise sans perte. |

Risque résiduel : machines 16 GB partagées avec d'autres onglets → repli distant. Indicateur : taux de
bascule vers le prouveur distant et taux d'OOM remontés par télémétrie opt-in.

---

## R2 — Budget de steps par tic

### Constat

- Une partie de 3 min = 6 300 tics. À 4 000 steps/tic → 25 M steps → **~48 segments de 2^19**.
  À 10 000 steps/tic → 63 M steps → 120 segments : preuve navigateur > 1 h. Le budget par tic
  conditionne directement le nombre de feuilles, le temps de preuve et le coût du wrapper.
- Micro-benchmarks : add/mul felt252 ≈ 1–3 steps ; comparaison, division, masque, conversion ≈ 10–20 steps.
- Décomposition attendue d'un tic Doom (ordres de grandeur, à mesurer en S1) :
  - joueur : `P_TryMove` (1–4 cellules blockmap × ~10 lignes × `point_on_side` + bbox) ≈ 800–1 500 ;
    friction/momentum ≈ 100 ; `P_PathTraverse` pour un tir hitscan ≈ 1 000–3 000 (rare) ;
  - monstre éveillé : `A_Chase` → `P_Move` ≈ 800–1 500 ; `P_CheckSight` avec REJECT positif ≈ 50,
    sinon traversée BSP ≈ 500–2 000 ;
  - monstre endormi : `A_Look` → `P_LookForPlayers` → `P_CheckSight` chaque tic ≈ 50–2 000 (dépend du REJECT) ;
  - spécials actifs : 50–200 par porte/plateforme ; hash d'état : ~1 000 felts → ~300 Poseidon ≈ 3–5 k
    **par segment** (négligeable par tic).
  Une map avec 20 monstres dont 5 éveillés donne ~10–15 k steps/tic sans optimisation : **le budget de
  4 000 n'est pas acquis**.

### Actions

| Id | Action | Quand | Effort | Critère de sortie |
|----|--------|-------|--------|-------------------|
| R2-A1 | Instrumentation : compteur de steps par sous-système via `cairo-profiler` sur le prototype S1 ; tableau de bord « steps/tic par fonction » régénéré en CI sur les replays dorés. | S1 | 3 jp | Top-10 des fonctions coûteuses publié à chaque PR. |
| R2-A2 | Table REJECT compilée dans le programme et utilisée en premier dans `P_CheckSight` ; secteurs mutuellement invisibles = 0 traversée BSP. | S1 | 1 jp | ≥ 80 % des appels `P_CheckSight` résolus par REJECT sur la map Freedoom E1M1 (mesuré). |
| R2-A3 | Cadencement de l'IA à la Doom : `A_Look` des monstres endormis exécuté **1 tic sur 4** (décalage par id de mobj) ; `P_CheckSight` des monstres éveillés mémorisé pendant `threshold` tics quand la cible n'a pas changé de secteur. | S1 | 2 jp | Coût des monstres endormis ≤ 50 steps/tic/monstre en moyenne. |
| R2-A4 | Représentations felt-first : coordonnées et momenta en felt252 non signés décalés (offset 2^40) pour éviter les négatifs ; comparaisons via `u128` seulement aux frontières ; `point_on_side` en produit croisé felt sans division ; angles BAM stockés en u32 mais additions en felt réduites une fois par tic. | S1/Phase 1 | 5 jp | `point_on_side` ≤ 12 steps ; `P_TryMove` ≤ 1 000 steps dans le cas courant (1 cellule, ≤ 8 lignes). |
| R2-A5 | Blockmap précalculée avec listes de lignes **triées et dédupliquées par cellule**, et bbox des lignes en constantes ; itération par cellule sans allocation (spans). | Phase 1 | 2 jp | Zéro allocation dynamique dans `P_TryMove`. |
| R2-A6 | Périmètre monstres : commencer au skill 1 (moins de things), n'implémenter que les types présents ; plafonner le nombre de monstres éveillés simultanément traités par tic (round-robin) si le budget est dépassé. | S1/G0 | 1 jp | Décision consignée à G0 avec chiffres. |
| R2-A7 | Levier de dernier recours : simulation à **17,5 Hz** (2 ticcmds fusionnés, constantes de mouvement doublées) → divise le total par ~2 ; à activer uniquement si S1 > 8 000 steps/tic après A2–A6. | G0 | 3 jp | Décision explicite ; tests de jouabilité. |
| R2-A8 | Test CI de budget : échec si la moyenne sur les replays dorés dépasse le budget G0 +10 %, ou si un tic dépasse 4× le budget (pics = segments qui débordent). | Phase 1 | 1 jp | Test actif dès la première crate. |

Risque résiduel : niveau Freedoom E1M1 plus dense que prévu → A6/A7. Indicateur : moyenne et p99 de
steps/tic sur le corpus de replays.

---

## R3 — Route on-chain : dimensionnement des circuits et couplage de versions

### Constat

- Le registre de circuits **`production`** du monorepo est défini pour des feuilles de trace
  **log 25 à 29** (32 M à 512 M steps, paramètres SHARP, `preprocessed_trace = canonical`) ; le
  registre **`canonical_small`** est un jeu de test à **log 20 exactement** avec des cibles de padding
  (`eq` 2^20, `qm31_ops` 2^23, `m31_to_u32` 2^21, `triple_xor` 2^20, `blake_g_gate` 2^23). **Aucun
  registre publié ne correspond à nos segments** : un registre dédié doit être généré
  (`circuit_params --registry` sur une `definition.json` à nous).
- `leaf_prover` choisit le circuit vérifieur selon `trace_log_size` et **padde** au `pad_to_component_log_sizes`
  commun : toutes les feuilles ont la même forme, ce qui rend l'arbre `recursive_tree` possible. Le coût
  mémoire/temps du wrapper dépend de ces cibles (2^23 pour `qm31_ops`/`blake_g_gate` : c'est là que
  partent les 13–22 GB mesurés par modeofO).
- Le vérifieur Cairo on-chain (`stwo_circuit_verifier`) est **générique** : il recalcule
  `circuit_hash` depuis l'engagement pré-traité de la preuve et sort `blake2s(circuit_hash ‖ outputs)`.
  Le contrat consommateur doit donc **épingler le hash du circuit multiverifier** de notre registre :
  toute régénération du registre change ce hash.
- modeofO a démontré la route avec des épinglages de juillet 2026 (proving-utils `b6fe5d3b`,
  stwo-circuits `0451681a`) et un wrap « bootloader + multiverifier 2 entrées ». Le monorepo a depuis
  remplacé ce wrap par `leaf_prover` + `recursive_tree` (N feuilles, plus de bootloader dans l'arbre).
  Les scripts modeofO **ne s'appliquent plus tels quels**.
- Le monorepo n'a **aucune release taggée** ; les topologies bougent (`TODO(Gali): Change to MultiVerifier consts`).
- Contraintes on-chain mesurées : plafond invoke **1,21e9 L2 gas**, calldata 5 000 felts, state-diff
  4 000 entrées/bloc ; vérification racine 3,8 M steps mais **1,43e9 gas en production** (snforge
  sous-estime de 1,6×) → découpe en 2 phases obligatoire. **S4 (cd7bc5f) mesure 5,3 M steps et
  93–96 k felts pour la racine** : à ce niveau, il faut prévoir ~3 phases de vérification et ~19 tx de
  staging (7 felts/slot) — à re-chiffrer en S5/P4.1 ; la réduction du nombre de tx (packing, calldata
  au maximum, agrégation multi-parties R7-A3) devient un sujet de Phase 4.
- Recomposition des sorties : pour N feuilles, le fait racine engage un arbre de digests blake2s
  (`packed_output`). `DoomRuns` doit recalculer cet arbre à partir des sorties de chaque segment
  (8 felts × N) : ~N × 2 blake2s + digests internes ≈ **quelques centaines de milliers de gas** pour
  N = 50 (blake2s est un libfunc audité ; `stwo_fact_binding` fait un calcul équivalent à ~0,8 M gas).

### Actions

| Id | Action | Quand | Effort | Critère de sortie |
|----|--------|-------|--------|-------------------|
| R3-A1 | **Épingler le monorepo `proving` à un commit** (`cd7bc5f` au 2026-09-12) via submodule + `Cargo.lock` ; vendoriser `stwo_cairo_verifier` à ce même commit dans `doom_contracts`. Toute montée de version passe par une PR dédiée avec la suite de conformité R3-A5. | S4 | 1 jp | Un seul commit de référence dans `CONTEXT.md` et les manifestes. |
| R3-A2 | Créer `circuit_registry_definitions/doom/definition.json` : `min_trace_log_size = max_trace_log_size = 20`, params `canonical_small` (Blake2sM31, pow 26, blowup 1, 70 requêtes), cibles de padding **minimales** trouvées par `circuit_params` (rapport de tailles) ; générer `registry.json` ; publier le **hash du multiverifier** obtenu. | S4 | 3 jp | Registre reproductible (hash identique sur 2 machines) ; temps/RSS de `leaf_prover` et d'une réduction de paire mesurés. |
| R3-A3 | Pipeline N feuilles bout en bout sur nos segments : `run_segment` × N → `leaf_prover` × N → `recursive_tree` → `stwo_circuit_verifier` (exécuté avec `--print-resource-usage`) pour N ∈ {1, 2, 4, 8, 50}. | S4 | 5 jp | Racine acceptée pour tous les N ; steps de vérification constants (~3,8 M ± 5 %) ; temps wrap(N=50) publié. |
| R3-A4 | Écrire `packed_output_verify.cairo` (crate générique `recursion_outputs`) : reconstruit la racine des digests depuis les sorties des feuilles et l'ordre de repli (arbre équilibré, report de l'entrée impaire), testé contre les fichiers `packed_output` produits par `recursive_tree` (fixtures), y compris N impair et N = 1 (feuille repliée avec elle-même). | S4 | 5 jp | Égalité byte-à-byte sur 10 fixtures ; coût mesuré sur devnet pour N = 50. |
| R3-A5 | **Suite de conformité hebdomadaire** en CI : rejoue R3-A3 contre `proving@main` (en plus du commit épinglé) et compare hash de circuit, format de preuve, steps du vérifieur ; alerte sur toute dérive. | Phase 3 | 2 jp | Job planifié actif ; première dérive détectée = issue ouverte automatiquement. |
| R3-A6 | Contrats : `DoomRuns` stocke une **table de versions** `{program_hash, circuit_hash, registry_addr}` gouvernée puis gelée par saison ; les parties référencent l'entrée utilisée. Le registry Stwo est déployé par nous (classes Phase1/Phase2/Registry), `freeze_routes()` après audit. | Phase 4 | 3 jp | Test snforge : preuve valide avec mauvais `circuit_hash` refusée ; changement de saison sans redéploiement du consommateur. |
| R3-A7 | **Drive devnet** systématique (starknet-devnet 0.9+, reçus réels) pour toutes les tx, avec assertion « ≤ 90 % du plafond invoke » ; re-jouer à chaque bump de version Starknet. | S5/Phase 4 | 2 jp | Script `infra/devnet_drive.py` en CI nocturne. |
| R3-A8 | Plan B documenté et testé une fois : multiverifier 2 entrées + **⌈N/2⌉ faits** par partie (coût ×N/2), ou agrégation côté serveur en passes successives, si `recursive_tree` régresse. | S4 | 2 jp | Procédure écrite ; un run de démonstration archivé. |
| R3-A9 | Veille protocole : `audited.json` (libfuncs qm31), SNIP-36 (ouverture à des programmes tiers), Integrity (support Stwo). Fiche trimestrielle dans `CONTEXT.md`. | Continu | 0,5 jp/trim. | Décision de migration prise sur données. |

Risque résiduel : un changement upstream incompatible juste avant une saison → geler la version
épinglée pendant la saison (les circuits et vérifieurs déployés continuent de fonctionner).

---

## R4 — Exécutions non prouvables

### Constat

- Une exécution Cairo qui **panique n'est pas prouvable** : un `unwrap`, un débordement `u32`, un
  index hors bornes au tic 5 000 rend le segment — donc la partie — improuvable **après coup**.
- Avec le prouveur Scarb 2.16 : panique `Cannot convert F252 to u128` dès qu'un **felt ≥ 2^128** est
  en mémoire (177 steps suffisent) et `index out of bounds` avec le builtin **bitwise**. Comportement
  à confirmer sur le monorepo (S0) mais à traiter comme une contrainte de conception tant que non levé.

### Actions

| Id | Action | Quand | Effort | Critère de sortie |
|----|--------|-------|--------|-------------------|
| R4-A1 | S0 : reproduire les deux paniques avec le prouveur du monorepo. **Fait : aucune ne se reproduit sur le chemin bootloader (felts ≥ 2^128 et bitwise prouvés et vérifiés) ; elles étaient des symptômes du chemin standalone, cassé pour tout exécutable Scarb (`extract_public_segments`). Règle A7 assouplie en règle de coût (< 2^72).** | Fait (S0) | 1 jp | Verdict écrit ; règles A7 confirmées ou assouplies. |
| R4-A2 | **Politique zéro-panique** dans `cairo/doom/*` et `cairo/crates/*` : pas d'`unwrap`/`expect`/indexation non vérifiée hors tests ; arithmétique saturante ou pré-vérifiée ; lint CI (`cairo-lint` + grep interdits) ; `run_segment` renvoie `status = ABORT` avec code d'erreur plutôt que de paniquer. | Phase 1 | 3 jp + continu | Zéro occurrence des motifs interdits ; test d'un état corrompu → `ABORT` prouvable. |
| R4-A3 | **Fuzzing de prouvabilité** : 10 000 tics d'inputs aléatoires (et adverses : coins de murs, portes en mouvement, mort pendant un tir) par nuit ; chaque état sérialisé vérifie `∀ felt < 2^128` ; les ressources (`--print-resource-usage`) vérifient l'absence de builtins interdits. | Phase 1 | 3 jp | 0 panique sur 30 nuits consécutives avant Phase 5. |
| R4-A4 | Preuve « à blanc » périodique côté client : le Worker prover valide (exécution + adaptation, sans FRI) le segment courant dès qu'il est clos ; en cas d'échec, l'utilisateur est averti **pendant** la partie et la partie continue en mode « non prouvable » (aucune perte silencieuse). | Phase 3 | 2 jp | Test : segment invalide injecté → alerte < 5 s. |
| R4-A5 | Encodage des nombres signés sans négatifs : offset fixe (2^40) ou couple (magnitude, signe) selon le domaine, décidé par crate (`fixed`, `bam`) et testé par propriétés. | Phase 1 (crates) | inclus R2-A4 | Sérialisation d'états sans valeur ≥ 2^128 sur tout le corpus. |

---

## R5 — Temps réel : Cairo à 35 Hz dans le navigateur

### Constat

- Décision A1 : la sim temps réel exécute `step_tic` via cairo-vm WASM. Budget par tic : 28,6 ms.
  Inconnues : débit de cairo-vm en WASM (probablement 0,5–2 M steps/s), coût de (dé)sérialisation de
  ~1–2 k felts, coût de création d'un runner par appel (`stwo-cairo-ts` re-parse l'exécutable à chaque
  `execute`, inacceptable à 35 Hz).

### Actions

| Id | Action | Quand | Effort | Critère de sortie |
|----|--------|-------|--------|-------------------|
| R5-A1 | Wrapper wasm dédié (`prover/wasm/sim`) : programme parsé une fois, hints pré-résolus, `step_tic(state_bytes, cmd) -> state_bytes` sans JSON (encodage binaire des felts), pas de génération de trace (mode non-proof). | S3 | 4 jp | ≥ 100 tics/s soutenus sur 4 k steps/tic, mesuré dans un Worker. |
| R5-A2 | État en **mémoire partagée** (`SharedArrayBuffer`) entre Worker sim et thread de rendu ; le renderer lit un snapshot double-buffer, pas de copie par tic. | Phase 2 | 2 jp | Coût de transfert < 1 ms/tic. |
| R5-A3 | Test d'équivalence continu : le même journal rejoué (a) par `step_tic` en boucle, (b) par `run_segment` natif, (c) par le prouveur (exécution) → hashes identiques. | Phase 2 | 1 jp | Test CI sur les 20 replays. |
| R5-A4 | Repli si S3 échoue : miroir TypeScript de la sim généré à partir des mêmes tables/constantes, tests de divergence sur le corpus (tolérance zéro), Cairo réservé à la preuve ; coût estimé +15 jp et risque de divergence permanent → à n'activer qu'après échec documenté. | G0 | 15 jp | — |

---

## R6 — UX de la preuve

### Constat

- Une partie de 3 min ≈ 48 segments ; à 60–120 s par segment en WASM, la preuve prend **48–96 min de
  CPU** si elle n'est pas parallèle à la partie ; pendant la partie, le prouveur (threads) concurrence
  le rendu et la sim.
- Un onglet fermé ou tué par manque de mémoire perd le travail en cours ; l'utilisateur ne veut pas
  attendre devant une barre de progression.

### Actions

| Id | Action | Quand | Effort | Critère de sortie |
|----|--------|-------|--------|-------------------|
| R6-A1 | Preuve **en tâche de fond pendant la partie** : dès que K tics sont clos, le segment part en preuve ; threads du prouveur = `hardwareConcurrency − 2` ; priorité basse ; mesure des frames droppées. | Phase 3 | 3 jp | < 1 % de frames > 33 ms pendant la preuve sur machine 8 cœurs. |
| R6-A2 | Persistance immédiate des preuves de segments et de la file (IndexedDB) ; reprise au rechargement ; export `.doomrun` (journal + preuves) et import. | Phase 2–3 | 3 jp | Scénario Playwright « fermer l'onglet à 50 % → rouvrir → terminer ». |
| R6-A3 | Mode « prouver plus tard » : la partie est jouable sans prouveur ; la preuve se lance ensuite (ou sur une autre machine via export). | Phase 3 | 1 jp | Flux testé. |
| R6-A4 | Prouveur distant (repli R1-A6) avec **file de jobs et estimation de délai** ; l'utilisateur choisit local/distant en connaissance de cause (temps estimé, machine requise). | Phase 3 | 5 jp | Délai annoncé vs réel < 30 % d'écart. |
| R6-A5 | Télémétrie opt-in : temps par segment, mémoire pic, échecs → tableau de bord de compatibilité par (OS, navigateur, RAM). | Phase 5 | 2 jp | Rapport de compatibilité publié. |

---

## R7 — Coûts on-chain et limites protocolaires

### Constat

- Coût par fait ≈ 1,7e9 L2 gas : **~5 STRK** au prix plancher (3 gFri), ~50 STRK observés sur Sepolia
  (prix « spiky »). Depuis v0.14.3, le prix de base L2 est **dynamique et indexé sur le prix du STRK**.
- Plafond invoke empirique 1,21e9 ; phases mesurées à 72 % et 67 % du plafond : marge correcte mais
  sensible à tout changement de tarification (storage 495 k gas/écriture, traitement 120 k gas/slot).
- `snforge` sous-estime de 1,6× ; seul devnet est fiable ; `sncast` sur-provisionne ×1,5 et dépasse
  le plafond → bornes explicites nécessaires ; `l1_data_gas` sous-provisionné **revert** (frais perdus).

### Actions

| Id | Action | Quand | Effort | Critère de sortie |
|----|--------|-------|--------|-------------------|
| R7-A1 | Estimation par `starknet_simulateTransactions` sur la **séquence complète** (stage → phase1 → phase2 → submit) avec `skip_validate` ; bornes = estimation × 1,15 pour L2 gas, ×1,3 pour L1 data gas ; jamais de multiplicateur global ×1,5. **S5 : écart mesuré −0,015 % sur devnet, 0,16 % vs Sepolia (script `spikes/s5/estimate.ts`)** ; à re-valider avec la classe de compte Controller (+19 % observés selon la classe). | Fait (S5) / Phase 4 | 3 jp | Écart estimation/réel < 20 % sur 10 soumissions (**C5**). |
| R7-A2 | Affichage : STRK, équivalent fiat (oracle Pragma ou API de prix, horodaté), détail par transaction, **avertissement si prix L2 > 2× la médiane 24 h** avec option « attendre ». | Phase 4 | 3 jp | Revue UX ; test avec prix simulés. |
| R7-A6 | **Transport calldata plutôt que storage** : S5 chiffre le staging des preuves S4 (94–96 k felts) à ≈ 4,3e9 L2 gas sur 5 tx contre ≈ 6,8e7 gas si les sections sont passées en calldata aux phases de vérification (61×). Concevoir le vérifieur résumable « N phases, sections en calldata liées par digest » (design lane 2 de modeofO, `fri_transport.cairo`) avant la Phase 4 ; objectif ≤ 6 invokes et ≤ 2,5e9 L2 gas par fait. | Phase 4 (avant P4.1) | 10 jp | Drive devnet : total L2 gas par fait publié, chaque tx ≤ 90 % du plafond. |
| R7-A3 | **Agrégation multi-parties par le wrapper** : l'arbre récursif peut replier les segments de plusieurs joueurs → un fait pour M parties, coût on-chain ÷ M (M = 8 → < 1 STRK/partie au plancher). `DoomRuns.submit_run` accepte déjà des sorties par feuille ; ajouter l'indexation joueur → feuilles. Politique : lot fermé toutes les X minutes ou à M parties. | Phase 5 | 8 jp | Démonstration M = 8 sur Sepolia ; coût par partie publié. |
| R7-A4 | Sponsoring : intégration paymaster Cartridge (sessions) en option de saison ; le coût reste affiché même sponsorisé. | Phase 4 | 3 jp | Flux sponsorisé testé. |
| R7-A5 | Marges protocolaires : toutes les tx ≤ 90 % du plafond ; drive devnet à chaque version Starknet annoncée (canal d'alerte sur les releases `starknet-devnet`/`blockifier`). | Continu | 0,5 jp/version | Aucun dépassement en production. |

---

## R8 — Service wrapper

### Constat

- Le wrap n'est pas faisable en WASM (13–22 GB) : dépendance à un service. Il ne peut pas forger,
  mais il peut **refuser, ralentir ou coûter cher**. Charge estimée : N = 48 feuilles × ~15 s +
  47 réductions × ~10 s ≈ **20 min de CPU** et 20+ GB RAM par partie (à re-mesurer avec le registre
  R3-A2 : des cibles de padding plus petites réduisent fortement ces chiffres).

### Actions

| Id | Action | Quand | Effort | Critère de sortie |
|----|--------|-------|--------|-------------------|
| R8-A1 | API « proof-only » : entrée = preuves de segments + sorties publiques ; le serveur vérifie chaque feuille (vérifieur Rust, secondes) **avant** tout travail coûteux ; rejet immédiat sinon. | Phase 3 | 3 jp | Feuille invalide rejetée en < 5 s. |
| R8-A2 | Authentification par signature de session Controller + quotas par compte ; taille max par job ; file persistante (Postgres/SQLite) ; reprise après crash. | Phase 3 | 5 jp | Test de charge 20 jobs concurrents. |
| R8-A3 | Parallélisme par niveau d'arbre (les réductions d'un même niveau sont indépendantes) et cache des feuilles déjà repliées (idempotence par hash). | Phase 3 | 3 jp | Wrap N = 48 < 10 min sur 16 cœurs/64 GB. |
| R8-A4 | Auto-hébergement documenté (`docker compose`) pour que tout joueur/organisateur puisse faire tourner son wrapper ; contrat indifférent à l'origine de la preuve. | Phase 5 | 2 jp | Un tiers reproduit un wrap depuis la doc. |
| R8-A5 | Coût d'exploitation : **S4 mesure 32,5 GB RSS par preuve de circuit** (feuille ou repli) → machine ≥ 64 GB, 2 preuves en parallèle max par 64 GB ; N = 50 ≈ 43 min séquentiel ≈ 0,5–1 $ par partie à 1 $/h ; budgétiser par saison ; métriques Prometheus (durée, RSS, file). | Phase 5 | 1 jp | Tableau de bord. |

---

## R9 — Juridique : licence GPL et marque DOOM

### Constat

- linuxdoom-1.10 et doomgeneric sont sous **GPL-2.0** ; un port ligne à ligne du gameplay est un
  dérivé. Le dépôt est Apache-2.0. Freedoom (assets) est BSD 3 clauses.
- **« DOOM » est une marque déposée** (ZeniMax/Microsoft). Un produit public nommé « Doom » est un
  risque distinct de la licence du code ; Freedoom a choisi son nom pour cette raison.

### Actions

| Id | Action | Quand | Effort | Critère de sortie |
|----|--------|-------|--------|-------------------|
| R9-A1 | Licensing par répertoire : `cairo/doom/*` en **GPL-2.0-only** avec en-têtes ; `cairo/crates/*`, `client/`, `prover/`, contrats en Apache-2.0 ; fichier `LICENSES/` et `REUSE.toml`. Les crates génériques sont écrites **sans copier** de code Doom (algorithmes classiques : BSP, blockmap, point fixe) et le journal de provenance le documente. | Avant Phase 1 | 1 jp | `reuse lint` passe ; revue par le juriste/CTO. |
| R9-A2 | Nom de produit distinct de « Doom » : **Hellproof** (retenu le 2026-09-12 ; aucune collision de jeu/projet trouvée), tagline « Knee-deep in proofs » ; `doom` reste le nom de code du dépôt ; pas de logo/assets id ; mention « compatible Freedoom ». | Fait | 0,5 jp | Nom validé. |
| R9-A3 | Vérifier la licence exacte de la copie de linuxdoom utilisée comme référence et celle de doomgeneric ; documenter dans `NOTICE`. **Fait (P0.1) : linuxdoom-1.10 est GPL-2.0-only (aucune clause « or later » chez id Software), doomgeneric est GPL-2.0-or-later → les crates `cairo/doom/*` sont sous GPL-2.0-only.** | Fait | 0,5 jp | `NOTICE` complet. |
| R9-A4 | Si la GPL est inacceptable pour le cœur : chiffrer la réécriture clean-room (spécifications Doom wiki / Black Book, équipe distincte de celle qui lit les sources) ≈ +30–50 % sur la Phase 1 ; décision à G0. | G0 | — | Décision U7 consignée. |

---

## R10 — Sémantique du fait, triche et intégrité du leaderboard

### Constat

- La preuve garantit « **ces inputs, appliqués aux règles R, donnent ce résultat** » ; elle ne garantit
  pas qu'un humain a joué (TAS/bots), ni l'unicité d'une partie (rejeu de la même preuve), ni que le
  journal n'a pas été optimisé hors ligne (sauvegarde/rechargement d'états pour « ré-essayer » un tic).
- Le fait engage `program_hash` (règles + niveau) et les sorties ; le `seed` de la RNG doit être
  fixé par les règles (table Doom : index de départ 0) ou engagé publiquement.

### Actions

| Id | Action | Quand | Effort | Critère de sortie |
|----|--------|-------|--------|-------------------|
| R10-A1 | Unicité : `DoomRuns` indexe par hash du journal d'inputs (sortie publique du premier segment = `poseidon(genesis)`, du dernier = `h_out`, plus `inputs_commitment` accumulé segment par segment) ; un même `inputs_commitment` ne peut être soumis deux fois ; le joueur soumetteur est le signataire. | Phase 4 | 2 jp | Test snforge de rejeu refusé. |
| R10-A2 | Catégories de leaderboard explicites : « vérifié on-chain » (toutes les parties prouvées, TAS possible) ; option **« session en direct »** ultérieure où le client s'engage périodiquement (hash de segment horodaté on-chain ou via serveur signataire) pour borner le temps réel écoulé. | Phase 4 / v2 | 1 jp (doc) | Règles publiées dans l'UI. |
| R10-A3 | Publication du replay (événement `Replay`, inputs packés 7 tics/felt) pour permettre la réexécution publique et le contrôle communautaire. | Phase 4 | 1 jp | Replay téléchargeable depuis le leaderboard. |
| R10-A4 | Le `seed`/table RNG, le skill et le niveau sont des constantes du programme (pas des inputs) pour cette saison ; documenté dans le fait via `program_hash`. | Phase 1 | 0 | Revue de conception. |

---

## R11 — Toolchain WASM64 et forks

### Constat

- Le seul prouveur navigateur existant a nécessité des **forks** (`fix-wasm64` de stwo-cairo et du
  compilateur Cairo) et est resté à un commit de 2025 ; le build exige `nightly` + `-Z build-std` +
  `wasm64-unknown-unknown` + threads (`SharedArrayBuffer`) ; le CI upstream ne vérifie que la
  **compilation** wasm64, pas l'exécution.

### Actions

| Id | Action | Quand | Effort | Critère de sortie |
|----|--------|-------|--------|-------------------|
| R11-A1 | Build reproductible en conteneur (`Dockerfile` avec nightly épinglé, `build-std`, `wasm-bindgen`/`wasm-opt` versions fixes) ; artefact `.wasm` hashé et publié par la CI. | S2 | 3 jp | Deux builds indépendants → même hash. |
| R11-A2 | Différences avec upstream maintenues comme **patches** (`prover/wasm/patches/*.patch`, `git apply` en CI) plutôt que fork long ; PR upstream pour chaque patch (getrandom, allocateur, threads). | S2/Phase 3 | 2 jp + suivi | Liste de patches ≤ 5, chacun avec une issue upstream. |
| R11-A3 | Test d'exécution wasm64 en CI (Playwright headless Chrome, `--enable-features=WebAssemblyMemory64` si nécessaire) sur une trace 2^16 : preuve + vérification. | S2 | 2 jp | Job CI vert. |
| R11-A4 | Matrice navigateurs documentée (Chrome/Edge OK, Firefox à valider, Safari non supporté) ; détection de fonctionnalités et message clair. | Phase 2 | 1 jp | Page de compatibilité. |

---

## R12 — Soundness du prouveur

La documentation Scarb avertit que « la soundness de la preuve n'est pas encore garantie par Stwo » ;
le prouveur est pourtant en production dans SHARP et le vérifieur Cairo est en cours de vérification
formelle (arXiv 2606.04311). Pour un jeu, un défaut de soundness permettrait au mieux de frauder un
leaderboard. Actions : suivre les avis de sécurité du monorepo (R3-A9), ne pas réduire les paramètres
de sécurité (pow 26, 70 requêtes), garder le replay public (R10-A3) pour permettre une réexécution
en cas de doute. Aucune action de développement dédiée.

---

## R13 — Charge et séquencement

Les phases 1–3 dépendent des verdicts de G0 ; le chemin critique passe par **S0 → S2 → Phase 3**
(prouveur) et **S1 → Phase 1** (cœur). Actions : démarrer S0/S1/S2/S4 dès la semaine 1 en parallèle ;
un responsable par spike ; revue de mi-spike à J+7 ; pas de développement de gameplay avant que S1
ait fixé le budget ; conserver 20 % de marge dans le planning du PLAN §5 ; réévaluer le périmètre
(niveau plus petit, skill 1) plutôt que la qualité des crates (A10) en cas de retard.

---

## Synthèse des actions à lancer immédiatement (semaine 1)

1. **R1-A1 / R1-A2 / R4-A1** — Prouveur de référence sur le monorepo épinglé, `canonical_small`,
   profil mémoire, reproduction des paniques.
2. **R3-A1 / R3-A2** — Épinglage et registre de circuits `doom` (log 20), hash du multiverifier.
3. **R2-A1 / R2-A2 / R2-A4** — Prototype S1 instrumenté avec REJECT et représentations felt-first.
4. **R11-A1 / R1-A3** — Conteneur de build WASM64 et première mesure dans Chrome.
5. **R9-A1 / R9-A2 / R9-A3** — Cadre de licences et nom du produit.
6. **R5-A1** — Wrapper wasm de simulation avec programme en cache.

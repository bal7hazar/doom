# STATUS — point d'avancement

> Mis à jour le 2026-09-12 (fin de journée 1). `main` est poussé sur `origin`, CI verte.

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

## En cours au moment de la pause (branches de worktree, non mergées)

| Ligne | Agent/branche | À faire à la reprise |
|---|---|---|
| P1.6 `doom_physics` (chemin critique) | `worktree-agent-aeda66fda72ab03ed` | relire le rapport, `scarb test`, merger, consigner les coûts |
| P1.7 `doom_specials` | `worktree-agent-a9dc6b8d1a91c7c14` | idem |
| P3.2/P2.5 pipeline de preuve + persistance client | `worktree-agent-a66ef38ca293daffd` | idem ; vérifier la dépendance workspace sur `prover/wasm` |
| P4.3 orchestration on-chain + écran de coût | `worktree-agent-aa1c0289ae5f550d2` | idem ; devnet uniquement |

Mise à jour après la pause : **les quatre lignes ont terminé** (branches ci-dessus, plus
`p4.3-submission-orchestrator` pour P4.3). Points saillants à traiter à la reprise :

- `doom_physics` : 30 tests, 94,5 % de couverture, `try_move` 964 steps ✓, mais **56 961 mots de
  bytecode** (cible D23 : 5 000) — ~20 k statements Sierra viennent de helpers core expansés à chaque usage
  (`felt_ge` → `u128_try_from_felt252`, `array_at`, `u32 ==`) ; `check_sight` en traversée 7,7–9,7 k steps
  (budget 2 500) ; `set_thing_position` 1 158. **Décision à prendre** : stratégie de réduction du bytecode
  (helpers non inlinés, plomberie d'arguments, `slide_move_lite`) avant `doom_player`/`doom_monsters`.
- `doom_specials` : 30 tests, 99,8 %, budgets tenus ; note : linedef 23 est S1 (switch) et `VDOORWAIT` = 150 tics.
- P3.2/P2.5 : 138 tests + Playwright ; le wrapper doit ajouter l'upload par segment
  (`PUT /v1/runs/{id}/segments/{i}`, `POST /v1/runs/{id}/complete`).
- P4.3 : 73 tests ; estimation à −0,012 % des reçus ; plan 6 tx par défaut (le plan 5 tx ne supporte pas
  la borne ×1,15) ; l'effet de classe de compte est par écriture storage, pas par calldata.

Les agents terminent seuls et commitent sur leur branche ; rien n'est poussé tant que l'orchestrateur n'a
pas relu et mergé.

## Prochaines étapes (ordre du chemin critique)

1. Merger les quatre lignes ci-dessus ; nettoyer les couches `compat` (D17).
2. `doom_player` + `doom_monsters` (parallèles, après `doom_physics`), puis `doom_game` + `doom_run`
   (`genesis`, `step_tic`, `run_segment`, test CI de taille de bytecode ≤ 32 k mots, hachage poseidon).
3. Replays dorés + fuzz de prouvabilité (P1.10) ; Worker sim du client (P2.3) + contrôles (P2.4).
4. E2E « partie complète prouvée » (P3.7, C3) ; Sepolia (P4.5) ; optimisation FRI on-chain (P4.1).

## Points d'attention

- Docker Desktop a été démarré par un agent (conteneurs d'un autre projet relancés).
- Threads wasm : blocages intermittents sur segments ≥ 2 M steps (R1-A8) — segments ≤ 1,5 M par défaut.
- Budget bytecode : données 21,7 k → 20,1 k après retrait des listes de candidats (à faire dans `doom_physics`).

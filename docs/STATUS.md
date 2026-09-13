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

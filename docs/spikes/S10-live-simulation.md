# S10 — simulation du jeu réel dans Chromium

Audit du 13 septembre 2026, après les mesures de preuve S9. Le petit programme
de référence S3 ne représentait pas le coût de passage du vrai état du jeu.
La simulation actuelle reste sous la cible de 35 tics/s, même sans preuve ni rendu.

## Méthode

`prover/sim` de `main` est compilé en WASM32 release avec Rust stable, deux jobs
Cargo et `wasm-pack --target web` (4 min). Aucun changement de source du moteur.
Le programme `step_tic` est compilé sous Scarb 2.16/proving ; SimProgram utilise
cairo-lang 2.19.4 et cairo-vm 3.2.0. Chargement du JSON une seule fois, exécution
dans un Worker Chromium 153.0.8010.12 isolé COOP/COEP, entrée/sortie binaire via
`reserve_input`/`run_buffered`. Les vues sont recréées après les appels susceptibles
de faire croître la mémoire.

Cinq scènes sont préparées par Scarb depuis les replays existants. Chaque commande
est exécutée individuellement, puis son état alimente le tic suivant. Cinq appels
de chauffe par scène sont exclus des mesures. À la fin de chaque scène, le SHA-256
de **toute** la sortie (état, snapshot, statut) égale la référence Scarb exécutée
en un seul segment. Il s’agit d’une comparaison des cinq sorties finales, pas
d’un oracle indépendant pour chacun des snapshots intermédiaires.

Le temps total comprend préparation des arguments, VM, décodage des longueurs et
copie de l’état pour le tic suivant ; il exclut rendu graphique, contrôles et preuve.
Machine M2 Max 64 GiB, douze cœurs annoncés par Chromium. Ce test local court ne
constitue ni une campagne matériel 16 GiB ni une validation de contention jeu/preuve.

## Référence après optimisation des monstres

Commit `883efbb`, `step_tic` **117 366 mots**, programme SHA-256
`c8e97df6994beeccf8120142c813616ac3b5a7a9d4b35cba0dbf71e36773a728`.
WASM sim SHA-256 `52721b82d3216e89929f876fc2a5ed74af74060e5e45ad29039af65ed10ab29a`.

| Scène, tics | Appels | Moyenne ms/tic | p99 ms | Tics/s moyens |
|---|---:|---:|---:|---:|
| idle, 300–380 | 80 | 47,182 | 48,680 | 21,19 |
| marche, 80–160 | 80 | 55,176 | 63,350 | 18,12 |
| porte, 230–310 | 80 | 58,510 | 73,545 | 17,09 |
| combat, 450–530 | 80 | 53,391 | 70,105 | 18,73 |
| mort, 780–846 | 66 | 50,221 | 59,315 | 19,91 |

**386/386 appels dépassent 28,57 ms**, le budget de 35 Hz. Les cinq sorties finales
sont exactes, y compris DEAD au tic 846. Le code JS autour de la VM prend en moyenne
moins de 0,1 ms par tic ; le coût dominant est dans la VM. Les appels exécutent en
moyenne 329 k à 415 k steps, frontière comprise. Mémoire linéaire maximale observée
**70 975 488 octets (67,69 MiB)** ; ce n’est pas la RSS totale du navigateur.

## Conséquence

La seconde passe frontière est ensuite combinée aux monstres dans `91719f8` :
`step_tic` **112 334 mots**, SHA-256
`f9a36d53aaa121aa569b8c40aa0382751963e877e71c077a9a5c01694d761a55`.
La même campagne, avec les mêmes cinq références de sortie Scarb, passe de nouveau :

| Scène | Moyenne ms/tic | p99 ms | Tics/s moyens |
|---|---:|---:|---:|
| idle | 46,645 | 59,470 | 21,44 |
| marche | 54,104 | 61,945 | 18,48 |
| porte | 57,811 | 74,330 | 17,30 |
| combat | 52,537 | 69,030 | 19,03 |
| mort | 49,516 | 59,095 | 20,20 |

Les steps moyens par appel tombent à 315 k–401 k, mais **386/386 appels restent
au-dessus de 28,57 ms**. La mémoire linéaire culmine à 70 254 592 octets.
Ces deux campagnes courtes ne sont pas une étude statistique du gain temporel ;
elles confirment toutes deux le défaut de capacité à 35 Hz.

R5 reste bloquant. La réduction des copies Mobj (D33) est utile au tic et au bytecode,
mais ne supprime pas la lecture/réémission complète du `GameState` à chaque appel.
Une expérience distincte sous `prover/sim` étudie la conservation de l’exécution
Cairo entre tics ou un autre passage d’état qui évite cette taxe, en réutilisant le
même `doom_game::step_tic`. Elle doit conserver les sorties exactes et l’interactivité,
sans batch d’inputs ajoutant de la latence, prédiction ou cadence abaissée. Les
entrypoints prouvés et leurs validations restent inchangés.

## Traces et reproduction

`/tmp/hellproof-audit-20260913/sim-real/` contient les fixtures, programmes immuables,
scripts `prepare.py`, `worker.mjs`, `browser.mjs` et résultats. La première campagne
est conservée dans `before-chromium.json` et `before-provenance.json`. Les scripts
servent uniquement une liste explicite de fichiers locaux et ferment navigateur,
Worker et serveur ; échéance de 180 s. Build : `sim-wasm-build.log` dans le répertoire
d’audit parent. La préparation Scarb utilise le programme complet de la branche
d’intégration, pas les squelettes encore présents sur `main`.

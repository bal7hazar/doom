# S10 — simulation du jeu réel dans Chromium

Audit du 13 septembre 2026, après les mesures de preuve S9. Le petit programme
de référence S3 ne représentait pas le coût de passage du vrai état du jeu.
La VM recréée à chaque tic reste sous la cible de 35 tics/s, même sans preuve ni rendu.
Le prototype de continuation assemblé avec D33 atteint depuis **8,8–16,6 ms moyens/tic**,
maintenance comprise, avec **512 MiB** linéaires ; les pointes de latence restent à traiter.

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

## Continuation conservée, puis combinaison avec D33

Les commits `b51cefe` et `350d6db` conservent une exécution Cairo non terminée entre les
commandes. Le harnais appelle le vrai `doom_game::step_tic` et émet son snapshot ; Rust
transporte les entrées et sorties. Les hints, scopes, builtins et caches de la VM persistent.
Un poll attend exactement un mot, les quantums reprennent une instruction sans rejouer ses
hints. Une exportation de checkpoint n’avance pas le tic ; son rechargement réexécute la
validation complète `from_felts`. Les entrypoints prouvés restent inchangés.

L’orchestrateur a reproduit la campagne de référence : **386 états/snapshots/statuts natifs
exacts**, puis 386 snapshots navigateur, checkpoints périodiques et cinq sorties ABI finales
identiques aux fixtures immuables. Interruption après 101 steps, reprise par 4 096 steps,
refus d’un second input en vol et attente sans exécution passent. **11 tests Rust**, format
et Clippy strict passent, dont limites, état empoisonné après erreur et récupération.
La référence `91719f8` mesure **9,55–18,73 ms/tic** maintenance comprise dans cette reproduction,
contre 9,73–18,64 dans la dernière campagne agent ; capacité WASM maximale 906,1 MiB.

L’intégration **`f306c6a`** ajoute le roster boxé D33 à ce même runtime. Seul le harnais Cairo
est reconstruit ; les empreintes du WASM et du runner natif sont vérifiées avant copie.
Les mêmes contrôles complets passent sur les mêmes 386 tics :

| Scène | Tic seul, ms moyens | Avec maintenance, ms moyens | p99 avec maintenance, ms | Appels >28,57 ms |
|---|---:|---:|---:|---:|
| idle | 8,102 | 8,845 | 38,235 | 2/80 |
| marche | 13,417 | 14,200 | 45,320 | 2/80 |
| porte | 15,848 | 16,620 | 45,355 | 2/80 |
| combat | 12,548 | 13,282 | 42,260 | 2/80 |
| mort | 10,639 | 11,983 | 45,050 | 3/66 |

Le Worker exporte puis recrée sa VM tous les 32 tics ; cette pause est comptée dans l’appel
qui la déclenche. Le setup initial et l’export final réservé à l’audit sont hors chronométrage.
La capacité linéaire atteint **536 870 912 octets (512 MiB)**, puis reste stable sur la fin de
cette courte campagne. Ce n’est ni une mesure de heap/RSS ni un test de fuite longue durée.
Les onze dépassements, les contrôles/rendu/preuve concurrents et le matériel 16 GiB restent
à évaluer. La limite locale de 256 commandes/32 M steps par session impose de reprendre un
checkpoint avant saturation ; elle ne modifie aucun budget de jeu ou de preuve.

Ce prototype est assemblé sur la branche d’intégration, sans branchement au client. Son
transport de simulation est de confiance ; il ne certifie pas ses checkpoints. Seuls le
journal rejoué et la chaîne de preuve existante peuvent les engager. Le client doit journaliser
dès le premier tic, conserver exactement les mots acceptés et fournir l’état sérialisé aux
segments, en plus de leur `h_in`. L’ouverture tardive de la file F4 et l’actuel `SegmentRequest`
limité au hash ne satisfont pas ces conditions.

Traces root : `/tmp/hellproof-audit-20260913/continuation-{reference,boxed}/`.
WASM SHA-256 `dd73ce152f44a9e00368e195c6de36d40b2948b0740794f056b2e557c94b67c5` ;
harnais avec D33 `6ae3f3820f9b075713e2edceec8d7cfe56ec5d4bdb6e214b8f8ceba115f9bd22`.
Le harnais suivi est `prover/sim/bench/continuation/run.py` sur la branche d’intégration.

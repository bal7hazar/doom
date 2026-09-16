# Calibration native Linux x86_64 — premiers points réels (D35)

> Mesures du **2026-09-16** sur la machine de session (4 cœurs, 15 Go), avec le prouveur du
> monorepo `starkware-libs/proving` épinglé à `cd7bc5f4697fb188a27e09f9242f1dd76df8afdc`, le
> **format feuille** (`leaf_simple_bootloader`, `program_hash_function: blake`,
> `prover/wasm/harness/params/leaf.json`) et le vrai `run_segment` du profil `proving`.
> Objectif : les premiers points **réels sur Linux** de la calibration que D35 demande
> (8–13 M steps sur 64 Go), faire prouver un vrai segment par le nœud (`infra/prover-node`) et
> mesurer le hash de tâche du programme courant. Tout ce qui est chiffré ici est mesuré ; ce qui
> ne l'est pas est dit tel quel (§6).

---

## 1. Machine et outils

| Composant | Valeur |
|---|---|
| CPU | Intel Xeon @ 2,10 GHz, **4 cœurs** (AVX-512 F/BW/CD/DQ/VL/IFMA/VBMI) |
| RAM | 15,7 Go (`MemTotal` 16 482 220 kB), **pas de swap** |
| Cgroup mémoire du bac à sable | **13,36 Go** (`memory.limit_in_bytes = 14 346 121 216`), **partagé avec un second agent** qui compilait le prouveur WASM (rustc 2–3 Go, Playwright) pendant toute la session |
| Disque libre | 25 Go au départ, 18 Go après les builds (le second agent construit aussi) |
| OS / noyau | Ubuntu 24.04.4, Linux 6.18.44 |
| Rust | `nightly-2026-01-15` (rustc 1.94.0-nightly `86a49fd71`), celui du `rust-toolchain.toml` du monorepo |
| Scarb | **2.16.0** (`231227f3f`, cairo 2.16.0), `--profile proving` |
| Monorepo | `cd7bc5f`, cloné depuis le cache git de cargo (`~/.cargo/git/db/proving-*`, déjà présent pour `leaf-verify`) |
| Bootloader | `crates/stwo_run_and_prove_recursive_tree/test_data/leaf_simple_bootloader_compiled.json` |
| Paramètres | `prover/wasm/harness/params/leaf.json` (`blake2s_m31`, `canonical_small`, `pow_bits` 26, `include_all_preprocessed_columns` true, `at_least_preprocessed`, `opt_n_id_to_big_components` 16) |
| Exécutable | `cairo/target/proving/run_segment.executable.json`, **SHA-256 `84c9bae19f94c17d8889f48104830ba178b4e98593885c2b03f25d4a435d74f0`**, 117 531 mots de bytecode |

### 1.1 Builds (release, uniquement les binaires nécessaires)

```bash
S=<scratchpad>
git clone ~/.cargo/git/db/proving-bb6dcab6002f80e5 $S/proving && git -C $S/proving checkout cd7bc5f4697fb188a27e09f9242f1dd76df8afdc
cd $S/proving && CARGO_TARGET_DIR=$S/proving-target RUSTFLAGS="-C target-cpu=native" \
  cargo +nightly-2026-01-15 build --release --locked -p stwo-run-and-prove -p stwo-vm-runner -j 3
ln -s $S/proving-target $S/proving/target      # prove_segment.sh attend $PROVING/target/release

cd prover/wrapper/leaf-verify && CARGO_TARGET_DIR=$S/target-leaf-verify \
  cargo +nightly-2026-01-15 build --release --locked -j 1
```

| Build | Durée mur | Cibles | Remarques |
|---|---:|---:|---|
| `stwo-run-and-prove` + `stwo-vm-runner` (289 crates) | **16 min 40 s** | 1,6 Go (release seul, aucun artefact debug) | `-j 3`, `nice 5`, machine partagée (load 5–12) ; S0 avait mesuré 6 min 06 s sur M2 Max 12 cœurs |
| `hellproof-leaf-verify` | **4 min 35 s** | 1,3 Go | `-j 1`, `nice 10`, en parallèle du build précédent |
| `doom_run` profil `proving` (scarb) | quelques secondes (déjà construit, `--no-build` ensuite) | 2,2 Mo | — |

SHA-256 des binaires utilisés (`artifact_hashes.json` du script) :
`stwo-run-and-prove` `6e39482832bfdefd6cdfc311baed7dafec84f7932dab2b84138288bb6ea6d588`,
`stwo-vm-runner` `4825ada10f2279ecb4937d2d7a7bdb33d5bfbd1c612a64cd169ef89330a23088`.

### 1.2 Le script, adapté à Linux sans toucher à `cairo/`

`cairo/doom/doom_run/bench/prove_segment.sh` est écrit pour macOS : il préfixe le prouveur de
`/usr/bin/time -l` (absent ici) et `grep`e ensuite `real|maximum resident` dans le log, ce qui,
sous `set -o pipefail`, fait échouer le script quand ces lignes manquent. Une copie dans le
scratchpad (`prove_segment_linux.sh`) diffère du script du dépôt sur exactement ces points :

1. plus de `/usr/bin/time -l` ; le superviseur Python mesure lui-même le mur et, à chaque
   échantillon (0,5 s), lit **`VmHWM`** dans `/proc/<pid>/status` de chaque processus du groupe
   (`vm_hwm_peak_bytes` dans `proof_metrics.json`, en plus de la somme RSS `ps` déjà là) ;
2. `grep … | tee` remplacé par `cat proof_metrics.json | tee` ;
3. `REPO` surchargeable par `HELLPROOF_REPO` (la copie n'est pas à quatre niveaux sous le dépôt) ;
4. un garde-fou `PROOF_RSS_LIMIT_BYTES` : le superviseur tue le groupe de processus lui-même
   au-delà de cette RSS (exit 125), avant que l'OOM-killer du cgroup partagé ne choisisse une
   victime — nécessaire ici, pas sur une machine dédiée.

Le verrou `mkdir $SCRATCH/.proof-lock` (+ `owner.pid`, `trap` de libération) et le timeout de
groupe de processus sont ceux du script ; `PROOF_TIMEOUT=900`. Avant chaque preuve, un pilote
(`run_calib.sh <out> <tics> <threads>`) attend jusqu'à 20 min (boucle de 30 s) que `free -g`
annonce ≥ 12 Go disponibles **et** que le cgroup ait ≥ 12 Go de marge (`limit − usage`).

```bash
export SCRATCH=$S PROVING=$S/proving VM_RUNNER=$S/proving/target/release/stwo-vm-runner
export HELLPROOF_REPO=/home/user/doom PROOF_TIMEOUT=900 RAYON_NUM_THREADS=1   # puis 4
bash $S/prove_segment_linux.sh $S/calib/fight35-t1 fight 35
```

Étapes 1–5 du script (build, genèse, arguments `[len, state…, len, words…, 0, n]` depuis
`bench/profile.py` `LOGS["fight"]`, `scarb execute`, `stwo-vm-runner`) : identiques au dépôt.

---

## 2. Les segments mesurés

Scénario `fight` de `bench/profile.py`, depuis la genèse d'E1M1 (état schéma 2, 6 362 felts),
`tic_start = 0`. Étapes 1–5 du script (exécution, dix felts publics, trace du bootloader) :

| tics | steps `run_segment` (scarb) | steps bootloader compris (`stwo-vm-runner`) | surcoût bootloader | `range_check` | `bitwise` | `poseidon` | `blake_compress` (opcodes) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 7 | 591 173 | **2 293 560** | 1 702 387 | 134 802 | 2 576 | 6 368 | — |
| 35 | 1 338 951 | **3 041 338** | 1 702 387 | 155 637 | 6 178 | 6 371 | 15 187 |

Le surcoût du bootloader est **constant à 1 702 387 steps** pour les deux segments : c'est le
hachage Blake des 117 531 mots du programme (modèle S0 : 2 340 + 14,74 × mots = 1 734 700, à
2 % près), plus le chargement de la tâche. Il fixe le plancher d'un segment à **≈ 2,0 M steps**
quelle que soit sa longueur (D35). `scarb execute` seul : ≈ 1,0 s (7 tics) et 1,3 s (35 tics) ;
`stwo-vm-runner` (exécution + `all_cairo_stwo` + ressources) : 3–4 s.

Dans les deux cas, la préimage dumpée par le bootloader est vérifiée égale à
`[task_hash, les dix felts exacts du segment]` avant toute preuve (étape 5).


### 2.1 Les preuves (étape 6, format feuille)

| tics | steps (bootloader compris) | threads | résultat | mur | RSS max (`VmHWM`) | preuve | vérif. |
|---:|---:|---:|---|---:|---:|---|---|
| 35 | 3 041 338 | 1 | **tuée par l'OOM-killer du cgroup** (`anon-rss` 12,34 Go + 1,5–3 Go de rustc du second agent > 13,36 Go), pendant `Constraint point-wise eval` de la composition, 527 s après la fin des commitments | > 589 s | **12,84 Go**, encore croissante | — | — |
| 35 | 3 041 338 | 1 | **tuée par l'OOM-killer du cgroup, seconde tentative, machine quasi seule** (`anon-rss` 12,48 Go + ≈ 0,8 Go du second agent = la limite), 72,7 s après le départ, dans le commitment Merkle de la composition — sans thrashing cette fois | > 72,7 s | **12,84 Go** (même valeur que la première tentative : le pic mono-thread est déterministe), encore croissante | — | — |
| 7 | 2 293 560 | 1 | **tuée par nous à 807 s** : cgroup saturé par les deux agents (PSI mémoire `full` 98 %, 163 k fautes majeures, prouveur à 45 % CPU), aucun progrès depuis 13 min | — | **10,91 Go**, encore croissante | — | — |
| 7 | 2 293 560 | 4 | **tuée par le garde-fou RSS à 12,9 Go** (§1.2), 11,7 s après le départ, dès l'entrée de `Write interaction trace` ; le cgroup (13,36 Go) l'aurait tuée dans la seconde | > 11,7 s | **13,21 Go**, encore croissante | — | — |
| 7 | 2 293 560 | 1 | **verte via `prove_segment.sh`** (`cairo-serde`, `--verify`), machine pour elle seule | **75,95 s** | **13,68 Go** | **767 478 felts** (10,97 Mo en JSON hex) | `verify_cairo` interne 24,1 ms, ok |
| 7 | 2 293 560 | 4 | **verte via `prove_segment.sh`**, seconde tentative, machine pour elle seule | **37,31 s** | **12,79 Go** | 767 478 felts, **identiques felt à felt** à la preuve mono-thread | `verify_cairo` 24,7 ms, ok |
| 7 | 2 293 560 | 1 | **verte via le nœud** (§4.3 ; même binaire, même ligne de commande, format `extended-binary`) | **74,5 s** | **13,70 Go** | 3 185 814 o (bzip2 bincode) | `--verify` interne 26,9 ms + `leaf-verify` 25,2 ms, ok |

Phases mesurées avant les arrêts (`tracing` du prouveur, `time.busy`) :

| phase | 35 tics, 1 thread | 7 tics, 1 thread | 7 tics, 4 threads |
|---|---:|---:|---:|
| `cairo run` (VM, trace + mémoire) | 1,39 s | 1,13–1,28 s | 1,10 s |
| `adapt` (relocation, `MemoryBuilder`, `StateTransitions`) | 0,82 s | 0,59 s | 0,52–0,56 s |
| `Write Base trace` | 18,2 s | 17,1–17,9 s | 6,06–9,67 s |
| `Compute base trace commitment` | 9,62 s | 8,40 s | 2,40–3,80 s |
| `Write interaction trace` | 3,51 s | 3,95 s | 1,82 s |
| `Compute interaction trace commitment` | 8,06 s | 7,23 s | 3,14 s |
| composition (`Constraint point-wise eval`) | **> 527 s** (tuée ; le cgroup était déjà saturé par le second agent, ce temps est du *thrashing*, pas du calcul) | **20,0–20,1 s** | 9,03 s |
| `Prove STARKs` complet (composition + FRI + PoW 26 bits) | — | 33,6–36,1 s | 15,9 s |
| total `stwo-run-and-prove` (`--verify` compris) | — | **74–76 s** | **37,3 s** |

Lecture :

* **La mémoire, pas le temps, est la borne sur cette machine.** Le plus petit segment Doom en
  format feuille (7 tics, 2,29 M steps dont 1,70 M de bootloader) a besoin de **13,7 Go
  mono-thread et 12,8–13,2 Go à 4 threads** (`VmHWM`) ; le cgroup du bac à sable fait 13,36 Go
  (14,35 × 10^9 octets) **partagés** avec le second agent. Les trois preuves vertes ont toutes été
  obtenues pendant ses pauses (`total_rss` du cgroup < 0,3 Go) ; les quatre échecs sont des
  échecs de mémoire, jamais du prouveur. D31 avait mesuré 11,73 Go pour 2,68 M steps sur macOS :
  la RSS Linux est plus haute (allocateur, pas de compression mémoire), ce qui compte pour
  dimensionner un nœud.
* **Le pic 4 threads n'est pas déterministe** : 12,79 Go pour la preuve verte, 13,21 Go
  observés 11,7 s après le départ (`Write interaction trace`) dans la tentative tuée par le
  garde-fou — les témoins parallèles font varier le pic de ± 0,5 Go d'une exécution à l'autre.
  La preuve, elle, est **strictement déterministe** : 767 478 felts identiques mono et 4 threads.
* **Temps** : 75,95 s mono → 37,31 s à 4 threads (× 2,04 ; la machine n'était pas totalement
  libre, load 2–4) pour 2,29 M steps, soit ≈ 33 s puis ≈ 16 s par million de steps *sur ce
  Xeon 2,1 GHz*. Les commitments et la composition se parallélisent bien (× 2,2–2,5), `Write
  Base trace` moins (× 1,8–2,9), l'exécution VM et l'adaptateur pas du tout (≈ 1,7 s fixes).
* Le point 70 tics (2 383 556 steps programme, ≈ 4,09 M avec le bootloader) **n'a pas été
  tenté** : 35 tics ne tenait déjà pas avec le second agent actif ; voir la ligne 35 tics
  « seconde tentative » pour le résultat machine seule.

---

## 3. Hash de tâche du programme courant (mesuré)

`output_preimage[0]` dumpé par le `leaf_simple_bootloader` lors de l'exécution native
(`stwo-vm-runner`, étape 5, puis identiquement par `stwo-run-and-prove`), avec
`program_hash_function: blake`, pour l'exécutable `run_segment.executable.json` du profil
`proving`, **SHA-256 `84c9bae19f94c17d8889f48104830ba178b4e98593885c2b03f25d4a435d74f0`** :

```
task_hash (Blake) = 0x5c3f9de0cfb3b334a49070f4a47b4f875d7ef511959cf0efc9bd67ea879bf93
```

Préimage complète du segment `fight` 35 tics (onze felts, D14) :

```
["0x5c3f9de0cfb3b334a49070f4a47b4f875d7ef511959cf0efc9bd67ea879bf93",   task hash
 "0x1",                                                                  version
 "0x2d1374414503eb8db44adb1498990546a9b5e20a8e62f3c70b29fb07d78c55a",    h_in (genèse E1M1)
 "0x7cb0be7eba55c422932456d436a5dad65eafa2dfd2eda6eee257fb4dd0d6a6",     h_out
 "0x0", "0x23", "0x0",                                                   tic_start, tic_end = 35, status
 "0x176938c7052a86eae928235cfa29cce479e2fcb6a6b4deabbe3dd00957d9868",    inputs_commitment
 "0x0", "0x0", "0x0"]                                                    kills, items, secrets
```

C'est le hash à épingler côté wrapper (`programs[].task_hash`) et nœud (`--program-hash`) pour
**cet** exécutable ; tout rebuild qui change son SHA-256 impose une nouvelle mesure
(`prover/wrapper/scripts/measure_task_hash.mjs` fait la même chose via le cœur WASM).
Le hash est indépendant de la longueur du segment (7 et 35 tics donnent le même `preimage[0]`).

---

## 4. Le nœud (`infra/prover-node`) sur le vrai binaire

### 4.1 L'écart corrigé dans `prover.ts`

`SubprocessProver` passait `--proof-format bincode` à `stwo-run-and-prove`. Ce n'est **pas une
valeur** de son `ProofFormat` (`cairo_air::utils::ProofFormat` à `cd7bc5f` : `json`,
`cairo-serde`, `binary`, `extended-binary`) : clap refuse la ligne de commande et le nœud
n'aurait jamais produit une preuve. Le `bincode_b64` que le wrapper replie est le `CairoProof`
**étendu**, que seul `extended-binary` écrit (bzip2 autour du bincode, magie `BZh` que le
wrapper et `leaf-verify` reconnaissent) ; `binary` écrit `CairoProofForRustVerifier`, sans le
`aux` dont le circuit feuille a besoin. Correction (commit `526a312` sur `wave/calib`) :

* l'option publique garde son orthographe (`proofFormat: "bincode"`, CLI `--proof-format
  bincode`) et `proofFormatFlag()` la traduit en `extended-binary` sur la ligne de commande ;
* le binaire de substitution des tests (`test/fixtures/fake-stwo.mjs`) refuse désormais toute
  autre valeur, comme le vrai, et journalise ses `argv` ; `test/prover.test.ts` épingle
  `--proof-format extended-binary … --verify` sur la ligne enregistrée
  (9 tests verts, `npx vitest run test/prover.test.ts`).

### 4.2 `scripts/prove-one.mjs` : les étapes du nœud, un vrai segment

`npx tsx scripts/prove-one.mjs --words <args.json de prove_segment.sh | words.json> --tics 7
--out <dir> [--threads n] [--timeout s] [--leaf-verify <bin>] [--expect-task-hash <felt>]` :

1. `ScarbExecutor.genesis(0)` (E1M1) puis `ScarbExecutor.segment(state, words, 0, tics)` —
   exactement ce qu'un poll fait — donnent les 6 373 felts d'arguments et les dix felts publics ;
   quand `--words` est l'`args.json` du script shell, les arguments reconstruits sont comparés
   felt à felt (**identiques** ici : `arguments identical to prove_segment.sh's args.json`) ;
2. `SubprocessProver.prove()` sur le vrai `stwo-run-and-prove` : tâche `Cairo1Executable`
   + `blake`, `leaf.json`, verrou `$SCRATCH/.proof-lock`, timeout de groupe de processus ;
3. la préimage est vérifiée comme `proveSegments` le fait (`[task_hash, dix felts]`) et
   comparée au `--expect-task-hash` ;
4. l'artefact est écrit au format du wrapper (`proof-0.json`, `format: bincode_b64`,
   `data` = base64 du fichier `extended-binary`) ;
5. avec `--leaf-verify`, `hellproof-leaf-verify --proof segment-0/proof.bin
   --expect-bootloader <leaf_simple_bootloader>` est exécuté et ses deux cellules de sortie
   comparées à `program_output.json` du bootloader.

### 4.3 Résultat

**Verte.** Segment `fight` de 7 tics (591 173 steps programme, 2 293 560 avec le bootloader),
`RAYON_NUM_THREADS=1`, pendant une fenêtre où le second agent était inactif (`total_rss` du
cgroup 0,24 Go avant le départ) :

```
npx tsx scripts/prove-one.mjs --words $S/calib/fight7/args.json --tics 7 --out $S/calib/node7-t1 \
  --threads 1 --timeout 1800 --manifest /home/user/doom/cairo/Scarb.toml \
  --executable /home/user/doom/cairo/target/proving/run_segment.executable.json \
  --params /home/user/doom/prover/wasm/harness/params/leaf.json \
  --leaf-verify $S/target-leaf-verify/release/hellproof-leaf-verify \
  --expect-task-hash 0x5c3f9de0cfb3b334a49070f4a47b4f875d7ef511959cf0efc9bd67ea879bf93
```

| mesure | valeur |
|---|---|
| `stwo-run-and-prove … --proof-format extended-binary --verify`, mur (`proveMs`) | **74,5 s** (dont `prove_cairo` 71,6 s, `verify_cairo` interne 26,9 ms, sérialisation 0,5 s) |
| RSS max du prouveur (`VmHWM`, échantillonné à 0,5 s) | **13,70 Go** |
| preuve `proof.bin` (`extended-binary` = bzip2(bincode `CairoProof`)) | **3 185 814 octets** (3,04 Mo ; sous les 8 Mo de `max_proof_bytes` du wrapper) |
| préimage | `[0x5c3f9de0…9bf93, 0x1, h_in, h_out, 0x0, 0x7, 0x0, inputs_commitment, 0x0, 0x0, 0x0]` = les dix felts exécutés |
| `hellproof-leaf-verify --expect-bootloader leaf_simple_bootloader_compiled.json` | **`ok: true` en 25,2 ms**, `program_hash` (bootloader) `0x54fe56ceb09ce499c0cd03a4a4b572c8d482fd81b4e674eda87ea66e40376dc`, `trace_log_size` **21**, deux cellules de sortie `0xf8b45374a3d98d6671c7ea70716cf911`, `0xf3c57b44a218b335d45c2731e2e27c06` = `program_output.json` du bootloader |
| artefact | `proof-0.json` : `{ index: 0, format: "bincode_b64", data: <base64 de proof.bin>, outputPreimage, programHash, proveMs, proofPath }` — la forme que `fold.ts` envoie au wrapper |

Phases (`time.busy`, 1 thread) : `cairo run` 1,13 s, `adapt` 0,59 s, `Write Base trace` 17,5 s,
`base trace commitment` 8,40 s, `Write interaction trace` 3,95 s, `interaction trace commitment`
7,23 s, `Prove STARKs` 33,6 s (dont composition 20,0 s). C'est le **premier segment Doom prouvé
par le code du nœud lui-même** sur le binaire réel, et la première preuve native Linux du dépôt.

Deux réserves. `trace_log_size = 21` : le registre feuille exige 20 (`min = max = 20`,
S0 §4 / D31) — comme D31 l'avait vu (`blake_g` en log 21), **ce segment n'est pas admissible
au registre courant** bien que sa preuve soit valide ; c'est la limite `resources()` de D26,
indépendante de la mémoire. Et 13,70 Go pour 2,29 M steps : sur cette machine le nœud ne peut
prouver qu'avec la machine pour lui seul.

---

## 5. Extrapolation prudente vers 8–13 M steps sur 64 Go

Ce que l'on tient de mesuré pour le **format feuille sur un segment Doom** :

| point | steps (bootloader compris) | RSS max (`VmHWM`) | temps | source |
|---|---:|---:|---:|---|
| 4 tics, 117 531 mots | 2 681 208 | 11,73 Go | 53,5 s (12 cœurs, M2 Max) | D31, macOS |
| **7 tics, 1 thread** | 2 293 560 | **13,68–13,70 Go** | **75,95 s** (Xeon 2,1 GHz) | ici, §2.1, deux preuves vertes |
| **7 tics, 4 threads** | 2 293 560 | **12,79 Go** (13,21 observés dans une tentative tuée) | **37,31 s** | ici, §2.1, preuve verte |
| 35 tics, 1 thread | 3 041 338 | **> 12,84 Go** (tuée deux fois par l'OOM du cgroup, dans la composition) | > 72,7 s (sans thrashing) | ici, §2.1 |

Et de la courbe S0 (programmes simples, `canonical_small`) : part fixe ≈ 2,2 Go, pente
≈ 1,8 Go par million de steps ; ce que le segment Doom ajoute par rapport à cette courbe
(≈ 5 Go à 2,7 M steps) vient des composants Blake (`blake_compress` ≈ 15 k instances,
`blake_g` en log 21 d'après D31), Poseidon et de la mémoire du programme (117 k mots), qui sont
essentiellement **fixes** par segment.

Hypothèse de travail (à vérifier, §6) : une part **fixe ≈ 9 Go** par segment Doom (Blake du
programme, mémoire des 117 k mots, composants auxiliaires, tous liftés à 2^20–2^21) plus
**≈ 2 Go par million de steps** — ce qui donne 13,6 Go à 2,29 M (mesuré 13,7) et 15 Go à 3,04 M
(cohérent avec le > 12,84 observé au moment du kill, avant le pic FRI). Les 4 threads n'ajoutent
pas de mémoire ici (12,8 Go), mais le pic varie de ± 0,5 Go. Avec cette pente :

| steps par segment | RSS estimée | tics ≈ (30–40 k/tic, monstres endormis ; 90–110 k réveillés) | remarque |
|---:|---:|---|---|
| 8 M | ≈ 25 Go | ≈ 170–200 tics calmes, ≈ 60 tics en combat | tient en 64 Go |
| 10 M | ≈ 29 Go | ≈ 230–260 / ≈ 80 | idem |
| 13 M | ≈ 35 Go | ≈ 300–350 / ≈ 100–120 | marge ≈ 1,8× sur 64 Go — **à confirmer**, la pente au-delà de 3 M n'est pas mesurée |

Le **temps**, sur ce Xeon 2,1 GHz, 4 cœurs : ≈ 33 s par million de steps mono-thread et ≈ 16 s
à 4 threads (7 tics), avec ≈ 1,7 s fixes (VM + adaptateur). Linéairement, un segment de 8–13 M
steps prendrait **≈ 2–3,5 min à 4 threads ici**, et sensiblement moins sur une machine de
calibration dédiée (≥ 8 cœurs AVX-512, 64 Go) ; l'exécution VM (≈ 0,5 s par million de steps)
et `Write Base trace` (mal parallélisé) prendront une part croissante. À mesurer, pas à supposer :
la composition et les commitments de 2^21+ lignes n'ont pas été observés ici.
La borne dure côté prouveur reste
`lifting_size_policy = at_least_preprocessed` + `canonical_small` : le registre feuille fixe
`trace_log_size = 20`, et un segment dont un composant dépasse 2^20 lignes n'est **pas**
admissible (D26/D31) — c'est `resources()` qui doit trancher, pas le compte de steps.

---

## 6. Ce qui reste à mesurer sur une grosse machine

1. **Les points 35 et 70 tics (1,34 M et 2,38 M steps programme, 3,0 M et 4,1 M avec le
   bootloader)** mono et 4 threads, avec RSS `VmHWM`, temps mur et taille de preuve
   (`cairo-serde` **et** `extended-binary`) — impossibles ici : 35 tics dépasse le cgroup de
   13,36 Go même machine seule (> 12,84 Go au kill), et seul le segment minimal de 7 tics
   (13,7 Go mono / 12,8 Go à 4 threads) a tenu, pendant les pauses du second agent (§2.1).
2. La **pente réelle RSS/steps du format feuille** sur Doom (au moins trois tailles entre 2 M
   et 13 M steps), pour remplacer l'hypothèse « 7 Go + 1,8 Go/M » de §5.
3. Le **temps multi-thread** (8 et 16 threads) par million de steps, et la part de la composition.
4. Les **hauteurs de composants** (`blake_g`, `range_check_*`, `memory_id_to_big`) aux mêmes
   tailles, pour fixer `--max-steps` / `--log-size` du nœud sur une base `resources()` et non sur
   les steps (README du nœud, « Native `resources()` »).
5. Le **repli de la preuve du nœud sur `extended-binary`** à grande taille : taille de l'artefact
   bzip2 vs `max_proof_bytes` du wrapper (8 Mo par défaut ; D31 : 765 202 felts en `cairo-serde`
   pour 2,68 M steps).

Ce qui est acquis sans grosse machine : la chaîne de commandes Linux (§1), le hash de tâche (§3),
le format de sortie du nœud corrigé (`extended-binary`, §4) et la vérification indépendante par
`leaf-verify` (§4).

# S4b — Trois mesures ciblées sur la route récursive (F4, D4, R2-A12, R1-A5)

> Suite de [S4](S4.md), vague 3 du [G0](../G0.md) §5. Mesures du **2026-09-12** sur la même
> machine et le même commit épinglé. Répertoire de travail : [`spikes/s4/`](../../spikes/s4).

## Question

Trois leviers laissés ouverts par S0 et S4, à trancher avec des chiffres avant P4.0 (constantes du
vérifieur on-chain) et avant que `doom_run` fige sa taille :

1. **`fold_step = 4` sur la preuve Cairo de la feuille** (S0 F4 / R1-A5 : −0,29 GiB et −12 % de
   taille de preuve en isolé) : le circuit vérifieur l'accepte-t-il ? Et
   `include_all_preprocessed_columns = false` (S0 : 290 k felts au lieu de 357 k) ?
2. **`program_hash_function: poseidon`** (D4, R2-A12 : ÷2,7 sur le terme proportionnel du
   bootloader) : les modèles de S0 tiennent-ils sur le bootloader *feuille*, et la route récursive
   + la recomposition on-chain passent-elles sans changement ?
3. **Registre à 2^21** (R2-A12 : diviserait par deux le surcoût bootloader et le nombre de
   feuilles) : `circuit-params` l'accepte-t-il, à quel prix, et le multiverifier reste-t-il celui
   de la production ?

## Verdicts

| # | Levier | Verdict | Chiffre clé |
|---|---|---|---|
| 1 | `fold_step = 4` (preuve Cairo) | **Accepté, mais sans gain tel quel** | bout-en-bout OK (racine 94 761 felts, vérifieur 5 316 217 steps) ; **0 %** de RSS gagné avec le padding production. Combiné au padding minimal (`doom_fold4_min`) : **21,9 GB au lieu de 32,5 GB (−33 %)** et **13,3 s au lieu de 22,8 s (−41 %)** par feuille — au prix de nouvelles constantes on-chain. |
| 1b | `include_all_preprocessed_columns = false` | **Refusé** | `leaf-prover` panique en 0,02 s (`prove_leaf.rs:70`). Piège : `circuit-params` accepte la définition et sort **le même hash de circuit feuille**. |
| 2 | `program_hash_function: poseidon` | **GO** | `1 969 + 5,50 × mots` contre `2 340 + 14,75 × mots` (résidus < 0,05 % sur 4 tailles) : **−147 569 steps** mesurés à 15 914 mots, **−294 459** à 31 794 mots. Chaîne complète OK avec le registre `doom` **inchangé** ; `recursion_outputs` inchangé (18 tests verts). |
| 3 | Registre 2^21 / 2^22 | **NO-GO, et sans objet** | `circuit-params` les génère (multiverifier = production), mais **aucune preuve `canonical_small` ne peut avoir `trace_log_size = 21`** (`seq_21` absent). Découverte associée : `trace_log_size` vient du **plus gros composant de l'AIR**, pas du nombre de steps — un segment de **1 586 951 steps passe déjà dans le registre `doom` actuel** (racine 96 189 felts, vérifieur 5 372 808 steps), et jusqu'à **5 381 951 steps** restent en `trace_log_size = 20`. |

## Setup

Identique à S4 (voir [S4.md](S4.md) §Setup) : monorepo `starkware-libs/proving` @ **`cd7bc5f`**,
binaires de `$SCRATCH/proving-s4/target/release`, Scarb **2.18.0** pour `stwo_cairo_verifier`,
`segment_stub`, `segment_stub_big`, `bigcode` et `recursion_outputs`, M2 Max 12 cœurs / 64 GB,
verrou de preuve partagé. `stwo-vm-runner` est réutilisé depuis le clone de S0 (même commit).

Nouveaux livrables dans `spikes/s4/` :

| Chemin | Rôle |
|---|---|
| `registry/doom_fold4/`, `doom_fold4_min/`, `doom_noprep/`, `doom_21/`, `doom_22/`, `doom_21_canonical/` | définitions + registres générés (mesures 1 et 3) |
| `programs/bigcode/` (`generate.py`) | programme à gros bytecode, Scarb 2.18 (mesure 2) |
| `programs/segment_stub_big/` | segment de ~1,59 M steps (mesure 3) |
| `scripts/bootloader_hash.sh` | surcoût bootloader = f(mots, fonction de hash) |
| `scripts/trace_log_probe.sh` | balayage de la longueur de run → `trace_log_size` |
| `scripts/canonical_sweep.sh` | tailles de trace où un circuit feuille `canonical` se construit |
| `scripts/gen_all_fixtures.sh` | régénère `recursion_outputs/src/fixtures.cairo` depuis tous les runs |
| `results/bootloader_hash.tsv`, `results/trace_log_probe.tsv`, `results/canonical_log_sweep.txt`, `results/rejects/` | mesures brutes et refus (stderr exact) |
| `results/N2_doom_{fold4,fold4_min,min,poseidon,big}/` | runs de pipeline N = 2 |

`run_pipeline.sh` prend désormais `HASH_FN=blake|poseidon`, `STUB=<paquet>` et `TAG=<suffixe>` ;
`gen_registry.sh` accepte `--report-only` (passe « rapport de tailles » seule, ~2 GB, pas de verrou).

---

## 1. `fold_step` et `include_all_preprocessed_columns` (F4, R1-A5)

### 1.1 Ce que `fold_step = 4` change dans le circuit feuille

`fold_step` vit dans `cairo_prover_params.json` du registre : c'est la config FRI de la **preuve
Cairo** que le circuit feuille vérifie (à ne pas confondre avec `circuit_fri_config.json`, la config
de la preuve *du circuit*, qui est **déjà à `fold_step = 4`** chez nous comme en production, codée
en dur dans le vérifieur Cairo). Une preuve Cairo repliée par 4 a moins de couches FRI à vérifier,
donc le circuit feuille rétrécit — avant padding :

| Registre (feuille log 20) | eq | qm31_ops | m31_to_u32 | triple_xor | blake_g_gate |
|---|---|---|---|---|---|
| `doom` (`fold_step = 1`) | 20 (61 %) | 23 (77 %) | 20 (93 %) | 19 (99 %) | **23 (62 %)** |
| `doom_fold4` (`fold_step = 4`) | 20 (61 %) | 23 (71 %) | 20 (77 %) | 19 (79 %) | **22 (98 %)** |

Le composant dominant (`blake_g_gate`, c'est-à-dire le hachage Blake2s en-circuit) **passe de 2^23 à
2^22**. C'est tout le gain : il n'est encaissable que si les cibles de padding du registre suivent.

### 1.2 Bout-en-bout (leaf → tree N = 2 → `stwo_circuit_verifier`)

Feuilles = `segment_stub` (144 837 steps), N = 2, machine partagée (temps ±10 %) :

| Registre | Cibles de padding | Feuille : mur / RSS | Repli : mur / RSS | `root.proof` | Vérifieur Cairo | Multiverifier |
|---|---|---|---|---|---|---|
| `doom` (référence S4) | 20/23/21/20/23 | 21,3 s ; 22,2 s / **32,5 GB** | 36,4 s / 32,3 GB | 93 797 felts | 5 260 345 steps | = production |
| **`doom_fold4`** | 20/23/21/20/23 | 22,8 s ; 22,8 s / **32,5 GB** | 22,8 s / 32,2 GB | 94 761 felts | **5 316 217** steps ✓ | = production |
| `doom_min` (padding minimal, fold 1) | 20/23/20/19/23 | 20,8 s ; 21,8 s / **31,9 GB** | 23,2 s / 31,6 GB | 94 709 felts | **refusé** | ≠ production |
| **`doom_fold4_min`** (padding minimal, fold 4) | 20/23/20/19/**22** | 13,3 s ; 14,3 s / **21,9 GB** | 13,5 s / 21,4 GB | 96 509 felts | **refusé** | ≠ production |

Lectures :

- **Accepté** : le vérifieur de circuit on-chain accepte une racine dont les feuilles ont vérifié une
  preuve Cairo à `fold_step = 4` (`doom_fold4`, 5 316 217 steps / 513 398 range_check, dans la bande
  5,26–5,37 M de S4). Le log de `leaf-prover` le confirme :
  `Proof FRI config: FriConfig { pow_bits: 26, log_blowup_factor: 1, log_last_layer_degree_bound: 0, n_queries: 70, fold_step: 4 }`.
  La recomposition on-chain reproduit l'`output_hash` (`fixtures::fixture_n2_doom_fold4`).
- **Aucun gain avec le padding production** : la feuille est paddée à la forme production dans les
  deux cas, donc la preuve de circuit — qui est *tout* le coût — est identique (32,5 GB, ~22 s).
  Le gain interne est marginal : la preuve Cairo intermédiaire passe de 2 881 936 à 2 756 480 octets
  (**−4,4 %**, pas les −12 % de S0, qui mesurait des params sans
  `include_all_preprocessed_columns`), et elle ne sort jamais du prouveur de feuille.
- **Le vrai levier est la combinaison** : l'ablation `doom_min` (padding minimal sans `fold_step`)
  ne gagne que 2 % de RSS ; c'est bien `fold_step = 4` qui fait tomber `blake_g_gate` d'un bit, et
  le padding minimal qui laisse le registre en profiter : **−33 % de RSS (32,5 → 21,9 GB)** et
  **−41 % de temps (22,8 → 13,3 s)** par preuve de circuit, feuilles **et** replis.
- **Prix à payer** : les cibles changent, donc le hash du multiverifier change
  (`02b34360…9f7fac34` au lieu de `a5989715…973f680f`) et le vérifieur on-chain, dont
  `COMPONENT_LOG_SIZES` est compilé en dur, **rejette la racine** :
  `An ASSERT_EQ instruction failed: 0:613 != 0:614` (`results/rejects/minimal_padding_verifier.txt`).
  Il faut régénérer les constantes (`FIX=1 cargo test -p circuit-params --test cairo_consts_test`
  sur la définition retenue) et redéployer les classes — décision à prendre **avant P4.0**, puisque
  R3-A6 prévoit de toute façon que nous déployons nous-mêmes le registry Stwo.

### 1.3 `include_all_preprocessed_columns = false` : refusé

```
thread 'main' panicked at crates/leaf_prover/src/prove_leaf.rs:70:5:
The prover parameters must set include_all_preprocessed_columns=true because the verifier circuit
expects a constant number of preprocessed columns
```

Refus en **0,02 s**, avant même l'exécution du programme. À noter, c'est un piège : `circuit-params`
ignore le drapeau (le circuit est construit sur `preprocessed_trace_variant.n_columns()`), accepte la
définition `doom_noprep` et produit un `registry.json` dont le **hash de circuit feuille est
byte-identique à celui de `doom`** (`2ad52ed0…9edac7e2`) — un registre invalide ne se voit qu'à la
première preuve. Les 290 k felts de S0 restent donc réservés à la route non récursive.

---

## 2. `program_hash_function: poseidon` (D4, R2-A12)

### 2.1 Coût du bootloader *feuille* = f(mots de bytecode, fonction de hash)

`spikes/s4/scripts/bootloader_hash.sh` — mêmes programmes `bigcode` qu'en S0 mais compilés en Scarb
2.18 et exécutés comme tâche du **bootloader feuille** (`leaf_simple_bootloader_compiled.json`),
sans preuve (`stwo-vm-runner`) :

| mots de bytecode | hash | steps seuls | + bootloader | **surcoût** | poseidon | range_check |
|---:|---|---:|---:|---:|---:|---:|
| 1 014 | blake | 484 | 17 785 | **17 301** | 1 | 1 040 |
| 1 014 | poseidon | 484 | 8 030 | **7 546** | 511 | 18 |
| 7 954 | blake | 3 954 | 123 609 | **119 655** | 1 | 7 980 |
| 7 954 | poseidon | 3 954 | 49 670 | **45 716** | 3 981 | 18 |
| 15 914 | blake | 7 934 | 244 999 | **237 065** | 1 | 15 940 |
| 15 914 | poseidon | 7 934 | 97 430 | **89 496** | 7 961 | 18 |
| 31 794 | blake | 15 874 | 487 169 | **471 295** | 1 | 31 820 |
| 31 794 | poseidon | 15 874 | 192 710 | **176 836** | 15 901 | 18 |

Modèles ajustés par moindres carrés sur les 4 tailles (résidus **< 0,05 %**, la linéarité est
parfaite) :

```
program_hash_function = "blake"     surcoût = 2 340 + 14,750 × mots   (+1   range_check/mot)
program_hash_function = "poseidon"  surcoût = 1 969 +  5,500 × mots   (+0,5 poseidon/mot,
                                                                       range_check constant = 18)
```

**Les modèles de S0 sont confirmés** : pente identique au millième près (14,74 / 5,50) ; seule la
constante poseidon monte de 1 840 à 1 969 (+129 steps), le bootloader feuille n'étant pas le
bootloader *privacy* de S0. Budget récupéré, à `2^20 − surcoût` :

| mots de `doom_run` | surcoût blake | surcoût poseidon | budget blake | budget poseidon | gain |
|---:|---:|---:|---:|---:|---:|
| 16 000 | 238 340 | 89 969 | 810 236 | 958 607 | **+148 371 steps (+18 %)** |
| 32 000 | 474 340 | 177 969 | 574 236 | 870 607 | **+296 371 steps (+52 %)** |
| 98 585 (prototype S1) | 1 456 469 | 544 187 | négatif | 504 389 | rend le prototype *prouvable* |

### 2.2 La route récursive ne bouge pas

Pipeline N = 2 identique au run S4, `HASH_FN=poseidon`, **registre `doom` inchangé** :

| Mesure | `doom` (blake, S4) | `doom` + poseidon |
|---|---|---|
| Feuille : mur / RSS | 21,3 s ; 22,2 s / 32,5–32,6 GB | 21,5 s ; 21,2 s / 32,6–32,8 GB |
| Preuve de feuille | 545 896 o | 545 896 o |
| Repli | 36,4 s / 32,3 GB | 22,9 s / 32,2 GB |
| `root.proof` | 93 797 felts | 94 705 felts |
| Vérifieur Cairo | 5 260 345 steps / 506 312 rc | **5 315 318 steps / 513 240 rc** |
| Recomposition on-chain | ✓ | ✓ (`fixture_n2_doom_poseidon`) |

C'est attendu à la lecture du code : le circuit feuille épingle le **programme bootloader**, pas la
tâche ; le hash de programme de la tâche n'est qu'un felt de la préimage de sortie.

### 2.3 Ce que le consommateur on-chain doit changer

**Rien de structurel.** Le hint `dump_privacy_simple_bootloader_output_preimage` recopie les felts de
sortie tels quels : la préimage garde la forme `[program_hash, h_in, h_out, n, status]` et
`H1 = blake2s(cairo0_encode(préimage))` est inchangé (le hachage *de la préimage* est toujours
Blake2s, quelle que soit la fonction de hash **du programme**). Seule la **valeur** de `preimage[0]`
change :

| `program_hash_function` | `preimage[0]` pour `segment_stub` |
|---|---|
| blake | `2784737126826178369939993031080194949960354326733421464854849544232566095676` |
| poseidon | `3123429690541791732247651535885863506882260532123250961348241600396459994871` |

Conséquences pour `spikes/s4/recursion_outputs` (futur `cairo/crates/recursion_outputs`) :

- l'API (`leaf_node`, `fold_tree`, `verification_output_hash`, `root_output_hash`) est **inchangée**,
  et les 14 tests de S4 restent verts ;
- la table de versions `DoomRuns` (R3-A6) doit épingler le `program_hash` **de la fonction choisie**
  et la fonction elle-même : une racine prouvée avec l'autre convention recompose vers un
  `output_hash` différent et doit être refusée. C'est ce que vérifie le nouveau test
  `tests::program_hash_function_binds_the_root` ;
- le `program_hash` poseidon est en plus **recalculable on-chain** si on le souhaite un jour
  (`poseidon_hash_span` sur `[0, main, n_builtins, builtins…, bytecode…]`), là où la chaîne Blake2s
  Cairo 0 ne l'est pas raisonnablement. Ce n'est pas nécessaire pour le MVP (constante épinglée).

`scarb test` sur `recursion_outputs` (Scarb 2.18) : **18 tests verts** (14 de S4 + `fixture_n2_doom_fold4`,
`fixture_n2_doom_poseidon`, `fixture_n2_doom_big`, `program_hash_function_binds_the_root`).

---

## 3. Registre à 2^21 (R2-A12)

### 3.1 `circuit-params` accepte 21 et 22 — et garde le multiverifier de production

| Registre | Cibles de padding | Hash de circuit feuille | Multiverifier | Génération |
|---|---|---|---|---|
| `doom` (log 20) | 20/23/21/20/23 | `2ad52ed0…9edac7e2` | `a5989715…973f680f` (production) | 6,9 s / 8,0 GB |
| **`doom_21`** | 20/23/21/20/23 | `0d3abfd0…8acb0e59` | **production** | 7,2 s / 8,0 GB |
| **`doom_22`** | 20/23/21/20/23 | `c54f6137…51746d9b` | **production** | 7,4 s / 8,0 GB |

Le circuit feuille grossit à peine avec la taille de trace vérifiée (le coût du vérifieur en-circuit
est dominé par les 70 requêtes FRI, pas par la trace) : à log 21 il demande 20/23/**20**/20/23, à
log 22 20/23/20/20/23 — tout tient **sous** la forme production, donc `pad_to` reste un point fixe
et les constantes on-chain resteraient valables.

### 3.2 Mais aucune preuve `canonical_small` ne peut atteindre `trace_log_size = 21`

`trace_log_size` est dérivé du **plus grand composant de l'AIR Cairo**, pas du nombre de steps
(`crates/prover/src/prover.rs:134` : `max(claim.log_sizes()) + log_blowup`, puis
`at_least_preprocessed` relève au plancher 21 de la trace pré-traitée). Balayage sur
`segment_stub_big` (`scripts/trace_log_probe.sh`, oracle = le refus du registre `doom_21`) :

| itérations | steps Cairo | `trace_log_size` | RSS de la phase Cairo | résultat |
|---:|---:|---:|---:|---|
| 23 000 | 1 586 951 | 20 | 4,4 GB | le circuit feuille **de `doom`** convient |
| 46 000 | 3 173 951 | 20 | 5,9 GB | idem |
| 64 000 | 4 415 951 | 20 | 6,8 GB | idem |
| 78 000 | 5 381 951 | 20 | 7,3 GB | idem |
| 92 000 | 6 347 951 | **21** | 10,3 GB | **panique** : `Preprocessed column PreProcessedColumnId { id: "seq_21" } is missing from static allocation` |

`canonical_small` s'arrête à `seq_20` (`SMALL_MAX_SEQUENCE_LOG_SIZE = 20`) : dès que la trace
demande log 21, le prouveur s'arrête avant même de produire la preuve. **`doom_21` et `doom_22` sont
donc inatteignables** ; ce sont des registres corrects pour des circuits qui ne peuvent pas exister.

Reste la trace pré-traitée complète (`canonical`, `MAX_SEQUENCE_LOG_SIZE = 25`). Elle ne sauve pas la
mise (`scripts/canonical_sweep.sh`, `results/canonical_log_sweep.txt`) :

| `preprocessed_trace = canonical`, feuille à log … | 20 | 21 | 22 | 23 | 24 | 25 |
|---|---|---|---|---|---|---|
| circuit feuille | panique | panique | panique | **OK** | OK | OK |

(`index out of bounds: the len is <log+1> but the index is 23` — le vérifieur en-circuit de
`memory_id_to_big` a besoin des bits jusqu'à 23.) Autrement dit `canonical` n'est utilisable qu'à
partir de `trace_log_size = 23` — c'est la plage du registre `production` (25–29) — et S0 a mesuré
sa part fixe à **15,9 GiB** côté prouveur Cairo, contre 2,2 GiB pour `canonical_small` : hors budget
navigateur (R1), et sans rapport avec un « segment 2× plus gros ».

### 3.3 Le corollaire utile : le plafond n'est pas 2^20 **steps**

Un segment de **1 586 951 steps** (1,5× le « plafond » supposé) passe la chaîne complète avec le
registre **`doom` inchangé** (`results/N2_doom_big/`, `STUB=segment_stub_big`) :

| Mesure | `segment_stub` (144 837 steps) | `segment_stub_big` (1 586 951 steps) |
|---|---|---|
| Feuille : mur / RSS | 21,3 s ; 22,2 s / 32,5 GB | 22,5 s ; 23,5 s / **33,5 GB** |
| Preuve de feuille | 545 896 o | 545 896 o |
| Repli | 36,4 s / 32,3 GB | 23,0 s / 32,2 GB |
| `root.proof` | 93 797 felts | 96 189 felts |
| Vérifieur Cairo | 5 260 345 steps | **5 372 808 steps / 520 298 rc** |
| Recomposition | ✓ | ✓ (`fixture_n2_doom_big`) |

Le coût on-chain et la preuve de circuit sont **insensibles** à la taille du segment (±2 %). Ce qui
borne un segment, dans l'ordre :

1. **la RSS du prouveur Cairo côté navigateur** (S0 : ≈ 2,2 GiB + 1,8 GiB/M steps ; ici mesuré
   4,4 GB à 1,59 M et 7,3 GB à 5,38 M dans `leaf-prover`) — c'est la contrainte qui mord en premier,
   vers **4–5 M steps** pour un budget de 12 GB ;
2. **le plus gros composant de l'AIR ≤ 2^20**, atteint entre 5,4 M et 6,3 M steps *pour ce
   programme* (la frontière dépend du mix d'instructions, donc elle est à remesurer sur `doom_run`) ;
3. **plus du tout** les 2^20 steps de la note « canonical_small plafonne à 2^20 » — ce plafond porte
   sur la trace pré-traitée, pas sur l'exécution.

---

## Recommandations

| Sujet | Recommandation | Quand |
|---|---|---|
| `fold_step` de la preuve Cairo | **Passer à 4 et re-padder au minimum** (`doom_fold4_min`) : −33 % de RSS et −41 % de temps sur *chaque* preuve de circuit (feuilles et replis), donc le wrapper redescend de 32,5 GB à 21,9 GB par preuve — deux preuves parallèles tiennent sur 64 GB, et une machine 32 GB redevient pensable. Prix : régénérer `multiverifier_consts.cairo` et déployer nos propres classes (déjà prévu R3-A6). **Décider avant P4.0**, qui fige les constantes. | P4.0 |
| `include_all_preprocessed_columns` | **Laisser `true`** — imposé par le circuit, refus immédiat sinon. Ne pas croire `circuit-params`, qui accepte la définition. | — |
| `program_hash_function` | **`poseidon`** : ÷2,68 sur le terme proportionnel, +147 k steps de budget à 16 k mots, zéro changement de registre, de circuit, de format ou de recomposition. Épingler la fonction **et** le hash dans la table de versions `DoomRuns`. | D4 confirmé, dès P1.5 |
| Registre 2^21 | **Abandonner** : impossible avec `canonical_small`, et `canonical` exigerait log ≥ 23 et 15,9 GiB. Remplacer l'action « évaluer un lifting 2^21 » de R2-A12 par « mesurer le plus gros composant de l'AIR de `doom_run` et caler K sur la RSS navigateur », le budget réel étant ~3–5× plus grand que `2^20 − bootloader`. | R2-A12, S1/P1 |

## Suites

- [ ] **R2-A12 / D1** : reformuler le budget de segment. Le plafond n'est ni 2^20 steps ni
      `2^20 − bootloader` : c'est `min(RSS navigateur, plus gros composant AIR ≤ 2^20)`. Mesurer les
      deux sur `doom_run` dès qu'il existe (rejouer `trace_log_probe.sh` avec le vrai programme).
- [ ] **D4** : inscrire `program_hash_function: poseidon` dans le format d'entrée du wrapper (P3.4)
      et dans la table de versions (R3-A6) ; ajouter le test CI de taille de bytecode avec le
      modèle `1 969 + 5,5 × mots`.
- [ ] **P4.0** : trancher `doom_fold4_min` avant de figer `COMPONENT_LOG_SIZES`. Si oui, regénérer
      les constantes du vérifieur Cairo et refaire les mesures de S5 (la racine passe à ~96,5 k
      felts, le coût du vérifieur reste à mesurer sur des constantes régénérées).
- [ ] **U8 / D7** : redimensionner le wrapper avec 21,9 GB par preuve si `doom_fold4_min` est
      retenu (2 preuves parallèles sur 64 GB, ou une machine 32 GB en mode dégradé).
- [ ] **Upstream** : signaler que `circuit-params` ignore silencieusement
      `include_all_preprocessed_columns` (registre accepté, hash identique, preuve impossible).

## Reproduire

```sh
cd spikes/s4
# 1. fold_step et include_all_preprocessed_columns
scripts/gen_registry.sh doom_fold4                # rapport + registre
scripts/gen_registry.sh doom_fold4_min
scripts/gen_registry.sh doom_noprep
scripts/run_pipeline.sh 2 doom_fold4              # leaf x2 -> tree -> stwo_circuit_verifier
scripts/verifier_output.sh 2 doom_fold4
scripts/run_pipeline.sh 1 doom_noprep             # refus attendu (prove_leaf.rs:70)
scripts/run_pipeline.sh 2 doom_min                # ablation padding minimal sans fold_step
scripts/run_pipeline.sh 2 doom_fold4_min          # refus attendu du vérifieur on-chain

# 2. poseidon
scripts/bootloader_hash.sh                        # 1 k / 8 k / 16 k / 32 k mots, blake vs poseidon
HASH_FN=poseidon TAG=_poseidon scripts/run_pipeline.sh 2 doom
HASH_FN=poseidon TAG=_poseidon scripts/verifier_output.sh 2 doom

# 3. registre 2^21
scripts/gen_registry.sh doom_21 && scripts/gen_registry.sh doom_22
scripts/trace_log_probe.sh                        # 23k..92k itérations -> trace_log_size
scripts/canonical_sweep.sh                        # canonical: log 20..25
STUB=segment_stub_big TAG=_big scripts/run_pipeline.sh 2 doom
STUB=segment_stub_big TAG=_big scripts/verifier_output.sh 2 doom

# fixtures + tests de recomposition
scripts/gen_all_fixtures.sh                       # régénère fixtures.cairo puis `scarb test`
```

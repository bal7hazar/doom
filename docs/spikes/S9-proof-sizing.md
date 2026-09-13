# S9 — dimensionnement de la preuve du jeu réel

Audit du 13 septembre 2026. Ce rapport corrige la généralisation de S4b §3.2 et
sépare validité locale, compatibilité avec le registre et capacité du navigateur.
Le jeu testé est la référence P1.9 `df1888d`, avant la passe de frontière et la
correction d’armure. `run_segment` compile à 117 531 mots sous Scarb 2.16/proving.
Les quatre premières commandes du replay `fight` sont des commandes de marche.

## Résultats

| Étape | Temps | Mémoire | Résultat |
|---|---:|---:|---|
| Preuve native, hash programme Poseidon | timeout 180 s | ~32 GiB RSS observés | aucune preuve produite |
| Preuve native, hash programme Blake | 53,50 s | 11,73 GiB RSS max | vérifiée, 765 202 felts |
| Même preuve WASM, Node 24.16, 4 threads | 42,225 s + 1,453 s exécution | 11,524 GiB linéaires | vérifiée, 4 343 870 octets bincode |
| Circuit feuille `doom_21`, consommant ce bincode | 75,83 s | 17,90 GiB RSS max / 25,99 GiB empreinte macOS | circuit valide, hash conforme au registre |
| Repli d’une feuille vers le multivérifieur canonique | ~60 s | ~30,1 GiB RSS échantillonnés | racine 95 325 felts |
| Vérifieur Cairo existant, sur cette racine | 5 333 257 steps | 5 032 262 adresse mémoire maximale | exécution réussie, huit sorties |

Les dix sorties D14 sont identiques entre standalone, bootloader Poseidon et
bootloader Blake. Seul le hash du programme diffère. La recomposition Python
indépendante (`doomruns_model`) du préimage public reproduit les huit mots du
repli, puis les huit sorties du vérifieur. Le segment est encore RUNNING : ce
résultat n’est pas une partie terminée enregistrée par `DoomRuns`.

## Cause du faux positif

Le prouveur WASM utilisait déjà `HashFunc::Blake` dans `src/core.rs`. Le script
natif P1.9 suivait l’hypothèse Poseidon de D4/D29 ; D31 aligne les décisions et
le script sur le code effectivement utilisé par le navigateur.

Les compteurs VM du même segment sont :

| Hash programme | Steps bootloader | Instances Poseidon | Entrées Poseidon uniques | Compressions Blake |
|---|---:|---:|---:|---:|
| Poseidon | 1 499 208 | 65 138 | 65 136 | 3 |
| Blake | 2 681 208 | 6 368 | 6 366 | 16 290 |

`resources()` annonce `max_component_rows=2^20`, `fits_leaf_registry=true` pour
Blake. Les claims réels de sa preuve donnent pourtant **`blake_g.log_size=21`**,
`cube_252=20`, `range_check_252_width_27=20`. La configuration finale porte
`trace_lifting_log_size=22`, `preprocessed_lifting_log_size=22`, blowup=1,
donc **trace_log_size=21**. Cette preuve ne convient pas au registre `doom` log20.

Dans `proving@cd7bc5f`, le compresseur Blake transmet ses lignes actives à dix
rounds, puis chaque round à huit G : **16 290 × 80 = 1 303 200 lignes**, arrondies
à 2^21. Poseidon transmet le nombre paddé A de son agrégateur aux sous-composants :
27A chaînes partielles, 8A chaînes complètes, 107A entrées cube. Pour A=65 536,
le cube atteint 2^23 lignes selon le code ; la preuve Poseidon a expiré avant
production, cette dernière taille est une déduction de source et non un claim mesuré.

Les tables fixes, le nombre total de colonnes, les contraintes de préprocessing
et les composantes auxiliaires ne se réduisent pas à un compteur de steps.
Une correction des compteurs est en cours ; elle doit conserver les plafonds
actuels tant qu’une politique de registre et de mémoire n’a pas été validée.

## Correction de S4b et voie de migration

L’absence de `seq_21` dans `canonical_small` bloque les composants qui ont
besoin de cette colonne. Elle n’interdit pas tout composant log21 : notre
preuve Blake log21 est vérifiée localement, repliée via le registre expérimental
`doom_21`, puis acceptée par le vérifieur Cairo existant. Le NO-GO universel
publié en S4b §3.2 est donc infirmé par ce contre-exemple réel.

Hash feuille du registre `doom_21` :
`0d3abfd062a42f30d2b5188d9d9e88ca43229182487d0e67a9a26db58acb0e59`.
Le multivérifieur conserve le hash de production
`a59897152377c07ac6d1e84454f0a04d8be65a7dfd73c2619078e728973f680f`.
Les paramètres de sécurité des preuves et les constantes du vérifieur final
n’ont pas été changés pour cette expérience. Aucun déploiement n’a été effectué.

D32 retient cette voie comme candidat technique. Restent : compteurs auxiliaires,
capacité de chaque composant à utiliser le préprocessing, budget mémoire réel,
planificateur et version de jeu/registre cohérents, fiabilité Chromium en concurrence
avec le jeu. Les plafonds de précaution 1,5 M steps avec threads et 2,3 M mono ne
sont pas relevés sur la base d’un seul essai Node. D2/D29 restent hors cible.

## Effet de la passe de frontière

La référence assemblée `b11fd7f`, après optimisation ABI et correction d’armure,
ramène `run_segment` à **116 287 mots**. L’exécution WASM, sans nouvelle preuve,
donne pour 0 / 1 / 4 tics **2 224 712 / 2 297 659 / 2 505 814 steps**. Le coût
sans tic dépasse déjà le plafond threads 1,5 M. Les 16 137 compressions Blake
alimentent 1 290 960 lignes G, donc log21. La réduction de frontière ne supprime
ni la taxe de hash du programme ni le besoin de revoir le découpage après une
campagne navigateur. Ces compteurs sont dans `integration-sizing.json` ; la
chaîne de preuve complète ci-dessus porte sur la référence antérieure 117 531 mots.

## Reproduction et traces

Les artefacts de cette session sont dans
`/tmp/hellproof-audit-20260913/hash-cost/` : copie de l’exécutable et arguments,
`blake-input.json`, preuves native et WASM, `wasm-blake-claims.json`, compteurs,
`wrapped-doom21.json`, `root-doom21.proof`, `verify-root-doom21.log`, recomposition
`verification-summary.json`. La comparaison Poseidon est conservée dans
`/tmp/game-p19-native-segment/`.

Exécution/proof : `proving-s4` au pin cd7bc5f ; wrapper `proving-p34b` à 8e459f1
(base cd7bc5f + patch D19 consommant la preuve). Le binaire `leaf-prover` prend
`--cairo_proof wasm-blake-proof.bin --proof_format extended-binary`, le bootloader
feuille et `spikes/s4/registry/doom_21/registry.json`. Le script existant
`spikes/s4/scripts/inject_preimage.py` prépare sa feuille pour le repli. La racine
est exécutée par `stwo_circuit_verifier` sous Scarb 2.18 avec `qm31_opcode`.
Chaque preuve lourde tient le verrou partagé ; superviseur avec timeout180s et
arrêt du groupe entier. Aucun nouveau build Docker local n’a été nécessaire.

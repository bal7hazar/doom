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
| Chromium 153, 4 threads, trois workers frais | 40,167–48,128 s | 11,524 GiB linéaires | 3/3 preuves vérifiées |
| Chromium 153, mono, deuxième essai | 136,425 s | 11,449 GiB linéaires | vérifiée ; premier essai arrêté à 150 s |
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

L’ancien `resources()` annonce `max_component_rows=2^20`, `fits_leaf_registry=true` pour
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
La correction intégrée par `d848951` conserve les plafonds actuels tant qu’une
politique de registre et de mémoire n’a pas été validée. Les deux nouveaux modules
Linux ARM64 reproduisent les compteurs réels et les 43 hauteurs variables de la
preuve ; ils déclarent log21, `fits_leaf_registry=false` et un prétraitement valide.
Les tableaux auxiliaires incomplets d’un ancien module sont refusés par le client,
y compris après reprise d’un segment ; contrôle frais avant chaque appel à `prove`.
Onze tests Rust et 193 tests client passent. Le rebuild local et cinq smokes k14
sont verts ; la reconstruction GitHub des nouveaux hashes reste à vérifier.

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

D32 retient cette voie comme candidat technique. Les compteurs auxiliaires et
besoins de préprocessing sont corrigés ; restent budget mémoire réel,
planificateur et version de jeu/registre cohérents, fiabilité Chromium en concurrence
avec le jeu. Les plafonds de précaution 1,5 M steps avec threads et 2,3 M mono ne
sont pas relevés sur la base d’un seul essai Node. D2/D29 restent hors cible.

## Confirmation Chromium sur le programme réel

Chromium headless **153.0.8010.12**, page COOP/COEP isolée, instance et worker
neufs à chaque essai, artefacts Linux ARM64 de `30f8d77`. À quatre threads,
les trois preuves passent en **48,128 / 40,653 / 40,167 s**, avec vérification
locale et les onze felts du préimage exactement identiques à la référence.
Mémoire linéaire **12 374 245 376 octets** ; la valeur est un maximum WASM,
pas une mesure de toute la consommation de la machine.

Le premier essai mono est arrêté à l’échéance d’audit de **150 s** pendant
`prove`, sans résultat vérifié. Une répétition avec une échéance de 240 s
aboutit en **136,425 s**, vérifiée, **12 292 849 664 octets** linéaires.
L’essai interrompu reste dans les résultats : cette campagne courte ne
prouve pas l’absence de blocages intermittents. La machine hôte possède
64 GiB ; ni le matériel 16 GiB ni la concurrence avec une partie Cairo ne
sont couverts. Les plafonds produit sont inchangés.

Traces : `chromium-real-t4-{1,2,3}.json`, `chromium-real-t1-{1,2}.json` et
leurs superviseurs dans le même répertoire d’audit. Timeout externe par
groupe de descendants, limite RSS échantillonnée 24 GiB, verrou partagé.

## Effet de la passe de frontière

La référence assemblée `b11fd7f`, après optimisation ABI et correction d’armure,
ramène `run_segment` à **116 287 mots**. L’exécution WASM, sans nouvelle preuve,
donne pour 0 / 1 / 4 tics **2 224 712 / 2 297 659 / 2 505 814 steps**. Le coût
sans tic dépasse déjà le plafond threads 1,5 M. Les 16 137 compressions Blake
alimentent 1 290 960 lignes G, donc log21. La réduction de frontière ne supprime
ni la taxe de hash du programme ni le besoin de revoir le découpage après une
campagne navigateur. Ces compteurs sont dans `integration-sizing.json` ; la
chaîne de preuve complète ci-dessus porte sur la référence antérieure 117 531 mots.

Après la seconde passe frontière et le parcours monstres, l’intégration `91719f8`
atteint **110 848 mots**. Une nouvelle exécution avec les compteurs AIR corrigés donne
**2 134 627 / 2 194 469 / 2 363 470 steps** pour 0 / 1 / 4 tics. Les **15 456**
compressions Blake génèrent **1 236 480** lignes G ; les trois cas annoncent correctement
log21 et `fits_leaf_registry=false`. Le seuil threads reste dépassé dès zéro tic et
le cas quatre tics dépasse encore le seuil mono. Mesure de ressources uniquement,
aucune nouvelle preuve : `integration-final-sizing.json`, Node 24.16.0,
exécutable SHA-256 `663028863fef87341e215928abd4e738817104167292655193e448544a57b021`.

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

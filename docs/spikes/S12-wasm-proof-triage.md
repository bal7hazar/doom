# S12 — incident de génération WASM sur le programme D33

État au 2026-09-13 : **cause identifiée, correction intégrée `e274bec` et validée localement**. Ce diagnostic
ne modifie ni le programme Cairo, ni les paramètres cryptographiques, ni les
plafonds de segments D26. La CI distante du nouveau build reste à vérifier. La matrice initiale ci-dessous conserve les essais avant correction.

## Entrée contrôlée

Programme `run_segment` de l’intégration D33 `aa16f2b`, inchangé dans `f306c6a`,
Scarb 2.16.0 / profil `proving` existant : **110 015 mots**. SHA-256 de l’exécutable :
`24672e9db90cf22502d2a69c50ea5d428fad5d45039acdc034d736b33b7b2b65`.
Même état genesis et quatre premières commandes du replay marche que S9.
Hash programme Blake, paramètres `prover/wasm/harness/params/leaf.json`, pile
native épinglée `proving@cd7bc5f`, Node **24.16.0**, M2 Max 64 GiB.

Les essais sont séquentiels sous verrou de preuve, avec délai explicite et
arrêt à 20 GiB RSS échantillonnés. Les fichiers sources des scripts, logs,
entrées et preuves sont conservés dans
`/tmp/hellproof-audit-20260913/hash-cost/` ; ce chemin local n’est pas un artefact CI.

## Résultats

| Générateur | Appel préalable `resources()` | Résultat | Durée |
|---|---|---|---|
| Natif épinglé | sans objet | Preuve générée et vérifiée ; préimage publique identique au WASM | 59,14 s murales |
| Ancien WASM, quatre threads | oui | Preuve valide, y compris sous vérifieur natif indépendant | 51,44 s de preuve |
| Nouveau WASM, quatre threads, essai 1 | oui | Preuve refusée en FRI, première couche | 42,32 s de preuve |
| Nouveau WASM, quatre threads, essai 2 | oui | Même refus FRI, confirmé par vérifieur natif indépendant | 43,66 s de preuve |
| Nouveau WASM, mono | oui | `prove` échoue : `Constraints not satisfied` ; aucune preuve retournée | 150,80 s murales |
| Nouveau WASM, quatre threads | non | `prove` échoue : `Constraints not satisfied` ; aucune preuve retournée | 48,14 s murales |

Le nouveau binaire est celui reconstruit indépendamment en CI après la correction AIR :
SHA-256 mono `3e94a4c0cd8a2e24af374bab733f77e2988b4b93731adea6a0a1b937009479a5`,
threads `fdb977ad4cbe2387a21a7472552b2b70b911252056c88d569e61de15da64277c`.
L’ancien contrôle provient du cache préservé du worktree `codex-ci-recovery`.
La preuve S9 historique valide est aussi acceptée par le **nouveau vérifieur**
WASM mono sous Node 24.16.0 (157,91 ms).

Preuves D33 conservées :

- Ancien WASM : `wasm-boxed-oldwasm-proof.bin`, **4 332 446 octets**,
  SHA-256 `abf90f0deb508b65858ea3f74df59cd720d388b4abaa23f9b7a731b4fc2258f8`.
  Vérification native et bzip2 vertes, corruption et mauvais bootloader refusés.
- Nouveau WASM, essai 2 : `wasm-boxed-repeat-proof.bin`, **4 345 102 octets**,
  SHA-256 `31a95a96aa8af6b57faf06941b0b77db068c62bbd570b278edd6bf7ef4598e0d`.
  Erreur indépendante : `queries do not resolve to their commitment in the first layer`.
- Natif : `boxed-native-proof.cairo_serde.json`, format Cairo-serde, vérification
  intégrée réussie ; RSS maximal système **12 780 896 256 octets**.

Le premier essai invalide n’avait pas sauvegardé la preuve avant vérification ;
seul le second en conserve une. Les scripts suivants sauvegardent avant `verify`.

## Diagnostic intermédiaire, avant résolution

Les claims, le PoW d’interaction, les quatre engagements Merkle et les valeurs
échantillonnées de la preuve native valide et du second essai WASM invalide sont
identiques selon le lecteur indépendant de leurs préfixes. La comparaison FRI
et l’inspection des buffers du backend étaient alors en cours.

Les observations excluent une explication limitée à la vérification JavaScript,
à une race exclusivement multithread ou à l’appel `resources()` lui-même. Elles
ne prouvent pas encore la cause du défaut : le nouveau binaire ou sa disposition
mémoire peut révéler un défaut sous-jacent. Le message `Constraints not satisfied`
est le contrôle OODS final du prouveur, pas un diagnostic de transition Doom.

Cet incident est **distinct** du rejet attendu par le registre de production
log20 : la même exécution demande log21. Les smokes arithmétiques CI restent
verts mais ne couvrent pas cette forme de trace réelle. Aucune promotion du jeu
complet, aucun relèvement de registre ou de plafond ne résout ce défaut.

## Résolution et revalidation

Le diagnostic final et les tests reproductibles sont dans
[prover/wasm/diagnostics](../../prover/wasm/diagnostics/README.md).
Le premier engagement divergent était FRI. Les kernels ont ensuite isolé les
chargements SIMD Memory64 de Liftoff dans Node24.16/V8 13.6 et Node25.2/V8 14.1.
Chromium153.0.8010.12 et Node en compilation optimisée dès le départ passent le
contrôle original. Cela explique pourquoi une variation d’allocation ou de tier
JIT exposait un défaut préexistant sans modification de l’AIR.

Le build abaisse quatre instructions en chargement scalaire de même largeur puis
splat, après optimisation. Il conserve les offsets, alignements et limites de
lecture. Deux tests Rust couvrent 80 modules ; 400 024 contrôles par mode Node
et 128 cas de kernels corrigés passent. Le build Docker ARM64 épinglé a terminé
en 763,002 s et reproduit exactement les copies soumises aux preuves root.

| Contrôle root après correction | Génération | Mémoire linéaire | Résultat |
|---|---:|---:|---|
| D33, Node24, quatre threads | 44,934 s | 12 133 269 504 B | valide |
| D33, Node24, mono | 156,293 s | 12 051 611 648 B | valide |
| D33, Chromium153, original quatre threads | 43,564 s | 12 133 269 504 B | valide |
| D29 final, Node24 corrigé, quatre threads | 42,161 s | 11 643 518 976 B | valide |

Les preuves D33 de Node corrigé et Chromium original sont identiques :
`89d7492ec4527b8c7454ccb542e0c57ae374c229437ab652676777622df34c1f`.
La preuve D29 fait 4 327 966 octets, SHA-256
`9eb3e16b70020535d51238df49c6a472014c124b0924f4e0457a2d7b094562cb`.
Vérification native indépendante et bzip2 vertes ; mutations et mauvais bootloader
refusés. Les dix sorties D29 correspondent exactement à l’ABI native validée.
Toutes sont des preuves de quatre tics RUNNING, sans nouveau wrap ni soumission.

Nouveaux SHA Linux : mono
`0524c748f426a867254c9909da18f3d82cae07321558883598b775b9edfc3714`, threads
`3534ddec473e406654161fd1c5138a27983de12d96a673519bdc24838e7e916c`.
Root a vérifié les copies locales dist/pkg/harness/client après merge et relancé
les tests Rust, le test runtime et REUSE. Aucun paramètre cryptographique ni
plafond n’a été changé ; le registre log20 refuse toujours ces traces log21.

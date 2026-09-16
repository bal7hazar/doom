# Worker Cairo réel — P2.3

Le jeu réel (`/`, alias `/?sim=cairo`) utilise `SimContinuation` R5 et les fonctions
`doom_game` compilées depuis le checkout courant. La démonstration du renderer
reste accessible via `/?sim=demo` ; les pages preuve et classement sont distinctes.
Les contrôles, écrans et sauvegardes de [la session de jeu](../game/README.md)
sont maintenant branchés. Le scheduler attend Start et reçoit les commandes
quantifiées D12 ; il n'envoie plus automatiquement des inputs neutres au chargement.

Les mesures et étapes P2.3 ci-dessous conservent leur provenance historique.
Les adaptations de sprites/psprites et le branchement du vrai programme de preuve
restent à livrer ; la présence du Worker ne clôt pas ces sujets.

## Préparation locale

Depuis `client/`, avec Scarb 2.16.0 et le package R5 déjà construit :

```sh
python3 scripts/prepare-sim.py /chemin/prover/sim/pkg
npm run assets
npm run build
npm run preview
```

Le préparateur vérifie le SHA256 WASM R5 épinglé dans
`src/prove/doomArtifacts.ts` (aujourd'hui
`70b305fe9e6e5a8d8f057cd5fdf4170c5a853b7e1b3b5b983e615f498bf86965`, build
Linux rustc 1.97.1 / wasm-pack 0.12.1 ; l'ancien build macOS `dd73ce15…` est
retiré avec l'identité `ee5f819`), reconstruit `doom_run` et le harnais existant de continuation avec le profil
`proving` (Cairo 2.16, `unsafe-panic=true`), puis copie les artefacts dans
`public/sim/`, ignoré par git. Deux jobs Cargo au maximum ; chaque compilation
est bornée à 600 secondes. Il ne télécharge rien et ne reconstruit pas Rust.
Le manifeste conserve le commit source et les empreintes du VM et des trois
exécutables ; le Worker vérifie les quatre empreintes avant de les charger.

À la base `8ae7f1c`, le harnais `session` mesure 108 041 mots ; c'est un programme
de simulation sans preuve. Le garde D29 concerne le vrai `run_segment`, qui
n'est pas remplacé par ce harnais. Aucun budget ou golden n'est changé ici.

## Protocole et propriété des buffers

`cairo.worker.ts` instancie `CairoController` et `cairoBackend.ts`. Le backend
appelle uniquement les exports du WASM R5 ; aucun moteur de jeu ne vit en JS.

| Requête | Résultat |
|---|---|
| `init` | `genesis(0)`, puis `step_tic(state, [])` pour obtenir la vue sans avancer ; charge la continuation et émet `ready`, à tic 0, en pause |
| `restart(state?)` | valide l'état via Cairo avec zéro input, recrée la VM et remet la séquence à zéro ; sans état, nouveau genesis |
| `resume` / `pause` | autorise ou suspend le calcul ; une commande déjà interrompue reste seule en vol |
| `advance(seq, word)` | exige le numéro attendu et un u32 exact, exécute un seul tic, renvoie le mot effectivement consommé, le statut et le snapshot |
| `checkpoint` | sérialise l'état exact du tic courant et compacte la VM sans avancer |
| `dispose` | annule la commande suspendue et libère la VM |

Chaque requête porte un `id` de corrélation. Les erreurs `busy`, `order`,
`paused`, `terminal`, `invalid` et `uninitialized` ne consomment aucun input.
Une erreur d'exécution empoisonne la session jusqu'à `restart`/`init`. Un état
terminal refuse les prochains inputs. `CairoClient.dispose()` termine le Worker
et refuse ensuite les appels ; il faut créer un autre client pour le recharger.

Un `ABORT` Cairo peut rendre l'état précédent sans avancer (notamment à
`MAX_TIC`). L'acquittement indique alors `consumed=false`, le statut d'opération
reste 3, et le snapshot brut garde exactement son statut antérieur. Le journal
conserve la tentative rejetée séparément ; il n'invente pas de tic ni de mot
consommé. Cette fin d'opération est conservée dans l'export/reprise.

Il n'existe aucune queue de rattrapage. Le scheduler échantillonne une commande
à l'échéance 35 Hz après l'acquittement précédent. Une pause ou un onglet caché
abandonne le retard mural, sans ajouter de mots au journal. Un calcul lent reste
lent : les moyennes observées ne garantissent pas une échéance de 28,57 ms pour
chaque tic. Le contrôle de cadence variable de la démonstration est désactivé
dans ce mode.

Les snapshots et checkpoints sont des buffers propriétaires de felts canoniques
32 octets little-endian. Ils sont transférés avec `postMessage(message, buffers)`
avec **et sans** isolation. Aucun buffer détaché ou vue d'une ancienne mémoire
WASM n'est réutilisé. Le ring du renderer est un `ArrayBuffer` local au thread
principal ; son producteur reçoit réellement les messages du Worker. Il n'y a
pas deux buffers prétendument partagés, ni de publication concurrente dans les
trois slots. Un redémarrage vide le ring pour éviter d'interpoler entre deux runs.

La VM est sérialisée puis recréée tous les 32 inputs et à la fin terminale.
Une demande explicite de frontière compacte aussi la VM : les demandes répétées
n'épuisent pas sa limite de commandes. Le snapshot/statut sont copiés avant la
requête de checkpoint, car celle-ci efface la réponse précédente dans R5.

## Journal, reprise et futures frontières de preuve

`InputJournal` existe dès `ready`, avant le premier tic et indépendamment de F4.
Il conserve les mots acquittés, leur ordre, le genesis importé et le dernier
checkpoint de maintenance. Les inputs sont exportés avec `packLog` D12 ; tous
les felts de l'état, y compris l'ordre historique de ThingGrid et les RNG,
restent présents. Le nombre de checkpoints retenus est constant (initial/dernier).

```ts
const sim = new CairoClient();
await sim.init(); // genesis visible ; aucun tic joué
await sim.resume();
await sim.advanceCmd({ forward: 25, side: 0, turn: 0, buttons: 0 });
await sim.pause();
const exactState = await sim.checkpoint();
const exported = sim.journal!.export();
sim.dispose();

const resumed = new CairoClient();
await resumed.restore(exported); // valide l'état et rejoue le suffixe ; reste en pause
```

L'API `export`/`restore` permet au propriétaire de sauvegarder le journal. Le
mode d'aperçu n'écrit pas automatiquement une partie persistante et ne fournit
pas encore d'interface d'import/export. Le test navigateur stocke un export,
recharge réellement le document, recrée le Worker et compare les sorties après
replay du suffixe. Une page fermée sans export peut donc perdre la partie.

`journal.boundary(ticStart, ticEnd)` renvoie l'identité, un état complet à
`stateTic <= ticStart`, les mots `prefix` à rejouer exactement jusqu'à la
frontière choisie, puis les mots du segment. Après `await sim.checkpoint()`,
une frontière au tic courant renvoie directement son état exact avec un préfixe
vide. Le futur adaptateur du vrai `run_segment` doit exécuter ce replay et
calculer les hashes D14 ; un hash seul ne remplace pas cet état. Aucun appel de
preuve ni branchement vers `createStubProgram` n'est fait dans cette livraison.
F4 affiche les limites dans le panneau de diagnostic en mode Cairo.

Les checkpoints de simulation importés restent une donnée de confiance locale,
pas une certification du journal ou du score. Le VM et les cheatcodes R5 ne
produisent pas de preuve. Le replay prouvé depuis genesis doit recertifier
toutes les transitions et vérifier les engagements ; l'import ne le remplace pas.

## Rendu : conversions établies et écarts conservés

`cairoSnapshot.ts` valide longueur, compteurs, identités d'acteurs et domaines
avant publication. Il convertit `Fixed.enc - 2^32` en entier signé, sans
troncature silencieuse dans le ring. Il transporte le snapshot Cairo brut ainsi
que `state`, `sprite`, `flags` et `playerstate` dans `CairoFrame`.

Le renderer Cairo joint les métadonnées au snapshot du même tic par identifiant
stable. Il choisit exactement `sprite`/`frame` et les rotations du WAD, avec
FULLBRIGHT/SHADOW issus du snapshot, sans fallback de famille ni de frame. Le
personnage caméra exclu est `player.mo` extrait de l'état validé, même non nul ;
les autres PLAY restent affichables. Les 49 noms viennent du fichier source
`cairo/doom/doom_things/generated/sprites.json`, distribué avec sa licence
GPL-2.0-only. Seule la liste des noms est consommée : aucune FSM JS n'est ajoutée.
L'atlas Freedoom épinglé contient 356 lumps de sprites, 1024 × 1024 RG8 (2 MiB).
Les ressources manquantes et métadonnées périmées arrêtent explicitement le rendu.

Seuls les trois flags communs sont transmis au ring : `CORPSE` (8) n'est jamais
pris pour `TELEPORTED` (8). Les bits corps/missile restent dans les données brutes.
Le HUD traduit les armes compactes Cairo 0..4 : 4 est la tronçonneuse, sans ammo ;
la démo conserve ses identifiants classiques. Le snapshot v1 historique ne contient
pas les psprites ; le snapshot live v2 décrit ci-dessous ajoute arme et flash.
La caméra et certains effets restent approximés :
ce lot ne constitue pas un rendu Doom exact ni un MVP visuel achevé.
Une sortie dépassant les capacités du ring est une erreur, jamais une troncature.

## Vérifications reproductibles

```sh
npm run typecheck
npm exec -- vitest run --maxWorkers=2 --minWorkers=1
npm run build
npm exec -- playwright test e2e/cairo.spec.ts e2e/render.spec.ts --workers=1
node scripts/audit-sim-worker.mjs /ref/fixtures.json /ref/native.json /tmp/worker.json
node scripts/audit-sim-worker.mjs /ref/fixtures.json /ref/native.json /tmp/worker-no-sab.json --unisolated
```

Le harnais utilise des références Cairo immuables et ne régénère aucun golden.
Il compare 386 snapshots, les états aux frontières de maintenance, cinq sorties
complètes de l'ABI `step_tic`, les statuts et les journaux. Il teste aussi un vrai
quantum de 101 steps, les commandes concurrentes/dupliquées, une pause pendant
ce quantum, le redémarrage après état invalide, puis un rechargement du document
avec huit mots à rejouer depuis le checkpoint. Chaque Worker d'audit est borné
à 180 s (30 s pour les contrôles ponctuels) ; les commandes de validation ont
été supervisées avec un timeout global de 240 s.

Mesure du 2026-09-13, Chromium 153.0.8010.12, transport et maintenance inclus :

| Scène | Tics | Moyenne ms | p99 ms | > 28,57 ms |
|---|---:|---:|---:|---:|
| idle | 80 | 8,861 | 38,235 | 2 |
| walk | 80 | 13,850 | 43,395 | 2 |
| door | 80 | 16,147 | 43,220 | 2 |
| fight | 80 | 12,858 | 40,910 | 2 |
| death | 66 | 11,778 | 42,955 | 3 |

Maximum mémoire linéaire WASM : 465 436 672 octets (443,875 MiB), hors heap JS,
renderer, assets et mémoire du navigateur. Sans isolation, les cinq moyennes
sont 8,811 / 13,711 / 16,184 / 13,010 / 11,550 ms, mêmes états et sorties.
Le smoke test de la production dessine un vrai frame Cairo et conserve les
quatre tests du renderer de démonstration. Ces mesures ne constituent pas une
campagne de gameplay complet avec capture, animations finales et preuve
simultanée sur machine 16 GiB ; aucun GO matériel ou cryptographique n'en découle.

### Live psprites (2026-09-13)

R5 now emits **render schema 2**: the unchanged v1 fields (apart from version)
followed by two five-felt slots: `state, sprite, frame, sx.enc, sy.enc`. These are
Cairo's weapon and flash states; state zero hides the slot, frame retains the
fullbright bit, and flash uses the weapon offsets. No JS weapon state machine
or wall-clock animation is involved. The ring carries the two slots without
interpolation so the HUD displays the same tic as the player statistics.

The continuation publishes v2 before the first `hp_poll`, including after loading
an in-flight shot checkpoint: pause/redraw/restore consumes no extra game tic.
The manifest advertises schema2 and the backend checks its live frame version.
The standalone `step_tic` keeps v1, and all six dev/proving game executables,
state schema2 and proof task identity stay unchanged. The v2 projection is kept
separate intentionally: sharing its header builder altered the step executable.
The test compares every legacy field and both slots against the exact state.

Only the audited S14 v1 session can migrate to this v2 session while all other
executable hashes match. Existing journal provenance is retained; loaded session
identity is tracked separately. Unknown game versions remain rejected. Existing
proof exports keep their artifact identity and are still accepted.

HUD selects the exact WAD frame, signed patch offsets and flip for each visible
slot; unknown frames fail explicitly. Weapon/flash currently use palette0 like
the previous HUD, without sector-light shading. Legacy v1/demo frames alone keep
the static weapon fallback. Gameplay/cadence/ammo remain entirely Cairo-owned.

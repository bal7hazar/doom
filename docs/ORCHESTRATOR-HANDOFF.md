# Handoff d’orchestration — Hellproof

> État actualisé le **2026-09-13**, après S14 et l’animation des armes Cairo ;
> audit distant du **2026-09-15** ajouté en fin de document (branche du jeu non poussée).
> Ce document remplace le handoff initial de Claude. Les mesures historiques
> détaillées restent dans `docs/STATUS.md` ; ne pas les confondre avec le moteur courant.

## Rôle

Tu es l'**orchestrateur** du projet **Hellproof** (dépôt `bal7hazar/doom`, branche `main`) : un
Doom-like dont le cœur de jeu est écrit en Cairo, prouvé localement dans le navigateur avec le prouveur
Stwo (WASM64), replié par un service « wrapper » en une preuve racine, vérifiée sur Starknet par un
vérifieur de circuit résumable, puis consommée par le contrat `DoomRuns` (classements, replays).
Tu ne codes pas toi-même les fonctionnalités : tu **audites, planifies, lances des sous-agents dans des
worktrees Git distincts, relis leurs rapports, testes, merges sur `main`, pousses, et tiens la
documentation de pilotage à jour**. Le sponsor (bal7hazar) t'a délégué les décisions techniques avec ce
critère : *maximiser les chances de réussite sans dégrader l'expérience utilisateur finale ; itérer si
un scénario échoue*. Tu lui rends compte en français, de façon concise, avec les chiffres qui comptent.

## État exact à reprendre

- Dépôt : `/Users/bal7hazar/git/doom`.
- `main` : dernier commit avant cette livraison `e3bc27b` (handoff précédent), poussé.
  **Le jeu complet n’est pas sur main** : `doom_game` / `doom_run` y restent des squelettes.
- Jeu complet : branche locale **`codex/game-integration`**, worktree
  `.claude/worktrees/codex-game-integration`, fusion animation **`6eec3e7`** (implémentation `5f1da8b`).
  Fusion fonctionnelle S14 **`49f2a66`**, assemblage **`d17b3be`**, moteur **`ee5f819`**.
  La synchronisation ultérieure de documentation peut changer HEAD sans changer le moteur.
- Aucun sous-agent ni campagne de preuve encore en cours à la fin de S14.
  Les agents Claude arrêtés pour quota ne sont plus attendus. Préserver leurs
  anciennes modifications non commitées ; ne pas nettoyer aveuglément les worktrees.
- CI générale : verte sur `e3bc27b` (run `34771778945`) ; run `34771558289`
  de `8763426` annulé par succession des mises à jour. Reconsulter GitHub.
  CI WASM de référence verte `34764805318`.

**Ne pas fusionner le jeu complet dans main avant résolution des gates D2/D29.**
Les passes moteur sont intégrées dans la branche du jeu ; les documents de
pilotage sont commités et poussés sur main, puis synchronisés dans cette branche.

## Le jeu est-il jouable ?

**Oui, en prototype local sur la branche du jeu.** La route `/` utilise le moteur
Cairo réel via le Worker R5 ; `/?sim=demo` est seulement la démonstration du renderer.
Déplacements, visée souris, tir, interactions, objets, monstres, portes/ascenseurs,
pause, sauvegarde/reprise, mort et sortie sont raccordés. Le journal conserve les
commandes réellement consommées. F4 ouvre la file de preuve et l’export récupérable.

Validation récente : treize smokes Chromium headed (dont contrôles et verrou souris),
262 tests client et replay navigateur jusqu’à **EXIT au tic 677**, santé 29,
quatre objets. Ce replay est piloté par l’API du client, pas une partie entière
jouée manuellement. La simulation conserve **35 tics/s** ; le rendu utilise rAF.
Cela ne constitue pas une mesure garantissant 35 FPS sur tout matériel.

Les images d’arme, recul, flash et baisse/remontée lors du changement suivent
maintenant les psprites Cairo (snapshot live v2). La visée automatique classique
est conservée à la demande du sponsor : aucun mouvement vertical de caméra.

Limites : certains effets visuels approximatifs ; aucune partie complète prouvée de bout en bout ni validation
jeu + preuve simultanés sur machine physique de 16 GiB. Le refus AIR est explicite
et laisse l’export disponible. Le prototype jouable ne vaut pas validation du MVP.

Sur cette machine, assets et WASM validés sont déjà présents (ignorés par Git),
et le build client a été refait après fusion. Pour ouvrir le jeu :

```sh
cd /Users/bal7hazar/git/doom/.claude/worktrees/codex-game-integration
export PATH=/Users/bal7hazar/.asdf/installs/nodejs/22.22.2/bin:$PATH
npm run dev --workspace client -- --host 127.0.0.1
```

Ouvrir l’URL locale indiquée par Vite, puis Start. Contrôles : WASD / ↑↓ pour
bouger, ←→ pour tourner, souris / Ctrl pour tirer, E / Espace pour utiliser,
Shift pour courir, 1–4 et 7 pour les armes, Esc / P pour pause, Tab pour la carte.
Aucun serveur permanent n’est lancé par ce handoff. Sur un nouveau checkout,
préparer les assets et les artefacts selon les scripts du client ; ne pas utiliser
les anciens exemples stub comme preuve du fonctionnement du jeu réel. Certains
paragraphes historiques du README client sont encore obsolètes.

## Mesures courantes et validations

| Sujet | Résultat courant |
|---|---|
| Cairo | **573 tests / 23 cibles**, aucun ignoré ; format, builds dev/proving et graphe verts |
| `run_segment` proving | **107 018 mots**, +163 depuis `0c8a3a8` |
| Profil de 2 946 tics | moyenne **48 543,68 steps/tic**, p99 **122 942**, max **166 315** |
| Gain S14 | moyenne **−1,98 %** ; chaque tic mesuré améliore son coût |
| Corpus moteur courant | **26/26 cas dev + 26/26 proving**, 7 575 tics logiques par profil, 1 365,78 s |
| Frontières | 149 coupes / 123 frontières sérialisées / 175 D14 indépendants par profil ; sorties et goldens exacts |
| Microbench S14 | 258 exécutions avec oracles ; 16 384 angles pour `sin_cos` |
| Client | **262 tests**, treize smokes headed ; replay EXIT677 validé avant cette extension de rendu ; build après fusion vert |
| Licences après fusion fonctionnelle | REUSE **1 789/1 789** |

S14 partage le pliage trigonométrique, remplace certains modulos IA par des
masques exacts et évite/réduit les copies de hauteurs. Les règles arithmétiques
sont mesurées sur Cairo 2.16 : aucune préférence universelle division/bitwise.
Voir [le rapport S14](design/cairo-calculation-costs.md) pour les sources et coûts.

Le coût fixe augmente avec le bytecode : execute WASM sur quatre tics de marche
passe de 2 193 266 à 2 195 222 steps (+1 956) ; sur 32 tics, de 3 083 596 à
3 081 268 (−2 328). Les entrées du prouveur grandissent dans les deux cas.
**Aucune nouvelle preuve n’a été générée avec ce moteur** ; pas de gain de durée
ou de mémoire de preuve revendiqué. Les sorties D14 restent identiques.

Trois budgets du bench global étaient déjà rouges et restent inchangés : hash
idle 120 441 / budget 76 686, serde 207 974 / 172 573, hash fight 122 618 / 76 684.
Ne pas rebaseliner les seuils pour rendre la suite verte.

Le fuzz de **10 000 tics / 158 cas / 11 épisodes** avec zéro divergence et la
preuve réelle quatre tics en **41,55 s** (WASM + native vérifiés, ~11,64 GB de
mémoire linéaire) concernent **l’ancien moteur `0c8a3a8`**, pas `ee5f819`.
Le nightly durable reste à mettre en place.

### Identités à préserver

- `run_segment` proving SHA256 :
  `18100435ee3882f0ae98d2b3fd89ee89c8dc365333a8cb3c0f74bed23f94b3bb`.
- Task hash mesuré par execute :
  `0x55fb48519602ba0310b362e11cfd040f3afad418cca2e37e2b3c069b251fc22`.
- R5 session live v2 : `2f2be024e3f91e24385aa3d73dead26394b924fd36d16be98c83dca935e39300`.
  Migration de sauvegarde v1 `dcb7193cbb8d77cdb08c66517e1c5e68453b15687808e40ea2abb5acbc4a0cac`
  autorisée seulement à exécutables jeu/VM identiques ; autres sessions inconnues refusées.
- VM sim R5 : `dd73ce152f44a9e00368e195c6de36d40b2948b0740794f056b2e557c94b67c5`.
- Schéma état 2, D14 à dix felts, RNG, D3 et cadence inchangés.
  Les anciens exports ne sont pas réétiquetés ; migration client explicite.

Les artefacts d’audit locaux sont dans `/tmp/hellproof-cairo-pass/`
(`comparison.json`, `corpus-report.md`, `corpus-final-validation.json`, logs
client/build/REUSE), et `/tmp/hellproof-cairo-cost-client/` pour execute WASM.
Ils sont temporaires : les faits durables sont consignés dans les docs et les
micro-harnais versionnés. Ne pas supposer leur présence sur une autre machine.

## Blocages et prochaine exécution

1. **D2** : cible moyenne ≤12 000 / p99 ≤25 000 steps/tic, encore manquée.
   Profiler les postes dominants en conservant le gameplay et mesurer le programme
   complet avant d’adopter une micro-optimisation.
2. **D29** : cible 100 000 mots, plafond projet 120 000 ; programme actuel +7 018
   au-dessus de la cible. C’est un budget de performance du projet, pas une limite
   intrinsèque Cairo. Le bootloader réel utilise Blake (~14,75 steps/mot), pas
   l’ancienne hypothèse Poseidon. S13 compression de carte a été rejeté car le
   chargement coûtait plus que le hachage économisé ; ne pas le réintroduire tel quel.
3. **Admission** : composant AIR `blake_g` exige log21, registre `doom` log20.
   Les caps 1,5 M threads / 2,3 M mono restent inchangés. Résoudre et valider le
   prouveur/registre avant de revendiquer la preuve complète.
4. **P3.7 / C3** : partie complète, preuve concurrente, wrapper, devnet et DoomRuns ;
   résiduel PLAN ≤10 min, objectif opérationnel ≤5 min. Matériel 16 GiB à valider.
5. Nightly de prouvabilité et finition visuelle ; puis P4.5 Sepolia,
   campagne et frais mesurés. Mainnet hors MVP.

À la reprise, lire STATUS, DECISIONS et le rapport S14 ; contrôler Git, les
worktrees, la CI et les agents avant lancement. Ne pas refaire toutes les longues
campagnes sans changement justifiant de les répéter. Les sous-agents doivent
recevoir un périmètre indépendant, livrer leurs commits et ne jamais pousser.

## Sepolia et coûts on-chain

Le sponsor indique **350 STRK sur Sepolia**, avec `SEPOLIA_ACCOUNT_ADDRESS`,
`SEPOLIA_PRIVATE_KEY`, `SEPOLIA_RPC_URL` (Infura) dans **`~/.hellproof`**.
L’emplacement exact à l’intérieur de ce chemin et le solde ne sont pas vérifiés.
Aucun secret lu ou affiché, aucune transaction envoyée dans la passe S14.
Les scripts peuvent charger la configuration sans l’exposer ; ne jamais afficher
la clé ni l’URL RPC contenant un identifiant. La mise à disposition du compte
ne clôt pas les gates et aucun déploiement n’a été décidé dans cette passe.

P4.1 mesuré sur devnet : vérification d’un fait en **5 transactions**, **1 540 234 480
L2 gas**, environ **47 STRK au prix historique**. Ce n’est pas un devis Sepolia
actuel, ni un tarif calculé directement sur les 100 k mots du programme. Déclarations,
déploiement, wrapper et enregistrement DoomRuns sont des coûts séparés. Refaire
une estimation de la séquence réelle avant P4.5 ; ne pas présumer que 350 STRK
couvrent le déploiement et toute la campagne. D28 `[2]` est déjà appliquée au
client et à la CLI sur main (`b00c90b`).

## Règles de travail (non négociables)

- **Une ligne = un sous-agent = un worktree = un périmètre de répertoires** déclaré dans le brief ; les
  documents racine (`README/PLAN/CONTEXT/RISKS/ROADMAP/docs/*.md` de pilotage) ne sont modifiés que par toi.
- Briefs auto-suffisants : contexte à lire, périmètre exact, livrables, tests exigés, critères de sortie
  chiffrés, règles de commit (`git -c commit.gpgsign=false commit`, message se terminant par la ligne
  d'attribution de ton harnais), **jamais de push**, format du rapport final. Choisis le modèle selon la
  difficulté (les tâches de crypto/prouveur/on-chain et le chemin critique au modèle le plus capable).
- Qualité (PLAN §3.1) : petites crates à périmètre précis, tests unitaires exhaustifs (valeurs de
  référence Python, propriétés, cas limites, budget de steps, couverture ≥ 90 %), règles de bytecode S7 §8,
  zéro panique sur le chemin chaud (R4-A2), valeurs < 2^72.
- Ressources machine (M2 Max 64 GB) : **verrou de preuve** `mkdir $SCRATCH/.proof-lock` (attente par
  boucle, `rmdir` en sortie avec trap) pour toute preuve > 2^19 steps et toute preuve de circuit
  (22–33 GB chacune) ; timeout explicite sur toute preuve avec threads (blocages intermittents R1-A8) ;
  **aucun build Docker sans l'annoncer au sponsor** ; devnet uniquement, jamais Sepolia/mainnet sans
  décision explicite.
- Sécurité : **ne jamais recevoir, lire, afficher ou copier une clé privée**. Le compte Sepolia sera
  fourni par le sponsor dans `~/.hellproof/sepolia.env` (variables `SEPOLIA_ACCOUNT_ADDRESS`,
  `SEPOLIA_PRIVATE_KEY`, `SEPOLIA_RPC_URL`, fichier `chmod 600` hors dépôt) ou via un keystore sncast
  chiffré ; les scripts lisent les variables, aucune sortie de commande ne les affiche.
- Licences : `cairo/doom/*` GPL-2.0-only (dérivé de linuxdoom-1.10), le reste Apache-2.0, assets Freedoom
  BSD jamais commités ; `reuse lint` doit rester vert.
- Après chaque merge : validation adaptée, publication de `main` uniquement pour les changements qui y sont intégrés, mise à jour de `docs/STATUS.md` et, si un fait
  mesuré change, de `CONTEXT.md`/`RISKS.md`/`docs/DECISIONS.md`.

## Outillage et compte rendu

- Scarb 2.16.0 pour `cairo/`, 2.18.0 pour les contrats ; Node 22.22.2 pour npm,
  Node 24.16.0 pour WASM64 ; Rust selon les fichiers du dépôt.
- Limiter les campagnes CPU : `RAYON_NUM_THREADS=1 CARGO_BUILD_JOBS=1` si adapté.
  Toute vraie preuve lourde utilise le verrou et un timeout explicite.
- Ici les accès complets sont accordés et la politique d’approbation est `never` :
  ne pas ajouter `sandbox_permissions`, ni redemander une autorisation pour les
  audits, tests, corrections réversibles et fusions déjà délégués.
- Attribution des commits : `Co-authored-by: Codex <noreply@openai.com>`.
- Après une vague, rapport concis en français : intégré où/commit, métriques,
  tests, limites, agents réellement actifs et prochain blocage. Ne jamais annoncer
  un agent, un serveur ou une preuve en cours sans en avoir vérifié l’état.

## Dernière livraison : animation de tir

`5f1da8b`, fusion `6eec3e7`, ajoute un snapshot **live** v2 : les deux slots
arme/flash, leurs frames et offsets proviennent de Cairo. Snapshot v1 de step_tic,
état2, D14 et les six exécutables dev/proving restent strictement identiques.
Le programme prouvé reste donc à 107 018 mots ; aucun changement de gameplay.
L’initialisation/restauration publie les psprites sans consommer de tic.
Les sauvegardes précédentes connues restent chargeables ; la provenance du journal
importé est conservée séparément de l’identité du simulateur chargé.

Validation ciblée Cairo : 63 tests doom_game, dont 45 tics comparant le préfixe
v1, les slots v2 et l’absence de mutation d’état. Les captures navigateur ont
confirmé l’alignement de l’arme et du flash après correction d’un décalage vertical.
La suite complète Cairo de 573 tests reste la mesure S14 ; elle n’a pas été
rejouée intégralement pour cette extension d’affichage.

Après fusion, root rejoue **262 tests client et 13 smokes Chromium headed** en
une minute : animation/flash, pause/restauration, munitions vides, changement
arme, migration v1/v2, clavier/souris natifs, sauvegarde/import, F4/refus AIR/export.
Build TypeScript/Vite et REUSE 1 789/1 789 verts. Aucune preuve ni transaction
lancée ; aucun agent ou serveur de test restant. Logs `/tmp/hellproof-weapon-audit/`.

## Audit de reprise distante — 2026-09-15

Session Claude Code distante (checkout frais de `origin/main`, Linux x86_64,
sans Scarb ni Docker ; Node 22.22.2, cargo 1.94.1). Aucun changement de code.

**Constat bloquant : le remote `origin` ne contient que `main` (`b8b2f40`).**
La branche `codex/game-integration` et tous les commits qu'elle porte
(`6eec3e7`, `5f1da8b`, `49f2a66`, `d17b3be`, `ee5f819`, `0c8a3a8`, `ae2feac`,
`3cb97c1`, `48b9dc7`) sont **absents du dépôt GitHub**. Le jeu complet, la passe
S14 et l'animation d'arme n'existent que dans le worktree local du sponsor.
Conséquences : aucune sauvegarde hors machine, aucune CI sur le moteur réel,
aucun orchestrateur distant ne peut auditer, tester ou fusionner le jeu.
Action requise du sponsor, depuis sa machine :

```sh
cd /Users/bal7hazar/git/doom
git push -u origin codex/game-integration
```

Pousser cette branche ne la fusionne pas dans `main` ; la règle « pas de fusion
avant D2/D29 » reste inchangée. Aucune PR n'est ouverte sur le dépôt ; aucune
autre branche à fusionner. CI générale verte sur `b8b2f40` (run `34772884084`).

### Commits Codex présents sur `main` audités

Trois revues indépendantes, lecture seule, sur ce qui est réellement poussé :

| Périmètre | Commits | Verdict | Tests rejoués ici |
|---|---|---|---|
| Wrapper Rust | `b817625` `bd68472` `dd90ffe` `8958be3` `899ef59` `e715fb3` | OK, aucun défaut de sécurité | 77 verts / 5 ignorés (pipeline réel) ; leaf-verify 2/2 `--locked` ; test `leaves` relancé 6× vert |
| WASM Memory64 | `1ed168c` (merge `e274bec`), `69d9e39` (merge `163c9e1`) | OK, réécriture sûre, gate CI réel | 2/2 cargo ; fixture .mjs 3 tiers 400 024 checks ; `ci_memory64.py` échoue bien sans artefact |
| Soumission D28 | `06b4394` (merge `b00c90b`) | OK, pas de double envoi ni saut d'étape | client 172 verts / 23 ignorés ; infra/submit 95 verts / 1 ignoré |

Les paires `1ed168c`/`e274bec` et `69d9e39`/`163c9e1` sont des commits de
merge, pas des doublons. Sur `main`, le client compte **172 tests** (23 ignorés
faute d'assets), pas les 262 de la branche du jeu.

Doutes relevés, non bloquants, à traiter dans une prochaine vague :

1. `prover/wasm/tools/memory64-splats/src/main.rs:50-54` : seuls les quatre
   `v128.loadN_splat` sont réécrits ; `load_extend`, `load_zero` et `load_lane`
   partagent le chemin Liftoff fusionné et ne sont ni corrigés ni couverts par
   la fixture `.mjs`. Ajouter ces opcodes à la fixture pour clore la question.
   Sur x86_64 / V8 12.4 l'artefact original passe tous les tiers : le bug est
   arm64 et/ou V8 13.x ; l'architecture hôte manque dans `diagnostics/README.md`.
2. `prover/wrapper/src/scheduler.rs:441-446` avec `:243-256` : un rejet
   déterministe à la revalidation est retenté trois fois puis classe le run
   `failed` au lieu de `rejected`, et se propage aux runs partageant le `leaf_key`.
3. `prover/wrapper/leaf-verify/src/main.rs:207-220` avec `pipeline.rs:183-199` :
   un bootloader illisible sort en exit 2 et est classé rejet de preuve définitif ;
   atténué par `check_runnable` au démarrage.
4. `prover/wrapper/tests/admission.rs:71` : assertion trivialement vraie ; la
   liaison bootloader réelle n'est testée que par un double shell.
5. `infra/submit/src/cli.ts:195-208` : un cut sauvegardé avant que `begin` soit
   accepté est relu comme explicite et désactive le fallback gas sans message.
6. `client/src/ui/costScreen.ts:136` n'est instancié par aucune page sur `main`.
7. `infra/submit` exige son propre `npm ci` et le module Python `poseidon_py`
   pour `batch.test.ts` ; non documenté. `prover/wrapper/README.md:251` cite
   encore `segment_stub`.

Non vérifiable ici : hashes `SHA256SUMS.linux` (pas de Docker), task hash Blake
(pas de `prover/wasm/pkg/dist`), suite Cairo (pas de Scarb). Aucun agent, serveur
ni preuve laissé en cours ; `node_modules` et caches cargo installés hors dépôt.

### Branche du jeu poussée et auditée — 2026-09-15

Le sponsor a poussé `codex/game-integration` (HEAD `310d5d8`, 99 commits au-dessus
de `main`, `main` entièrement contenu). Tous les SHA cités plus haut existent
désormais sur `origin`. La CI générale et le workflow `game-regression` ne se
déclenchent que sur `main` et sur les PR ; le `schedule` nightly présent dans
cette branche est inerte tant que le fichier n'est pas sur la branche par défaut.
**Aucune CI n'a donc tourné sur le moteur réel.** Ouvrir une PR de suivi
(sans la fusionner) suffirait à déclencher CI et régression sur chaque push.

Validation distante indépendante, Linux x86_64, 4 cœurs, 15 Go, Scarb 2.16.0
téléchargé dans le scratchpad, worktree jetable de `310d5d8` :

| Contrôle | Résultat |
|---|---|
| `scarb fmt --check` | vert |
| Tests Cairo | **553 verts / 554 dénombrés** sur 17 packages ; `doom_game` exécuté par module puis test par test |
| Test non exécutable | `e1m1::test_fight_is_associative_across_serialized_boundaries` dépasse **15 Go** seul (tué, code 137) ; `scarb test -p doom_game` entier dépasse aussi 15 Go à 4 threads comme en mono-thread |
| `size.py --report` proving | `run_segment` **107 018**, `step_tic` 108 505, `genesis` 46 496 ; dev 125 657 / 125 784 / 50 877 |
| SHA256 `run_segment` proving | `18100435ee3882f0ae98d2b3fd89ee89c8dc365333a8cb3c0f74bed23f94b3bb`, identique au pin, **re-mesuré sur HEAD après les commits de formatage** |
| Client | `npm ci` vert ; **262 tests : 252 verts, 10 ignorés** (artefacts prouveur absents) ; `tsc` vert. Sans `npm run assets`, `cairoAppearance.test.ts` échoue sur `freedoom1.wad` absent |
| REUSE 6.2.0 | **1 789/1 789**, conforme |

Point d'attention CI : la suite `doom_game` seule atteint ~14 Go de RSS sur ce
conteneur ; les runners GitHub standard ont 16 Go. Le job `cairo` de `ci.yml`
n'a jamais tourné sur cette branche ; prévoir `RAYON_NUM_THREADS` réduit ou un
découpage par filtre si le job tombe en OOM.

Deux revues de code en lecture seule sur les deux dernières vagues Codex :

| Périmètre | Commits | Verdict |
|---|---|---|
| Passe S14 | `11d925c` `2b9c362` `2dda0e0` `c4696b2` `ae2feac` `95939fa` | OK : équivalence de `sin_cos` démontrée sur les quatre quadrants et testée sur 16 384 angles ; masques exacts sur u32 ; `refresh_heights` ne peut sauter aucune mise à jour ; formatage strictement pur ; identités de preuve refusées explicitement |
| Animation d'arme et Workers | `5f1da8b` (`6eec3e7`), `3cb97c1` = `d049d4b` + `e454740` + `e5cac03` | OK : `snapshot_with_psprites` est une projection pure, inatteignable depuis `doom_run` ; sessions inconnues refusées ; `terminate()` règle toutes les promesses, pas de retry après hard stop |

Doutes non bloquants à traiter dans une prochaine vague :

1. `cairo/doom/doom_game/src/level.cairo:85,89` : deux `Span::at` ajoutés sur le
   chemin chaud de `refresh_heights`, contraire à S7 §8.1 (`get` + `match`).
   Pas de changement de comportement, mais un site de panique de plus.
2. `client/src/sim/cairoClient.ts:114-117` : `restore` charge le checkpoint
   étranger avant le contrôle d'identité ; sûr uniquement grâce à la
   pré-vérification de `playSession.ts:147-156`. Inverser l'ordre.
3. `client/src/prove/pipeline.ts:405-424` : `planNext` sans garde explicite
   de hard stop entre ses `await`, ni test dédié.
4. `client/src/prove/gameBridge.ts:55-59` : double `stop(true)` et flush/sync
   concurrents ; idempotent mais fragile.
5. `cairo/doom/doom_game/src/tests/synthetic.cairo:812-841` : l'assertion
   « aucune mutation d'état » est tautologique (argument `@GameState`) ; rien
   n'atteste qu'un flash survient dans les 45 tics ; « zéro tic consommé »
   n'est prouvé que par l'e2e.
6. `client/e2e/gameProof.spec.ts:46` : assertion du message de refus affaiblie
   (`"identity"` au lieu de `"identity differs"`).
7. `client/src/ui/hud.ts:147-149` : offset de la barre d'état ignoré, arme
   environ 16 px trop basse en vue 168 lignes ; cosmétique.

La paire de sessions R5 `dcb7…` → `2f2b…` n'est attestée que par le code et les
docs : le manifeste est un artefact de build non commité. Rayon limité au rendu.

Aucun agent, serveur ni preuve laissé en cours ; worktree jetable supprimé.
Prochain chemin critique inchangé : D2/D29, admission log21/log20, puis P3.7/C3.

## Reprise de l'exécution — 2026-09-15 (session distante)

Base de travail : branche **`claude/happy-knuth-pr0xjr`** = `codex/game-integration`
(`310d5d8`) + documents d'audit + vagues ci-dessous, poussée sur `origin`. Le
sponsor peut l'intégrer dans `codex/game-integration` par fast-forward. Les
sous-agents commitent en worktree, sans push ; les commits sont re-signés par
l'orchestrateur à la fusion (le hook de cet environnement exige des commits signés).

### Vagues fusionnées

| Vague | Fusion | Contenu | Validation |
|---|---|---|---|
| Correctifs client | `0a8ec84` | `restore` vérifie l'identité avant tout `init` ; `planNext` gardé contre le hard stop ; `retire` séquentiel avec un seul stop dur et `flushJournal` idempotent ; assertion e2e exacte | 258 tests client, `tsc`, build ; e2e Cairo non exécutables ici (pas de `public/sim` ni WASM) |
| Test psprites | `4379024` | test v2 non tautologique : deux parties en lockstep 45 tics, hash identique, flash observé, ≥ 2 frames d'arme | `-f synthetic` 32 verts |
| Écran de coût P4.3 | `f3c3f7f` | `client/src/prove/onchain.ts` : batch → felts racine → `prepareSubmission` (D28, `submit_batch` ou `register_member`) → `CostScreen` → séquence signée par Controller, reprise par proof id dérivé du batch id ; configuration `VITE_RPC_URL`/`?rpc=`, `VITE_ROUTER_ADDRESS`/`?router=`, `VITE_DOOM_RUNS_ADDRESS`/`?runs=`, `VITE_VERSION_ID`/`?version=` | **272 tests client** (14 nouveaux sur la fixture réelle `B2-1_doom`), `tsc`, build ; Controller réel, wrapper réel et écart < 20 % (C5) non validés |
| Profil D2 | `8a3f800` | `docs/design/d2-profile.md`, `bench/attribute_tics.py`, `bench/d2_tables.py` : attribution exacte des 2 946 tics (48 543,68 / p99 122 942 retrouvés au step près) | REUSE 1 789 + 3 |

Retenu hors fusion : `wave/fixes-cairo-held` (`6e0c0b0`, `refresh_heights` sans
`Span::at`, **106 948 mots**, SHA `8b0a81c5d36fd03279b9b06d16f156a887973150976db53f01c6806f0d8385e0`),
repris dans la vague O1 pour ne faire qu'une migration d'identité.

**Migration d'identité impossible ici** : le task hash Blake se mesure avec le
runtime WASM construit (`prover/wrapper/scripts/measure_task_hash.mjs`, Node 24,
`prover/wasm/pkg/dist/core.js`) ; l'artefact CI `hellproof-prover-wasm` existe mais
le proxy de cet environnement bloque son téléchargement. Tout changement de
bytecode moteur fusionné ici laisse donc `client/src/prove/doomArtifacts.ts` à
migrer par le sponsor : SHA `segment`/`step`/`genesis`, `programHash`, `revision`,
plus le test `legacyDoomIdentity`, comme `95939fa`.

### Ce que dit le profil D2 (`docs/design/d2-profile.md`)

- Moyennes par scénario (frontière exclue) : idle 26 386, walk 50 504, door 64 931,
  fight 63 228, death 47 137 ; aucun tic sous 25 000.
- **≈ 17 000 steps par tic sont des balayages complets des 210 slots** (`awake_count`,
  `next_actor`, plomberie de `monsters_ticker_in`, `has`) : 64 % d'un tic idle.
- Frontière `step_tic` hors tic : 266–278 k steps/appel ; pour `run_segment`
  ≈ **440 000 steps par segment** (parseur, sérialisation, deux hachages Poseidon).
- Micro-optimisations équivalentes cumulées (O1 liste d'acteurs dérivée −14 000,
  O3 clip par cellules −3 500, O2/O4 −2 000) : moyenne ≈ 28 500, p99 ≈ 93 000.
  **D2 (12 000 / 25 000) n'est atteignable ni par micro-optimisations ni par les
  pistes algorithmiques sans réduire le gameplay** (fenêtre D3, cadence `A_Look`).

### Arbitrage C3 à soumettre au sponsor

Coût fixe par segment prouvé, avec les mesures consignées : hachage Blake du
programme 2 340 + 14,75 × 107 018 ≈ **1 581 000 steps**, plus la frontière
≈ 440 000, soit **≈ 2,02 M steps avant le premier tic**. Les plafonds D26 sont
1,5 M steps avec threads et 2,3 M mono : le mode threads ne peut contenir aucun
segment, le mode mono laisse ≈ 280 000 steps de jeu, soit **6 tics par segment**
aujourd'hui, ~8 après O1, ~23 si D2 était atteint. Une partie de 3 min (6 300 tics)
demande donc ~1 000 segments aujourd'hui, ~275 même à D2 ; à 42–54 s par segment
(preuve réelle mesurée), cela fait **de 3–4 h (à D2) à 12–15 h (aujourd'hui)**,
contre 10 min visées. C3 ≤ 10 min exigerait ≤ 12 segments, donc ≥ 525 tics par
segment : impossible sous 2,3 M steps quel que soit le coût par tic. Le problème
n'est pas D2 : c'est le coût fixe par segment dans un segment borné par la
mémoire du navigateur.

Trois options, à décider avant toute nouvelle campagne de preuve :

1. **Réviser C3** : preuve locale en tâche de fond acceptée sur plusieurs heures
   (le pipeline P3.2 la reprend déjà après rechargement) ; D2 révisé vers une
   cible mesurable après O1/O3 (~25 000 / 70 000).
2. **Prouver côté service** (P3.5 devient la voie principale) : segments plus
   grands sur la machine 64 Go (2^23–2^24 steps) et parallélisme, le navigateur
   n'exécutant que le jeu ; à mesurer, probablement des dizaines de minutes,
   pas 10.
3. **Supprimer le hachage du programme par segment** : preuve de feuille sans
   bootloader, le programme étant lié dans le circuit feuille du wrapper.
   Chemin « standalone » cassé en amont pour les exécutables Scarb (S0) ;
   travail prouveur/wrapper lourd, à chiffrer avant de l'engager.

Sans décision, la prochaine vague utile reste O1 puis O3 (gain à gameplay
identique, moins de segments quel que soit le choix).

### En cours à la rédaction

Vague **O1** (worktree `wt/o1`, branche `wave/o1-actors`, inclut `6e0c0b0`) :
liste d'acteurs dérivée non sérialisée, itération du ticker sur ces indices,
reconstruction par tranches ; gain visé ≥ 13 000 steps/tic, équivalence exacte
exigée, mesure avant/après sur les cinq scénarios. Si elle n'est pas fusionnée
à la lecture de ce document, vérifier `git worktree list` et `git branch`.

### Reste à faire côté sponsor

1. Ouvrir une PR de suivi `codex/game-integration` (ou cette branche) → `main`
   sans la fusionner, pour obtenir CI et `game-regression` à chaque push.
2. Mesurer le task hash du nouveau `run_segment` après O1 et migrer
   `doomArtifacts.ts` ; vérifier que le job `cairo` tient en 16 Go (la suite
   `doom_game` seule approche 14 Go ; prévoir `RAYON_NUM_THREADS` réduit ou un
   découpage par filtre).
3. Trancher l'arbitrage C3 ci-dessus.

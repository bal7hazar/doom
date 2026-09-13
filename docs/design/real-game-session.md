# Session du jeu réel — audit du branchement client

État au 2026-09-13 : Worker Cairo et journal assemblés sur la branche du jeu
par `3e21031`, après revue indépendante et correction du cycle pagehide/pageshow.
Root a revalidé 386 tics exacts avec isolation et 386 sans isolation, reprise après
reload et interruption comprises, puis 209 tests client et six smokes Chromium
après fusion. Le contrôle du retour de page conservée utilise des événements
persisted synthétiques ; aucune admission BFCache réelle n’est revendiquée.

`main` utilise encore `stubSim`. La capture, les écrans et la sauvegarde utilisateur
sont assemblés par `8cf6d97` : 222 tests et neuf smokes après fusion, dont clavier/
souris et sauvegarde/reload/import exacts. Le rendu v1 des acteurs/HUD et l’adaptateur sont maintenant livrés (`f188fc8`,
`1b9816a`) et assemblés indépendamment par root : 243 tests et dix smokes verts.
Le raccord F4 réel est en cours ; les psprites animés nécessitent encore v2. Le défaut WASM S12 est corrigé et sa CI est
verte ; les budgets, le registre et P3.7 restent distincts de ce résultat.

Les écarts ci-dessous décrivent le point de départ de l’audit. Le journal avant
le premier tic, le Worker, le transport par transfert et le décodage des positions
sont désormais réalisés dans la branche d’intégration. Les flags bruts sont
conservés séparément, sans aliaser CORPSE avec TELEPORTED.

## Écarts vérifiés

| Interface | Code actuel | Travail nécessaire |
|---|---|---|
| Début de partie | `ProveSession` créée à l’ouverture F4 ; seuls les tics suivants sont enregistrés | Créer le journal et son identité avant le premier tic ; chargement du prouveur et panneau peuvent rester différés |
| Simulation | `TicScheduler` synchrone appelle `stubSim` sur le thread principal | Worker utilisant la continuation, commandes numérotées, interruption/reprise et pause sans tic ajouté |
| Arguments de preuve | `SegmentRequest` fournit `hIn` et les mots, sans état | Fournir le checkpoint sérialisé exact à `ticStart`, contrôler son identité/hash et rejouer les mots jusqu’à la frontière choisie |
| Positions | Le snapshot Cairo contient `Fixed.enc`, le renderer attend un entier fixe signé | Décoder explicitement `enc − 2^32` avec contrôle de domaine avant stockage dans le ring |
| Acteurs | Cairo émet `state`, `sprite`, `frame`, `doomednum` ; le renderer choisit une famille via `type` | Transporter la sprite réelle et sa table versionnée, y compris missiles et changements de famille d’animation |
| Flags | Bit 8 = `CORPSE` dans Cairo, `TELEPORTED` dans le ring ; bit 16 = missile côté Cairo | Adapter ou versionner les flags ; ne pas copier le masque brut |
| Arme | Cairo émet arme courante et `attackdown`, sans état/position complets des psprites | Exposer les données de rendu nécessaires depuis Cairo ; ne pas reconstruire la machine d’arme en JavaScript |
| Fin/pause | Le scheduler de démonstration publie deux tics au démarrage et autorise une vitesse variable | Publier l’état initial sans avancer le jeu ; clock 35 Hz, pause/reprise déterministe, fin sur le statut Cairo |

Les snapshots sont du rendu, pas des checkpoints de consensus. Une évolution explicite de
leur format peut être nécessaire sans changer le schéma d’état 2 ni les dix sorties D14.
Les tests actuels de snapshots devront alors garder leur version et leurs références
historiques ; une modification de format ne doit pas passer pour une optimisation équivalente.

## Flux à préserver

Le début de partie crée l’identité du programme, le journal vide et l’état genesis validé.
Chaque commande quantifiée D12 porte un numéro de tic. Le Worker accepte un mot, termine
son tic ou reprend son calcul interrompu, puis publie le snapshot et confirme le mot
effectivement consommé. Le journal ne contient ni commande inventée ni commande exécutée
deux fois. Une file bornée doit gérer le retard explicitement ; elle ne remplace pas des
inputs par des neutres et ne change pas la cadence de simulation.

Le renderer lit le ring sans attendre la preuve. Hors isolation, le transport doit être
explicite par messages transférables : deux ArrayBuffer indépendants ne constituent pas
un ring partagé. Le ring existant doit être testé sous un vrai producteur Worker, avec
rafraîchissement des vues après croissance WASM et contrôle des comptes avant publication.

Les checkpoints de maintenance permettent de recréer la VM et de reprendre une session.
Ils sont associés au programme, à la version d’état et au tic ; le journal conserve le
suffixe nécessaire au replay. Un export ou une reprise ne fait pas confiance au checkpoint
pour certifier un score : le programme prouvé recalcule les transitions et leurs hashes.

Le planificateur peut choisir une frontière différente des checkpoints de maintenance.
L’adaptateur de programme doit retrouver l’état exact de cette frontière puis encoder le
véritable `run_segment`. Un simple hash ne permet pas de le reconstituer. L’admission AIR
fraîche, le refus des anciens compteurs et la conservation du segment refusé restent requis.

## Validation de sortie

Les tests doivent couvrir journal démarré avant F4, pause/reprise, input reçu pendant un
quantum, erreur VM puis replay depuis checkpoint, fin réelle, fermeture/rechargement et
export/import. Sur les mêmes commandes, snapshots et états doivent correspondre au moteur
Cairo, y compris missiles, corps, portes, ramassage, dégâts et arme.

Une campagne navigateur avec contrôles et rendu mesure les latences, les tics réellement
avancés et la mémoire pendant une partie complète. La campagne suivante ajoute la preuve
concurrente sur matériel 16 GiB et mesure le temps résiduel C3. Le débit moyen du prototype
S10 ne clôt pas ces critères. Aucun défaut de registre, de preuve ou de budget n’est levé
par le seul branchement du Worker.

## Suite décidée après audit du rendu v1

Les acteurs v1 contiennent déjà sprite/frame/flags réels. La livraison `f188fc8`
corrige leur sélection et les sept familles absentes de l’atlas, ainsi que le HUD :
WeaponId compact 4 est la tronçonneuse, tandis que 4 désigne le lance-roquettes en
démonstration. Les métadonnées doivent correspondre au même tic que le ring et être
indexées par identifiant ; le mobj de la vue provient du player.mo de l’état validé,
pas d’un id zéro supposé. Aucun changement des pins ou du format v1 n’est nécessaire.

Les psprites animés exigent ensuite une projection Cairo explicite. L’audit propose
13 felts supplémentaires dans un harnais v2 isolé, avec coexistence v1 et migration
épinglée ; cette seconde livraison n’est pas encore implémentée. Le client ne doit
pas reconstruire les transitions d’arme en JavaScript. L’adaptateur de preuve reste
un chantier séparé, avec replay depuis genesis et refus AIR conservant le journal.

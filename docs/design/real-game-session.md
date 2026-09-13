# Session du jeu réel — audit du branchement client

État au 2026-09-13, après S10 et D33. La continuation Cairo est assemblée dans la
branche du jeu et vérifiée sur 386 tics ; le client `main` utilise encore `stubSim`.
Ce document fixe les interfaces à livrer pour P2.3/P2.4/P2.6. Il ne déclare pas ces
tâches terminées. La génération de preuve WASM du nouveau programme est en diagnostic.

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

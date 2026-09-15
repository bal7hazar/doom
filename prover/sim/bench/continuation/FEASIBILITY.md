# Faisabilité R5 — VM Cairo conservée

Base : 91719f8 ; cairo-vm 3.2.0 et cairo-lang-runner 2.19.4 épinglés.

La VM peut rester vivante entre deux tics. `CairoRunner` expose `vm`,
`exec_scopes`, `get_hint_data`, et `VirtualMachine::step` conserve pc/ap/fp,
les segments et les builtins. `run_until_pc` est seulement une boucle sur
cette même méthode : l'absence de reset n'empêche pas de suspendre une
exécution non terminée. Les hints peuvent être compilés une seule fois.

Voie retenue pour le prototype : boucle Cairo autonome qui charge une fois
le GameState validé et appelle le même `doom_game::step_tic`. Une cheatcode
`starknet::testing::cheatcode` sert de point d'échange explicite avec le
runner de simulation. Le host s'arrête AVANT son instruction quand aucune
entrée n'est disponible, puis fournit exactement un mot sur reprise. Chaque
mot est exécuté immédiatement ; le moteur produit son snapshot habituel.
Une demande distincte produit le schéma2 complet pour vérification ou
checkpoint, sans avancer le tic. Les entrypoints prouvés restent inchangés.

Le host ne calcule aucune règle de jeu. Ce chemin n'est pas un programme à
prouver : il fait confiance au transport des mots et aux points d'échange.
Les snapshots/états doivent être comparés avec l'exécutable stateless ; un
checkpoint externe doit repasser dans from_felts lors d'un nouveau chargement.
Les erreurs VM et limites d'exécution sont distinctes d'un ABORT du moteur.

Deuxième voie étudiée et écartée : transférer directement les pointeurs du
GameState d'une VM terminée à une VM neuve. Les pointeurs mènent à des
segments, dictionnaires et scopes de hints liés à la première VM ; il n'existe
pas de migration typée publique. Un copieur Rust de ce graphe engagerait la
représentation Cairo interne et ses trackers de dict. Ce serait nettement
plus fragile que conserver l'exécution, sans bénéfice démontré.

Risques du prototype : la mémoire Cairo est immuable et croît pendant une
session conservée ; il n'y a pas de GC de segments public. Mesurer les octets
par tic et borner le nombre de tics/steps est indispensable. Un checkpoint
avec recréation occasionnelle de VM ne regroupe pas les inputs, mais sa
latence doit être mesurée séparément. Le prototype doit aussi accepter une
interruption au milieu du calcul et reprendre sans réexécuter les hints ou
consommer deux fois un mot. Aucun objectif35Hz ne sera déclaré à partir des
seuls steps natifs : mesure Chromium Worker requise.

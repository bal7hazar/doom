# Hellproof

> *Knee-deep in proofs.* Un FPS « Doom-like » dont le cœur de jeu est écrit en Cairo, prouvé
> localement dans le navigateur avec Stwo, et vérifié on-chain sur Starknet.

Assets : [Freedoom](https://freedoom.github.io/) (BSD). Nom de code interne du dépôt : `doom`.
« DOOM » est une marque déposée qui n'est pas utilisée pour désigner ce produit.

## Documents

| Document | Contenu |
|---|---|
| [CONTEXT.md](CONTEXT.md) | Étude de faisabilité : état de l'art Stwo / Starknet / Doom, mesures, inconnues, sources |
| [PLAN.md](PLAN.md) | Plan d'exécution : décisions d'architecture, phases, tests, critères de validation |
| [RISKS.md](RISKS.md) | Analyse des risques et actions concrètes (`R<n>-A<m>`) |
| [ROADMAP.md](ROADMAP.md) | Roadmap : WBS, Gantt, chemin critique, parallélisation, orchestration |
| `docs/spikes/` | Notes de résultats des spikes S0–S6 |

## Licences

Apache-2.0 pour l'infrastructure, les crates génériques, le client et les contrats ;
GPL-2.0-only pour les crates dérivées de linuxdoom (`cairo/doom/*`) ; BSD pour les assets Freedoom.
Voir [PLAN.md](PLAN.md) A9 et [RISKS.md](RISKS.md) R9.

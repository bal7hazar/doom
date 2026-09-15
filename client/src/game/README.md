# Play session and controls

`/` (also `?sim=cairo`) opens the real Cairo game in pause at genesis. `?sim=demo`
retains the renderer demonstration and its existing proof harness. Start/Resume
is an explicit click; no input is sent before it. Click the view to retry mouse
capture if the browser refuses the first request; keyboard control remains usable.

| Input | Command |
|---|---|
| W/S or up/down | Forward/back, 25 units; Shift increases to 50 |
| A/D | Strafe, 24 units; Shift increases to 40 |
| Left/right | Turn; Shift increases turning speed |
| Locked mouse | Turn (32 BAM units per pixel, D12 quantization) |
| Left mouse / Ctrl | Fire (`BT_ATTACK = 1`) |
| E / Space | Use (`BT_USE = 2`) |
| 1–4 | Fist, pistol, shotgun, chaingun request |
| 7 | Chainsaw request (vanilla button code **7**, not compact WeaponId 4) |
| Esc / P | Pause and release the mouse |
| Tab | Automap |

Weapon requests use `BT_CHANGE = 4` and `code << 3`, matching the current Cairo
`WEAPON_OF_BUTTON` table. Ownership, attack state, movement, use and weapon
selection remain entirely in Cairo. Mouse deltas are bounded and consumed once
per sampled tic. Keyboard repeats cannot create repeated weapon requests. Pause,
blur, pointer unlock, hidden document and cached-page departure clear held inputs.
Input capture starts with the user's running intent, so keys pressed during the
Worker's initial resume acknowledgement are preserved for the first sampled tic.

The journal already exists before Start or F4; only acknowledged words enter it.
F4 never starts the demo prover in the real game. DEAD/EXIT/ABORT screens use the
actual operation status and Cairo counters. Animations remain explicitly incomplete;
this interface does not certify a score or change any consensus schema.

## Saving and restoration

Save writes **one explicit IndexedDB slot**, replacing its previous value only
when the transaction commits. There is no per-tic storage write and no automatic
save on exit. The interface tells the player to save before leaving and reports
quota/storage failures while preserving the live journal. Export downloads a
separate JSON file; Load save or Import restores in pause, also after reloading
the document. The save file is bounded to 8 MiB. Normal UI saves have a checkpoint
at the current tic; imports needing more than 256 replay inputs are rejected
before touching the VM. A recent checkpoint can be exported from the source run.

Save/export/restart/import are mutually exclusive. They stop the scheduler, allow
only an already submitted input to finish (at most 30 seconds), and then operate
on the exact acknowledged checkpoint. No fresh neutral word is injected. Import
checks executable hashes before initialization, validates the checkpoint through
Cairo, and recovers the previous exact run if Cairo rejects the imported state.
A recovered import is not written to the local slot automatically. Checkpoints
remain untrusted for proving: certification must replay and verify from genesis.

## Validation

Unit tests cover D12 keys/buttons, mouse bounds, loss of focus, resume and late
pointer-lock races, storage quotas, operation serialization and terminal labels.
Production Chromium tests cover actual keyboard changes in Cairo, exact save /
reload restoration, file import/export and identity rejection. Native pointer lock
is tested with a headed browser on this host:

```
HELLPROOF_POINTER_LOCK=1 npm exec -- playwright test e2e/controls.spec.ts --workers=1
```

Without that variable the dedicated native-lock test is explicitly skipped;
keyboard controls and save/reload tests still run headless. The local headless
Chromium rejects native pointer capture, also on a minimal independent page.
No synthetic assignment to `pointerLockElement` substitutes for the headed
integration test. Unit tests do use a DOM double to exercise late lock callbacks.

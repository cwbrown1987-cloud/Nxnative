# Blasphemous 2 (`010040801A4C8000`)

Update 1.0.8 (v524288), The Game Kitchen's Unity 2021.3.20f1 / IL2CPP game on NVN, SDK 15.3.2, with FMOD. The loaded modules are `main`, `subsdk0` (NintendoSDK_movie) and `sdk`. The supplied DLC NSP is licence-only and contains no game data.

On the Mac, the game boots through its opening into early combat. The HUD, enemies and attack effects render; a save is created. The route reached frame 11,700 with a final 300-frame p50 of 16.67 ms (p99 17.24 ms) and 2.9 GB resident memory. The iOS build has not been validated.

## Profile

- `game.tsv` records update 1.0.8 only; the base game and update 1.0.7 have not been separately validated.
- The NPDM declares 16 MB of system resource. The profile reserves a 5 GB guest address space with a 4.375 GB alias region; the Mac heap check found no game heap request and selected a 1 GB application pool.
- The RomFS contains 1,428 files (1.69 GB), mostly UnityFS bundles under `Data/StreamingAssets/`.

## Graphics

The shader split found 4,354 shaders: 2,178 pixel, 2,174 vertex, one geometry and one compute shader. The Mac route rendered the title, opening and an early combat scene; no missing-shader errors were reported on that route. The shader tables and compute-shader facts are the split output for update 1.0.8.

## Mac route

Start the Mac host with `DM_CTL` and advance through the opening into combat. The run reached frame 11,700, created save data, and rendered combat with its HUD and attack effects. The last 300-frame timing sample reported a 16.67 ms p50 and 17.24 ms p99. A second boot and save reload remain unchecked.

## Found on this game

- `main+0x1e86fc` branches through `br x18` to an indirect tail call; the same function has another code block after that branch in the linear disassembly. The rewriter now recognizes the tail call at the end of its basic block instead of requiring it to be the last instruction in the function: [Indirect tail calls through x18 in IL2CPP thunks](../../../docs/reference/rewriter.md#indirect-tail-calls-through-x18-in-il2cpp-thunks).

## Open

- Validate the iOS build, a second boot and save reload, the base build and update 1.0.7.

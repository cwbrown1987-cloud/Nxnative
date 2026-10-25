# Super Mario 3D All-Stars, program 0 (the launcher, 010049900F546000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py
# and applies those of a module's NSO build ID; CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
CUTS = {
  # 1.0.0 (v0) main: the menu's contents are 0-2 the games (Super Mario 64, Sunshine, Galaxy; program = content + 1, main+0xe710) and 3-5 their soundtracks. Galaxy's program is
  # 32-bit ARM, which Apple silicon cannot run, so its tile stays in the menu (artwork and text) but A does nothing on it. The menu's select state (main+0xf090) asks main+0xc040
  # each frame: "the selected tile can be decided (main+0xadc0) and A was just pressed (main+0x151e0)" → the decide action (main+0xaf90, the sound and animation) and true, after
  # which the next state starts the game or opens the soundtrack's player. The function is rewritten in its own 24 words (two of them padding) to read the selected content as
  # main+0xacf0 does (main+0x421d90, its vtable +0x10, the word at +4) and answer false for content 2 before deciding. Found with DM_PROBE on setNerve (main+0x421c40)
  'ff44f58218c6a6b22b24c3e1af680a7f': [
    (0xc040, 'f30f1ef8fd7b01a9fd430091f30300aa5cfbff97200100366224009460010036e00313aacbfbff97e0030032fd7b41a9f30742f8c0035fd6e0031f2afd7b41a9f30742f8c0035fd6e0031f2afd7b41a9f30742f8c0035fd60000000000000000',
     'f30f1ef8fd7b01a9fd430091f30300aa5cfbff97e001003662240094a0010036e00313aa4b571094080040f9080940f900013fd6080440b91f090071a0000054e00313aac3fbff972000805202000014e0031f2afd7b41a9f30742f8c0035fd6',
     'decide the selected tile on A (main+0xc040): also false when the selected content is 2 (Super Mario Galaxy, a 32-bit program)'),
  ],
}

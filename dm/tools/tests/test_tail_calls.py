"""Exercise indirect tail-call recognition when an unreachable block follows the br."""
import ast
from pathlib import Path
import re
import struct
import sys
import unittest

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

TOOLS = Path(__file__).resolve().parents[1]
tree = ast.parse((TOOLS / 'patch_nso.py').read_text())
body = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'tail_call']
scope = {'re': re}
exec(compile(ast.Module(body=body, type_ignores=[]), str(TOOLS / 'patch_nso.py'), 'exec'), scope)


def instructions(words):
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    md.detail = True
    ins = list(md.disasm(struct.pack('<' + 'I' * len(words), *words), 0))
    if len(ins) != len(words):
        raise AssertionError(f'decoded {len(ins)} of {len(words)} instructions')
    return ins


class TailCall(unittest.TestCase):
    def test_branch_can_be_followed_by_another_block(self):
        # cbz reaches the second block; the br is still the terminal instruction
        # of the first block, even though the function disassembly continues.
        self.assertTrue(scope['tail_call'](instructions([
            0xb4000061,  # cbz x1, #12
            0xf9400812,  # ldr x18, [x0, #0x10]
            0xd61f0240,  # br x18
            0x94000000,  # bl #0 (the other block)
        ]), 2))

    def test_table_dispatch_is_not_a_tail_call(self):
        self.assertFalse(scope['tail_call'](instructions([
            0xb9400000,  # ldr w0, [x0]
            0x8b000252,  # add x18, x18, x0
            0xd61f0240,  # br x18
        ]), 2))


if __name__ == '__main__':
    unittest.main()

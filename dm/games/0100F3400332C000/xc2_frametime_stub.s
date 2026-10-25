.text
stub:
  sub  sp, sp, #0x60
  stp  x0, x1, [sp]
  str  x2, [sp, #0x10]
  mrs  x0, nzcv
  str  x0, [sp, #0x18]
  stp  q0, q1, [sp, #0x20]
  str  q2, [sp, #0x40]
  adrp x2, 0               // [9] state page
  ldr  s1, [x2, #0x4c]
  fcmp s1, #0.0
  b.eq off
  mrs  x0, cntvct_el0
  ldr  x1, [x2, #0x40]
  str  x0, [x2, #0x40]
  cbz  x1, done
  sub  x0, x0, x1
  ucvtf d0, x0
  mrs  x1, cntfrq_el0
  ucvtf d1, x1
  fdiv d0, d0, d1
  fcvt s0, d0
  fmov s2, #1.0
  fdiv s2, s2, s1
  fcmp s0, s2
  b.ge 1f
  fmov s0, s2
1:
  fadd s2, s2, s2
  fcmp s0, s2
  b.le 2f
  fmov s0, s2
2:
  str  s0, [x2, #0x38]
  adrp x0, 0               // [33] 0xb90000
  ldr  x0, [x0, #0xd0]
  cbz  x0, 3f
  ldr  w1, [x0, #0x78]      // only while the field holds a frame time (0.001 .. 0.5 s): at the title the global is another object
  mov  w2, #0x126f
  movk w2, #0x3a83, lsl #16
  cmp  w1, w2
  b.lo 3f
  mov  w2, #0x3f000000
  cmp  w1, w2
  b.hi 3f
  str  s0, [x0, #0x78]
  str  s0, [x0, #0x7c]
3:
  adrp x0, 0               // [38] 0xc23000
  ldr  x0, [x0, #0x2c8]
  cbz  x0, done
  str  s0, [x0, #0x80]
  b    done
off:
  mov  w0, #0x8889
  movk w0, #0x3d08, lsl #16
  str  w0, [x2, #0x38]
  str  xzr, [x2, #0x40]
done:
  ldr  x0, [sp, #0x18]
  msr  nzcv, x0
  ldp  q0, q1, [sp, #0x20]
  ldr  q2, [sp, #0x40]
  ldp  x0, x1, [sp]
  ldr  x2, [sp, #0x10]
  add  sp, sp, #0x60
  mov  w8, #0x21a0
  ret

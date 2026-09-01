//
//  kernel.s
//  16Forth
//
//  Minimal 64Forth-derived kernel — memory data stack (no TOS-in-register)
//
//  ARM64 (Apple Silicon) — clang / Xcode
//
//  Registers:
//    x19 = IP
//    x21 = W
//    x22 = DSP  (points AT TOS cell in memory; empty stack = &data_stack[DSTACK_SIZE])
//    x23 = RSP
//    x24 = &latest
//    x20 = scratch only — NOT TOS
//
//  Dictionary header (grows up from HERE):
//    HFA: counted HELP + pad 8
//    NFA: counted NAME (uppercase) + pad 8
//    LFA: previous CFA              @ CFA-16
//    FFA: flags                     @ CFA-8
//         bits 0-15  NFA_OFF, 16-31 HFA_OFF, bit 63 IMMEDIATE
//    CFA: code pointer (xt)
//    BODY @ CFA+8   (CREATE: does_ip @ CFA+8, PFA @ CFA+16)
//
// ============================================================================
// DATA STACK RULE
// ============================================================================
// The data stack lives entirely in memory.
//   DPUSH xn    stores xn and pre-decrements x22
//   DPOP  xn    loads xn and post-increments x22
// Peeking TOS is:  ldr xn, [x22]
// There is no hidden DUP. Every consume is an explicit DPOP.
// ============================================================================

.equ CELL, 8
.equ DSTACK_SIZE, 8192
.equ RSTACK_SIZE, 4096
.equ FL_IMM,     1
.equ FL_INLINE,  2
.equ FFA_INLINE, 62              // FFA bit 62
// Search-Order: heads per wid (1 = single chain; raise later for hashing).
.equ DICT_THREADS, 1
.equ WORDLIST_REG_MAX, 128
.equ SEARCH_ORDER_MAX, 8

// NEXT — inner interpreter dispatch
// Typical M-series, L1 I/D hit, predicted indirect branch:
//   ~7–11 cycles wall, 3 issued memory ops + 1 indirect branch
//
.macro NEXT
    ldr  x21, [x19], #8     // 1  load xt from threaded list (IP), writeback IP
                            //    AGU + L1: often 4-cycle load-to-use for x21
                            //    post-index +8 is free on the load
    ldr  x1,  [x21]         // 2  load code address from CFA
                            //    cannot start until x21 ready → ~4 cycle stall
                            //    after 1 if back-to-back, L1 hit ~4 more
    br   x1                 // 3  indirect jump to primitive
                            //    predicted: ~1–3 cycles after x1 ready
                            //    mispredict: ~10–20+ cycles (pipeline flush)
.endm

.macro DPUSH reg
    str  \reg, [x22, #-8]!  // 1  store TOS-to-be at [DSP-8], DSP -= 8
                            //    pre-index writeback is free on the store
                            //    L1 store: typically 1 issued cycle;
                            //    store-to-load forward later ~4c if next DPOP
                            //    same address soon
.endm                       // ~1c issue; not on NEXT's load chain

.macro DPOP reg
    ldr  \reg, [x22], #8    // 1  load from [DSP], DSP += 8
                            //    post-index writeback is free on the load
                            //    L1 hit: ~4c load-to-use for \reg
                            //    miss: tens of cycles
.endm                       // ~4c to first use of \reg (L1 hit)

.macro RPUSH
    str  x19, [x23, #-8]!
.endm

.macro RPOP
    ldr  x19, [x23], #8
.endm

// Preserve AAPCS64 callee-saved regs — Forth uses x19–x24 as VM state.
.macro SAVE_C_CALLEE
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    stp  x27, x28, [sp, #80]
.endm

.macro RESTORE_C_CALLEE
    ldp  x27, x28, [sp, #80]
    ldp  x25, x26, [sp, #64]
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #96
.endm

.macro BOOT_WORD name, help, imm, code
    .pushsection __DATA,__bootword,regular
    .quad .Lname_\@, .Lhelp_\@, \imm, \code
    .popsection
    .pushsection __TEXT,__cstring,cstring_literals
.Lname_\@:  .asciz "\name"
.Lhelp_\@:  .asciz "\help"
    .popsection
.endm

// ============================================================================
// Data
// ============================================================================
.section __DATA,__data
.align 3
data_stack:     .skip DSTACK_SIZE
return_stack:   .skip RSTACK_SIZE
.equ USER_DICT_SIZE, 8*1024*1024   // 8 MiB — matrix benchmarks need ~1 MiB data
user_dict:      .skip USER_DICT_SIZE
input_buffer:   .skip 2048
name_buf:       .skip 256

.align 3
here_ptr:       .quad user_dict
noname_xt:      .quad 0            // :NONAME CFA; ; pushes then clears
// FORTH-WORDLIST = &latest_var (DICT_THREADS head cells)
latest_var:     .quad 0
                .space (DICT_THREADS - 1) * 8
current_var:    .quad 0          // compilation wid
search_order:   .space SEARCH_ORDER_MAX * 8
search_order_n: .quad 0
wordlist_reg:   .space WORDLIST_REG_MAX * 8
wordlist_reg_n: .quad 0
// TRAVERSE-WORDLIST visitor return: IP → tw_continue_cell → tw_continue_cfa → XTW_CONTINUE
tw_continue_cfa:  .quad 0
tw_continue_cell: .quad 0
state_var:      .quad 0
base_var:       .quad 10
last_cfa:       .quad 0
source_addr:    .quad 0
source_len:     .quad 0
to_in:          .quad 0
word_addr:      .quad 0
cfa_lit:        .quad 0
cfa_exit:       .quad 0
cfa_comma:      .quad 0
cfa_does_rt:    .quad 0
cfa_slit:       .quad 0
cfa_branch:     .quad 0
cfa_0branch:    .quad 0
cfa_do:         .quad 0
cfa_qdo:        .quad 0
cfa_loop:       .quad 0
cfa_plusloop:   .quad 0
quit_ready:     .quad 0
interp_lr:      .quad 0
in_interpret:   .quad 0          // 1 while _interpret_run is active
embed_mode:     .quad 0          // 1 = GUI/host eval (QUIT/ABORT return to C, no readline)
embed_c_sp:     .quad 0          // C SP after SAVE_C_CALLEE in kernel_eval (abort unwind)
.align 3
timeval_buf:    .quad 0, 0       // gettimeofday scratch (avoid SP timeval)
timespec_buf:   .quad 0, 0       // nanosleep scratch
ms_remain:      .quad 0          // MS remaining ms across nanosleep
pending_help_addr: .quad 0       // SETDOC / DOC" → next : / N: / CREATE
pending_help_len:  .quad 0
.align 3
pending_help_buf:  .space 256    // NUL-terminated copy for _header_build
source_id_var:  .quad 0          // 0=user/eval, -1=EVALUATE, 1=malloc INCLUDE, 2=host INCLUDE
.equ SRC_MAX, 8
.equ SRC_FRAME, 40               // addr,len,>IN,id,file_echo_pos
.equ SRCID_EVAL, -1
.equ SRCID_MALLOC, 1
.equ SRCID_HOST, 2
source_sp:      .quad 0
file_echo_pos:  .quad 0
file_echo_var:  .quad 0          // FILE-ECHO variable cell
repl_batch_stop: .quad 0
.align 3
source_stack:   .space (SRC_MAX * SRC_FRAME)
.equ INCL_MAX, 64
.equ INCL_NAME, 256
included_count: .quad 0
.align 3
included_names: .space (INCL_MAX * INCL_NAME)  // counted strings
include_path_len: .quad 0        // pending path length in name_buf
resolve_key_buf: .space INCL_NAME
file_o1:        .quad 0
file_o2:        .quad 0
// Host hooks (INCLUDE / FROMLIB / cwd)
load_file_hook:     .quad 0
resolve_key_hook:   .quad 0
last_load_key_hook: .quad 0
fromlib_hook:       .quad 0
fromlib_clear_hook: .quad 0
end_include_hook:   .quad 0
chdir_hook:         .quad 0
pwd_hook:           .quad 0
dir_hook:           .quad 0
inline_var:         .quad 0      // 0 = no expand; -1 = expand inlineable + native-convert unsafe
compiling_native:   .quad 0      // -1 while emitting whole-word native (convert at ;)
warnings_var:       .quad 0      // -1 = warn when EXIT appears in a definition
colon_no_inline:    .quad 0      // -1 = N: — never set FL_INLINE
dcolon_flag:        .quad 0      // -1 = ;/ABORT should restore INLINE? from dcolon_saved
dcolon_saved:       .quad 0      // INLINE? value saved by D:
// Macro expand: map source cell addr → output cursor; fixups for branches.
// Nested expand saves the full map/fix arrays (not only counts) on the C
// stack so inner FILL→1+ expand cannot clobber the outer BRANCH reloc table.
.equ MEX_MAP_MAX, 128
.equ MEX_FIX_MAX, 64
.equ MEX_MAP_BYTES, (MEX_MAP_MAX * 16)
.equ MEX_FIX_BYTES, (MEX_FIX_MAX * 16)
.equ MEX_SAVE_BYTES, (MEX_MAP_BYTES + MEX_FIX_BYTES)
mex_map_n:          .quad 0
mex_fix_n:          .quad 0
mex_map:            .space MEX_MAP_BYTES    // [old, new] …
mex_fix:            .space MEX_FIX_BYTES    // [patch, old_target] …
emit_hook:          .quad 0      // void (*)(int c)
emit_buf_hook:      .quad 0      // void (*)(const char *buf, size_t n)
vm_dsp:             .quad 0      // saved DSP across C returns (embed host)
vm_rsp:             .quad 0      // saved RSP across C returns
code_here:      .quad 0          // next free byte in the JIT buffer

.align 3
restart_cfa:    .quad XRESTART
restart_cell:   .quad restart_cfa
// Trampoline IP for returning from ITC word called from JIT (_native_exec_xt).
native_ret_xt:  .quad XNATIVE_RET
native_ret_ip:  .quad native_ret_xt

.section __DATA,__bootword,regular
.align 3
boot_word_table:

// ============================================================================
// 16 inner CODE primitives
// ============================================================================
.text
.align 4

BOOT_WORD "EXIT", "EXIT ( -- ) return from colon definition", 0, XEXIT
XEXIT:
    RPOP
    NEXT

BOOT_WORD "LIT", "LIT ( -- n ) push inline literal", 0, XLIT
XLIT:
    ldr  x0, [x19], #8
    DPUSH x0
    NEXT

BOOT_WORD "BRANCH", "BRANCH ( -- ) jump by relative offset cell", 0, XBRANCH
XBRANCH:
    ldr  x0, [x19]
    add  x19, x19, x0
    NEXT

BOOT_WORD "0BRANCH", "0BRANCH ( f -- ) relative jump if TOS false", 0, X0BRANCH
X0BRANCH:
    DPOP x0
    cbz  x0, 1f
    add  x19, x19, #8
    NEXT
1:  ldr  x0, [x19]
    add  x19, x19, x0
    NEXT

BOOT_WORD "EXECUTE", "EXECUTE ( xt -- ) run xt", 0, XEXECUTE
XEXECUTE:
    DPOP x0
    mov  x21, x0
    ldr  x1, [x21]
    br   x1

BOOT_WORD "@", "@ ( a -- n )", FL_INLINE, XFETCH
XFETCH:
    ldr  x0, [x22]
    ldr  x0, [x0]
    str  x0, [x22]
XFETCH_END:
    NEXT

BOOT_WORD "!", "! ( n a -- )", FL_INLINE, XSTORE
XSTORE:
    DPOP x1                     // a
    DPOP x0                     // n
    str  x0, [x1]
XSTORE_END:
    NEXT

BOOT_WORD "+", "+ ( n1 n2 -- n3 )", FL_INLINE, XPLUS
XPLUS:
    DPOP x0                     // n2
    ldr  x1, [x22]              // n1
    add  x1, x1, x0
    str  x1, [x22]
XPLUS_END:
    NEXT

BOOT_WORD "-", "- ( n1 n2 -- n3 )", FL_INLINE, XMINUS
XMINUS:
    DPOP x0                     // n2
    ldr  x1, [x22]              // n1
    sub  x1, x1, x0
    str  x1, [x22]
XMINUS_END:
    NEXT

BOOT_WORD "*", "* ( n1 n2 -- n3 )", FL_INLINE, XMUL
XMUL:
    DPOP x0
    ldr  x1, [x22]
    mul  x1, x1, x0
    str  x1, [x22]
XMUL_END:
    NEXT

BOOT_WORD "/", "/ ( n1 n2 -- n3 )", FL_INLINE, XDIV
XDIV:
    DPOP x0
    ldr  x1, [x22]
    sdiv x1, x1, x0
    str  x1, [x22]
XDIV_END:
    NEXT

BOOT_WORD "DUP", "DUP ( n -- n n )", FL_INLINE, XDUP
XDUP:
    ldr  x0, [x22]
    DPUSH x0
XDUP_END:
    NEXT

BOOT_WORD "DROP", "DROP ( n -- )", FL_INLINE, XDROP
XDROP:
    DPOP x0
XDROP_END:
    NEXT

BOOT_WORD "SWAP", "SWAP ( n1 n2 -- n2 n1 )", FL_INLINE, XSWAP
XSWAP:
    ldr  x0, [x22]
    ldr  x1, [x22, #8]
    str  x1, [x22]
    str  x0, [x22, #8]
XSWAP_END:
    NEXT

BOOT_WORD "OVER", "OVER ( n1 n2 -- n1 n2 n1 )", FL_INLINE, XOVER
XOVER:
    ldr  x0, [x22, #8]
    DPUSH x0
XOVER_END:
    NEXT

BOOT_WORD "EMIT", "EMIT ( c -- )", 0, XEMIT
XEMIT:
    DPOP x0
    stp  x19, x21, [sp, #-32]!
    stp  x22, x23, [sp, #16]
    bl   _putchar
    ldp  x22, x23, [sp, #16]
    ldp  x19, x21, [sp], #32
    NEXT

BOOT_WORD "ABORT", "ABORT ( i*x -- ) empty stacks, then QUIT", 0, XABORT
XABORT:
    b    _abort

BOOT_WORD "QUIT", "QUIT ( -- ) empty return stack, interpret; embed returns to host", 0, XQUIT
XQUIT:
    b    _do_quit

// ============================================================================
// Bootstrap compiler / dictionary words
// ============================================================================

BOOT_WORD "HERE", "HERE ( -- addr ) next dictionary byte", 0, XHERE
XHERE:
    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD ",", ", ( n -- ) compile cell", 0, XCOMMA
XCOMMA:
    DPOP x0
    bl   _compile_cell
    NEXT

BOOT_WORD "ALLOT", "ALLOT ( n -- ) advance HERE", 0, XALLOT
XALLOT:
    DPOP x0
    adrp x1, here_ptr@page
    add  x1, x1, here_ptr@pageoff
    ldr  x2, [x1]
    add  x2, x2, x0
    str  x2, [x1]
    NEXT

BOOT_WORD "STATE", "STATE ( -- addr ) compile-state variable", 0, XSTATE
XSTATE:
    adrp x0, state_var@page
    add  x0, x0, state_var@pageoff
    DPUSH x0
    NEXT

BOOT_WORD "LATEST", "LATEST ( -- addr ) FORTH wordlist head array", 0, XLATEST
XLATEST:
    adrp x0, latest_var@page
    add  x0, x0, latest_var@pageoff
    DPUSH x0
    NEXT

BOOT_WORD "LAST", "LAST ( -- xt ) CFA of most recently defined word", 0, XLAST
XLAST:
    adrp x0, last_cfa@page
    add  x0, x0, last_cfa@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD "CURRENT", "CURRENT ( -- addr ) compilation wordlist variable", 0, XCURRENT
XCURRENT:
    adrp x0, current_var@page
    add  x0, x0, current_var@pageoff
    DPUSH x0
    NEXT

BOOT_WORD "IMMEDIATE", "IMMEDIATE ( -- ) mark latest immediate", 0, XIMMEDIATE
XIMMEDIATE:
    adrp x0, last_cfa@page
    add  x0, x0, last_cfa@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    ldr  x1, [x0, #-8]
    mov  x2, #1
    lsl  x2, x2, #63
    orr  x1, x1, x2
    str  x1, [x0, #-8]
1:  NEXT

BOOT_WORD ":", ": ( \"name\" -- ) start colon definition", 0, XCOLON
XCOLON:
    mov  x20, #0                     // allow auto FL_INLINE at ;
    b    _colon_common

// N: — like :, but never marked inlineable (opt-out for large / identity-sensitive words).
BOOT_WORD "N:", "N: ( \"name\" -- ) colon that is never macro-expanded", 0, XNCOLON
XNCOLON:
    mov  x20, #1                     // colon_no_inline
    b    _colon_common

// D: — define with INLINE temporarily off (no expand / no native-convert), restore on ; / ABORT.
BOOT_WORD "D:", "D: ( \"name\" -- ) colon with INLINE off until ;", 0, XDCOLON
XDCOLON:
    adrp x0, dcolon_flag@page
    add  x0, x0, dcolon_flag@pageoff
    ldr  x1, [x0]
    cbnz x1, 1f                      // already in D: — just start colon
    adrp x1, inline_var@page
    add  x1, x1, inline_var@pageoff
    ldr  x2, [x1]
    adrp x3, dcolon_saved@page
    add  x3, x3, dcolon_saved@pageoff
    str  x2, [x3]
    str  xzr, [x1]                   // INLINE-OFF for this definition
    mov  x2, #-1
    str  x2, [x0]                    // pending restore
1:  mov  x20, #0
    b    _colon_common

_colon_common:
    // Named colon clears any pending :NONAME xt.
    adrp x0, noname_xt@page
    add  x0, x0, noname_xt@pageoff
    str  xzr, [x0]
    // N: → colon_no_inline; : / D: clear it.
    adrp x0, colon_no_inline@page
    add  x0, x0, colon_no_inline@pageoff
    cbz  x20, 0f
    mov  x1, #-1
    str  x1, [x0]
    b    01f
0:  str  xzr, [x0]
01: bl   _word
    cbz  x0, _colon_fail
    bl   _counted_to_cstr            // x0 = name cstr
    bl   _take_pending_help          // x1 = help cstr (preserves x0, x3)
    mov  x2, xzr                     // never set FL_INLINE at create — ; decides
    adrp x3, DOCOL@page
    add  x3, x3, DOCOL@pageoff
    bl   _header_build
    // Always compile the body threaded; INLINE-ON may convert at ; if not inlineable.
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    str  xzr, [x0]
    adrp x0, state_var@page
    add  x0, x0, state_var@pageoff
    mov  x1, #-1
    str  x1, [x0]
    NEXT

// :NONAME — anonymous colon; ; leaves xt. Always threaded (POSTPONE-friendly).
BOOT_WORD ":NONAME", ":NONAME ( C: -- ) ( -- xt ) start anonymous colon; ; leaves xt", 0, XNONAME
XNONAME:
    adrp x0, empty_name@page
    add  x0, x0, empty_name@pageoff
    bl   _take_pending_help          // x1 = help
    mov  x2, #0
    adrp x3, DOCOL@page
    add  x3, x3, DOCOL@pageoff
    bl   _header_build
    adrp x0, last_cfa@page
    add  x0, x0, last_cfa@pageoff
    ldr  x0, [x0]
    adrp x1, noname_xt@page
    add  x1, x1, noname_xt@pageoff
    str  x0, [x1]
    adrp x0, colon_no_inline@page
    add  x0, x0, colon_no_inline@pageoff
    str  xzr, [x0]
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    str  xzr, [x0]
    adrp x0, state_var@page
    add  x0, x0, state_var@pageoff
    mov  x1, #-1
    str  x1, [x0]
    NEXT

BOOT_WORD ";", "; ( -- ) end colon definition", FL_IMM, XSEMI
XSEMI:
    // Always plant trailing EXIT into the threaded body (no EXIT warning).
    adrp x0, cfa_exit@page
    add  x0, x0, cfa_exit@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    str  xzr, [x0]
    // :NONAME: no auto-inline / native-convert
    adrp x0, noname_xt@page
    add  x0, x0, noname_xt@pageoff
    ldr  x0, [x0]
    cbnz x0, 2f
    bl   _colon_finish_inline
2:  // STATE = 0
    adrp x0, state_var@page
    add  x0, x0, state_var@pageoff
    str  xzr, [x0]
    // D: restore previous INLINE?
    adrp x0, dcolon_flag@page
    add  x0, x0, dcolon_flag@pageoff
    ldr  x1, [x0]
    cbz  x1, 3f
    str  xzr, [x0]
    adrp x0, dcolon_saved@page
    add  x0, x0, dcolon_saved@pageoff
    ldr  x1, [x0]
    adrp x0, inline_var@page
    add  x0, x0, inline_var@pageoff
    str  x1, [x0]
3:  // :NONAME → leave xt
    adrp x0, noname_xt@page
    add  x0, x0, noname_xt@pageoff
    ldr  x1, [x0]
    cbz  x1, 4f
    str  xzr, [x0]
    DPUSH x1
4:  NEXT

BOOT_WORD "INLINE?", "INLINE? ( -- addr )", 0, XINLINEQ
XINLINEQ:
    adrp x0, inline_var@page
    add  x0, x0, inline_var@pageoff
    DPUSH x0
    NEXT

BOOT_WORD "WARNINGS?", "WARNINGS? ( -- addr ) EXIT-in-definition warning flag", 0, XWARNINGSQ
XWARNINGSQ:
    adrp x0, warnings_var@page
    add  x0, x0, warnings_var@pageoff
    DPUSH x0
    NEXT

BOOT_WORD "IF", "IF ( f -- )", FL_IMM, XIF
XIF:
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    // native: DPOP x0 ; cbz x0, hole
    movz x0, #0x86C0
    movk x0, #0xF840, lsl #16       // ldr x0,[x22],#8
    bl   _emit_u32
    adrp x1, code_here@page
    add  x1, x1, code_here@pageoff
    ldr  x0, [x1]                   // addr of forthcoming cbz
    movz x2, #0x0000
    movk x2, #0xB400, lsl #16       // cbz x0, .+0
    stp  x0, xzr, [sp, #-16]!
    mov  x0, x2
    bl   _emit_u32
    ldr  x0, [sp], #16
    DPUSH x0                        // orig for THEN
    NEXT
1:  // threaded
    adrp x0, cfa_0branch@page
    add  x0, x0, cfa_0branch@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    adrp x1, here_ptr@page
    add  x1, x1, here_ptr@pageoff
    ldr  x0, [x1]
    DPUSH x0
    mov  x0, #0
    bl   _compile_cell
    NEXT

BOOT_WORD "THEN", "THEN ( addr -- )", FL_IMM, XTHEN
XTHEN:
    DPOP x1                         // hole
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x0, [x0]
    bl   _patch_rel
    NEXT
1:  // threaded: store relative dest-hole at hole
    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x0, [x0]
    sub  x0, x0, x1
    str  x0, [x1]
    NEXT

BOOT_WORD "ELSE", "ELSE ( addr -- addr )", FL_IMM, XELSE
XELSE:
    adrp x3, compiling_native@page
    add  x3, x3, compiling_native@pageoff
    ldr  x3, [x3]
    cbz  x3, 1f

    // ---- native ----
    adrp x2, code_here@page
    add  x2, x2, code_here@pageoff
    ldr  x0, [x2]
    DPUSH x0                        // &B before emit
    movz x0, #0x0000
    movk x0, #0x1400, lsl #16       // b .+0
    bl   _emit_u32
    DPOP x4                         // &B
    DPOP x1                         // IF’s cbz
    str  x4, [sp, #-16]!
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x0, [x0]                   // dest = after B
    bl   _patch_rel
    ldr  x0, [sp], #16
    DPUSH x0                        // &B for THEN
    NEXT

1:  // ---- threaded (relative offsets) ----
    adrp x0, cfa_branch@page
    add  x0, x0, cfa_branch@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    adrp x1, here_ptr@page
    add  x1, x1, here_ptr@pageoff
    ldr  x0, [x1]
    DPUSH x0                        // new hole
    mov  x0, #0
    bl   _compile_cell
    DPOP x0                         // new
    DPOP x1                         // old IF hole
    adrp x2, here_ptr@page
    add  x2, x2, here_ptr@pageoff
    ldr  x2, [x2]
    sub  x2, x2, x1                 // relative: else_start - if_hole
    str  x2, [x1]
    DPUSH x0                        // leave ELSE hole for THEN
    NEXT
    
BOOT_WORD "BEGIN", "BEGIN ( -- addr )", FL_IMM, XBEGIN
XBEGIN:
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT
1:  adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD "AGAIN", "AGAIN ( addr -- )", FL_IMM, XAGAIN
XAGAIN:
    DPOP x1                         // dest
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x0, [x0]                   // addr of forthcoming B
    str  x1, [sp, #-16]!
    movz x2, #0x0000
    movk x2, #0x1400, lsl #16
    str  x0, [sp, #-16]!
    mov  x0, x2
    bl   _emit_u32
    ldr  x1, [sp], #16              // instr
    ldr  x0, [sp], #16              // dest
    bl   _patch_rel
    NEXT
1:  adrp x0, cfa_branch@page
    add  x0, x0, cfa_branch@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x0, [x0]                   // offset cell addr
    sub  x0, x1, x0                 // relative: dest - hole
    bl   _compile_cell
    NEXT

BOOT_WORD "UNTIL", "UNTIL ( addr -- )", FL_IMM, XUNTIL
XUNTIL:
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f

    movz x0, #0x86C0
    movk x0, #0xF840, lsl #16       // ldr x0, [x22], #8
    bl   _emit_u32

    adrp x2, code_here@page
    add  x2, x2, code_here@pageoff
    ldr  x0, [x2]                   // x0 = &cbz (not yet emitted)
    DPOP x1                         // x1 = BEGIN dest
    stp  x0, x1, [sp, #-16]!        // save &cbz, dest

    movz x0, #0x0000
    movk x0, #0xB400, lsl #16       // cbz x0, .+0
    bl   _emit_u32

    ldp  x1, x0, [sp], #16          // x1 = &cbz, x0 = dest
    bl   _patch_rel
    NEXT

1:  adrp x0, cfa_0branch@page
    add  x0, x0, cfa_0branch@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    DPOP x1                         // BEGIN dest
    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x0, [x0]
    sub  x0, x1, x0                 // relative
    bl   _compile_cell
    NEXT

BOOT_WORD "WHILE", "WHILE ( orig -- orig hole ) leave if false", FL_IMM, XWHILE
XWHILE:
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    // native: same as IF, then SWAP with BEGIN dest → (hole dest)
    movz x0, #0x86C0
    movk x0, #0xF840, lsl #16       // ldr x0,[x22],#8
    bl   _emit_u32
    adrp x1, code_here@page
    add  x1, x1, code_here@pageoff
    ldr  x0, [x1]                   // &cbz
    movz x2, #0x0000
    movk x2, #0xB400, lsl #16       // cbz x0, .+0
    stp  x0, xzr, [sp, #-16]!
    mov  x0, x2
    bl   _emit_u32
    ldr  x0, [sp], #16              // hole
    DPUSH x0
    ldr  x0, [x22]
    ldr  x1, [x22, #8]
    str  x1, [x22]
    str  x0, [x22, #8]
    NEXT
1:  // threaded: IF then SWAP
    adrp x0, cfa_0branch@page
    add  x0, x0, cfa_0branch@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    adrp x1, here_ptr@page
    add  x1, x1, here_ptr@pageoff
    ldr  x0, [x1]
    DPUSH x0
    mov  x0, #0
    bl   _compile_cell
    ldr  x0, [x22]
    ldr  x1, [x22, #8]
    str  x1, [x22]
    str  x0, [x22, #8]
    NEXT

BOOT_WORD "REPEAT", "REPEAT ( hole dest -- )", FL_IMM, XREPEAT
XREPEAT:
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    // native: B to BEGIN (AGAIN), then patch WHILE cbz to here (THEN)
    DPOP x1                         // dest = BEGIN
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x0, [x0]                   // &B
    str  x1, [sp, #-16]!
    movz x2, #0x0000
    movk x2, #0x1400, lsl #16       // b .+0
    str  x0, [sp, #-16]!
    mov  x0, x2
    bl   _emit_u32
    ldr  x1, [sp], #16              // instr
    ldr  x0, [sp], #16              // dest
    bl   _patch_rel
    DPOP x1                         // WHILE hole
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x0, [x0]
    bl   _patch_rel
    NEXT
1:  // threaded: AGAIN then THEN (relative)
    adrp x0, cfa_branch@page
    add  x0, x0, cfa_branch@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    DPOP x1                         // BEGIN dest
    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x0, [x0]
    sub  x0, x1, x0
    bl   _compile_cell
    DPOP x1                         // WHILE hole
    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x0, [x0]
    sub  x0, x0, x1
    str  x0, [x1]
    NEXT

// DO ( -- 0 dest )  plant (DO) or native setup; dest = body start
BOOT_WORD "DO", "DO ( C: -- 0 dest ) compile DO loop", FL_IMM, XDO
XDO:
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    adrp x0, native_do_setup@page
    add  x0, x0, native_do_setup@pageoff
    adrp x1, native_do_setup_end@page
    add  x1, x1, native_do_setup_end@pageoff
    sub  x1, x1, x0
    bl   _emit_bytes
    mov  x0, #0
    DPUSH x0                        // no forward hole
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x0, [x0]
    DPUSH x0                        // dest
    NEXT
1:  adrp x0, cfa_do@page
    add  x0, x0, cfa_do@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    mov  x0, #0
    DPUSH x0
    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

// ?DO ( -- orig dest )  plant (?DO)+hole or native qdo; orig = skip hole
BOOT_WORD "?DO", "?DO ( C: -- orig dest ) compile ?DO loop", FL_IMM, XQDO
XQDO:
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    // native: pop index/limit; b.eq hole; RPUSH
    movz x0, #0x86C1
    movk x0, #0xF840, lsl #16       // ldr x1,[x22],#8
    bl   _emit_u32
    movz x0, #0x86C0
    movk x0, #0xF840, lsl #16       // ldr x0,[x22],#8
    bl   _emit_u32
    movz x0, #0x001F
    movk x0, #0xEB01, lsl #16       // cmp x0,x1
    bl   _emit_u32
    adrp x2, code_here@page
    add  x2, x2, code_here@pageoff
    ldr  x0, [x2]
    DPUSH x0                        // orig = &b.eq
    movz x0, #0x0000
    movk x0, #0x5400, lsl #16       // b.eq
    bl   _emit_u32
    movz x0, #0x8EE0
    movk x0, #0xF81F, lsl #16       // str x0,[x23,#-8]!
    bl   _emit_u32
    movz x0, #0x8EE1
    movk x0, #0xF81F, lsl #16       // str x1,[x23,#-8]!
    bl   _emit_u32
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x0, [x0]
    DPUSH x0                        // dest
    NEXT
1:  adrp x0, cfa_qdo@page
    add  x0, x0, cfa_qdo@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    adrp x1, here_ptr@page
    add  x1, x1, here_ptr@pageoff
    ldr  x0, [x1]
    DPUSH x0                        // orig hole
    mov  x0, #0
    bl   _compile_cell
    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x0, [x0]
    DPUSH x0                        // dest
    NEXT

// LOOP ( orig dest -- )  — keep dest/orig on CS stack; never clobber x19 (IP)
BOOT_WORD "LOOP", "LOOP ( C: orig dest -- ) compile LOOP", FL_IMM, XLOOP
XLOOP:
    // stack: ... orig dest  → save both on C stack
    DPOP x0                         // dest
    DPOP x1                         // orig
    stp  x0, x1, [sp, #-16]!        // [sp]=dest, [sp,#8]=orig
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    ldr  x0, [sp]                   // dest
    mov  x1, #0
    bl   _emit_native_loop
    ldr  x1, [sp, #8]               // orig
    add  sp, sp, #16
    cbz  x1, 2f
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x0, [x0]
    bl   _patch_rel
2:  NEXT
1:  adrp x0, cfa_loop@page
    add  x0, x0, cfa_loop@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x0, [x0]                   // hole
    ldr  x1, [sp]                   // dest
    sub  x0, x1, x0
    bl   _compile_cell
    ldr  x1, [sp, #8]               // orig
    add  sp, sp, #16
    cbz  x1, 2b
    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x0, [x0]
    sub  x0, x0, x1
    str  x0, [x1]
    NEXT

// +LOOP ( orig dest -- )
BOOT_WORD "+LOOP", "+LOOP ( C: orig dest -- ) compile +LOOP", FL_IMM, XPLUSLOOP
XPLUSLOOP:
    DPOP x0
    DPOP x1
    stp  x0, x1, [sp, #-16]!        // dest, orig
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    ldr  x0, [sp]
    mov  x1, #0
    bl   _emit_native_plusloop
    ldr  x1, [sp, #8]
    add  sp, sp, #16
    cbz  x1, 2f
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x0, [x0]
    bl   _patch_rel
2:  NEXT
1:  adrp x0, cfa_plusloop@page
    add  x0, x0, cfa_plusloop@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x0, [x0]
    ldr  x1, [sp]
    sub  x0, x1, x0
    bl   _compile_cell
    ldr  x1, [sp, #8]
    add  sp, sp, #16
    cbz  x1, 2b
    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x0, [x0]
    sub  x0, x0, x1
    str  x0, [x1]
    NEXT

BOOT_WORD "CREATE", "CREATE ( \"name\" -- ) header + DOVAR", 0, XCREATE
XCREATE:
    bl   _word
    cbz  x0, _colon_fail
    bl   _counted_to_cstr            // x0 = name cstr
    bl   _take_pending_help          // x1 = help cstr
    mov  x2, #0
    adrp x3, DOVAR@page
    add  x3, x3, DOVAR@pageoff
    bl   _header_build
    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x1, [x0]
    str  xzr, [x1], #8
    str  x1, [x0]
    NEXT

BOOT_WORD "DOES>", "DOES> ( -- ) compile (DOES>)", FL_IMM, XDOES
XDOES:
    adrp x0, cfa_does_rt@page
    add  x0, x0, cfa_does_rt@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    NEXT

BOOT_WORD "(DOES>)", "(DOES>) ( -- ) patch last defined with DODOES", 0, XDOES_RT
XDOES_RT:
    adrp x0, last_cfa@page
    add  x0, x0, last_cfa@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    adrp x1, DODOES@page
    add  x1, x1, DODOES@pageoff
    str  x1, [x0]
    str  x19, [x0, #8]
1:  RPOP
    NEXT

// RECURSE must go through _compile_word so INLINE-ON emits a native call,
// not a threaded cell via "," into HERE.
BOOT_WORD "RECURSE", "RECURSE ( C: -- ) compile call to word being defined", FL_IMM, XRECURSE
XRECURSE:
    adrp x0, last_cfa@page
    add  x0, x0, last_cfa@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    bl   _compile_word
1:  NEXT

BOOT_WORD "POSTPONE", "POSTPONE ( \"name\" -- ) ANS postpone", FL_IMM, XPOSTPONE
XPOSTPONE:
    bl   _word
    cbz  x0, _undef_current
    bl   _find
    cbz  x0, _undef_current
    stp  x0, x1, [sp, #-16]!         // xt, imm (1) / non-imm (-1)
    adrp x2, compiling_native@page
    add  x2, x2, compiling_native@pageoff
    ldr  x2, [x2]
    cbz  x2, 10f

    // Native: imm → call xt; non-imm → lit xt + call ,
    ldp  x0, x1, [sp], #16
    cmp  x1, #1
    b.eq 2f
    bl   _emit_native_lit
    adrp x0, cfa_comma@page
    add  x0, x0, cfa_comma@pageoff
    ldr  x0, [x0]
    bl   _emit_native_call
    NEXT
2:  bl   _emit_native_call
    NEXT

10: // Threaded: imm → , xt; non-imm → LIT xt ,
    ldp  x0, x1, [sp]
    cmp  x1, #1
    b.eq 11f
    adrp x0, cfa_lit@page
    add  x0, x0, cfa_lit@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    ldr  x0, [sp]
    bl   _compile_cell
    adrp x0, cfa_comma@page
    add  x0, x0, cfa_comma@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    add  sp, sp, #16
    NEXT
11: ldr  x0, [sp], #16
    bl   _compile_cell
    NEXT

BOOT_WORD "'", "' ( \"name\" -- xt )", 0, XTICK
XTICK:
    bl   _word
    cbz  x0, _undef_current
    bl   _find
    cbz  x0, _undef_current
    DPUSH x0
    NEXT

// PARSE ( delim -- c-addr u ) text until delim in SOURCE; updates >IN (ANS: no lead skip)
BOOT_WORD "PARSE", "PARSE ( char -- c-addr u ) parse until char in SOURCE", 0, XPARSE
XPARSE:
    DPOP x0                         // delimiter
    and  w0, w0, #0xFF
    adrp x1, source_addr@page
    add  x1, x1, source_addr@pageoff
    ldr  x1, [x1]
    adrp x2, source_len@page
    add  x2, x2, source_len@pageoff
    ldr  x2, [x2]
    adrp x3, to_in@page
    add  x3, x3, to_in@pageoff
    ldr  x4, [x3]                   // start offset
    mov  x5, x4
1:  cmp  x5, x2
    b.hs 2f
    ldrb w6, [x1, x5]
    cmp  w6, w0
    b.eq 3f
    add  x5, x5, #1
    b    1b
3:  sub  x7, x5, x4                  // u
    add  x5, x5, #1                 // skip delimiter
    str  x5, [x3]
    add  x1, x1, x4                 // c-addr
    DPUSH x1
    DPUSH x7
    NEXT
2:  sub  x7, x5, x4
    str  x5, [x3]
    add  x1, x1, x4
    DPUSH x1
    DPUSH x7
    NEXT

// SETDOC ( c-addr u -- ) pending help for next : / N: / CREATE (skip lead blanks)
BOOT_WORD "SETDOC", "SETDOC ( c-addr u -- ) pending help for next defining word", 0, XSETDOC
XSETDOC:
    DPOP x1                         // u
    DPOP x0                         // c-addr
1:  cbz  x1, 2f
    ldrb w2, [x0]
    cmp  w2, #32
    b.eq 3f
    cmp  w2, #9
    b.ne 2f
3:  add  x0, x0, #1
    sub  x1, x1, #1
    b    1b
2:  adrp x2, pending_help_addr@page
    add  x2, x2, pending_help_addr@pageoff
    str  x0, [x2]
    adrp x2, pending_help_len@page
    add  x2, x2, pending_help_len@pageoff
    str  x1, [x2]
    NEXT

BOOT_WORD "\\", "\\ ( -- ) line comment", FL_IMM, XBS
XBS:
    adrp x1, source_addr@page
    add  x1, x1, source_addr@pageoff
    ldr  x1, [x1]
    adrp x2, source_len@page
    add  x2, x2, source_len@pageoff
    ldr  x2, [x2]
    adrp x3, to_in@page
    add  x3, x3, to_in@pageoff
    ldr  x4, [x3]
1:  cmp  x4, x2
    b.hs 2f
    ldrb w5, [x1, x4]
    add  x4, x4, #1
    cmp  w5, #10
    b.ne 1b
2:  str  x4, [x3]
    NEXT

// F-PC multi-line block comment: \\ … {  (word name is two backslashes)
// Skip chars until '{' (consumed) or end of current SOURCE (no REFILL yet).
BOOT_WORD "\\\\", "\\\\ ( -- ) multi-line comment until { (immediate)", FL_IMM, XDBS
XDBS:
    adrp x1, source_addr@page
    add  x1, x1, source_addr@pageoff
    ldr  x1, [x1]
    adrp x2, source_len@page
    add  x2, x2, source_len@pageoff
    ldr  x2, [x2]
    adrp x3, to_in@page
    add  x3, x3, to_in@pageoff
    ldr  x4, [x3]
1:  cmp  x4, x2
    b.hs 2f
    ldrb w5, [x1, x4]
    add  x4, x4, #1
    cmp  w5, #'{'
    b.ne 1b
2:  str  x4, [x3]
    NEXT

BOOT_WORD "(", "( -- ) parenthesis comment", FL_IMM, XPAREN
XPAREN:
    adrp x1, source_addr@page
    add  x1, x1, source_addr@pageoff
    ldr  x1, [x1]
    adrp x2, source_len@page
    add  x2, x2, source_len@pageoff
    ldr  x2, [x2]
    adrp x3, to_in@page
    add  x3, x3, to_in@pageoff
    ldr  x4, [x3]
1:  cmp  x4, x2
    b.hs 2f
    ldrb w5, [x1, x4]
    add  x4, x4, #1
    cmp  w5, #')'
    b.ne 1b
2:  str  x4, [x3]
    NEXT

BOOT_WORD "C@", "C@ ( a -- c )", FL_INLINE, XCFETCH
XCFETCH:
    ldr  x0, [x22]
    ldrb w0, [x0]
    str  x0, [x22]
XCFETCH_END:
    NEXT

BOOT_WORD "C!", "C! ( c a -- )", FL_INLINE, XCSTORE
XCSTORE:
    DPOP x1                     // a
    DPOP x0                     // c
    strb w0, [x1]
XCSTORE_END:
    NEXT

BOOT_WORD "AND", "AND ( n1 n2 -- n3 )", FL_INLINE, XAND
XAND:
    DPOP x0
    ldr  x1, [x22]
    and  x1, x1, x0
    str  x1, [x22]
XAND_END:
    NEXT

BOOT_WORD "OR", "OR ( n1 n2 -- n3 )", FL_INLINE, XORR
XORR:
    DPOP x0
    ldr  x1, [x22]
    orr  x1, x1, x0
    str  x1, [x22]
XORR_END:
    NEXT

BOOT_WORD "XOR", "XOR ( n1 n2 -- n3 )", FL_INLINE, XXOR
XXOR:
    DPOP x0
    ldr  x1, [x22]
    eor  x1, x1, x0
    str  x1, [x22]
XXOR_END:
    NEXT

BOOT_WORD "INVERT", "INVERT ( n -- n' )", FL_INLINE, XINVERT
XINVERT:
    ldr  x0, [x22]
    mvn  x0, x0
    str  x0, [x22]
XINVERT_END:
    NEXT

BOOT_WORD "0=", "0= ( n -- f )", FL_INLINE, XZEQ
XZEQ:
    ldr  x0, [x22]
    cmp  x0, #0
    csetm x0, eq
    str  x0, [x22]
XZEQ_END:
    NEXT

BOOT_WORD "0<", "0< ( n -- f )", FL_INLINE, XZLT
XZLT:
    ldr  x0, [x22]
    cmp  x0, #0
    csetm x0, lt
    str  x0, [x22]
XZLT_END:
    NEXT

BOOT_WORD "<", "< ( n1 n2 -- f )", FL_INLINE, XLT
XLT:
    DPOP x0                     // n2
    ldr  x1, [x22]              // n1
    cmp  x1, x0
    csetm x1, lt
    str  x1, [x22]
XLT_END:
    NEXT

BOOT_WORD ">R", ">R ( n -- )", FL_INLINE, XTOR
XTOR:
    DPOP x0
    str  x0, [x23, #-8]!
XTOR_END:
    NEXT

BOOT_WORD "R>", "R> ( -- n )", FL_INLINE, XRFROM
XRFROM:
    ldr  x0, [x23], #8
    DPUSH x0
XRFROM_END:
    NEXT

BOOT_WORD "R@", "R@ ( -- n )", FL_INLINE, XRAT
XRAT:
    ldr  x0, [x23]
    DPUSH x0
XRAT_END:
    NEXT


// ============================================================================
// DO / LOOP family  (R: limit index  with index on top)
// 16Forth: memory data stack (no TOS-in-x20). Stack: ( limit start -- )
//   TOS at [x22] = start/index; under = limit.
// ============================================================================

// (DO) ( limit start -- )  R: -- limit index

    BOOT_WORD "(DO)", "(DO) ( limit start -- ) internal runtime for DO (setup rstack)", 0, XDO_RT
XDO_RT:
    DPOP x1                        // start (index)
    DPOP x0                        // limit
    str  x0, [x23, #-8]!           // R: limit
    str  x1, [x23, #-8]!           // R: index
    NEXT

// (?DO) ( limit start -- )  R: -- limit index | skip loop if equal
// Inline after xt: forward branch offset (like BRANCH) used when index==limit.

    BOOT_WORD "(?DO)", "(?DO) ( limit start -- ) internal runtime for ?DO", 0, XQDO_RT
XQDO_RT:
    DPOP x1                        // start (index)
    DPOP x0                        // limit
    cmp  x1, x0
    b.eq _qdo_skip
    str  x0, [x23, #-8]!           // R: limit
    str  x1, [x23, #-8]!           // R: index
    add  x19, x19, #8              // skip forward-offset cell
    NEXT
_qdo_skip:
    ldr  x0, [x19]
    add  x19, x19, x0              // branch past LOOP/+LOOP
    NEXT

// (LOOP) ( -- )  increment index; branch by relative offset if not done
// LEAVE sets index=limit so first cmp exits.

    BOOT_WORD "(LOOP)", "(LOOP) ( -- ) internal runtime for LOOP", 0, XLOOP_RT
XLOOP_RT:
    ldr  x0, [x23], #8             // index
    ldr  x1, [x23], #8             // limit
    cmp  x0, x1
    b.ge _loop_done                // LEAVE or finished
    add  x0, x0, #1
    cmp  x0, x1
    b.eq _loop_done
    str  x1, [x23, #-8]!
    str  x0, [x23, #-8]!
    ldr  x2, [x19]
    add  x19, x19, x2
    NEXT
_loop_done:
    add  x19, x19, #8              // skip offset
    NEXT

// (+LOOP) ( n -- )

    BOOT_WORD "(+LOOP)", "(+LOOP) ( n -- ) internal runtime for +LOOP", 0, XPLUSLOOP_RT
XPLUSLOOP_RT:
    ldr  x0, [x23], #8             // index
    ldr  x1, [x23], #8             // limit
    DPOP x2                        // step n
    cmp  x0, x1
    b.eq _pl_done                  // LEAVE: index == limit
    mov  x3, x0                    // old index
    add  x0, x0, x2                // new index
    cmp  x2, #0
    b.lt _pl_neg
    // n >= 0: done if old < limit && new >= limit
    cmp  x3, x1
    b.ge _pl_cont
    cmp  x0, x1
    b.ge _pl_done
    b    _pl_cont
_pl_neg:
    cmp  x3, x1
    b.lt _pl_cont
    cmp  x0, x1
    b.lt _pl_done
_pl_cont:
    str  x1, [x23, #-8]!
    str  x0, [x23, #-8]!
    ldr  x2, [x19]
    add  x19, x19, x2
    NEXT
_pl_done:
    add  x19, x19, #8
    NEXT

// I/J/K/UNLOOP/LEAVE are FL_INLINE so native DO loops paste them (trampoline
// would hide the index under the JIT resume cell on the return stack).

    BOOT_WORD "I", "I ( -- n ) current DO loop index", FL_INLINE, XI
XI:
    ldr  x0, [x23]
    DPUSH x0
XI_END:
    NEXT

    BOOT_WORD "J", "J ( -- n ) outer DO loop index (for nested loops)", FL_INLINE, XJ
XJ:
    ldr  x0, [x23, #16]            // skip inner index+limit
    DPUSH x0
XJ_END:
    NEXT

    BOOT_WORD "K", "K ( -- n ) third DO loop index", FL_INLINE, XK
XK:
    ldr  x0, [x23, #32]            // skip two index+limit pairs
    DPUSH x0
XK_END:
    NEXT

    BOOT_WORD "UNLOOP", "UNLOOP ( -- ) discard current DO loop params from rstack", FL_INLINE, XUNLOOP
XUNLOOP:
    add  x23, x23, #16
XUNLOOP_END:
    NEXT

    BOOT_WORD "LEAVE", "LEAVE ( -- ) exit current DO loop (branch to after LOOP)", FL_INLINE, XLEAVE
XLEAVE:
    ldr  x0, [x23, #8]             // limit
    str  x0, [x23]                 // index = limit
XLEAVE_END:
    NEXT




BOOT_WORD "DEPTH", "DEPTH ( -- n )", 0, XDEPTH
XDEPTH:
    adrp x0, data_stack@page
    add  x0, x0, data_stack@pageoff
    add  x0, x0, #DSTACK_SIZE
    sub  x0, x0, x22
    lsr  x0, x0, #3
    DPUSH x0
    NEXT

BOOT_WORD "WORD", "WORD ( char -- c-addr ) counted token at HERE", 0, XWORD
XWORD:
    DPOP x0                     // drop delimiter
    bl   _word
    DPUSH x0
    NEXT

BOOT_WORD "(S\")", "(S\") ( -- c-addr u ) runtime for S\"", 0, XSLIT
XSLIT:
    ldr  x0, [x19], #8          // u
    mov  x1, x19                // c-addr
    add  x19, x19, x0
    add  x19, x19, #7
    and  x19, x19, #-8
    DPUSH x1
    DPUSH x0
    NEXT

BOOT_WORD "S\"", "S\" ( -- c-addr u ) parse quoted string", FL_IMM, XSQUOTE
XSQUOTE:
    bl   _parse_quote           // x0=addr, x1=len
    adrp x2, state_var@page
    add  x2, x2, state_var@pageoff
    ldr  x2, [x2]
    cbnz x2, 1f
    DPUSH x0
    DPUSH x1
    NEXT
1:  stp  x0, x1, [sp, #-16]!
    adrp x0, cfa_slit@page
    add  x0, x0, cfa_slit@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    ldr  x0, [sp, #8]
    bl   _compile_cell
    ldp  x0, x1, [sp], #16
    adrp x2, here_ptr@page
    add  x2, x2, here_ptr@pageoff
    ldr  x3, [x2]
    cbz  x1, 3f
2:  ldrb w4, [x0], #1
    strb w4, [x3], #1
    subs x1, x1, #1
    b.ne 2b
3:  add  x3, x3, #7
    and  x3, x3, #-8
    str  x3, [x2]
    NEXT

BOOT_WORD "BYE", "BYE ( -- ) exit process", 0, XBYE
XBYE:
    mov  x0, #0
    mov  x16, #1
    svc  #0x80

_colon_fail:
    adrp x1, str_colon_fail@page
    add  x1, x1, str_colon_fail@pageoff
    mov  x2, #16
    bl   _sys_write
    b    _die

// ----------------------------------------------------------------------------
// File-Access
// ----------------------------------------------------------------------------

BOOT_WORD "FILE-O1", "FILE-O1 ( -- n )", 0, XFO1
XFO1:
    adrp x0, file_o1@page
    add  x0, x0, file_o1@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD "FILE-O2", "FILE-O2 ( -- n )", 0, XFO2
XFO2:
    adrp x0, file_o2@page
    add  x0, x0, file_o2@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD "(CREATE-FILE)", "(CREATE-FILE) ( fam ptr -- fileid ior )", 0, XCREATEFILE2
XCREATEFILE2:
    DPOP x4                     // ptr
    DPOP x1                     // fam
    mov  x0, #2
    mov  x2, #0
    mov  x3, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    mov  x1, x0                 // ior
    adrp x0, file_o1@page
    add  x0, x0, file_o1@pageoff
    ldr  x0, [x0]
    DPUSH x0                    // fileid
    DPUSH x1                    // ior
    NEXT

BOOT_WORD "(OPEN-FILE)", "(OPEN-FILE) ( fam ptr -- fileid ior )", 0, XOPENFILE
XOPENFILE:
    DPOP x4                     // ptr
    DPOP x1                     // fam
    mov  x0, #1
    mov  x2, #0
    mov  x3, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    mov  x1, x0
    adrp x0, file_o1@page
    add  x0, x0, file_o1@pageoff
    ldr  x0, [x0]
    DPUSH x0
    DPUSH x1
    NEXT

BOOT_WORD "(CLOSE-FILE)", "(CLOSE-FILE) ( fileid -- ior )", 0, XCLOSEFILE
XCLOSEFILE:
    DPOP x1                     // fileid
    mov  x0, #3
    mov  x2, #0
    mov  x3, #0
    mov  x4, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    DPUSH x0
    NEXT

BOOT_WORD "(READ-FILE)", "(READ-FILE) ( c-addr u fileid -- u2 ior )", 0, XREADFILE
XREADFILE:
    DPOP x1                     // fileid
    DPOP x2                     // u
    DPOP x4                     // c-addr
    mov  x0, #4
    mov  x3, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    mov  x1, x0
    adrp x0, file_o1@page
    add  x0, x0, file_o1@pageoff
    ldr  x0, [x0]
    DPUSH x0                    // u2
    DPUSH x1                    // ior
    NEXT

BOOT_WORD "(WRITE-FILE)", "(WRITE-FILE) ( c-addr u fileid -- ior )", 0, XWRITEFILE
XWRITEFILE:
    DPOP x1                     // fileid
    DPOP x2                     // u
    DPOP x4                     // c-addr
    mov  x0, #5
    mov  x3, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    DPUSH x0
    NEXT

BOOT_WORD "(READ-LINE)", "(READ-LINE) ( c-addr u1 fileid -- u2 flag ior )", 0, XREADLINE
XREADLINE:
    DPOP x1                     // fileid
    DPOP x2                     // u1
    DPOP x4                     // c-addr
    mov  x0, #6
    mov  x3, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    mov  x3, x0                 // ior
    adrp x0, file_o1@page
    add  x0, x0, file_o1@pageoff
    ldr  x0, [x0]
    DPUSH x0                    // u2
    adrp x0, file_o2@page
    add  x0, x0, file_o2@pageoff
    ldr  x0, [x0]
    DPUSH x0                    // flag
    DPUSH x3                    // ior
    NEXT

BOOT_WORD "(WRITE-LINE)", "(WRITE-LINE) ( c-addr u fileid -- ior )", 0, XWRITELINE
XWRITELINE:
    DPOP x1                     // fileid
    DPOP x2                     // u
    DPOP x4                     // c-addr
    mov  x0, #7
    mov  x3, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    DPUSH x0
    NEXT

BOOT_WORD "(REPOSITION-FILE)", "(REPOSITION-FILE) ( lo hi fileid -- ior )", 0, XREPOSFILE
XREPOSFILE:
    DPOP x1                     // fileid → a
    DPOP x3                     // hi    → c (ignored by C for now)
    DPOP x2                     // lo    → b
    mov  x0, #10                // op = FOP_REPOSITION
    mov  x4, #0                 // ptr unused

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    DPUSH x0                    // ior
    NEXT

BOOT_WORD "(FILE-SIZE)", "(FILE-SIZE) ( fileid -- ud ior )", 0, XFILESIZE
XFILESIZE:
    DPOP x1                     // a = fileid
    mov  x0, #8                 // FOP_FILE_SIZE
    mov  x2, #0
    mov  x3, #0
    mov  x4, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    mov  x3, x0                 // ior
    adrp x0, file_o1@page
    add  x0, x0, file_o1@pageoff
    ldr  x0, [x0]
    DPUSH x0                    // size lo (or full size in o1)
    adrp x0, file_o2@page
    add  x0, x0, file_o2@pageoff
    ldr  x0, [x0]
    DPUSH x0                    // size hi (0 if unused)
    DPUSH x3                    // ior
    NEXT

BOOT_WORD "(FILE-POSITION)", "(FILE-POSITION) ( fileid -- ud ior )", 0, XFILEPOS
XFILEPOS:
    DPOP x1                     // a = fileid
    mov  x0, #9                 // FOP_FILE_POS
    mov  x2, #0
    mov  x3, #0
    mov  x4, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    mov  x3, x0
    adrp x0, file_o1@page
    add  x0, x0, file_o1@pageoff
    ldr  x0, [x0]
    DPUSH x0                    // pos lo
    adrp x0, file_o2@page
    add  x0, x0, file_o2@pageoff
    ldr  x0, [x0]
    DPUSH x0                    // pos hi
    DPUSH x3                    // ior
    NEXT

BOOT_WORD "(DELETE-FILE)", "(DELETE-FILE) ( c-addr -- ior )", 0, XDELETEFILE
XDELETEFILE:
    DPOP x4                     // ptr = NUL-terminated name
    mov  x0, #11                // FOP_DELETE
    mov  x1, #0
    mov  x2, #0
    mov  x3, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    DPUSH x0                    // ior
    NEXT

// ============================================================================
// INCLUDE / INCLUDED / REQUIRED / REQUIRE / .INCLUDED
// Whole-file SOURCE nest (64Forth-style): push current SOURCE, install file
// buffer, continue outer interpret; pop (+ free) when file SOURCE ends.
// ============================================================================

BOOT_WORD "INCLUDED", "INCLUDED ( c-addr u -- ) load and interpret named file", 0, XINCLUDED
XINCLUDED:
    DPOP x1                     // u
    DPOP x0                     // c-addr
    bl   _path_to_name_buf
    b    _include_do

BOOT_WORD "INCLUDE", "INCLUDE ( 'name'|bare|\"path\" -- ) load and interpret file", 0, XINCLUDE
XINCLUDE:
    bl   _next_filespec         // len 0 = bare → open panel via hook
    b    _include_do

BOOT_WORD "FLOAD", "FLOAD ( 'name'|bare -- ) synonym of INCLUDE", 0, XFLOAD
XFLOAD:
    b    XINCLUDE

BOOT_WORD "REQUIRED", "REQUIRED ( c-addr u -- ) INCLUDED if not yet loaded", 0, XREQUIRED
XREQUIRED:
    DPOP x1
    DPOP x0
    bl   _path_to_name_buf
    bl   _resolve_abs_key       // may rewrite name_buf to absolute key
    adrp x0, name_buf@page
    add  x0, x0, name_buf@pageoff
    adrp x1, include_path_len@page
    add  x1, x1, include_path_len@pageoff
    ldr  x1, [x1]
    bl   _included_find
    cbnz x0, _require_skip
    b    _include_do
_require_skip:
    bl   _fromlib_clear
    NEXT

BOOT_WORD "REQUIRE", "REQUIRE ( 'name' -- ) parse name REQUIRED", 0, XREQUIRE
XREQUIRE:
    bl   _next_filespec
    cbz  x0, _include_need_name
    bl   _resolve_abs_key
    adrp x0, name_buf@page
    add  x0, x0, name_buf@pageoff
    adrp x1, include_path_len@page
    add  x1, x1, include_path_len@pageoff
    ldr  x1, [x1]
    bl   _included_find
    cbnz x0, _require_skip
    b    _include_do

BOOT_WORD ".INCLUDED", ".INCLUDED ( -- ) list files registered by INCLUDE/REQUIRED", 0, XDOTINCLUDED
XDOTINCLUDED:
    stp  x19, x20, [sp, #-16]!
    adrp x1, str_included_hdr@page
    add  x1, x1, str_included_hdr@pageoff
    mov  x2, #10
    bl   _sys_write
    adrp x0, included_count@page
    add  x0, x0, included_count@pageoff
    ldr  x19, [x0]
    cbz  x19, 9f
    mov  x20, #0
1:  cmp  x20, x19
    b.hs 9f
    mov  x0, #INCL_NAME
    mul  x0, x0, x20
    adrp x1, included_names@page
    add  x1, x1, included_names@pageoff
    add  x1, x1, x0
    ldrb w2, [x1], #1
    bl   _sys_write
    adrp x1, str_nl@page
    add  x1, x1, str_nl@pageoff
    mov  x2, #1
    bl   _sys_write
    add  x20, x20, #1
    b    1b
9:  ldp  x19, x20, [sp], #16
    NEXT

BOOT_WORD "FROMLIB", "FROMLIB ( -- ) next INCLUDE/FLOAD/REQUIRE/CHDIR/DIR uses Library", 0, XFROMLIB
XFROMLIB:
    adrp x0, fromlib_hook@page
    add  x0, x0, fromlib_hook@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    SAVE_C_CALLEE
    blr  x0
    RESTORE_C_CALLEE
1:  NEXT

BOOT_WORD "FROM-LIBRARY", "FROM-LIBRARY ( -- ) synonym for FROMLIB", 0, XFROMLIB2
XFROMLIB2:
    b    XFROMLIB

BOOT_WORD "FILE-ECHO", "FILE-ECHO ( -- addr ) variable; echo INCLUDE source when nonzero", 0, XFILEECHO
XFILEECHO:
    adrp x0, file_echo_var@page
    add  x0, x0, file_echo_var@pageoff
    DPUSH x0
    NEXT

BOOT_WORD "\\S", "\\S ( -- ) stop rest of current SOURCE (immediate)", FL_IMM, XBACKSLASH_S
XBACKSLASH_S:
    adrp x0, source_len@page
    add  x0, x0, source_len@pageoff
    ldr  x1, [x0]
    adrp x0, to_in@page
    add  x0, x0, to_in@pageoff
    str  x1, [x0]
    adrp x0, source_id_var@page
    add  x0, x0, source_id_var@pageoff
    ldr  x0, [x0]
    cbnz x0, 1f
    adrp x0, repl_batch_stop@page
    add  x0, x0, repl_batch_stop@pageoff
    mov  x1, #1
    str  x1, [x0]
1:  NEXT

BOOT_WORD "SOURCE", "SOURCE ( -- c-addr u ) current input buffer", 0, XSOURCE
XSOURCE:
    adrp x0, source_addr@page
    add  x0, x0, source_addr@pageoff
    ldr  x0, [x0]
    DPUSH x0
    adrp x0, source_len@page
    add  x0, x0, source_len@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD "SOURCE-ID", "SOURCE-ID ( -- n ) 0=user, -1=EVALUATE, >0=INCLUDE", 0, XSOURCEID
XSOURCEID:
    adrp x0, source_id_var@page
    add  x0, x0, source_id_var@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD ">IN", ">IN ( -- addr ) input offset variable", 0, XTOIN
XTOIN:
    adrp x0, to_in@page
    add  x0, x0, to_in@pageoff
    DPUSH x0
    NEXT

BOOT_WORD "EVALUATE", "EVALUATE ( i*x c-addr u -- j*x ) interpret string", 0, XEVALUATE
XEVALUATE:
    DPOP x1                     // u
    DPOP x0                     // c-addr
    stp  x0, x1, [sp, #-16]!
    bl   _push_source
    ldp  x0, x1, [sp], #16
    bl   _set_source
    adrp x0, source_id_var@page
    add  x0, x0, source_id_var@pageoff
    mov  x1, #SRCID_EVAL
    str  x1, [x0]
    adrp x0, file_echo_pos@page
    add  x0, x0, file_echo_pos@pageoff
    str  xzr, [x0]
    // Continue outer interpret on the new SOURCE (do not return into caller colon).
    b    _interpret_loop

BOOT_WORD "REFILL", "REFILL ( -- flag ) refill input; false for INCLUDE/EVALUATE", 0, XREFILL
XREFILL:
    // Line-based GUI REPL: no multi-line refill yet.
    mov  x0, #0
    DPUSH x0
    NEXT

BOOT_WORD "CHDIR", "CHDIR ( 'path'|bare -- ) change working directory", 0, XCHDIR
XCHDIR:
    bl   _next_filespec         // 0 = bare panel
    adrp x0, chdir_hook@page
    add  x0, x0, chdir_hook@pageoff
    ldr  x9, [x0]
    cbz  x9, 1f
    adrp x0, name_buf@page
    add  x0, x0, name_buf@pageoff
    adrp x1, include_path_len@page
    add  x1, x1, include_path_len@pageoff
    ldr  x1, [x1]
    SAVE_C_CALLEE
    blr  x9
    RESTORE_C_CALLEE
1:  NEXT

BOOT_WORD "PWD", "PWD ( -- ) print working directory", 0, XPWD
XPWD:
    adrp x0, pwd_hook@page
    add  x0, x0, pwd_hook@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    SAVE_C_CALLEE
    blr  x0
    RESTORE_C_CALLEE
1:  NEXT

BOOT_WORD "DIR", "DIR ( 'path'|bare -- ) list directory (* ? ok)", 0, XDIR
XDIR:
    bl   _next_filespec
    adrp x0, dir_hook@page
    add  x0, x0, dir_hook@pageoff
    ldr  x9, [x0]
    cbz  x9, 1f
    adrp x0, name_buf@page
    add  x0, x0, name_buf@pageoff
    adrp x1, include_path_len@page
    add  x1, x1, include_path_len@pageoff
    ldr  x1, [x1]
    SAVE_C_CALLEE
    blr  x9
    RESTORE_C_CALLEE
1:  NEXT

// ============================================================================
// Search-Order / vocabularies (ANS + 64Forth lineage)
// ============================================================================

BOOT_WORD "DICT-THREADS", "DICT-THREADS ( -- n ) heads per wordlist", 0, XDICT_THREADS
XDICT_THREADS:
    mov  x0, #DICT_THREADS
    DPUSH x0
    NEXT

BOOT_WORD "FORTH-WORDLIST", "FORTH-WORDLIST ( -- wid ) main FORTH word list", 0, XFORTH_WORDLIST
XFORTH_WORDLIST:
    adrp x0, latest_var@page
    add  x0, x0, latest_var@pageoff
    DPUSH x0
    NEXT

BOOT_WORD "GET-CURRENT", "GET-CURRENT ( -- wid ) compilation wordlist", 0, XGET_CURRENT
XGET_CURRENT:
    adrp x0, current_var@page
    add  x0, x0, current_var@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD "SET-CURRENT", "SET-CURRENT ( wid -- ) set compilation wordlist", 0, XSET_CURRENT
XSET_CURRENT:
    DPOP x0
    adrp x1, current_var@page
    add  x1, x1, current_var@pageoff
    str  x0, [x1]
    NEXT

BOOT_WORD "WORDLIST", "WORDLIST ( -- wid ) create empty word list", 0, XWORDLIST
XWORDLIST:
    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x1, [x0]
    add  x1, x1, #7
    and  x1, x1, #-8
    mov  x2, x1                    // wid
    mov  x3, #DICT_THREADS
1:  str  xzr, [x1], #8
    subs x3, x3, #1
    b.ne 1b
    str  x1, [x0]
    mov  x0, x2
    bl   _wordlist_register
    DPUSH x0
    NEXT

BOOT_WORD "WORDLISTS", "WORDLISTS ( -- addr n ) registered wordlist table", 0, XWORDLISTS
XWORDLISTS:
    adrp x0, wordlist_reg@page
    add  x0, x0, wordlist_reg@pageoff
    DPUSH x0
    adrp x0, wordlist_reg_n@page
    add  x0, x0, wordlist_reg_n@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD "GET-ORDER", "GET-ORDER ( -- widn ... wid1 n ) wid1 searched first", 0, XGET_ORDER
XGET_ORDER:
    adrp x0, search_order_n@page
    add  x0, x0, search_order_n@pageoff
    ldr  x1, [x0]
    adrp x2, search_order@page
    add  x2, x2, search_order@pageoff
    mov  x3, x1
1:  cbz  x3, 2f
    sub  x3, x3, #1
    ldr  x4, [x2, x3, lsl #3]
    DPUSH x4
    b    1b
2:  DPUSH x1
    NEXT

BOOT_WORD "SET-ORDER", "SET-ORDER ( widn ... wid1 n -- ) n=-1 means ONLY", 0, XSET_ORDER
XSET_ORDER:
    DPOP x1                        // n
    cmp  x1, #-1
    b.eq XONLY
    cmp  x1, #0
    b.lt 9f
    cmp  x1, #SEARCH_ORDER_MAX
    b.hi 9f
    adrp x0, search_order_n@page
    add  x0, x0, search_order_n@pageoff
    str  x1, [x0]
    adrp x2, search_order@page
    add  x2, x2, search_order@pageoff
    mov  x3, #0
2:  cmp  x3, x1
    b.hs 3f
    DPOP x4
    str  x4, [x2, x3, lsl #3]
    add  x3, x3, #1
    b    2b
3:  NEXT
9:  NEXT

BOOT_WORD "PUSH-ORDER", "PUSH-ORDER ( wid -- ) prepend wid to search order", 0, XPUSH_ORDER
XPUSH_ORDER:
    DPOP x0                        // wid
    adrp x1, search_order_n@page
    add  x1, x1, search_order_n@pageoff
    ldr  x2, [x1]
    cmp  x2, #SEARCH_ORDER_MAX
    b.hs 9f
    adrp x3, search_order@page
    add  x3, x3, search_order@pageoff
    mov  x4, x2
1:  cbz  x4, 2f
    sub  x4, x4, #1
    ldr  x5, [x3, x4, lsl #3]
    add  x6, x4, #1
    str  x5, [x3, x6, lsl #3]
    b    1b
2:  str  x0, [x3]
    add  x2, x2, #1
    str  x2, [x1]
9:  NEXT

BOOT_WORD "DEFINITIONS", "DEFINITIONS ( -- ) CURRENT = first in search order", 0, XDEFINITIONS
XDEFINITIONS:
    adrp x0, search_order_n@page
    add  x0, x0, search_order_n@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    adrp x1, search_order@page
    add  x1, x1, search_order@pageoff
    ldr  x1, [x1]
    adrp x0, current_var@page
    add  x0, x0, current_var@pageoff
    str  x1, [x0]
1:  NEXT

BOOT_WORD "ONLY", "ONLY ( -- ) search order = FORTH only", 0, XONLY
XONLY:
    adrp x0, latest_var@page
    add  x0, x0, latest_var@pageoff
    adrp x1, search_order@page
    add  x1, x1, search_order@pageoff
    str  x0, [x1]
    mov  x0, #1
    adrp x1, search_order_n@page
    add  x1, x1, search_order_n@pageoff
    str  x0, [x1]
    NEXT

BOOT_WORD "ALSO", "ALSO ( -- ) duplicate first search-order entry", 0, XALSO
XALSO:
    adrp x0, search_order_n@page
    add  x0, x0, search_order_n@pageoff
    ldr  x1, [x0]
    cbz  x1, 9f
    cmp  x1, #SEARCH_ORDER_MAX
    b.hs 9f
    adrp x2, search_order@page
    add  x2, x2, search_order@pageoff
    ldr  x3, [x2]
    mov  x4, x1
1:  cbz  x4, 2f
    sub  x4, x4, #1
    ldr  x5, [x2, x4, lsl #3]
    add  x6, x4, #1
    str  x5, [x2, x6, lsl #3]
    b    1b
2:  str  x3, [x2]
    add  x1, x1, #1
    str  x1, [x0]
9:  NEXT

BOOT_WORD "PREVIOUS", "PREVIOUS ( -- ) drop first search-order entry", 0, XPREVIOUS
XPREVIOUS:
    adrp x0, search_order_n@page
    add  x0, x0, search_order_n@pageoff
    ldr  x1, [x0]
    cmp  x1, #1
    b.ls 9f
    adrp x2, search_order@page
    add  x2, x2, search_order@pageoff
    mov  x3, #0
1:  add  x4, x3, #1
    cmp  x4, x1
    b.hs 2f
    ldr  x5, [x2, x4, lsl #3]
    str  x5, [x2, x3, lsl #3]
    add  x3, x3, #1
    b    1b
2:  sub  x1, x1, #1
    str  x1, [x0]
9:  NEXT

BOOT_WORD "FORTH", "FORTH ( -- ) set first search-order entry to FORTH", 0, XFORTH
XFORTH:
    adrp x0, latest_var@page
    add  x0, x0, latest_var@pageoff
    adrp x1, search_order@page
    add  x1, x1, search_order@pageoff
    str  x0, [x1]
    adrp x1, search_order_n@page
    add  x1, x1, search_order_n@pageoff
    ldr  x2, [x1]
    cbnz x2, 1f
    mov  x2, #1
    str  x2, [x1]
1:  NEXT

BOOT_WORD "FIND", "FIND ( c-addr -- c-addr 0 | xt 1 | xt -1 ) counted name", 0, XFIND
XFIND:
    DPOP x2                        // c-addr (counted)
    mov  x0, x2
    stp  x2, xzr, [sp, #-16]!
    bl   _find
    ldp  x2, xzr, [sp], #16
    cbz  x0, 1f
    DPUSH x0
    DPUSH x1
    NEXT
1:  DPUSH x2
    mov  x0, #0
    DPUSH x0
    NEXT

BOOT_WORD "SEARCH-WORDLIST", "SEARCH-WORDLIST ( c-addr u wid -- 0 | xt 1 | xt -1 )", 0, XSEARCH_WORDLIST
XSEARCH_WORDLIST:
    DPOP x9                        // wid
    DPOP x8                        // u
    DPOP x7                        // c-addr
    cbz  x9, _swl_miss
    cbz  x8, _swl_miss
    ldr  x21, [x9]                 // tip (DICT_THREADS=1)
_swl_loop:
    cbz  x21, _swl_miss
    ldr  x2, [x21, #-8]
    and  x3, x2, #0xFFFF
    sub  x4, x21, x3
    ldrb w3, [x4], #1
    cmp  x3, x8
    b.ne _swl_next
    mov  x5, #0
_swl_cmp:
    cmp  x5, x8
    b.hs _swl_hit
    ldrb w6, [x4, x5]
    ldrb w10, [x7, x5]
    cmp  w10, #'a'
    b.lo 1f
    cmp  w10, #'z'
    b.hi 1f
    sub  w10, w10, #32
1:  cmp  w6, w10
    b.ne _swl_next
    add  x5, x5, #1
    b    _swl_cmp
_swl_hit:
    tst  x2, #(1 << 63)
    mov  x0, #-1
    b.eq 2f
    mov  x0, #1
2:  DPUSH x21
    DPUSH x0
    NEXT
_swl_next:
    ldr  x21, [x21, #-16]
    b    _swl_loop
_swl_miss:
    mov  x0, #0
    DPUSH x0
    NEXT

BOOT_WORD "ORDER", "ORDER ( -- ) print search order and CURRENT", 0, XORDER
XORDER:
    // Preserve IP / scratch (x19–x21 are VM + temps)
    stp  x19, x20, [sp, #-32]!
    str  x21, [sp, #16]
    adrp x1, str_search_order@page
    add  x1, x1, str_search_order@pageoff
    mov  x2, #14
    bl   _sys_write
    adrp x0, search_order_n@page
    add  x0, x0, search_order_n@pageoff
    ldr  x19, [x0]
    adrp x20, search_order@page
    add  x20, x20, search_order@pageoff
    mov  x21, #0
1:  cmp  x21, x19
    b.hs 2f
    ldr  x0, [x20, x21, lsl #3]
    bl   _print_wid_name
    mov  x0, #' '
    bl   _putchar
    add  x21, x21, #1
    b    1b
2:  adrp x1, str_nl@page
    add  x1, x1, str_nl@pageoff
    mov  x2, #1
    bl   _sys_write
    adrp x1, str_comp_wl@page
    add  x1, x1, str_comp_wl@pageoff
    mov  x2, #22
    bl   _sys_write
    adrp x0, current_var@page
    add  x0, x0, current_var@pageoff
    ldr  x0, [x0]
    bl   _print_wid_name
    adrp x1, str_nl@page
    add  x1, x1, str_nl@pageoff
    mov  x2, #1
    bl   _sys_write
    ldr  x21, [sp, #16]
    ldp  x19, x20, [sp], #32
    NEXT

// TRAVERSE-WORDLIST ( i*x xt wid -- j*x )
// Visitor: ( i*x nt -- j*x flag ); stop on false. nt = CFA.
// R (top first while visiting): next, xt, thread, wid, saved_IP
BOOT_WORD "TRAVERSE-WORDLIST", "TRAVERSE-WORDLIST ( i*x xt wid -- j*x ) visit each name in wid", 0, XTRAVERSE_WORDLIST
XTRAVERSE_WORDLIST:
    DPOP x5                        // wid
    DPOP x6                        // visitor xt
    RPUSH                          // R: saved IP
    str  x5, [x23, #-8]!           // R: wid
    mov  x7, #0
    str  x7, [x23, #-8]!           // R: thread
    str  x6, [x23, #-8]!           // R: xt
    ldr  x7, [x5]                  // heads[0]
_tw_loop:
    cbz  x7, _tw_advance_thread
    ldr  x8, [x7, #-16]            // next CFA
    ldr  x6, [x23]                 // xt peek
    str  x8, [x23, #-8]!           // R: next
    DPUSH x7                       // nt
    mov  x21, x6
    ldr  x1, [x21]
    adrp x19, tw_continue_cell@page
    add  x19, x19, tw_continue_cell@pageoff
    br   x1

BOOT_WORD "(TW-CONT)", "(TW-CONT) TRAVERSE-WORDLIST continuation", 0, XTW_CONTINUE
.align 4
XTW_CONTINUE:
    DPOP x0                        // flag
    ldr  x8, [x23], #8             // next
    ldr  x6, [x23]                 // xt peek
    cbz  x0, _tw_stop
    mov  x7, x8
    cbz  x7, _tw_advance_thread
    b    _tw_loop
_tw_stop:
    ldr  x6, [x23], #8             // xt
    ldr  x7, [x23], #8             // thread
    ldr  x5, [x23], #8             // wid
    RPOP
    NEXT
_tw_advance_thread:
    // R top: xt, thread, wid, IP
    ldr  x6, [x23], #8             // xt
    ldr  x7, [x23], #8             // thread
    ldr  x5, [x23], #8             // wid
    add  x7, x7, #1
    cmp  x7, #DICT_THREADS
    b.hs _tw_done
    str  x5, [x23, #-8]!
    str  x7, [x23, #-8]!
    str  x6, [x23, #-8]!
    add  x0, x5, x7, lsl #3
    ldr  x7, [x0]
    b    _tw_loop
_tw_done:
    RPOP
    NEXT

BOOT_WORD "PICK", "PICK ( xu ... x0 u -- xu ... x0 xu )", 0, XPICK
XPICK:
    DPOP x0                     // u
    lsl  x0, x0, #3             // byte offset
    ldr  x0, [x22, x0]          // load xu
    DPUSH x0
    NEXT

BOOT_WORD "LSHIFT", "LSHIFT ( n u -- n' ) logical left shift", FL_INLINE, XLSHIFT
XLSHIFT:
    DPOP x1                     // u
    DPOP x0                     // n
    lsl  x0, x0, x1
    DPUSH x0
XLSHIFT_END:
    NEXT

BOOT_WORD "RSHIFT", "RSHIFT ( n u -- n' ) logical right shift", FL_INLINE, XRSHIFT
XRSHIFT:
    DPOP x1                     // u
    DPOP x0                     // n
    lsr  x0, x0, x1
    DPUSH x0
XRSHIFT_END:
    NEXT

// SEE helpers: push cached xts / DOCOL code address (avoid awkward names in .fth)
BOOT_WORD "LIT-ADDR", "LIT-ADDR ( -- xt ) xt of LIT (for SEE)", 0, XLIT_ADDR
XLIT_ADDR:
    adrp x0, cfa_lit@page
    add  x0, x0, cfa_lit@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD "0BRANCH-ADDR", "0BRANCH-ADDR ( -- xt ) xt of 0BRANCH (for SEE)", 0, X0BRANCH_ADDR
X0BRANCH_ADDR:
    adrp x0, cfa_0branch@page
    add  x0, x0, cfa_0branch@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD "BRANCH-ADDR", "BRANCH-ADDR ( -- xt ) xt of BRANCH (for SEE)", 0, XBRANCH_ADDR
XBRANCH_ADDR:
    adrp x0, cfa_branch@page
    add  x0, x0, cfa_branch@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD "EXIT-ADDR", "EXIT-ADDR ( -- xt ) xt of EXIT (for SEE)", 0, XEXIT_ADDR
XEXIT_ADDR:
    adrp x0, cfa_exit@page
    add  x0, x0, cfa_exit@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD "SLIT-ADDR", "SLIT-ADDR ( -- xt ) xt of (S\") runtime (for SEE)", 0, XSLIT_ADDR
XSLIT_ADDR:
    adrp x0, cfa_slit@page
    add  x0, x0, cfa_slit@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD "DO-ADDR", "DO-ADDR ( -- xt ) xt of (DO) runtime (for SEE)", 0, XDO_ADDR
XDO_ADDR:
    adrp x0, cfa_do@page
    add  x0, x0, cfa_do@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD "QDO-ADDR", "QDO-ADDR ( -- xt ) xt of (?DO) runtime (for SEE)", 0, XQDO_ADDR
XQDO_ADDR:
    adrp x0, cfa_qdo@page
    add  x0, x0, cfa_qdo@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD "LOOP-ADDR", "LOOP-ADDR ( -- xt ) xt of (LOOP) runtime (for SEE)", 0, XLOOP_ADDR
XLOOP_ADDR:
    adrp x0, cfa_loop@page
    add  x0, x0, cfa_loop@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD "PLUSLOOP-ADDR", "PLUSLOOP-ADDR ( -- xt ) xt of (+LOOP) runtime (for SEE)", 0, XPLUSLOOP_ADDR
XPLUSLOOP_ADDR:
    adrp x0, cfa_plusloop@page
    add  x0, x0, cfa_plusloop@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD "DOCOL-ADDR", "DOCOL-ADDR ( -- addr ) address of DOCOL (colon entry; for DOCOL?/SEE)", 0, XDOCOL_ADDR
XDOCOL_ADDR:
    adrp x0, DOCOL@page
    add  x0, x0, DOCOL@pageoff
    DPUSH x0
    NEXT

BOOT_WORD "BASE", "BASE ( -- addr ) current numeric base variable", 0, XBASE
XBASE:
    adrp x0, base_var@page
    add  x0, x0, base_var@pageoff
    DPUSH x0
    NEXT

// UM/MOD ( ulo uhi u -- rem quot )
BOOT_WORD "UM/MOD", "UM/MOD ( ud u -- rem quot ) unsigned double divmod", 0, XUMMOD
XUMMOD:
    DPOP x2                         // divisor
    DPOP x1                         // uhi
    DPOP x0                         // ulo
    cbz  x2, 2f
    cbnz x1, 1f
    udiv x3, x0, x2
    msub x4, x3, x2, x0
    DPUSH x4
    DPUSH x3
    NEXT
1:  SAVE_C_CALLEE
    sub  sp, sp, #16
    mov  x3, sp                     // &rem
    add  x4, sp, #8                 // &quot
    bl   _forth_udivmod128
    ldr  x4, [sp]                   // rem
    ldr  x3, [sp, #8]               // quot
    add  sp, sp, #16
    RESTORE_C_CALLEE
    DPUSH x4
    DPUSH x3
    NEXT
2:  DPUSH xzr
    DPUSH xzr
    NEXT

// MS@ ( -- u ) wall-clock ms since Unix epoch (gettimeofday)
BOOT_WORD "UNUSED", "UNUSED ( -- u ) bytes remaining in dictionary", 0, XUNUSED
XUNUSED:
    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x0, [x0]
    adrp x1, user_dict@page
    add  x1, x1, user_dict@pageoff
    add  x1, x1, #USER_DICT_SIZE
    sub  x0, x1, x0
    DPUSH x0
    NEXT

BOOT_WORD "MS@", "MS@ ( -- u ) wall-clock milliseconds since epoch", 0, XMSFETCH
XMSFETCH:
    SAVE_C_CALLEE
    adrp x0, timeval_buf@page
    add  x0, x0, timeval_buf@pageoff
    mov  x1, xzr
    bl   _gettimeofday
    adrp x2, timeval_buf@page
    add  x2, x2, timeval_buf@pageoff
    ldr  x0, [x2]                   // tv_sec
    ldr  x1, [x2, #8]               // tv_usec
    mov  x2, #1000
    mul  x0, x0, x2
    udiv x1, x1, x2
    add  x0, x0, x1
    RESTORE_C_CALLEE
    DPUSH x0
    NEXT

// MS ( u -- ) sleep at least u ms via nanosleep (yields; GUI-safe)
BOOT_WORD "MS", "MS ( u -- ) wait at least u milliseconds (OS sleep; yields)", 0, XMS
XMS:
    DPOP x0
    cbz  x0, _ms_done
    adrp x1, ms_remain@page
    add  x1, x1, ms_remain@pageoff
    str  x0, [x1]
    SAVE_C_CALLEE
_ms_chunk:
    adrp x1, ms_remain@page
    add  x1, x1, ms_remain@pageoff
    ldr  x19, [x1]
    cbz  x19, _ms_restore
    mov  x1, #1000
    cmp  x19, x1
    csel x2, x19, x1, lo            // chunk ms
    udiv x3, x2, x1                 // sec 0 or 1
    msub x4, x3, x1, x2             // rem_ms
    mov  x5, #1000
    mul  x4, x4, x5
    mul  x4, x4, x5                 // nsec
    adrp x0, timespec_buf@page
    add  x0, x0, timespec_buf@pageoff
    str  x3, [x0]
    str  x4, [x0, #8]
    mov  x1, xzr                    // rem = NULL (ignore EINTR remainder)
    bl   _nanosleep
    adrp x1, ms_remain@page
    add  x1, x1, ms_remain@pageoff
    ldr  x19, [x1]
    mov  x2, #1000
    cmp  x19, x2
    csel x3, x19, x2, lo
    sub  x19, x19, x3
    str  x19, [x1]
    cbnz x19, _ms_chunk
_ms_restore:
    RESTORE_C_CALLEE
_ms_done:
    NEXT

.section __DATA,__bootword,regular
.quad 0, 0, 0, 0

// After all primitives are defined:
.section __DATA,__data
.align 3
inline_len_tab:
    .quad XDUP,   XDUP_END
    .quad XDROP,  XDROP_END
    .quad XSWAP,  XSWAP_END
    .quad XOVER,  XOVER_END
    .quad XPLUS,  XPLUS_END
    .quad XMINUS, XMINUS_END
    .quad XMUL,   XMUL_END
    .quad XDIV,   XDIV_END
    .quad XFETCH, XFETCH_END
    .quad XSTORE, XSTORE_END
    .quad XCFETCH,XCFETCH_END
    .quad XCSTORE,XCSTORE_END
    .quad XAND,   XAND_END
    .quad XORR,   XORR_END
    .quad XXOR,   XXOR_END
    .quad XINVERT,XINVERT_END
    .quad XZEQ,   XZEQ_END
    .quad XZLT,   XZLT_END
    .quad XLT,    XLT_END
    .quad XTOR,   XTOR_END
    .quad XRFROM, XRFROM_END
    .quad XRAT,   XRAT_END
    .quad XI,     XI_END
    .quad XJ,     XJ_END
    .quad XK,     XK_END
    .quad XUNLOOP,XUNLOOP_END
    .quad XLEAVE, XLEAVE_END
    .quad XLSHIFT,XLSHIFT_END
    .quad XRSHIFT,XRSHIFT_END
    .quad 0, 0

// ============================================================================
// Inner interpreter runtimes
// ============================================================================
.text
.align 4

DOCOL:
    RPUSH
    add  x19, x21, #8
    NEXT

DOVAR:
    add  x0, x21, #16
    DPUSH x0
    NEXT

DODOES:
    RPUSH
    ldr  x19, [x21, #8]
    add  x0, x21, #16
    DPUSH x0
    NEXT

XRESTART:
    b    _interpret_loop

// ============================================================================
// Helpers
// ============================================================================

// void kernel_set_emit(void (*fn)(int c))
.globl _kernel_set_emit
_kernel_set_emit:
    adrp x1, emit_hook@page
    add  x1, x1, emit_hook@pageoff
    str  x0, [x1]
    ret

// void kernel_set_emit_buf(void (*fn)(const char *buf, size_t n))
.globl _kernel_set_emit_buf
_kernel_set_emit_buf:
    adrp x1, emit_buf_hook@page
    add  x1, x1, emit_buf_hook@pageoff
    str  x0, [x1]
    ret

.globl _kernel_set_fromlib
_kernel_set_fromlib:
    adrp x1, fromlib_hook@page
    add  x1, x1, fromlib_hook@pageoff
    str  x0, [x1]
    ret

.globl _kernel_set_fromlib_clear
_kernel_set_fromlib_clear:
    adrp x1, fromlib_clear_hook@page
    add  x1, x1, fromlib_clear_hook@pageoff
    str  x0, [x1]
    ret

.globl _kernel_set_end_include
_kernel_set_end_include:
    adrp x1, end_include_hook@page
    add  x1, x1, end_include_hook@pageoff
    str  x0, [x1]
    ret

.globl _kernel_set_load_file
_kernel_set_load_file:
    adrp x1, load_file_hook@page
    add  x1, x1, load_file_hook@pageoff
    str  x0, [x1]
    ret

.globl _kernel_set_resolve_key
_kernel_set_resolve_key:
    adrp x1, resolve_key_hook@page
    add  x1, x1, resolve_key_hook@pageoff
    str  x0, [x1]
    ret

.globl _kernel_set_last_load_key
_kernel_set_last_load_key:
    adrp x1, last_load_key_hook@page
    add  x1, x1, last_load_key_hook@pageoff
    str  x0, [x1]
    ret

.globl _kernel_set_chdir
_kernel_set_chdir:
    adrp x1, chdir_hook@page
    add  x1, x1, chdir_hook@pageoff
    str  x0, [x1]
    ret

.globl _kernel_set_pwd
_kernel_set_pwd:
    adrp x1, pwd_hook@page
    add  x1, x1, pwd_hook@pageoff
    str  x0, [x1]
    ret

.globl _kernel_set_dir
_kernel_set_dir:
    adrp x1, dir_hook@page
    add  x1, x1, dir_hook@pageoff
    str  x0, [x1]
    ret

.globl _kernel_take_repl_batch_stop
_kernel_take_repl_batch_stop:
    adrp x1, repl_batch_stop@page
    add  x1, x1, repl_batch_stop@pageoff
    ldr  x0, [x1]
    str  xzr, [x1]
    ret

// _putchar: w0 = character. Prefer emit_hook; else write(1).
_putchar:
    stp  x29, x30, [sp, #-16]!
    adrp x1, emit_hook@page
    add  x1, x1, emit_hook@pageoff
    ldr  x1, [x1]
    cbz  x1, 1f
    blr  x1
    ldp  x29, x30, [sp], #16
    ret
1:
    sub  sp, sp, #16
    strb w0, [sp]
    mov  x0, #1
    mov  x1, sp
    mov  x2, #1
    mov  x16, #4
    svc  #0x80
    add  sp, sp, #16
    ldp  x29, x30, [sp], #16
    ret

// _sys_write: x1 = buf, x2 = len. Prefer emit_buf_hook, else per-byte emit_hook, else write(1).
_sys_write:
    stp  x29, x30, [sp, #-48]!
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x1                   // buf
    mov  x20, x2                   // len
    adrp x0, emit_buf_hook@page
    add  x0, x0, emit_buf_hook@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    cbz  x20, 3f
    mov  x1, x20
    mov  x2, x0
    mov  x0, x19
    blr  x2
    b    3f
1:
    cbz  x20, 3f
0:
    adrp x0, emit_hook@page
    add  x0, x0, emit_hook@pageoff
    ldr  x0, [x0]
    cbz  x0, 2f
    ldrb w1, [x19], #1
    mov  x21, x0
    mov  w0, w1
    blr  x21
    sub  x20, x20, #1
    cbnz x20, 0b
    b    3f
2:
    cbz  x20, 3f
    mov  x0, #1
    mov  x1, x19
    mov  x2, x20
    mov  x16, #4
    svc  #0x80
3:
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// Save / restore DSP+RSP for embed hosts that return to C between evals.
_vm_save_stacks:
    adrp x0, vm_dsp@page
    add  x0, x0, vm_dsp@pageoff
    str  x22, [x0]
    adrp x0, vm_rsp@page
    add  x0, x0, vm_rsp@pageoff
    str  x23, [x0]
    ret

_vm_restore_stacks:
    adrp x0, vm_dsp@page
    add  x0, x0, vm_dsp@pageoff
    ldr  x22, [x0]
    adrp x0, vm_rsp@page
    add  x0, x0, vm_rsp@pageoff
    ldr  x23, [x0]
    // Rebuild &latest (x24) — address is stable
    adrp x24, latest_var@page
    add  x24, x24, latest_var@pageoff
    ret

_compile_cell:
    adrp x1, here_ptr@page
    add  x1, x1, here_ptr@pageoff
    ldr  x2, [x1]
    str  x0, [x2], #8
    str  x2, [x1]
    ret

// If WARNINGS? and compiling: "<name> uses EXIT - Not inlinable\n"
// Independent of INLINE?. Uses last_cfa name (word being defined).
_maybe_warn_exit:
    stp  x29, x30, [sp, #-32]!
    stp  x19, x20, [sp, #16]
    adrp x0, warnings_var@page
    add  x0, x0, warnings_var@pageoff
    ldr  x0, [x0]
    cbz  x0, 9f
    adrp x0, state_var@page
    add  x0, x0, state_var@pageoff
    ldr  x0, [x0]
    cbz  x0, 9f
    adrp x0, last_cfa@page
    add  x0, x0, last_cfa@pageoff
    ldr  x0, [x0]
    cbz  x0, 9f
    ldr  x1, [x0, #-8]              // FFA
    and  x1, x1, #0xFFFF             // NFA offset
    cbz  x1, 9f
    sub  x19, x0, x1                 // NFA (counted)
    ldrb w20, [x19], #1
    cbz  w20, 1f
    mov  x1, x19
    mov  x2, x20
    bl   _sys_write
1:  adrp x1, str_exit_warn_mid@page
    add  x1, x1, str_exit_warn_mid@pageoff
    mov  x2, #str_exit_warn_mid_len
    bl   _sys_write
9:  ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// After trailing EXIT: set/clear FL_INLINE; maybe native-convert.
// FL_INLINE: safe shape (trailing EXIT only, no RECURSE, no S"), and not N:.
// Native convert (INLINE-ON && !FL_INLINE): requires trailing-EXIT-only
// (expander stops at first EXIT — early EXIT must stay threaded).
_colon_finish_inline:
    stp  x29, x30, [sp, #-32]!
    stp  x19, x20, [sp, #16]
    adrp x0, colon_no_inline@page
    add  x0, x0, colon_no_inline@pageoff
    ldr  x19, [x0]                   // N? nonzero
    str  xzr, [x0]
    bl   _colon_body_scan            // x0=inlineable, x1=trailing_exit_ok
    mov  x20, x1                     // save trailing_exit_ok
    // clear or set FL_INLINE
    adrp x2, last_cfa@page
    add  x2, x2, last_cfa@pageoff
    ldr  x2, [x2]
    cbz  x2, 9f
    ldr  x3, [x2, #-8]
    mov  x4, #(1 << 62)
    bic  x3, x3, x4
    cbnz x19, 1f                     // N: → never set
    cbz  x0, 1f                      // not inlineable shape
    orr  x3, x3, x4
    str  x3, [x2, #-8]
    b    9f                          // stay DOCOL + FL_INLINE
1:  str  x3, [x2, #-8]               // cleared
    // INLINE-ON && trailing EXIT only → whole-word native
    adrp x0, inline_var@page
    add  x0, x0, inline_var@pageoff
    ldr  x0, [x0]
    cbz  x0, 9f
    cbz  x20, 9f                     // early EXIT / corrupt → stay threaded
    bl   _colon_convert_native
9:  ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// Walk threaded body [last_cfa+8, HERE).
// → x0 = 1 if FL_INLINE-safe (trailing EXIT, no self, no S")
// → x1 = 1 if single trailing EXIT (native-convertible shape)
_colon_body_scan:
    mov  x0, #0
    mov  x1, #0
    adrp x2, last_cfa@page
    add  x2, x2, last_cfa@pageoff
    ldr  x9, [x2]                    // xt / self
    cbz  x9, 90f
    ldr  x2, [x9]
    adrp x3, DOCOL@page
    add  x3, x3, DOCOL@pageoff
    cmp  x2, x3
    b.ne 90f
    adrp x2, here_ptr@page
    add  x2, x2, here_ptr@pageoff
    ldr  x10, [x2]                   // end
    add  x11, x9, #8                 // p
    mov  x16, #0                     // saw_self
    mov  x17, #0                     // saw_slit
    adrp x12, cfa_exit@page
    add  x12, x12, cfa_exit@pageoff
    ldr  x12, [x12]
    adrp x13, cfa_lit@page
    add  x13, x13, cfa_lit@pageoff
    ldr  x13, [x13]
    adrp x14, cfa_slit@page
    add  x14, x14, cfa_slit@pageoff
    ldr  x14, [x14]
    adrp x15, cfa_branch@page
    add  x15, x15, cfa_branch@pageoff
    ldr  x15, [x15]
10: cmp  x11, x10
    b.hs 90f                         // ran off without EXIT
    ldr  x2, [x11]
    cmp  x2, x12
    b.eq 20f                         // EXIT
    cmp  x2, x9
    b.ne 11f
    mov  x16, #1                     // self / RECURSE
11: cmp  x2, x14
    b.ne 12f
    mov  x17, #1                     // (S")
    b    90f                         // can't reliably skip payload — fail both
12: cmp  x2, x13
    b.eq 30f                         // LIT + value
    cmp  x2, x15
    b.eq 30f                         // BRANCH + off
    adrp x3, cfa_0branch@page
    add  x3, x3, cfa_0branch@pageoff
    ldr  x3, [x3]
    cmp  x2, x3
    b.eq 30f
    adrp x3, cfa_qdo@page
    add  x3, x3, cfa_qdo@pageoff
    ldr  x3, [x3]
    cmp  x2, x3
    b.eq 30f
    adrp x3, cfa_loop@page
    add  x3, x3, cfa_loop@pageoff
    ldr  x3, [x3]
    cmp  x2, x3
    b.eq 30f
    adrp x3, cfa_plusloop@page
    add  x3, x3, cfa_plusloop@pageoff
    ldr  x3, [x3]
    cmp  x2, x3
    b.eq 30f
    add  x11, x11, #8
    b    10b
30: add  x11, x11, #16
    b    10b
20: add  x2, x11, #8
    cmp  x2, x10
    b.ne 90f                         // early EXIT → neither flag
    // Trailing EXIT only. RECURSE/self: not FL_INLINE and not native-convert
    // for now (convert-before-expand leaves a fragile self-call).
    cbnz x16, 90f
    cbnz x17, 90f
    mov  x1, #1                      // native-convertible
    mov  x0, #1                      // FL_INLINE-safe
90: ret

// Convert last DOCOL body to whole-word native (INLINE-ON && !FL_INLINE).
_colon_convert_native:
    stp  x29, x30, [sp, #-32]!
    stp  x19, x20, [sp, #16]
    adrp x19, last_cfa@page
    add  x19, x19, last_cfa@pageoff
    ldr  x19, [x19]
    cbz  x19, 9f
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x1, [x0]
    cbz  x1, 9f
    str  x1, [x19]                   // CFA → JIT entry
    adrp x0, native_pro@page
    add  x0, x0, native_pro@pageoff
    adrp x1, native_pro_end@page
    add  x1, x1, native_pro_end@pageoff
    sub  x1, x1, x0
    bl   _emit_bytes
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    mov  x1, #-1
    str  x1, [x0]
    mov  x0, x19
    bl   _macro_expand_colon
    adrp x0, native_epi@page
    add  x0, x0, native_epi@pageoff
    adrp x1, native_epi_end@page
    add  x1, x1, native_epi_end@pageoff
    sub  x1, x1, x0
    bl   _emit_bytes
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    str  xzr, [x0]
9:  ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

_cstrlen:
    mov  x1, x0
0:  ldrb w2, [x1], #1
    cbnz w2, 0b
    sub  x0, x1, x0
    sub  x0, x0, #1
    ret

_counted_to_cstr:
    ldrb w1, [x0], #1
    adrp x2, name_buf@page
    add  x2, x2, name_buf@pageoff
    mov  x3, x2
    cbz  w1, 1f
0:  ldrb w4, [x0], #1
    strb w4, [x3], #1
    subs w1, w1, #1
    b.ne 0b
1:  strb wzr, [x3]
    mov  x0, x2
    ret

// _take_pending_help: x1 = help C-string for _header_build; clears pending.
// Preserves x0 and x3. Copies SETDOC text into pending_help_buf (NUL-terminated).
_take_pending_help:
    stp  x0, x3, [sp, #-16]!
    adrp x4, pending_help_addr@page
    add  x4, x4, pending_help_addr@pageoff
    ldr  x0, [x4]
    adrp x5, pending_help_len@page
    add  x5, x5, pending_help_len@pageoff
    ldr  x2, [x5]
    str  xzr, [x4]
    str  xzr, [x5]
    cbz  x0, 2f
    cbz  x2, 2f
    cmp  x2, #255
    b.ls 0f
    mov  x2, #255
0:  adrp x1, pending_help_buf@page
    add  x1, x1, pending_help_buf@pageoff
    mov  x4, x1
1:  cbz  x2, 3f
    ldrb w5, [x0], #1
    strb w5, [x4], #1
    sub  x2, x2, #1
    b    1b
3:  strb wzr, [x4]
    ldp  x0, x3, [sp], #16
    ret
2:  adrp x1, empty_help@page
    add  x1, x1, empty_help@pageoff
    ldp  x0, x3, [sp], #16
    ret

_header_build:
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]

    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3

    adrp x4, here_ptr@page
    add  x4, x4, here_ptr@pageoff
    ldr  x5, [x4]

    mov  x6, x5
    mov  x0, x20
    bl   _cstrlen
    mov  x1, x0
    strb w1, [x5], #1
    cbz  x1, 1f
    mov  x2, x20
0:  ldrb w3, [x2], #1
    strb w3, [x5], #1
    subs x1, x1, #1
    b.ne 0b
1:  add  x5, x5, #7
    and  x5, x5, #-8

    mov  x7, x5
    mov  x0, x19
    bl   _cstrlen
    mov  x1, x0
    strb w1, [x5], #1
    cbz  x1, 2f
    mov  x2, x19
0:  ldrb w3, [x2], #1
    cmp  w3, #'a'
    b.lo 1f
    cmp  w3, #'z'
    b.hi 1f
    sub  w3, w3, #'a' - 'A'
1:  strb w3, [x5], #1
    subs x1, x1, #1
    b.ne 0b
2:  add  x5, x5, #7
    and  x5, x5, #-8

    mov  x9, x5
    add  x5, x5, #24
    add  x10, x9, #16

    // Link into CURRENT wordlist head (fallback FORTH).
    adrp x11, current_var@page
    add  x11, x11, current_var@pageoff
    ldr  x11, [x11]
    cbnz x11, 4f
    adrp x11, latest_var@page
    add  x11, x11, latest_var@pageoff
4:  ldr  x12, [x11]
    str  x12, [x9]

    sub  x13, x10, x7
    and  x13, x13, #0xFFFF
    sub  x14, x10, x6
    and  x14, x14, #0xFFFF
    lsl  x14, x14, #16
    orr  x13, x13, x14
    tst  x21, #FL_IMM           // testing for immediate
    b.eq _in
    orr  x13, x13, #(1 << 63)
_in: tst  x21, #FL_INLINE       // Testing for inlinable
    b.eq 3f
    orr  x13, x13, #(1 << 62)
3:  str  x13, [x9, #8]
    str  x22, [x10]

    adrp x4, here_ptr@page
    add  x4, x4, here_ptr@pageoff
    str  x5, [x4]
    str  x10, [x11]             // CURRENT tip = new CFA

    adrp x4, last_cfa@page
    add  x4, x4, last_cfa@pageoff
    str  x10, [x4]

    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

_set_source:
    adrp x2, source_addr@page
    add  x2, x2, source_addr@pageoff
    str  x0, [x2]
    adrp x2, source_len@page
    add  x2, x2, source_len@pageoff
    str  x1, [x2]
    adrp x2, to_in@page
    add  x2, x2, to_in@pageoff
    str  xzr, [x2]
    adrp x2, file_echo_pos@page
    add  x2, x2, file_echo_pos@pageoff
    str  xzr, [x2]
    ret

// Echo INCLUDE source when FILE-ECHO nonzero.
// Line-oriented (64Forth-style): before parsing the next word, write any
// not-yet-echoed text through the end of the line that contains that word.
// That prints `ELAPSED main` before ELAPSED runs (timing follows the line).
// Uses _sys_write for the span — the old per-char _putchar loop left the
// end limit in x1, which emit_hook clobbers, truncating mid-line.
_file_echo_upto:
    stp  x29, x30, [sp, #-48]!
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    adrp x0, file_echo_var@page
    add  x0, x0, file_echo_var@pageoff
    ldr  x0, [x0]
    cbz  x0, 9f
    adrp x0, source_id_var@page
    add  x0, x0, source_id_var@pageoff
    ldr  x0, [x0]
    cmp  x0, #0
    b.le 9f
    adrp x19, source_addr@page
    add  x19, x19, source_addr@pageoff
    ldr  x19, [x19]                 // base
    adrp x0, source_len@page
    add  x0, x0, source_len@pageoff
    ldr  x20, [x0]                   // len
    // cursor = >IN (next parse position), clamped
    adrp x0, to_in@page
    add  x0, x0, to_in@pageoff
    ldr  x0, [x0]
    cmp  x0, x20
    csel x0, x20, x0, hi
    // skip whitespace to next token (or EOF)
1:  cmp  x0, x20
    b.hs 2f
    ldrb w1, [x19, x0]
    cbz  w1, 2f
    cmp  w1, #32
    b.eq 3f
    cmp  w1, #9
    b.eq 3f
    cmp  w1, #10
    b.eq 3f
    cmp  w1, #13
    b.eq 3f
    b    2f
3:  add  x0, x0, #1
    b    1b
2:  // x0 = token offset or EOF; find end of that line (CR/LF/NUL/EOF)
    mov  x21, x0
4:  cmp  x21, x20
    b.hs 5f
    ldrb w1, [x19, x21]
    cbz  w1, 5f
    cmp  w1, #10
    b.eq 5f
    cmp  w1, #13
    b.eq 5f
    add  x21, x21, #1
    b    4b
5:  // x21 = line_end offset; x22 = file_echo_pos
    adrp x0, file_echo_pos@page
    add  x0, x0, file_echo_pos@pageoff
    ldr  x22, [x0]
    cmp  x22, x20
    csel x22, x20, x22, hi
    cmp  x22, x21
    b.hs 9f                          // already echoed this line
    // write [base+pos, base+line_end)
    add  x1, x19, x22                // buf
    sub  x2, x21, x22                // len
    cbz  x2, 6f
    bl   _sys_write
6:  // Advance past CR/LF/CRLF before putchar (emit clobbers x0-x18).
    mov  x0, x21                     // next pos candidate
    cmp  x21, x20
    b.hs 8f
    ldrb w1, [x19, x21]
    cmp  w1, #10
    b.eq 7f
    cmp  w1, #13
    b.ne 8f
    add  x0, x21, #1
    cmp  x0, x20
    b.hs 8f
    ldrb w1, [x19, x0]
    cmp  w1, #10
    b.ne 8f
    add  x0, x0, #1
    b    8f
7:  add  x0, x21, #1
8:  adrp x1, file_echo_pos@page
    add  x1, x1, file_echo_pos@pageoff
    str  x0, [x1]
    mov  x0, #10
    bl   _putchar
9:  ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// _push_source: save addr,len,>IN,id,echo_pos. x0=1 ok, 0=overflow.
_push_source:
    adrp x0, source_sp@page
    add  x0, x0, source_sp@pageoff
    ldr  x1, [x0]
    cmp  x1, #SRC_MAX
    b.hs 1f
    mov  x2, #SRC_FRAME
    mul  x3, x1, x2
    adrp x2, source_stack@page
    add  x2, x2, source_stack@pageoff
    add  x2, x2, x3
    adrp x3, source_addr@page
    add  x3, x3, source_addr@pageoff
    ldr  x3, [x3]
    str  x3, [x2], #8
    adrp x3, source_len@page
    add  x3, x3, source_len@pageoff
    ldr  x3, [x3]
    str  x3, [x2], #8
    adrp x3, to_in@page
    add  x3, x3, to_in@pageoff
    ldr  x3, [x3]
    str  x3, [x2], #8
    adrp x3, source_id_var@page
    add  x3, x3, source_id_var@pageoff
    ldr  x3, [x3]
    str  x3, [x2], #8
    adrp x3, file_echo_pos@page
    add  x3, x3, file_echo_pos@pageoff
    ldr  x3, [x3]
    str  x3, [x2]
    add  x1, x1, #1
    str  x1, [x0]
    mov  x0, #1
    ret
1:  mov  x0, #0
    ret

// _call_end_include: if current SOURCE-ID > 0, invoke end_include hook.
_call_end_include:
    stp  x29, x30, [sp, #-16]!
    adrp x0, source_id_var@page
    add  x0, x0, source_id_var@pageoff
    ldr  x0, [x0]
    cmp  x0, #0
    b.le 1f
    adrp x0, end_include_hook@page
    add  x0, x0, end_include_hook@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    SAVE_C_CALLEE
    blr  x0
    RESTORE_C_CALLEE
1:  ldp  x29, x30, [sp], #16
    ret

_fromlib_clear:
    stp  x29, x30, [sp, #-16]!
    adrp x0, fromlib_clear_hook@page
    add  x0, x0, fromlib_clear_hook@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    SAVE_C_CALLEE
    blr  x0
    RESTORE_C_CALLEE
1:  ldp  x29, x30, [sp], #16
    ret

// _pop_source: end_include + free malloc buffer if SRCID_MALLOC; restore frame.
// x0=1 restored, 0=already at base.
_pop_source:
    stp  x29, x30, [sp, #-16]!
    adrp x0, source_sp@page
    add  x0, x0, source_sp@pageoff
    ldr  x1, [x0]
    cbz  x1, 9f
    bl   _call_end_include
    adrp x2, source_id_var@page
    add  x2, x2, source_id_var@pageoff
    ldr  x3, [x2]
    cmp  x3, #SRCID_MALLOC
    b.ne 1f
    adrp x3, source_addr@page
    add  x3, x3, source_addr@pageoff
    ldr  x0, [x3]
    cbz  x0, 1f
    bl   _free
1:  adrp x0, source_sp@page
    add  x0, x0, source_sp@pageoff
    ldr  x1, [x0]
    sub  x1, x1, #1
    str  x1, [x0]
    mov  x2, #SRC_FRAME
    mul  x3, x1, x2
    adrp x2, source_stack@page
    add  x2, x2, source_stack@pageoff
    add  x2, x2, x3
    ldr  x3, [x2], #8
    adrp x0, source_addr@page
    add  x0, x0, source_addr@pageoff
    str  x3, [x0]
    ldr  x3, [x2], #8
    adrp x0, source_len@page
    add  x0, x0, source_len@pageoff
    str  x3, [x0]
    ldr  x3, [x2], #8
    adrp x0, to_in@page
    add  x0, x0, to_in@pageoff
    str  x3, [x0]
    ldr  x3, [x2], #8
    adrp x0, source_id_var@page
    add  x0, x0, source_id_var@pageoff
    str  x3, [x0]
    ldr  x3, [x2]
    adrp x0, file_echo_pos@page
    add  x0, x0, file_echo_pos@pageoff
    str  x3, [x0]
    mov  x0, #1
    ldp  x29, x30, [sp], #16
    ret
9:  mov  x0, #0
    ldp  x29, x30, [sp], #16
    ret

// _path_to_name_buf: x0=c-addr, x1=u → name_buf NUL, include_path_len=u (capped).
_path_to_name_buf:
    cmp  x1, #255
    b.ls 1f
    mov  x1, #255
1:  adrp x2, include_path_len@page
    add  x2, x2, include_path_len@pageoff
    str  x1, [x2]
    adrp x2, name_buf@page
    add  x2, x2, name_buf@pageoff
    mov  x3, x1
2:  cbz  x3, 3f
    ldrb w4, [x0], #1
    strb w4, [x2], #1
    sub  x3, x3, #1
    b    2b
3:  strb wzr, [x2]
    ret

// _next_filespec: parse next path from SOURCE (preserves case; supports "quotes").
// → name_buf, include_path_len; x0=len (0 if none).
_next_filespec:
    adrp x1, source_addr@page
    add  x1, x1, source_addr@pageoff
    ldr  x1, [x1]
    adrp x2, source_len@page
    add  x2, x2, source_len@pageoff
    ldr  x2, [x2]
    adrp x3, to_in@page
    add  x3, x3, to_in@pageoff
    ldr  x4, [x3]
1:  cmp  x4, x2
    b.hs 8f
    ldrb w5, [x1, x4]
    cmp  w5, #' '
    b.hi 2f
    add  x4, x4, #1
    b    1b
2:  cmp  w5, #'"'
    b.eq 4f
    // unquoted: until whitespace
    mov  x6, x4
3:  cmp  x4, x2
    b.hs 5f
    ldrb w5, [x1, x4]
    cmp  w5, #' '
    b.ls 5f
    add  x4, x4, #1
    b    3b
5:  sub  x7, x4, x6
    str  x4, [x3]
    add  x0, x1, x6
    mov  x1, x7
    b    _path_to_name_buf_ret
4:  // quoted
    add  x4, x4, #1
    mov  x6, x4
6:  cmp  x4, x2
    b.hs 7f
    ldrb w5, [x1, x4]
    cmp  w5, #'"'
    b.eq 7f
    add  x4, x4, #1
    b    6b
7:  sub  x7, x4, x6
    cmp  x4, x2
    b.hs 70f
    add  x4, x4, #1             // consume closing quote
70: str  x4, [x3]
    add  x0, x1, x6
    mov  x1, x7
    b    _path_to_name_buf_ret
8:  str  x4, [x3]
    mov  x0, #0
    adrp x1, include_path_len@page
    add  x1, x1, include_path_len@pageoff
    str  xzr, [x1]
    ret
_path_to_name_buf_ret:
    stp  x30, xzr, [sp, #-16]!
    bl   _path_to_name_buf
    adrp x0, include_path_len@page
    add  x0, x0, include_path_len@pageoff
    ldr  x0, [x0]
    ldp  x30, xzr, [sp], #16
    ret

// _included_find: x0=path bytes, x1=len → x0=1 if in registry (case-sensitive).
_included_find:
    adrp x2, included_count@page
    add  x2, x2, included_count@pageoff
    ldr  x2, [x2]
    cbz  x2, 9f
    mov  x3, #0
1:  cmp  x3, x2
    b.hs 9f
    mov  x4, #INCL_NAME
    mul  x4, x4, x3
    adrp x5, included_names@page
    add  x5, x5, included_names@pageoff
    add  x5, x5, x4
    ldrb w6, [x5]
    cmp  x6, x1
    b.ne 2f
    add  x7, x5, #1
    mov  x8, x0
    mov  x9, x1
3:  cbz  x9, 4f
    ldrb w10, [x7], #1
    ldrb w11, [x8], #1
    cmp  w10, w11
    b.ne 2f
    sub  x9, x9, #1
    b    3b
4:  mov  x0, #1
    ret
2:  add  x3, x3, #1
    b    1b
9:  mov  x0, #0
    ret

// _included_register: name_buf / include_path_len → registry (no-op if full/dup).
_included_register:
    stp  x29, x30, [sp, #-16]!
    adrp x0, name_buf@page
    add  x0, x0, name_buf@pageoff
    adrp x1, include_path_len@page
    add  x1, x1, include_path_len@pageoff
    ldr  x1, [x1]
    cbz  x1, 9f
    bl   _included_find
    cbnz x0, 9f
    adrp x0, included_count@page
    add  x0, x0, included_count@pageoff
    ldr  x2, [x0]
    cmp  x2, #INCL_MAX
    b.hs 9f
    mov  x3, #INCL_NAME
    mul  x3, x3, x2
    adrp x4, included_names@page
    add  x4, x4, included_names@pageoff
    add  x4, x4, x3
    cmp  x1, #255
    b.ls 1f
    mov  x1, #255
1:  strb w1, [x4], #1
    adrp x5, name_buf@page
    add  x5, x5, name_buf@pageoff
2:  cbz  x1, 3f
    ldrb w6, [x5], #1
    strb w6, [x4], #1
    sub  x1, x1, #1
    b    2b
3:  add  x2, x2, #1
    str  x2, [x0]
9:  ldp  x29, x30, [sp], #16
    ret

_include_need_name:
    adrp x1, str_incl_need@page
    add  x1, x1, str_incl_need@pageoff
    mov  x2, #18
    bl   _sys_write
    bl   _fromlib_clear
    b    _abort

// _resolve_abs_key: if resolve_key_hook set, rewrite name_buf to absolute key.
// Hook: (path, path_len, out, out_max, out_len*) — 5th arg on stack.
_resolve_abs_key:
    stp  x29, x30, [sp, #-16]!
    adrp x0, resolve_key_hook@page
    add  x0, x0, resolve_key_hook@pageoff
    ldr  x9, [x0]
    cbz  x9, 9f
    adrp x0, name_buf@page
    add  x0, x0, name_buf@pageoff
    adrp x1, include_path_len@page
    add  x1, x1, include_path_len@pageoff
    ldr  x1, [x1]
    cbz  x1, 9f
    adrp x2, resolve_key_buf@page
    add  x2, x2, resolve_key_buf@pageoff
    mov  x3, #255
    sub  sp, sp, #32
    str  xzr, [sp, #16]          // out_len cell
    add  x4, sp, #16
    str  x4, [sp]                // 5th arg: &out_len
    SAVE_C_CALLEE
    blr  x9
    RESTORE_C_CALLEE
    ldr  x1, [sp, #16]
    add  sp, sp, #32
    cbnz x0, 9f
    cbz  x1, 9f
    adrp x0, resolve_key_buf@page
    add  x0, x0, resolve_key_buf@pageoff
    bl   _path_to_name_buf
9:  ldp  x29, x30, [sp], #16
    ret

// Prefer last_load_key absolute path into name_buf before registry insert.
// Hook: (out, out_max, out_len*)
_apply_last_load_key:
    stp  x29, x30, [sp, #-16]!
    adrp x0, last_load_key_hook@page
    add  x0, x0, last_load_key_hook@pageoff
    ldr  x9, [x0]
    cbz  x9, 9f
    adrp x0, resolve_key_buf@page
    add  x0, x0, resolve_key_buf@pageoff
    mov  x1, #255
    sub  sp, sp, #16
    str  xzr, [sp]
    mov  x2, sp                  // &out_len
    SAVE_C_CALLEE
    blr  x9
    RESTORE_C_CALLEE
    ldr  x1, [sp], #16
    cbnz x0, 9f
    cbz  x1, 9f
    adrp x0, resolve_key_buf@page
    add  x0, x0, resolve_key_buf@pageoff
    bl   _path_to_name_buf
9:  ldp  x29, x30, [sp], #16
    ret

// Shared: name_buf + include_path_len (0 = bare). Hook or host_load_entire fallback.
_include_do:
    stp  x19, x20, [sp, #-48]!
    str  xzr, [sp, #16]          // out_buf
    str  xzr, [sp, #24]          // out_len
    str  xzr, [sp, #32]          // owned: 0=host, 1=malloc
    adrp x1, include_path_len@page
    add  x1, x1, include_path_len@pageoff
    ldr  x1, [x1]
    // Try host load_file hook first (supports bare panel).
    adrp x0, load_file_hook@page
    add  x0, x0, load_file_hook@pageoff
    ldr  x9, [x0]
    cbz  x9, _include_fallback
    cbz  x1, 2f
    adrp x0, name_buf@page
    add  x0, x0, name_buf@pageoff
    b    3f
2:  mov  x0, #0
    mov  x1, #0
3:  add  x2, sp, #16
    add  x3, sp, #24
    SAVE_C_CALLEE
    blr  x9
    RESTORE_C_CALLEE
    mov  x19, x0
    ldr  x20, [sp, #16]
    cbnz x19, _include_fail_msg
    cbz  x20, _include_fail_msg
    // host-owned buffer
    str  xzr, [sp, #32]
    b    _include_install

_include_fallback:
    // Headless: no bare panel
    cbz  x1, _include_need_name_pop
    adrp x0, name_buf@page
    add  x0, x0, name_buf@pageoff
    add  x2, sp, #16
    add  x3, sp, #24
    // host_load_entire wants long long* out_buf/out_len — same layout
    SAVE_C_CALLEE
    bl   _host_load_entire
    RESTORE_C_CALLEE
    mov  x19, x0
    ldr  x20, [sp, #16]
    cbnz x19, _include_fail_msg
    cbz  x20, _include_fail_msg
    mov  x0, #1
    str  x0, [sp, #32]           // malloc-owned
    b    _include_install

_include_need_name_pop:
    ldp  x19, x20, [sp], #48
    b    _include_need_name

_include_install:
    bl   _push_source
    cbz  x0, _include_overflow_free
    mov  x0, x20
    ldr  x1, [sp, #24]
    bl   _set_source
    adrp x0, source_id_var@page
    add  x0, x0, source_id_var@pageoff
    ldr  x1, [sp, #32]
    cbnz x1, 1f
    mov  x1, #SRCID_HOST
    b    2f
1:  mov  x1, #SRCID_MALLOC
2:  str  x1, [x0]
    adrp x0, file_echo_pos@page
    add  x0, x0, file_echo_pos@pageoff
    str  xzr, [x0]
    bl   _apply_last_load_key
    bl   _included_register
    ldp  x19, x20, [sp], #48
    NEXT

_include_overflow_free:
    ldr  x0, [sp, #32]
    cbz  x0, 1f                  // host-owned: do not free
    mov  x0, x20
    bl   _free
1:  adrp x1, str_incl_nest@page
    add  x1, x1, str_incl_nest@pageoff
    mov  x2, #20
    bl   _sys_write
    b    _include_fail

_include_fail_msg:
    bl   _fromlib_clear
    adrp x1, str_cant_open@page
    add  x1, x1, str_cant_open@pageoff
    mov  x2, #12
    bl   _sys_write
    adrp x1, name_buf@page
    add  x1, x1, name_buf@pageoff
    adrp x2, include_path_len@page
    add  x2, x2, include_path_len@pageoff
    ldr  x2, [x2]
    bl   _sys_write
    adrp x1, str_nl@page
    add  x1, x1, str_nl@pageoff
    mov  x2, #1
    bl   _sys_write
_include_fail:
    ldp  x19, x20, [sp], #48
    b    _abort

_word:
    adrp x1, source_addr@page
    add  x1, x1, source_addr@pageoff
    ldr  x1, [x1]
    adrp x2, source_len@page
    add  x2, x2, source_len@pageoff
    ldr  x2, [x2]
    adrp x3, to_in@page
    add  x3, x3, to_in@pageoff
    ldr  x4, [x3]

skip_ws:
    cmp  x4, x2
    b.hs end_of_source
    ldrb w5, [x1, x4]
    cmp  w5, #' '
    b.hi token_start
    add  x4, x4, #1
    b    skip_ws

token_start:
    mov  x6, x4
scan:
    cmp  x4, x2
    b.hs token_end
    ldrb w5, [x1, x4]
    cmp  w5, #' '
    b.ls token_end
    add  x4, x4, #1
    b    scan

token_end:
    sub  x7, x4, x6
    str  x4, [x3]
    adrp x8, here_ptr@page
    add  x8, x8, here_ptr@pageoff
    ldr  x9, [x8]
    strb w7, [x9]
    cbz  x7, empty_token
    add  x10, x1, x6
    add  x11, x9, #1
copy:
    ldrb w12, [x10], #1
    cmp  w12, #'a'
    b.lo 2f
    cmp  w12, #'z'
    b.hi 2f
    sub  w12, w12, #32
2:  strb w12, [x11], #1
    subs x7, x7, #1
    b.ne copy
empty_token:
    mov  x0, x9
    ret
end_of_source:
    str  x4, [x3]
    mov  x0, #0
    ret

// _wordlist_register: x0 = wid. Append if not already present and room remains.
_wordlist_register:
    adrp x1, wordlist_reg_n@page
    add  x1, x1, wordlist_reg_n@pageoff
    ldr  x2, [x1]
    adrp x3, wordlist_reg@page
    add  x3, x3, wordlist_reg@pageoff
    mov  x4, #0
1:  cmp  x4, x2
    b.hs 2f
    ldr  x5, [x3, x4, lsl #3]
    cmp  x5, x0
    b.eq 3f
    add  x4, x4, #1
    b    1b
2:  cmp  x2, #WORDLIST_REG_MAX
    b.hs 3f
    str  x0, [x3, x2, lsl #3]
    add  x2, x2, #1
    str  x2, [x1]
3:  ret

// _print_wid_name: x0 = wid. Prints FORTH, VOCABULARY name, or "wid".
_print_wid_name:
    stp  x29, x30, [sp, #-48]!
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x0
    adrp x1, latest_var@page
    add  x1, x1, latest_var@pageoff
    cmp  x19, x1
    b.ne 1f
    adrp x1, str_forth_name@page
    add  x1, x1, str_forth_name@pageoff
    mov  x2, #5
    bl   _sys_write
    b    9f
1:  adrp x0, DODOES@page
    add  x0, x0, DODOES@pageoff
    mov  x22, x0
    mov  x20, #0
20: cmp  x20, #DICT_THREADS
    b.hs 8f
    adrp x0, latest_var@page
    add  x0, x0, latest_var@pageoff
    add  x0, x0, x20, lsl #3
    ldr  x21, [x0]
2:  cbz  x21, 21f
    ldr  x0, [x21]
    cmp  x0, x22
    b.ne 3f
    add  x0, x21, #16
    cmp  x0, x19
    b.ne 3f
    ldr  x0, [x21, #-8]
    and  x0, x0, #0xFFFF
    sub  x0, x21, x0
    ldrb w1, [x0], #1
    mov  x2, #0
4:  cmp  x2, x1
    b.hs 9f
    ldrb w3, [x0, x2]
    stp  x0, x1, [sp, #-16]!
    stp  x2, xzr, [sp, #-16]!
    mov  x0, x3
    bl   _putchar
    ldp  x2, xzr, [sp], #16
    ldp  x0, x1, [sp], #16
    add  x2, x2, #1
    b    4b
3:  ldr  x21, [x21, #-16]
    b    2b
21: add  x20, x20, #1
    b    20b
8:  adrp x1, str_wid@page
    add  x1, x1, str_wid@pageoff
    mov  x2, #3
    bl   _sys_write
9:  ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// _find: x0 = counted name → x0=CFA/0, x1=-1|1|0 (imm flag). Walks search order.
_find:
    stp  x19, x20, [sp, #-48]!
    stp  x21, x22, [sp, #16]
    str  x23, [sp, #32]
    mov  x19, x0                   // counted name
    adrp x0, search_order_n@page
    add  x0, x0, search_order_n@pageoff
    ldr  x20, [x0]                 // n
    cbz  x20, _find_fallback_forth
    mov  x21, #0                   // order index
_find_wl:
    cmp  x21, x20
    b.hs _find_miss
    adrp x0, search_order@page
    add  x0, x0, search_order@pageoff
    ldr  x22, [x0, x21, lsl #3]    // wid
    cbz  x22, _find_next_wl
    ldr  x22, [x22]                // tip CFA (DICT_THREADS=1)
_find_chain:
    cbz  x22, _find_next_wl
    ldr  x3, [x22, #-8]
    and  x4, x3, #0xFFFF
    sub  x5, x22, x4               // NFA
    ldrb w6, [x19]
    ldrb w7, [x5]
    cmp  w6, w7
    b.ne _find_next
    add  x8, x19, #1
    add  x9, x5, #1
0:  cbz  w6, _find_hit
    ldrb w10, [x8], #1
    ldrb w11, [x9], #1
    cmp  w10, w11
    b.ne _find_next
    sub  w6, w6, #1
    b    0b
_find_hit:
    tst  x3, #(1 << 63)
    mov  x1, #-1
    b.eq 1f
    mov  x1, #1
1:  mov  x0, x22
    ldr  x23, [sp, #32]
    ldp  x21, x22, [sp, #16]
    ldp  x19, x20, [sp], #48
    ret
_find_next:
    ldr  x22, [x22, #-16]
    b    _find_chain
_find_next_wl:
    add  x21, x21, #1
    b    _find_wl
_find_fallback_forth:
    adrp x22, latest_var@page
    add  x22, x22, latest_var@pageoff
    ldr  x22, [x22]
    mov  x20, #1
    mov  x21, #0
    // Fake a one-entry order using latest tip already in x22
    b    _find_chain
_find_miss:
    mov  x0, #0
    mov  x1, #0
    ldr  x23, [sp, #32]
    ldp  x21, x22, [sp, #16]
    ldp  x19, x20, [sp], #48
    ret

_number:
    ldrb w1, [x0]
    cbz  w1, 9f
    add  x2, x0, #1
    mov  x3, #0
    mov  x4, #1
    ldrb w5, [x2]
    cmp  w5, #'-'
    b.ne 1f
    mov  x4, #-1
    add  x2, x2, #1
    sub  w1, w1, #1
1:  cbz  w1, 9f
0:  ldrb w5, [x2], #1
    sub  w5, w5, #'0'
    cmp  w5, #9
    b.hi 9f
    mov  x6, #10
    mul  x3, x3, x6
    add  x3, x3, x5
    subs w1, w1, #1
    b.ne 0b
    mul  x0, x3, x4
    mov  x1, #1
    ret
9:  mov  x1, #0
    ret

_parse_quote:
    adrp x2, source_addr@page
    add  x2, x2, source_addr@pageoff
    ldr  x2, [x2]
    adrp x3, source_len@page
    add  x3, x3, source_len@pageoff
    ldr  x3, [x3]
    adrp x4, to_in@page
    add  x4, x4, to_in@pageoff
    ldr  x5, [x4]
    cmp  x5, x3
    b.hs 2f
    ldrb w6, [x2, x5]
    cmp  w6, #' '
    b.ne 1f
    add  x5, x5, #1
1:  mov  x0, x5
3:  cmp  x5, x3
    b.hs 4f
    ldrb w6, [x2, x5]
    cmp  w6, #'"'
    b.eq 4f
    add  x5, x5, #1
    b    3b
4:  sub  x1, x5, x0
    add  x0, x2, x0
    cmp  x5, x3
    b.hs 5f
    add  x5, x5, #1
5:  str  x5, [x4]
    ret
2:  mov  x0, x2
    mov  x1, #0
    ret

_boot_kernel:
    stp  x29, x30, [sp, #-16]!
    adrp x9, boot_word_table@page
    add  x9, x9, boot_word_table@pageoff
1:  ldr  x0, [x9]
    cbz  x0, 2f
    ldr  x1, [x9, #8]
    ldr  x2, [x9, #16]
    ldr  x3, [x9, #24]
    stp  x9, xzr, [sp, #-16]!
    bl   _header_build
    ldp  x9, xzr, [sp], #16
    add  x9, x9, #32
    b    1b
2:  // TRAVERSE-WORDLIST continuation trampoline
    adrp x0, XTW_CONTINUE@page
    add  x0, x0, XTW_CONTINUE@pageoff
    adrp x1, tw_continue_cfa@page
    add  x1, x1, tw_continue_cfa@pageoff
    str  x0, [x1]
    adrp x0, tw_continue_cell@page
    add  x0, x0, tw_continue_cell@pageoff
    adrp x1, tw_continue_cfa@page
    add  x1, x1, tw_continue_cfa@pageoff
    str  x1, [x0]
    ldp  x29, x30, [sp], #16
    ret

_cache_one:
    stp  x1, x30, [sp, #-16]!
    bl   _find
    ldp  x1, x30, [sp], #16
    cbz  x0, _cache_fail
    str  x0, [x1]
    ret
_cache_fail:
    adrp x1, str_cache_fail@page
    add  x1, x1, str_cache_fail@pageoff
    mov  x2, #18
    bl   _sys_write
    b    _die

_boot_cache:
    stp  x29, x30, [sp, #-16]!
    adrp x0, cnt_lit@page
    add  x0, x0, cnt_lit@pageoff
    adrp x1, cfa_lit@page
    add  x1, x1, cfa_lit@pageoff
    bl   _cache_one
    
    adrp x0, cnt_exit@page
    add  x0, x0, cnt_exit@pageoff
    adrp x1, cfa_exit@page
    add  x1, x1, cfa_exit@pageoff
    bl   _cache_one
    
    adrp x0, cnt_comma@page
    add  x0, x0, cnt_comma@pageoff
    adrp x1, cfa_comma@page
    add  x1, x1, cfa_comma@pageoff
    bl   _cache_one
    
    adrp x0, cnt_does@page
    add  x0, x0, cnt_does@pageoff
    adrp x1, cfa_does_rt@page
    add  x1, x1, cfa_does_rt@pageoff
    bl   _cache_one
    
    adrp x0, cnt_slit@page
    add  x0, x0, cnt_slit@pageoff
    adrp x1, cfa_slit@page
    add  x1, x1, cfa_slit@pageoff
    bl   _cache_one

    adrp x0, cnt_branch@page
    add  x0, x0, cnt_branch@pageoff
    adrp x1, cfa_branch@page
    add  x1, x1, cfa_branch@pageoff
    bl   _cache_one

    adrp x0, cnt_0branch@page
    add  x0, x0, cnt_0branch@pageoff
    adrp x1, cfa_0branch@page
    add  x1, x1, cfa_0branch@pageoff
    bl   _cache_one

    adrp x0, cnt_do@page
    add  x0, x0, cnt_do@pageoff
    adrp x1, cfa_do@page
    add  x1, x1, cfa_do@pageoff
    bl   _cache_one

    adrp x0, cnt_qdo@page
    add  x0, x0, cnt_qdo@pageoff
    adrp x1, cfa_qdo@page
    add  x1, x1, cfa_qdo@pageoff
    bl   _cache_one

    adrp x0, cnt_loop@page
    add  x0, x0, cnt_loop@pageoff
    adrp x1, cfa_loop@page
    add  x1, x1, cfa_loop@pageoff
    bl   _cache_one

    adrp x0, cnt_plusloop@page
    add  x0, x0, cnt_plusloop@pageoff
    adrp x1, cfa_plusloop@page
    add  x1, x1, cfa_plusloop@pageoff
    bl   _cache_one

    ldp  x29, x30, [sp], #16
    ret

// ============================================================================
// Outer interpreter
// ============================================================================
_interpret_run:
    adrp x1, interp_lr@page
    add  x1, x1, interp_lr@pageoff
    str  x30, [x1]
    adrp x1, in_interpret@page
    add  x1, x1, in_interpret@pageoff
    mov  x0, #1
    str  x0, [x1]
    b    _interpret_loop

_interpret_loop:
    bl   _check_data_stack
    cbnz x0, _abort
    bl   _file_echo_upto
    bl   _word
    cbz  x0, _interpret_empty
    ldrb w1, [x0]
    cbz  w1, _interpret_loop

    adrp x1, word_addr@page
    add  x1, x1, word_addr@pageoff
    str  x0, [x1]

    bl   _find
    cbz  x0, _try_num

    adrp x2, state_var@page
    add  x2, x2, state_var@pageoff
    ldr  x2, [x2]
    cbz  x2, _exec
    cmp  x1, #1
    b.eq _exec
    bl   _compile_word
    b    _interpret_loop

_exec:
    adrp x19, restart_cell@page
    add  x19, x19, restart_cell@pageoff
    mov  x21, x0
    ldr  x1, [x21]
    br   x1

_try_num:
    adrp x0, word_addr@page
    add  x0, x0, word_addr@pageoff
    ldr  x0, [x0]
    bl   _number
    cbz  x1, _undef_current
    adrp x2, state_var@page
    add  x2, x2, state_var@pageoff
    ldr  x2, [x2]
    cbnz x2, _compile_num
    DPUSH x0
    b    _interpret_loop

_compile_num:
    adrp x2, compiling_native@page
    add  x2, x2, compiling_native@pageoff
    ldr  x2, [x2]
    cbnz x2, 1f

    str  x0, [sp, #-16]!
    adrp x0, cfa_lit@page
    add  x0, x0, cfa_lit@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    ldr  x0, [sp], #16
    bl   _compile_cell
    b    _interpret_loop

1:  bl   _emit_native_lit          // x0 = value
    b    _interpret_loop
    
_undef_current:
    adrp x1, str_undef@page
    add  x1, x1, str_undef@pageoff
    mov  x2, #11
    bl   _sys_write
    adrp x0, word_addr@page
    add  x0, x0, word_addr@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    ldrb w2, [x0]
    add  x1, x0, #1
    bl   _sys_write
1:  adrp x1, str_nl@page
    add  x1, x1, str_nl@pageoff
    mov  x2, #1
    bl   _sys_write
    b    _abort
    
// End of current SOURCE: pop nested INCLUDE or finish this evaluate.
_interpret_empty:
    bl   _pop_source               // x0=1 restored outer
    cbnz x0, _interpret_loop
    b    _interpret_done

_interpret_done:
    adrp x1, in_interpret@page
    add  x1, x1, in_interpret@pageoff
    str  xzr, [x1]
    adrp x1, interp_lr@page
    add  x1, x1, interp_lr@pageoff
    ldr  x30, [x1]
    ret

_die:
    mov  x0, #1
    mov  x16, #1
    svc  #0x80

// Returns: NZ = bad stack, EQ = ok.  Does not change x22 unless you want reset in abort.
_check_data_stack:
    adrp x0, data_stack@page
    add  x0, x0, data_stack@pageoff          // base
    mov  x1, x0
    add  x1, x1, #DSTACK_SIZE               // empty
    cmp  x22, x1
    b.hi _stack_underflow                   // x22 > empty
    cmp  x22, x0
    b.lo _stack_overflow                    // x22 < base
    mov  x0, #0
    ret
    
_stack_underflow:
    adrp x1, str_under@page
    add  x1, x1, str_under@pageoff
    ldr  x2, [x1], #8
    bl   _sys_write
    b    _abort

_stack_overflow:
    adrp x1, str_over@page
    add  x1, x1, str_over@pageoff
    ldr  x2, [x1], #8
    bl   _sys_write
    b    _abort

// ABORT: empty data + return stacks, leave compile state, then QUIT.
_abort:
    // If compiling, unlink incomplete def from CURRENT tip via last_cfa.
    adrp x0, state_var@page
    add  x0, x0, state_var@pageoff
    ldr  x1, [x0]
    cbz  x1, 1f
    adrp x2, last_cfa@page
    add  x2, x2, last_cfa@pageoff
    ldr  x3, [x2]
    cbz  x3, 1f
    adrp x4, current_var@page
    add  x4, x4, current_var@pageoff
    ldr  x4, [x4]
    cbnz x4, 0f
    adrp x4, latest_var@page
    add  x4, x4, latest_var@pageoff
0:  ldr  x5, [x4]
    cmp  x5, x3
    b.ne 1f
    ldr  x5, [x3, #-16]
    str  x5, [x4]
1:  str  xzr, [x0]                  // STATE = 0
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    str  xzr, [x0]
    adrp x0, colon_no_inline@page
    add  x0, x0, colon_no_inline@pageoff
    str  xzr, [x0]
    // If D: was open, restore prior INLINE?; else leave INLINE? alone.
    adrp x0, dcolon_flag@page
    add  x0, x0, dcolon_flag@pageoff
    ldr  x1, [x0]
    cbz  x1, 2f
    str  xzr, [x0]
    adrp x0, dcolon_saved@page
    add  x0, x0, dcolon_saved@pageoff
    ldr  x1, [x0]
    adrp x0, inline_var@page
    add  x0, x0, inline_var@pageoff
    str  x1, [x0]
2:  // Unwind nested INCLUDE frames (free malloc'd file buffers).
3:  bl   _pop_source
    cbnz x0, 3b
    // Pin base SOURCE >IN to end so remainder of this evaluate is skipped.
    adrp x0, source_len@page
    add  x0, x0, source_len@pageoff
    ldr  x0, [x0]
    adrp x1, to_in@page
    add  x1, x1, to_in@pageoff
    str  x0, [x1]
    adrp x22, data_stack@page
    add  x22, x22, data_stack@pageoff
    add  x22, x22, #DSTACK_SIZE
    adrp x23, return_stack@page
    add  x23, x23, return_stack@pageoff
    add  x23, x23, #RSTACK_SIZE
    b    _do_quit

// QUIT: empty return stack, interpret state. ANS does not empty the data stack.
// Like 64Forth: under embed_mode return to the host; else enter the CLI loop.
// Does not clear INLINE? — user INLINE-ON survives errors / QUIT.
_do_quit:
    adrp x0, state_var@page
    add  x0, x0, state_var@pageoff
    str  xzr, [x0]
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    str  xzr, [x0]
    adrp x0, colon_no_inline@page
    add  x0, x0, colon_no_inline@pageoff
    str  xzr, [x0]
    adrp x0, dcolon_flag@page
    add  x0, x0, dcolon_flag@pageoff
    ldr  x1, [x0]
    cbz  x1, 1f
    str  xzr, [x0]
    adrp x0, dcolon_saved@page
    add  x0, x0, dcolon_saved@pageoff
    ldr  x1, [x0]
    adrp x0, inline_var@page
    add  x0, x0, inline_var@pageoff
    str  x1, [x0]
1:
    adrp x23, return_stack@page
    add  x23, x23, return_stack@pageoff
    add  x23, x23, #RSTACK_SIZE

    adrp x0, embed_mode@page
    add  x0, x0, embed_mode@pageoff
    ldr  x0, [x0]
    cbnz x0, _embed_quit_return

    adrp x0, quit_ready@page
    add  x0, x0, quit_ready@pageoff
    ldr  x0, [x0]
    cbz  x0, _die
    b    _quit_loop

// GUI/host: finish this kernel_eval without unbalanced-C-stack ret via interp_lr.
// Abort often happens deep in bl helpers; restoring embed_c_sp matches 64Forth.
_embed_quit_return:
    adrp x0, in_interpret@page
    add  x0, x0, in_interpret@pageoff
    str  xzr, [x0]
    bl   _vm_save_stacks
    mov  x0, #0
    // fall through

// Restore the SAVE_C_CALLEE frame saved in embed_c_sp and return x0 to host.
_embed_ret_x0:
    adrp x1, embed_c_sp@page
    add  x1, x1, embed_c_sp@pageoff
    ldr  x1, [x1]
    cbz  x1, _die
    mov  sp, x1
    RESTORE_C_CALLEE
    ret

// ============================================================================
// helpers for inlineable
// ============================================================================
// x0 = code address → x1 = length, or 0 if not inlineable
_inline_len:
    adrp x2, inline_len_tab@page
    add  x2, x2, inline_len_tab@pageoff
1:  ldr  x3, [x2], #16
    cbz  x3, 2f
    cmp  x3, x0
    b.ne 1b
    ldr  x1, [x2, #-8]           // end label
    sub  x1, x1, x0
    ret
2:  mov  x1, #0
    ret

// copy x1 bytes from x0 to HERE, 4-align HERE
_emit_bytes:                       // x0=src, x1=len
    stp  x0, x1, [sp, #-32]!
    stp  x29, x30, [sp, #16]
    bl   _forth_code_begin_write
    ldp  x0, x1, [sp]
    adrp x2, code_here@page
    add  x2, x2, code_here@pageoff
    ldr  x3, [x2]
    cbz  x3, 3f
    cbz  x1, 2f
1:  ldrb w4, [x0], #1
    strb w4, [x3], #1
    subs x1, x1, #1
    b.ne 1b
2:  add  x3, x3, #3
    and  x3, x3, #-4
    str  x3, [x2]
3:  bl   _forth_code_end_write
    ldp  x29, x30, [sp, #16]
    add  sp, sp, #32
    ret

// w0 = instruction
// already have _emit_u32

// x0 = dest addr, x1 = instr addr  → patch B, CBZ, or B.cond at x1 to dest
_patch_rel:
    stp  x29, x30, [sp, #-32]!
    stp  x19, x20, [sp, #16]
    mov  x19, x0                    // dest
    mov  x20, x1                    // instr
    bl   _forth_code_begin_write
    sub  x0, x19, x20
    asr  x0, x0, #2                 // imm in words
    ldr  w1, [x20]
    lsr  w2, w1, #24
    cmp  w2, #0xB4                  // CBZ
    b.eq 1f
    cmp  w2, #0x54                  // B.cond
    b.eq 3f
    // B imm26 (top 6 bits 0x14)
    and  x0, x0, #0x03FFFFFF
    and  w1, w1, #0xFC000000
    orr  w1, w1, w0
    b    2f
1:  // CBZ imm19 at bits 23-5
    and  x0, x0, #0x7FFFF
    mov  w2, w1
    and  w2, w2, #0xFF00001F
    orr  w1, w2, w0, lsl #5
    b    2f
3:  // B.cond imm19 at bits 23-5; keep cond in bits 3-0
    and  x0, x0, #0x7FFFF
    and  w2, w1, #0xFF00001F
    orr  w1, w2, w0, lsl #5
2:  str  w1, [x20]
    bl   _forth_code_end_write
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// w0 = one A64 instruction → append to code_here
_emit_u32:
    stp  x29, x30, [sp, #-16]!
    str  w0, [sp, #-16]!
    mov  x0, sp
    mov  x1, #4
    bl   _emit_bytes
    add  sp, sp, #16
    ldp  x29, x30, [sp], #16
    ret

// x0 = 64-bit literal
// emits:
//   movz x0, #b0
//   movk x0, #b1, lsl #16
//   movk x0, #b2, lsl #32
//   movk x0, #b3, lsl #48
//   str  x0, [x22, #-8]!
_emit_native_lit:
    stp  x29, x30, [sp, #-32]!
    str  x19, [sp, #16]
    mov  x19, x0                    // keep value

    mov  x0, x19
    and  x0, x0, #0xFFFF
    movz x1, #0x0000
    movk x1, #0xD280, lsl #16       // MOVZ x0, #imm
    orr  x0, x1, x0, lsl #5
    bl   _emit_u32

    lsr  x0, x19, #16
    and  x0, x0, #0xFFFF
    movz x1, #0x0000
    movk x1, #0xF280, lsl #16       // MOVK x0, #imm
    orr  x0, x1, x0, lsl #5
    orr  x0, x0, #(1 << 21)         // hw = 1 → lsl #16
    bl   _emit_u32

    lsr  x0, x19, #32
    and  x0, x0, #0xFFFF
    movz x1, #0x0000
    movk x1, #0xF280, lsl #16       // MOVK x0, #imm
    orr  x0, x1, x0, lsl #5
    orr  x0, x0, #(2 << 21)         // lsl #32
    bl   _emit_u32

    lsr  x0, x19, #48
    and  x0, x0, #0xFFFF
    movz x1, #0x0000
    movk x1, #0xF280, lsl #16       // MOVK x0, #imm
    orr  x0, x1, x0, lsl #5
    orr  x0, x0, #(3 << 21)         // lsl #48
    bl   _emit_u32

    movz x0, #0x8EC0
    movk x0, #0xF81F, lsl #16     // 0xF81F0EC0 = str x0, [x22, #-8]!
    bl   _emit_u32
    
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// ============================================================================
// xt in x0.
// Native (convert-at-;): FL_INLINE CODE → paste; FL_INLINE DOCOL → expand;
//         else trampoline call.
// Threaded: if INLINE? && FL_INLINE DOCOL → macro-expand; else ,
// EXIT compiled here may warn (WARNINGS?); ; plants EXIT via _compile_cell.
// ============================================================================
_compile_word:                   // x0 = xt
    stp  x29, x30, [sp, #-32]!
    stp  x19, x20, [sp, #16]
    mov  x19, x0                 // save xt
    adrp x1, cfa_exit@page
    add  x1, x1, cfa_exit@pageoff
    ldr  x1, [x1]
    cmp  x19, x1
    b.ne 5f
    bl   _maybe_warn_exit
5:  adrp x1, compiling_native@page
    add  x1, x1, compiling_native@pageoff
    ldr  x1, [x1]
    cbz  x1, 20f                 // threaded

    // ---- native ----
    ldr  x2, [x19, #-8]
    tbz  x2, #62, 15f            // no INLINE bit → call
    ldr  x0, [x19]
    bl   _inline_len             // CODE leaf?
    cbz  x1, 12f
    ldr  x0, [x19]
    bl   _emit_bytes
    b    30f
12: // FL_INLINE colon? macro-expand if DOCOL (nested-safe via map save)
    ldr  x0, [x19]
    adrp x1, DOCOL@page
    add  x1, x1, DOCOL@pageoff
    cmp  x0, x1
    b.ne 15f
    mov  x0, x19
    bl   _macro_expand_colon
    b    30f
15: mov  x0, x19
    bl   _emit_native_call
    b    30f

20: // ---- threaded ----
    adrp x1, inline_var@page
    add  x1, x1, inline_var@pageoff
    ldr  x1, [x1]
    cbz  x1, 25f                 // INLINE-OFF: never expand
    ldr  x2, [x19, #-8]
    tbz  x2, #62, 25f
    ldr  x0, [x19]
    adrp x1, DOCOL@page
    add  x1, x1, DOCOL@pageoff
    cmp  x0, x1
    b.ne 25f
    mov  x0, x19
    bl   _macro_expand_colon
    b    30f
25: mov  x0, x19
    bl   _compile_cell
30: ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------------
// Macro expand helpers (relative BRANCH/0BRANCH reloc)
// ---------------------------------------------------------------------------
// Output cursor: HERE (threaded) or code_here (native)
_mex_cursor:                         // → x0
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x0, [x0]
    ret
1:  adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x0, [x0]
    ret

// x0 = source cell address; record map[old]=cursor
_mex_note:
    stp  x29, x30, [sp, #-32]!
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    bl   _mex_cursor
    mov  x20, x0
    adrp x0, mex_map_n@page
    add  x0, x0, mex_map_n@pageoff
    ldr  x1, [x0]
    cmp  x1, #MEX_MAP_MAX
    b.hs 9f
    adrp x2, mex_map@page
    add  x2, x2, mex_map@pageoff
    add  x2, x2, x1, lsl #4
    str  x19, [x2]
    str  x20, [x2, #8]
    add  x1, x1, #1
    str  x1, [x0]
9:  ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// x0 = patch addr, x1 = old_target (absolute source addr)
_mex_add_fix:
    adrp x2, mex_fix_n@page
    add  x2, x2, mex_fix_n@pageoff
    ldr  x3, [x2]
    cmp  x3, #MEX_FIX_MAX
    b.hs 9f
    adrp x4, mex_fix@page
    add  x4, x4, mex_fix@pageoff
    add  x4, x4, x3, lsl #4
    str  x0, [x4]
    str  x1, [x4, #8]
    add  x3, x3, #1
    str  x3, [x2]
9:  ret

// x0 = old addr → x0 = new addr (0 if missing)
_mex_lookup:
    adrp x1, mex_map_n@page
    add  x1, x1, mex_map_n@pageoff
    ldr  x1, [x1]
    adrp x2, mex_map@page
    add  x2, x2, mex_map@pageoff
    mov  x3, #0
1:  cmp  x3, x1
    b.hs 2f
    add  x5, x2, x3, lsl #4
    ldr  x4, [x5]
    cmp  x4, x0
    b.eq 3f
    add  x3, x3, #1
    b    1b
3:  ldr  x0, [x5, #8]
    ret
2:  mov  x0, #0
    ret

_mex_resolve:
    stp  x29, x30, [sp, #-48]!
    stp  x19, x20, [sp, #16]
    str  x21, [sp, #32]
    adrp x0, mex_fix_n@page
    add  x0, x0, mex_fix_n@pageoff
    ldr  x19, [x0]                   // count
    mov  x20, #0
1:  cmp  x20, x19
    b.hs 9f
    adrp x0, mex_fix@page
    add  x0, x0, mex_fix@pageoff
    add  x0, x0, x20, lsl #4
    ldr  x21, [x0]                   // patch
    ldr  x0, [x0, #8]                // old_target
    bl   _mex_lookup
    cbz  x0, 2f
    adrp x1, compiling_native@page
    add  x1, x1, compiling_native@pageoff
    ldr  x1, [x1]
    cbz  x1, 3f
    // native: x0=dest, x1=instr
    mov  x1, x21
    bl   _patch_rel
    b    2f
3:  // threaded relative: store dest - patch at patch
    sub  x0, x0, x21
    str  x0, [x21]
2:  add  x20, x20, #1
    b    1b
9:  ldr  x21, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// Copy n [quad,quad] entries: x0=n, x1=src, x2=dst (clobbers x0-x4).
_mex_copy_entries:
    cbz  x0, 9f
1:  ldp  x3, x4, [x1], #16
    stp  x3, x4, [x2], #16
    subs x0, x0, #1
    b.ne 1b
9:  ret

// Native (?DO): pop index/limit; if equal b to old_target; else RPUSH.
// x0 = old_target (skip past loop)
_mex_emit_native_qdo:
    stp  x29, x30, [sp, #-32]!
    str  x19, [sp, #16]
    mov  x19, x0
    movz x0, #0x86C1
    movk x0, #0xF840, lsl #16       // ldr x1,[x22],#8 index
    bl   _emit_u32
    movz x0, #0x86C0
    movk x0, #0xF840, lsl #16       // ldr x0,[x22],#8 limit
    bl   _emit_u32
    movz x0, #0x001F
    movk x0, #0xEB01, lsl #16       // cmp x0, x1  (subs xzr,x0,x1)
    bl   _emit_u32
    // b.eq skip
    adrp x2, code_here@page
    add  x2, x2, code_here@pageoff
    ldr  x0, [x2]
    stp  x0, x19, [sp, #-16]!
    movz x0, #0x0000
    movk x0, #0x5400, lsl #16       // b.eq .+0
    bl   _emit_u32
    ldp  x0, x1, [sp], #16
    bl   _mex_add_fix
    // RPUSH limit, index
    movz x0, #0x8EE0
    movk x0, #0xF81F, lsl #16       // str x0,[x23,#-8]!
    bl   _emit_u32
    movz x0, #0x8EE1
    movk x0, #0xF81F, lsl #16       // str x1,[x23,#-8]!
    bl   _emit_u32
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// Native (LOOP): x0 = body dest. x1 = 0 → patch B now; nonzero → mex_add_fix.
// _mex_emit_native_loop: same, always mex (x1 ignored / forced).
_emit_native_loop:
    stp  x29, x30, [sp, #-64]!
    stp  x19, x20, [sp, #16]
    stp  x21, xzr, [sp, #32]
    str  x1, [sp, #48]               // mode
    mov  x19, x0                     // body dest
    b    1f
_mex_emit_native_loop:
    stp  x29, x30, [sp, #-64]!
    stp  x19, x20, [sp, #16]
    stp  x21, xzr, [sp, #32]
    mov  x1, #1
    str  x1, [sp, #48]
    mov  x19, x0
1:  // ldr x0,[x23],#8 ; ldr x1,[x23],#8
    movz x0, #0x86E0
    movk x0, #0xF840, lsl #16
    bl   _emit_u32
    movz x0, #0x86E1
    movk x0, #0xF840, lsl #16
    bl   _emit_u32
    movz x0, #0x001F
    movk x0, #0xEB01, lsl #16
    bl   _emit_u32
    adrp x2, code_here@page
    add  x2, x2, code_here@pageoff
    ldr  x20, [x2]                   // &b.ge
    movz x0, #0x000A
    movk x0, #0x5400, lsl #16
    bl   _emit_u32
    movz x0, #0x0400
    movk x0, #0x9100, lsl #16       // add x0,x0,#1
    bl   _emit_u32
    movz x0, #0x001F
    movk x0, #0xEB01, lsl #16
    bl   _emit_u32
    adrp x2, code_here@page
    add  x2, x2, code_here@pageoff
    ldr  x21, [x2]                   // &b.eq
    movz x0, #0x0000
    movk x0, #0x5400, lsl #16
    bl   _emit_u32
    movz x0, #0x8EE1
    movk x0, #0xF81F, lsl #16
    bl   _emit_u32
    movz x0, #0x8EE0
    movk x0, #0xF81F, lsl #16
    bl   _emit_u32
    // b body — keep &B in [sp,#40]; do not push (would shift mode at #48)
    adrp x2, code_here@page
    add  x2, x2, code_here@pageoff
    ldr  x0, [x2]
    str  x0, [sp, #40]
    movz x0, #0x0000
    movk x0, #0x1400, lsl #16
    bl   _emit_u32
    ldr  x0, [sp, #40]               // &B
    mov  x1, x19                     // dest
    ldr  x2, [sp, #48]               // mode
    cbz  x2, 2f
    bl   _mex_add_fix               // (patch, old_target)
    b    3f
2:  // _patch_rel(dest, instr)
    mov  x2, x0
    mov  x0, x1
    mov  x1, x2
    bl   _patch_rel
3:  // patch forward b.ge / b.eq to here
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x0, [x0]
    mov  x1, x20
    str  x0, [sp, #40]               // scratch: dest
    bl   _patch_rel
    ldr  x0, [sp, #40]
    mov  x1, x21
    bl   _patch_rel
    ldp  x21, xzr, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #64
    ret

// Native (+LOOP): x0 = body dest. Same crossing rules as XPLUSLOOP_RT.
// x1 = 0 patch B now / nonzero mex_add_fix (_mex_* forces mex).
// Frame (no x22 — DSP): [sp,#40..#88] patch slots, [sp,#96] mode
_emit_native_plusloop:
    stp  x29, x30, [sp, #-128]!
    stp  x19, x20, [sp, #16]
    str  x21, [sp, #32]
    str  x1, [sp, #96]
    mov  x19, x0
    b    1f
_mex_emit_native_plusloop:
    stp  x29, x30, [sp, #-128]!
    stp  x19, x20, [sp, #16]
    str  x21, [sp, #32]
    mov  x1, #1
    str  x1, [sp, #96]
    mov  x19, x0                     // old_target (body)
1:
    // ldr x0,[x23],#8 ; ldr x1,[x23],#8 ; ldr x2,[x22],#8
    movz x0, #0x86E0
    movk x0, #0xF840, lsl #16
    bl   _emit_u32
    movz x0, #0x86E1
    movk x0, #0xF840, lsl #16
    bl   _emit_u32
    movz x0, #0x86C2
    movk x0, #0xF840, lsl #16
    bl   _emit_u32
    // cmp index,limit ; b.eq done (LEAVE)
    movz x0, #0x001F
    movk x0, #0xEB01, lsl #16
    bl   _emit_u32
    adrp x1, code_here@page
    add  x1, x1, code_here@pageoff
    ldr  x0, [x1]
    str  x0, [sp, #40]               // leave_eq
    movz x0, #0x0000
    movk x0, #0x5400, lsl #16       // b.eq
    bl   _emit_u32
    // mov x3,x0 ; add x0,x0,x2
    movz x0, #0x03E3
    movk x0, #0xAA00, lsl #16
    bl   _emit_u32
    movz x0, #0x0000
    movk x0, #0x8B02, lsl #16
    bl   _emit_u32
    // cmp x2,#0 ; b.lt neg
    movz x0, #0x005F
    movk x0, #0xF100, lsl #16
    bl   _emit_u32
    adrp x1, code_here@page
    add  x1, x1, code_here@pageoff
    ldr  x0, [x1]
    str  x0, [sp, #48]               // to_neg
    movz x0, #0x000B
    movk x0, #0x5400, lsl #16       // b.lt
    bl   _emit_u32
    // ---- n >= 0: done if old < limit && new >= limit ----
    movz x0, #0x007F
    movk x0, #0xEB01, lsl #16       // cmp x3,x1
    bl   _emit_u32
    adrp x1, code_here@page
    add  x1, x1, code_here@pageoff
    ldr  x0, [x1]
    str  x0, [sp, #56]               // pos_cont
    movz x0, #0x000A
    movk x0, #0x5400, lsl #16       // b.ge cont
    bl   _emit_u32
    movz x0, #0x001F
    movk x0, #0xEB01, lsl #16       // cmp x0,x1
    bl   _emit_u32
    adrp x1, code_here@page
    add  x1, x1, code_here@pageoff
    ldr  x0, [x1]
    str  x0, [sp, #64]               // pos_done
    movz x0, #0x000A
    movk x0, #0x5400, lsl #16       // b.ge done
    bl   _emit_u32
    adrp x1, code_here@page
    add  x1, x1, code_here@pageoff
    ldr  x0, [x1]
    str  x0, [sp, #72]               // pos_b_cont
    movz x0, #0x0000
    movk x0, #0x1400, lsl #16       // b cont
    bl   _emit_u32
    // ---- neg path ----
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x0, [x0]
    ldr  x1, [sp, #48]
    bl   _patch_rel                  // to_neg → here
    movz x0, #0x007F
    movk x0, #0xEB01, lsl #16       // cmp x3,x1
    bl   _emit_u32
    adrp x1, code_here@page
    add  x1, x1, code_here@pageoff
    ldr  x0, [x1]
    str  x0, [sp, #80]               // neg_cont
    movz x0, #0x000B
    movk x0, #0x5400, lsl #16       // b.lt cont
    bl   _emit_u32
    movz x0, #0x001F
    movk x0, #0xEB01, lsl #16       // cmp x0,x1
    bl   _emit_u32
    adrp x1, code_here@page
    add  x1, x1, code_here@pageoff
    ldr  x0, [x1]
    str  x0, [sp, #88]               // neg_done
    movz x0, #0x000B
    movk x0, #0x5400, lsl #16       // b.lt done
    bl   _emit_u32
    // ---- cont: RPUSH limit,index ; B body ----
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x20, [x0]                   // cont
    mov  x0, x20
    ldr  x1, [sp, #56]
    bl   _patch_rel
    mov  x0, x20
    ldr  x1, [sp, #72]
    bl   _patch_rel
    mov  x0, x20
    ldr  x1, [sp, #80]
    bl   _patch_rel
    movz x0, #0x8EE1
    movk x0, #0xF81F, lsl #16       // str x1,[x23,#-8]!
    bl   _emit_u32
    movz x0, #0x8EE0
    movk x0, #0xF81F, lsl #16       // str x0,[x23,#-8]!
    bl   _emit_u32
    // b body — &B in [sp,#104]; do not push (would shift mode at #96)
    adrp x2, code_here@page
    add  x2, x2, code_here@pageoff
    ldr  x0, [x2]
    str  x0, [sp, #104]
    movz x0, #0x0000
    movk x0, #0x1400, lsl #16
    bl   _emit_u32
    ldr  x0, [sp, #104]              // &B
    mov  x1, x19                     // dest
    ldr  x2, [sp, #96]               // mode
    cbz  x2, 2f
    bl   _mex_add_fix
    b    3f
2:  mov  x2, x0
    mov  x0, x1
    mov  x1, x2
    bl   _patch_rel
3:  // ---- done: patch leave_eq / pos_done / neg_done ----
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x20, [x0]
    mov  x0, x20
    ldr  x1, [sp, #40]
    bl   _patch_rel
    mov  x0, x20
    ldr  x1, [sp, #64]
    bl   _patch_rel
    mov  x0, x20
    ldr  x1, [sp, #88]
    bl   _patch_rel
    ldr  x21, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #128
    ret

// Expand FL_INLINE colon body (xt in x0). Stops at first EXIT.
// Nested-safe: copies map[]/fix[] to this frame before clearing counts.
_macro_expand_colon:
    // Frame: [0..63] locals, [64 .. 64+MAP) saved map, then saved fix
    mov  x1, #(64 + MEX_SAVE_BYTES)
    sub  sp, sp, x1
    stp  x29, x30, [sp]
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x0                     // xt
    // save counts
    adrp x1, mex_map_n@page
    add  x1, x1, mex_map_n@pageoff
    adrp x2, mex_fix_n@page
    add  x2, x2, mex_fix_n@pageoff
    ldr  x3, [x1]
    ldr  x4, [x2]
    stp  x3, x4, [sp, #48]
    // copy live map/fix entries into this frame
    mov  x0, x3                      // map_n
    adrp x1, mex_map@page
    add  x1, x1, mex_map@pageoff
    add  x2, sp, #64                 // dest map save
    bl   _mex_copy_entries
    ldr  x0, [sp, #56]               // fix_n
    adrp x1, mex_fix@page
    add  x1, x1, mex_fix@pageoff
    add  x2, sp, #(64 + MEX_MAP_BYTES)
    bl   _mex_copy_entries
    // clear working tables for this nest level
    adrp x1, mex_map_n@page
    add  x1, x1, mex_map_n@pageoff
    adrp x2, mex_fix_n@page
    add  x2, x2, mex_fix_n@pageoff
    str  xzr, [x1]
    str  xzr, [x2]

    add  x20, x19, #8                // body pointer
1:  mov  x0, x20
    bl   _mex_note
    ldr  x19, [x20], #8
    adrp x0, cfa_exit@page
    add  x0, x0, cfa_exit@pageoff
    ldr  x0, [x0]
    cmp  x19, x0
    b.eq 8f
    adrp x0, cfa_lit@page
    add  x0, x0, cfa_lit@pageoff
    ldr  x0, [x0]
    cmp  x19, x0
    b.eq 2f
    adrp x0, cfa_branch@page
    add  x0, x0, cfa_branch@pageoff
    ldr  x0, [x0]
    cmp  x19, x0
    b.eq 4f
    adrp x0, cfa_0branch@page
    add  x0, x0, cfa_0branch@pageoff
    ldr  x0, [x0]
    cmp  x19, x0
    b.eq 5f
    adrp x0, cfa_do@page
    add  x0, x0, cfa_do@pageoff
    ldr  x0, [x0]
    cmp  x19, x0
    b.eq 40f
    adrp x0, cfa_qdo@page
    add  x0, x0, cfa_qdo@pageoff
    ldr  x0, [x0]
    cmp  x19, x0
    b.eq 50f
    adrp x0, cfa_loop@page
    add  x0, x0, cfa_loop@pageoff
    ldr  x0, [x0]
    cmp  x19, x0
    b.eq 51f
    adrp x0, cfa_plusloop@page
    add  x0, x0, cfa_plusloop@pageoff
    ldr  x0, [x0]
    cmp  x19, x0
    b.eq 52f
    mov  x0, x19
    bl   _compile_word
    b    1b

2:  ldr  x0, [x20], #8
    adrp x1, compiling_native@page
    add  x1, x1, compiling_native@pageoff
    ldr  x1, [x1]
    cbz  x1, 3f
    bl   _emit_native_lit
    b    1b
3:  str  x0, [sp, #-16]!
    adrp x0, cfa_lit@page
    add  x0, x0, cfa_lit@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    ldr  x0, [sp], #16
    bl   _compile_cell
    b    1b

// ---- (DO): no trailing cell ----
40: adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 41f
    adrp x0, native_do_setup@page
    add  x0, x0, native_do_setup@pageoff
    adrp x1, native_do_setup_end@page
    add  x1, x1, native_do_setup_end@pageoff
    sub  x1, x1, x0
    bl   _emit_bytes
    b    1b
41: mov  x0, x19
    bl   _compile_cell
    b    1b

// ---- relative-tail ops: BRANCH/0BRANCH/(?DO)/(LOOP)/(+LOOP) ----
4:  mov  x21, #0                     // BRANCH → native B
    b    6f
5:  mov  x21, #1                     // 0BRANCH → native CBZ
    b    6f
50: mov  x21, #2                     // (?DO)
    b    6f
51: mov  x21, #3                     // (LOOP)
    b    6f
52: mov  x21, #4                     // (+LOOP)
6:  ldr  x1, [x20], #8               // old relative
    sub  x0, x20, #8
    add  x1, x0, x1                  // old_target
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 7f
    // native by kind
    cmp  x21, #1
    b.eq 61f
    cmp  x21, #2
    b.eq 62f
    cmp  x21, #3
    b.eq 63f
    cmp  x21, #4
    b.eq 64f
    // kind 0: B
    adrp x2, code_here@page
    add  x2, x2, code_here@pageoff
    ldr  x0, [x2]
    stp  x0, x1, [sp, #-16]!
    movz x0, #0x0000
    movk x0, #0x1400, lsl #16
    bl   _emit_u32
    ldp  x0, x1, [sp], #16
    bl   _mex_add_fix
    b    1b
61: // 0BRANCH
    movz x0, #0x86C0
    movk x0, #0xF840, lsl #16
    str  x1, [sp, #-16]!
    bl   _emit_u32
    adrp x2, code_here@page
    add  x2, x2, code_here@pageoff
    ldr  x0, [x2]
    ldr  x1, [sp]
    stp  x0, x1, [sp]
    movz x0, #0x0000
    movk x0, #0xB400, lsl #16
    bl   _emit_u32
    ldp  x0, x1, [sp], #16
    bl   _mex_add_fix
    b    1b
62: mov  x0, x1
    bl   _mex_emit_native_qdo
    b    1b
63: mov  x0, x1
    bl   _mex_emit_native_loop
    b    1b
64: mov  x0, x1
    bl   _mex_emit_native_plusloop
    b    1b

7:  // threaded: xt + relative hole
    mov  x0, x19
    str  x1, [sp, #-16]!             // old_target
    bl   _compile_cell
    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x2, [x0]                    // hole addr
    ldr  x1, [sp]                    // old_target
    stp  x2, x1, [sp]
    mov  x0, #0
    bl   _compile_cell
    ldp  x0, x1, [sp], #16
    bl   _mex_add_fix
    b    1b

8:  bl   _mex_resolve
    // restore outer map/fix arrays, then counts
    ldr  x0, [sp, #48]               // saved map_n
    add  x1, sp, #64
    adrp x2, mex_map@page
    add  x2, x2, mex_map@pageoff
    bl   _mex_copy_entries
    ldr  x0, [sp, #56]               // saved fix_n
    add  x1, sp, #(64 + MEX_MAP_BYTES)
    adrp x2, mex_fix@page
    add  x2, x2, mex_fix@pageoff
    bl   _mex_copy_entries
    adrp x1, mex_map_n@page
    add  x1, x1, mex_map_n@pageoff
    adrp x2, mex_fix_n@page
    add  x2, x2, mex_fix_n@pageoff
    ldp  x3, x4, [sp, #48]
    str  x3, [x1]
    str  x4, [x2]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp]
    mov  x1, #(64 + MEX_SAVE_BYTES)
    add  sp, sp, x1
    ret

// Emit movz/movk sequence loading imm64 in x0 into register rd (x1 = rd 0..31)
_emit_load64_rd:                     // x0=imm, x1=rd
    stp  x29, x30, [sp, #-48]!
    stp  x19, x20, [sp, #16]
    str  x21, [sp, #32]
    mov  x19, x0
    mov  x20, x1                     // rd
    // movz rd, #b0
    and  x0, x19, #0xFFFF
    movz x2, #0x0000
    movk x2, #0xD280, lsl #16
    orr  x0, x2, x0, lsl #5
    orr  x0, x0, x20
    bl   _emit_u32
    // movk rd, #b1, lsl #16
    lsr  x0, x19, #16
    and  x0, x0, #0xFFFF
    movz x2, #0x0000
    movk x2, #0xF280, lsl #16
    orr  x0, x2, x0, lsl #5
    orr  x0, x0, #(1 << 21)
    orr  x0, x0, x20
    bl   _emit_u32
    lsr  x0, x19, #32
    and  x0, x0, #0xFFFF
    movz x2, #0x0000
    movk x2, #0xF280, lsl #16
    orr  x0, x2, x0, lsl #5
    orr  x0, x0, #(2 << 21)
    orr  x0, x0, x20
    bl   _emit_u32
    lsr  x0, x19, #48
    and  x0, x0, #0xFFFF
    movz x2, #0x0000
    movk x2, #0xF280, lsl #16
    orr  x0, x2, x0, lsl #5
    orr  x0, x0, #(3 << 21)
    orr  x0, x0, x20
    bl   _emit_u32
    ldr  x21, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// JIT: load xt into x0, &_native_exec_xt into x16, blr x16
_emit_native_call:                   // x0 = xt
    stp  x29, x30, [sp, #-32]!
    str  x19, [sp, #16]
    mov  x19, x0
    mov  x1, #0                      // rd = x0
    bl   _emit_load64_rd
    adrp x0, _native_exec_xt@page
    add  x0, x0, _native_exec_xt@pageoff
    mov  x1, #16                     // rd = x16
    bl   _emit_load64_rd
    movz x0, #0x0200
    movk x0, #0xD63F, lsl #16        // blr x16
    bl   _emit_u32
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// Enter ITC word xt (x0) from JIT; return to LR in JIT after word completes.
.globl _native_exec_xt
_native_exec_xt:
    str  x30, [x23, #-8]!            // RPUSH JIT resume
    adrp x19, native_ret_ip@page
    add  x19, x19, native_ret_ip@pageoff
    mov  x21, x0
    ldr  x1, [x21]
    br   x1

XNATIVE_RET:
    ldr  x0, [x23], #8               // RPOP JIT resume
    br   x0

// ============================================================================
// Native colon prologue/epilogue
// ============================================================================
.text
.align 4

native_pro:
    str  x19, [x23, #-8]!        // RPUSH IP
native_pro_end:

native_epi:
    ldr  x19, [x23], #8          // RPOP
    ldr  x21, [x19], #8          // NEXT
    ldr  x1,  [x21]
    br   x1
native_epi_end:

// Pasted by macro expander for native (DO)
native_do_setup:
    ldr  x1, [x22], #8           // index
    ldr  x0, [x22], #8           // limit
    str  x0, [x23, #-8]!
    str  x1, [x23, #-8]!
native_do_setup_end:

// C: host_jit.c
.globl _code_buf
.globl _forth_code_begin_write
.globl _forth_code_end_write

// ============================================================================
// Cold start, eval API, REPL
// ============================================================================
.globl _kernel_cold_start
_kernel_cold_start:
    SAVE_C_CALLEE
    adrp x22, data_stack@page
    add  x22, x22, data_stack@pageoff
    add  x22, x22, #DSTACK_SIZE
    adrp x23, return_stack@page
    add  x23, x23, return_stack@pageoff
    add  x23, x23, #RSTACK_SIZE

    adrp x0, _code_buf@page
    add  x0, x0, _code_buf@pageoff
    ldr  x0, [x0]                // mmap base
    adrp x1, code_here@page
    add  x1, x1, code_here@pageoff
    str  x0, [x1]
    
    adrp x24, latest_var@page
    add  x24, x24, latest_var@pageoff
    // Clear FORTH heads (DICT_THREADS cells)
    mov  x0, x24
    mov  x1, #DICT_THREADS
1:  str  xzr, [x0], #8
    subs x1, x1, #1
    b.ne 1b
    adrp x0, last_cfa@page
    add  x0, x0, last_cfa@pageoff
    str  xzr, [x0]
    adrp x0, wordlist_reg_n@page
    add  x0, x0, wordlist_reg_n@pageoff
    str  xzr, [x0]
    adrp x0, search_order_n@page
    add  x0, x0, search_order_n@pageoff
    str  xzr, [x0]
    adrp x0, current_var@page
    add  x0, x0, current_var@pageoff
    str  xzr, [x0]

    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    adrp x1, user_dict@page
    add  x1, x1, user_dict@pageoff
    str  x1, [x0]

    adrp x0, state_var@page
    add  x0, x0, state_var@pageoff
    str  xzr, [x0]

    adrp x0, source_sp@page
    add  x0, x0, source_sp@pageoff
    str  xzr, [x0]
    adrp x0, source_id_var@page
    add  x0, x0, source_id_var@pageoff
    str  xzr, [x0]
    adrp x0, included_count@page
    add  x0, x0, included_count@pageoff
    str  xzr, [x0]

    bl   _boot_kernel
    // Search-Order defaults: CURRENT = FORTH, order = (FORTH), register FORTH
    adrp x0, latest_var@page
    add  x0, x0, latest_var@pageoff
    adrp x1, current_var@page
    add  x1, x1, current_var@pageoff
    str  x0, [x1]
    adrp x1, search_order@page
    add  x1, x1, search_order@pageoff
    str  x0, [x1]
    mov  x1, #1
    adrp x2, search_order_n@page
    add  x2, x2, search_order_n@pageoff
    str  x1, [x2]
    bl   _wordlist_register

    bl   _boot_cache

    adrp x0, forth_source@page
    add  x0, x0, forth_source@pageoff
    adrp x1, forth_source_end@page
    add  x1, x1, forth_source_end@pageoff
    sub  x1, x1, x0
    bl   _set_source
    bl   _interpret_run

    // Startup sign-on (versioned)
    adrp x1, banner@page
    add  x1, x1, banner@pageoff
    mov  x2, #banner_len
    bl   _sys_write

    adrp x0, quit_ready@page
    add  x0, x0, quit_ready@pageoff
    mov  x1, #1
    str  x1, [x0]
    bl   _vm_save_stacks
    RESTORE_C_CALLEE
    ret

.globl _kernel_eval
_kernel_eval:
    SAVE_C_CALLEE
    // Abort/QUIT may jump here with a deep C stack; remember this frame.
    mov  x2, sp
    adrp x3, embed_c_sp@page
    add  x3, x3, embed_c_sp@pageoff
    str  x2, [x3]
    // x0=line, x1=n — stash across restore
    stp  x0, x1, [sp, #-16]!
    // Like 64Forth: mark embed so QUIT/ABORT return here, not into readline.
    adrp x0, embed_mode@page
    add  x0, x0, embed_mode@pageoff
    mov  x1, #1
    str  x1, [x0]
    bl   _vm_restore_stacks
    ldp  x0, x1, [sp], #16
    bl   _set_source
    bl   _interpret_run
    bl   _vm_save_stacks
    mov  x0, #0
    RESTORE_C_CALLEE
    ret

.globl _kernel_data_depth
_kernel_data_depth:
    adrp x0, data_stack@page
    add  x0, x0, data_stack@pageoff
    add  x0, x0, #DSTACK_SIZE          // empty
    adrp x1, vm_dsp@page
    add  x1, x1, vm_dsp@pageoff
    ldr  x1, [x1]
    cbz  x1, 1f
    sub  x0, x0, x1
    lsr  x0, x0, #3
    ret
1:
    mov  x0, #0
    ret

// CLI entry retained for reference builds; not used by the .app (Swift @main).
.globl _cli_main
_cli_main:
    stp  x29, x30, [sp, #-16]!
    bl   _forth_io_init
    bl   _kernel_cold_start
    // TTY REPL: QUIT/ABORT must enter readline, not embed return.
    adrp x0, embed_mode@page
    add  x0, x0, embed_mode@pageoff
    str  xzr, [x0]
    b    _quit_loop

_quit_loop:
    bl   _vm_restore_stacks
    bl   _check_data_stack
    cbnz x0, _abort
    adrp x0, input_buffer@page
    add  x0, x0, input_buffer@pageoff
    mov  x1, #2047
    bl   _forth_readline
    cmp  x0, #0
    b.le _exit0
    mov  x1, x0
    adrp x0, input_buffer@page
    add  x0, x0, input_buffer@pageoff
    bl   _set_source
    bl   _interpret_run
    bl   _vm_save_stacks
    b    _quit_loop

_exit0:
    mov  x0, #0
    mov  x16, #1
    svc  #0x80

// ============================================================================
// Strings + embedded Forth
// ============================================================================
.section __TEXT,__const
.align 3
forth_source:
    .incbin "16Forth/kernel.fth"
    .incbin "16Forth/ansfile.fth"
forth_source_end:

.section __TEXT,__const
.align 3
banner:
    .ascii "16Forth 0.5 ready\n"
.equ banner_len, . - banner

.align 3
empty_help:
    .byte 0
empty_name:
    .byte 0

.align 3
str_undef:
    .ascii "undefined: "
.align 3
str_nl:
    .ascii "\n"
.align 3
str_ok:
    .ascii " ok\n"
.align 3
str_colon_fail:
    .ascii " : missing name\n"
.align 3
str_cache_fail:
    .ascii "boot cache fail\n"
.align 3
str_under:
    .quad 17
    .ascii " stack underflow\n"
.align 3
str_over:
    .quad 16
    .ascii " stack overflow\n"
.align 3
str_exit_warn_mid:
    .ascii " uses EXIT - Not inlinable\n"
.equ str_exit_warn_mid_len, . - str_exit_warn_mid

.align 3
str_cant_open:
    .ascii "can't open: "
.align 3
str_incl_need:
    .ascii "INCLUDE needs name\n"
.align 3
str_incl_nest:
    .ascii "INCLUDE too nested\n"
.align 3
str_included_hdr:
    .ascii "Included:\n"
.align 3
str_search_order:
    .ascii "Search order: "
.align 3
str_comp_wl:
    .ascii "Compilation wordlist: "
.align 3
str_forth_name:
    .ascii "FORTH"
.align 3
str_wid:
    .ascii "wid"

.align 3
cnt_lit:        .byte 3, 'L','I','T'
.align 3
cnt_exit:       .byte 4, 'E','X','I','T'
.align 3
cnt_comma:      .byte 1, ','
.align 3
cnt_does:       .byte 7, '(','D','O','E','S','>',')'
.align 3
cnt_slit:       .byte 4, '(','S','"',')'
.align 3
cnt_branch:     .byte 6, 'B','R','A','N','C','H'
.align 3
cnt_0branch:    .byte 7, '0','B','R','A','N','C','H'
.align 3
cnt_do:         .byte 4, '(','D','O',')'
cnt_qdo:        .byte 5, '(','?','D','O',')'
cnt_loop:       .byte 6, '(','L','O','O','P',')'
cnt_plusloop:   .byte 7, '(','+','L','O','O','P',')'

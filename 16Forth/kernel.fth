\ High-level 16Forth — loaded after the 16 inner primitives and the
\ assembly bootstrap compiler (: ; CREATE DOES> , HERE POSTPONE ...).
\ This file is real Forth, not .ascii embedded in the assembler.

CREATE PAD 256 ALLOT

\ --- Stack helpers ----------------------------------------------------------
I: NIP   SWAP DROP ;
I: TUCK  SWAP OVER ;
I: 2DUP  OVER OVER ;
I: 2DROP DROP DROP ;
: ROT   >R SWAP R> SWAP ;
I: 1+    1 + ;
I: 1-    1 - ;
I: NEGATE  0 SWAP - ;
: 2SWAP  ROT >R ROT R> ;

\ --- CREATE-family ----------------------------------------------------------
: CONSTANT  CREATE , DOES> @ ;
: VARIABLE  CREATE 0 , ;

0 CONSTANT FALSE
-1 CONSTANT TRUE
8 CONSTANT CELL
32 CONSTANT BL

I: CELL+ CELL + ;
I: CELLS CELL * ;

\ --- Logic (built on CODE 0= 0< < AND INVERT) -------------------------------
I: =    - 0= ;
I: <>   = INVERT ;
I: >    SWAP < ;
I: 0<>  0= INVERT ;

\ --- Compile state ----------------------------------------------------------
: [  0 STATE !  ; IMMEDIATE
: ] -1 STATE !  ;
: LITERAL  POSTPONE LIT  ,  ; IMMEDIATE
: [']  '  POSTPONE LITERAL  ; IMMEDIATE
: RECURSE  LATEST @  ,  ; IMMEDIATE

\ --- Control structures (BRANCH / 0BRANCH store relative offsets) -----------
\ Compiled in asm (IF THEN ELSE BEGIN …). I: expander relocates BRANCH/0BRANCH.

\ I: ok — bodies compile to 0BRANCH/BRANCH cells; smart expander relocates them.
I: MIN  ( n1 n2 -- n3 )  2DUP < IF DROP ELSE NIP THEN ;
I: MAX  ( n1 n2 -- n3 )  2DUP < IF NIP ELSE DROP THEN ;

I: ABS   DUP 0< IF NEGATE THEN ;
I: ?DUP  DUP IF DUP THEN ;

\ --- Arithmetic extras ------------------------------------------------------
I: /MOD  ( n1 n2 -- rem quot )  2DUP / DUP >R * - R> ;
I: MOD   /MOD DROP ;

\ DO/?DO/LOOP/+LOOP are asm immediates (native-aware under INLINE-ON).
\ DO leaves ( 0 dest ); ?DO leaves ( orig dest ). Threaded offsets are relative.

\ --- I/O --------------------------------------------------------------------
: CR      10 EMIT ;
: SPACE   BL EMIT ;
: SPACES  BEGIN DUP WHILE SPACE 1 - REPEAT DROP ;
: COUNT   DUP C@ SWAP 1 + SWAP ;
: TYPE    BEGIN DUP WHILE OVER C@ EMIT SWAP 1 + SWAP 1 - REPEAT 2DROP ;
: ."      POSTPONE S"  POSTPONE TYPE  ; IMMEDIATE

\ --- Memory words
: CMOVE  ( c-addr1 c-addr2 u -- )
    BEGIN DUP WHILE
        >R  OVER C@  OVER C!  1 + SWAP 1 + SWAP  R> 1 -
    REPEAT  2DROP DROP ;
    
\ --- Number output ----------------------------------------------------------
: U.  10 /MOD DUP IF RECURSE ELSE DROP THEN  48 + EMIT ;
: (.) DUP 0< IF 45 EMIT NEGATE THEN U. ;
: .   (.) SPACE ;

: .S  ( -- )
     DEPTH ." (" DUP (.) ." ) "
     DUP  0 > IF
         BEGIN DUP WHILE
             DUP PICK . 1 -
         REPEAT
     THEN DROP CR ;

\ --- Inline enable/disable -------------------------------------------------
\ Build/kernel stays INLINE-OFF (threaded, SEE-friendly).
\ App workflow: develop with INLINE-OFF; later INLINE-ON and recompile so
\ new : words are whole-word native. Marked I:/CODE leaves paste or macro-
\ expand (nested I: ok); anything else is a native trampoline call.
\ D: (asm) saves INLINE?, forces OFF for that definition, restores on ;.
: INLINE-ON   -1 INLINE? ! ;
: INLINE-OFF   0 INLINE? ! ;

\ --- Dictionary walking -----------------------------------------------------
: >LINK  16 - ;
: >FLAGS 8 - ;
: >NAME  DUP >FLAGS @ 65535 AND - ;

: WORDS ( -- )
    0 >R
    LATEST @
    BEGIN DUP WHILE
        DUP >NAME COUNT DUP R> + >R TYPE SPACE
        R@ 60 > IF CR R> DROP 0 >R THEN
        >LINK @
    REPEAT DROP R> DROP CR ;

\ --- Smoke tests (left INLINE-OFF so the image boots debuggable) ------------
: SQUARE  DUP * ;
: TEST    5 SQUARE . CR ;

\ After load, user may:  INLINE-ON  and redefine app words for speed.
\ Or wrap a single threaded definition:  D: DEBUGGY ... ;

\ S" hi" TYPE CR
\ TEST

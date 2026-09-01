\ High-level 16Forth — loaded after the 16 inner primitives and the
\ assembly bootstrap compiler (: ; CREATE DOES> , HERE POSTPONE ...).
\ This file is real Forth, not .ascii embedded in the assembler.
\ PARSE / SETDOC are CODE; DOC" arms help for the next : / N: / CREATE.

: DOC"  34 PARSE SETDOC ;

DOC" PAD ( -- addr ) scratch buffer"
CREATE PAD 256 ALLOT

\ --- Stack helpers ----------------------------------------------------------
DOC" NIP ( x1 x2 -- x2 ) drop NOS"
: NIP   SWAP DROP ;
DOC" TUCK ( x1 x2 -- x2 x1 x2 ) copy TOS under NOS"
: TUCK  SWAP OVER ;
DOC" 2DUP ( x1 x2 -- x1 x2 x1 x2 ) duplicate pair"
: 2DUP  OVER OVER ;
DOC" 2DROP ( x1 x2 -- ) drop two cells"
: 2DROP DROP DROP ;
DOC" ROT ( x1 x2 x3 -- x2 x3 x1 ) rotate top three"
: ROT   >R SWAP R> SWAP ;
DOC" 1+ ( n -- n+1 )"
: 1+    1 + ;
DOC" 1- ( n -- n-1 )"
: 1-    1 - ;
DOC" NEGATE ( n -- -n )"
: NEGATE  0 SWAP - ;
DOC" 2SWAP ( x1 x2 x3 x4 -- x3 x4 x1 x2 ) swap cell pairs"
: 2SWAP  ROT >R ROT R> ;
DOC" 2>R ( x1 x2 -- ) ( R: -- x1 x2 ) move pair to return stack"
: 2>R  SWAP >R >R ;
DOC" 2R> ( -- x1 x2 ) ( R: x1 x2 -- ) restore pair from return stack"
: 2R>  R> R> SWAP ;
DOC" 2R@ ( -- x1 x2 ) ( R: x1 x2 -- x1 x2 ) copy pair from return stack"
: 2R@  R> R> 2DUP >R >R SWAP ;

\ --- CREATE-family ----------------------------------------------------------
DOC" CONSTANT ( x 'name' -- ) create constant"
: CONSTANT  CREATE , DOES> @ ;
DOC" VARIABLE ( 'name' -- ) create cell variable (0)"
: VARIABLE  CREATE 0 , ;

DOC" VOCABULARY ( 'name' -- ) named word list; execute to push onto search order"
: VOCABULARY  CREATE WORDLIST DROP DOES> PUSH-ORDER ;

VOCABULARY BIG-INTEGER
VOCABULARY EDITOR
VOCABULARY ASSEMBLER
VOCABULARY FP
ONLY FORTH DEFINITIONS

DOC" FALSE ( -- 0 )"
0 CONSTANT FALSE
DOC" TRUE ( -- -1 )"
-1 CONSTANT TRUE
DOC" CELL ( -- n ) address units per cell"
8 CONSTANT CELL
DOC" BL ( -- c ) space character"
32 CONSTANT BL

DOC" CELL+ ( a-addr -- a-addr' ) add one cell"
: CELL+ CELL + ;
DOC" CELLS ( n1 -- n2 ) cells to address units"
: CELLS CELL * ;

\ --- Logic (built on CODE 0= 0< < AND INVERT) -------------------------------
DOC" = ( n1 n2 -- flag ) equal"
: =    - 0= ;
DOC" <> ( n1 n2 -- flag ) not equal"
: <>   = INVERT ;
DOC" > ( n1 n2 -- flag ) greater than"
: >    SWAP < ;
DOC" 0<> ( n -- flag ) not equal to zero"
: 0<>  0= INVERT ;

\ --- Compile state ----------------------------------------------------------
DOC" [ ( -- ) enter interpret state (immediate)"
: [  0 STATE !  ; IMMEDIATE
DOC" ] ( -- ) enter compile state"
: ] -1 STATE !  ;
DOC" LITERAL ( C: x -- ) ( -- x ) compile literal (immediate)"
: LITERAL  POSTPONE LIT  ,  ; IMMEDIATE
DOC" ['] ( C: 'name' -- ) ( -- xt ) compile xt of name (immediate)"
: [']  '  POSTPONE LITERAL  ; IMMEDIATE
\ RECURSE is CODE (native-aware via _compile_word); do not redefine here.

\ --- Control structures (BRANCH / 0BRANCH store relative offsets) -----------
\ Compiled in asm (IF THEN ELSE BEGIN …). Expander relocates BRANCH/0BRANCH.

\ Control-flow ok — bodies compile to 0BRANCH/BRANCH cells; expander relocates them.
DOC" MIN ( n1 n2 -- n3 ) lesser of two"
: MIN  ( n1 n2 -- n3 )  2DUP < IF DROP ELSE NIP THEN ;
DOC" MAX ( n1 n2 -- n3 ) greater of two"
: MAX  ( n1 n2 -- n3 )  2DUP < IF NIP ELSE DROP THEN ;

DOC" ABS ( n -- u ) absolute value"
: ABS   DUP 0< IF NEGATE THEN ;
DOC" ?DUP ( x -- 0 | x x ) duplicate if nonzero"
: ?DUP  DUP IF DUP THEN ;

\ --- Arithmetic extras ------------------------------------------------------
DOC" /MOD ( n1 n2 -- rem quot )"
: /MOD  ( n1 n2 -- rem quot )  2DUP / DUP >R * - R> ;
DOC" MOD ( n1 n2 -- n3 ) remainder"
: MOD   /MOD DROP ;

\ DO/?DO/LOOP/+LOOP are asm immediates (native-aware under INLINE-ON).
\ DO leaves ( 0 dest ); ?DO leaves ( orig dest ). Threaded offsets are relative.

\ --- I/O --------------------------------------------------------------------
DOC" CR ( -- ) emit newline"
: CR      10 EMIT ;
DOC" SPACE ( -- ) emit one space"
: SPACE   BL EMIT ;
DOC" SPACES ( n -- ) emit n spaces"
: SPACES  BEGIN DUP WHILE SPACE 1 - REPEAT DROP ;
DOC" COUNT ( c-addr1 -- c-addr2 u ) from counted string"
: COUNT   DUP C@ SWAP 1 + SWAP ;
DOC" TYPE ( c-addr u -- ) emit string"
: TYPE    BEGIN DUP WHILE OVER C@ EMIT SWAP 1 + SWAP 1 - REPEAT 2DROP ;
DOC" DOT-QUOTE ( C: ccc -- ) compile print of string (immediate)"
\ Interpret or compile: print until " (ANS ." is compile-only; we allow both).
\ 34 = ASCII '"' — avoid [CHAR] (defined later / may be absent).
: ."
    STATE @ IF  POSTPONE S"  POSTPONE TYPE
    ELSE  34 PARSE TYPE  THEN  ; IMMEDIATE
DOC" .( ( -- ) print text until ) immediately (immediate; Core Ext)"
\ Skip leading spaces/tabs (ANS), then PARSE to ')' and TYPE.
\ 41 = ASCII ')'. N: so this is never mex'd as a callee.
\ Use >IN @ 1+ >IN ! — +! is defined later in this file.
N: .(
    BEGIN
      SOURCE NIP >IN @ >
      IF SOURCE DROP >IN @ + C@ DUP BL = SWAP 9 = OR ELSE FALSE THEN
    WHILE >IN @ 1+ >IN ! REPEAT
    41 PARSE TYPE ; IMMEDIATE

\ --- Memory words
DOC" CMOVE ( c-addr1 c-addr2 u -- ) copy u chars low→high"
: CMOVE  ( c-addr1 c-addr2 u -- )
    BEGIN DUP WHILE
        >R  OVER C@  OVER C!  1 + SWAP 1 + SWAP  R> 1 -
    REPEAT  2DROP DROP ;
    
\ --- Number base ------------------------------------------------------------
DOC" DECIMAL ( -- ) set BASE to 10"
: DECIMAL  10 BASE ! ;
DOC" HEX ( -- ) set BASE to 16"
: HEX      16 BASE ! ;

\ --- Number output ----------------------------------------------------------
DOC" U. ( u -- ) print unsigned in BASE 10"
: U.  10 /MOD DUP IF RECURSE ELSE DROP THEN  48 + EMIT ;
DOC" (.) ( n -- ) print signed without trailing space"
: (.) DUP 0< IF 45 EMIT NEGATE THEN U. ;
DOC" . ( n -- ) print signed with trailing space"
: .   (.) SPACE ;

DOC" .S ( -- ) print data stack contents"
: .S  ( -- )
     DEPTH ." (" DUP (.) ." ) "
     DUP  0 > IF
         BEGIN DUP WHILE
             DUP PICK . 1 -
         REPEAT
     THEN DROP CR ;

\ --- Pictured numeric output (64Forth-style) --------------------------------
DOC" +! ( n a-addr -- ) add n to cell at a-addr"
: +!  ( n a-addr -- )  DUP @ ROT + SWAP ! ;
DOC" HLD ( -- a-addr ) pictured-output pointer variable"
VARIABLE HLD
DOC" <# ( -- ) begin pictured numeric output"
: <#  ( -- )  PAD 256 + HLD ! ;
DOC" HOLD ( char -- ) add char to pictured output"
: HOLD  ( char -- )  -1 HLD +!  HLD @ C! ;
DOC" #> ( xd -- c-addr u ) end pictured numeric output"
: #>  ( xd -- c-addr u )  2DROP HLD @ PAD 256 + OVER - ;
DOC" # ( ud1 -- ud2 ) convert one pictured digit"
: #   ( ud1 -- ud2 )
    0 BASE @ UM/MOD >R BASE @ UM/MOD R> ROT
    DUP 9 > IF 7 + THEN 48 + HOLD ;
DOC" #S ( ud1 -- ud2 ) convert remaining pictured digits"
: #S  ( ud1 -- ud2 )  BEGIN # 2DUP OR 0= UNTIL ;
DOC" SIGN ( n -- ) HOLD minus if n<0"
: SIGN  ( n -- )  0< IF 45 HOLD THEN ;
DOC" UD. ( ud -- ) print unsigned double"
: UD.  ( ud -- )  <# #S #> TYPE SPACE ;
DOC" D. ( n -- ) print signed via pictured output"
: D.   ( n -- )
    DUP 0< IF NEGATE 0 <# #S 45 HOLD #> ELSE 0 <# #S #> THEN TYPE SPACE ;

\ --- Inline enable/disable -------------------------------------------------
\ Bodies always compile threaded. At ; a safe body (single trailing EXIT,
\ no RECURSE / S") gets FL_INLINE unless defined with N:.
\ INLINE-ON: callers macro-expand FL_INLINE callees; unsafe/N: words are
\ converted to whole-word native at ;. INLINE-OFF: no expand, no convert.
\ D: saves INLINE?, forces OFF for that definition, restores on ;.
DOC" INLINE-ON ( -- ) expand inlineable callees; native-convert the rest"
: INLINE-ON   -1 INLINE? ! ;
DOC" INLINE-OFF ( -- ) no macro-expand; leave : threaded (SEE-friendly)"
: INLINE-OFF   0 INLINE? ! ;
DOC" WARNINGS-ON ( -- ) warn when EXIT appears inside a definition"
: WARNINGS-ON   -1 WARNINGS? ! ;
DOC" WARNINGS-OFF ( -- ) silence EXIT-in-definition warnings"
: WARNINGS-OFF   0 WARNINGS? ! ;

\ --- Dictionary walking -----------------------------------------------------
DOC" >LINK ( xt -- a-addr ) link field address"
: >LINK  16 - ;
DOC" >FLAGS ( xt -- a-addr ) flags field address"
: >FLAGS 8 - ;
DOC" >NAME ( xt -- nfa ) name field address"
: >NAME  DUP >FLAGS @ 65535 AND - ;
DOC" NFA ( xt -- nfa ) synonym for >NAME"
: NFA    >NAME ;
DOC" NAME>STRING ( xt -- c-addr u ) name as string"
: NAME>STRING  NFA COUNT ;
DOC" HFA ( xt -- hfa ) help field address"
: HFA    DUP >FLAGS @ 16 RSHIFT 65535 AND - ;
DOC" >HELP ( xt -- hfa ) help counted string"
: >HELP  HFA ;
DOC" >BODY ( xt -- a-addr ) parameter field (CFA+8)"
: >BODY  8 + ;
DOC" ALIGNED ( addr -- a-addr ) align upward to cell"
: ALIGNED  7 + 7 INVERT AND ;
DOC" ALIGN ( -- ) align HERE to cell boundary"
: ALIGN  HERE ALIGNED HERE - ALLOT ;
DOC" CHAR+ ( c-addr -- c-addr' ) add one character"
: CHAR+  1+ ;
DOC" 2@ ( addr -- x1 x2 ) fetch two cells (x2 from addr, x1 from addr+CELL)"
: 2@  DUP CELL+ @ SWAP @ ;
DOC" 2! ( x1 x2 addr -- ) store two cells (x2 at addr, x1 at addr+CELL)"
: 2!  SWAP OVER ! CELL+ ! ;
DOC" UNDER+ ( a x b -- a+b x ) add b under x"
: UNDER+  ROT + SWAP ;
DOC" FILL ( addr u b -- ) fill u bytes at addr with b"
: FILL  >R BEGIN DUP WHILE OVER R@ SWAP C! SWAP 1+ SWAP 1- REPEAT R> DROP 2DROP ;
DOC" ERASE ( addr u -- ) fill u bytes with zero"
: ERASE  0 FILL ;
VARIABLE (CMP-U1)
VARIABLE (CMP-U2)
DOC" COMPARE ( c-addr1 u1 c-addr2 u2 -- n ) string compare -1/0/1"
: COMPARE  ( c-addr1 u1 c-addr2 u2 -- n )
  (CMP-U2) ! >R (CMP-U1) ! >R      \ R: ca2 ca1
  R> R>                            \ ca1 ca2
  (CMP-U1) @ (CMP-U2) @ MIN 0 ?DO
    OVER I + C@  OVER I + C@ -
    ?DUP IF
      NIP NIP
      0< IF -1 ELSE 1 THEN
      UNLOOP EXIT
    THEN
  LOOP
  2DROP
  (CMP-U1) @ (CMP-U2) @
  2DUP = IF 2DROP 0 ELSE < IF -1 ELSE 1 THEN THEN ;
DOC" [DEFINED] ( 'name' -- flag ) true if name is found (immediate)"
: [DEFINED]  BL WORD FIND NIP 0<> ; IMMEDIATE
DOC" [UNDEFINED] ( 'name' -- flag ) true if name is not found (immediate)"
: [UNDEFINED]  BL WORD FIND NIP 0= ; IMMEDIATE
DOC" [THEN] ( -- ) end of [IF] (immediate no-op)"
: [THEN]  ; IMMEDIATE
DOC" [ELSE] ( -- ) skip to matching [THEN] (immediate)"
: [ELSE]
  1 BEGIN
    BEGIN BL WORD COUNT DUP WHILE
      2DUP S" [IF]" COMPARE 0= IF 2DROP 1+
      ELSE 2DUP S" [ELSE]" COMPARE 0= IF 2DROP 1- DUP IF 1+ THEN
      ELSE 2DUP S" [THEN]" COMPARE 0= IF 2DROP 1- ELSE 2DROP THEN THEN THEN
      DUP 0= IF DROP EXIT THEN
    REPEAT 2DROP REFILL 0= UNTIL DROP ; IMMEDIATE
DOC" [IF] ( flag -- ) interpret if true else skip to [ELSE]/[THEN] (immediate)"
: [IF]  0= IF POSTPONE [ELSE] THEN ; IMMEDIATE
DOC" ABORT-QUOTE ( flag -- ) if flag nonzero type message and ABORT (immediate)"
: ABORT"  STATE @ IF
    POSTPONE IF POSTPONE S" POSTPONE TYPE POSTPONE CR
    POSTPONE ABORT POSTPONE THEN
  ELSE 34 PARSE ROT IF TYPE CR ABORT THEN 2DROP THEN ; IMMEDIATE
DOC" DOCOL? ( xt -- flag ) true if colon (CFA holds DOCOL)"
: DOCOL?  @ DOCOL-ADDR = ;

DOC" (CONTEXT) ( -- wid ) first search-order wordlist, or FORTH"
: (CONTEXT)  GET-ORDER ?DUP 0= IF FORTH-WORDLIST EXIT THEN
  BEGIN DUP 1 > WHILE SWAP DROP 1- REPEAT DROP ;

DOC" WORDS ( -- ) list names in CONTEXT wordlist"
: WORDS ( -- )
    0 >R
    (CONTEXT) @
    BEGIN DUP WHILE
        DUP >NAME COUNT DUP R> + >R TYPE SPACE
        R@ 60 > IF CR R> DROP 0 >R THEN
        >LINK @
    REPEAT DROP R> DROP CR ;

\ --- SEE (ITC decompiler; 64Forth-style, plus DO/?DO offsets) ----------------
\ Colon bodies: walk xt cells until EXIT. Special inline payloads:
\   LIT value | (S") len bytes | BRANCH/0BRANCH/(?DO)/(LOOP)/(+LOOP) offset
\ (DO) has no trailing cell. CODE / native JIT: header + (primitive).

DOC" (SEE-BR?) ( xt -- flag ) SEE: branch/loop runtime with offset cell?"
: (SEE-BR?) ( xt -- flag )
    >R
    R@ BRANCH-ADDR =  R@ 0BRANCH-ADDR = OR
    R@ LOOP-ADDR = OR  R@ PLUSLOOP-ADDR = OR
    R@ QDO-ADDR = OR
    R> DROP ;

\ FFA bit 62 = auto-inlineable colon (same as asm FFA_INLINE).
DOC" (SEE-I?) ( xt -- flag ) true if inlineable (FL_INLINE) bit set"
: (SEE-I?) ( xt -- flag )  >FLAGS @ 1 62 LSHIFT AND ;

DOC" (SEE-HDR) ( xt -- xt ) print :/I:/CODE tag (I if inlineable) and help or name"
: (SEE-HDR) ( xt -- xt )
    DUP DOCOL? IF
        DUP (SEE-I?) IF 73 EMIT THEN
        58 EMIT SPACE
    ELSE 67 EMIT 79 EMIT 68 EMIT 69 EMIT SPACE THEN
    DUP >HELP COUNT DUP IF TYPE ELSE 2DROP DUP NAME>STRING TYPE THEN CR ;

DOC" (SEE-PRIM) ( xt -- ) print (primitive) for non-colon"
: (SEE-PRIM) ( xt -- )
    DROP
    40 EMIT 112 EMIT 114 EMIT 105 EMIT 109 EMIT
    105 EMIT 116 EMIT 105 EMIT 118 EMIT 101 EMIT 41 EMIT CR ;

DOC" (SEE-STEP) ( addr -- addr'|0 ) decompile one body cell"
: (SEE-STEP) ( addr -- addr' )
    DUP @ >R
    R@ EXIT-ADDR = IF R> DROP DROP 59 EMIT CR 0 EXIT THEN
    R@ LIT-ADDR = IF R> DROP 8 + DUP @ . SPACE 8 + EXIT THEN
    R@ SLIT-ADDR = IF
        R> DROP 8 + DUP @ >R 8 +
        83 EMIT 34 EMIT SPACE DUP R@ TYPE 34 EMIT SPACE
        R> + ALIGNED EXIT THEN
    R@ CSTR-ADDR = IF
        R> DROP 8 + DUP C@ >R 1+
        67 EMIT 34 EMIT SPACE DUP R@ TYPE 34 EMIT SPACE
        R> + ALIGNED EXIT THEN
    R@ (SEE-BR?) IF
        R@ NAME>STRING TYPE SPACE R> DROP
        8 + DUP @ . SPACE 8 + EXIT THEN
    R@ NAME>STRING TYPE SPACE R> DROP 8 + ;

\ (SEE-HDR) is ( xt -- xt ). After the body walk, UNTIL leaves the 0 sentinel
\ for one DROP. Do not DUP before (SEE-HDR) — that was the 64Forth stack leak.
DOC" SEE ( 'name' -- ) show help and decompile word"
: SEE ( "name" -- )
    ' (SEE-HDR)
    DUP DOCOL? IF
        >BODY BEGIN (SEE-STEP) DUP 0= UNTIL DROP
    ELSE
        (SEE-PRIM)
    THEN ;

DOC" HELP ( 'name' -- ) synonym of SEE"
: HELP  SEE ;

\ --- Timing (MS@ / MS are CODE; ELAPSED prints HH:MM:SS.mmm) -----------------
DOC" .2DIG ( n -- ) print n as 2 decimal digits"
: .2DIG  ( n -- )  10 /MOD 48 + EMIT 48 + EMIT ;
DOC" .3DIG ( n -- ) print n as 3 decimal digits"
: .3DIG  ( n -- )  100 /MOD 48 + EMIT .2DIG ;
DOC" .ELAPSED ( ms -- ) print ms as HH:MM:SS.mmm"
: .ELAPSED  ( ms -- )
    BASE @ >R DECIMAL
    1000 /MOD SWAP >R 60 /MOD SWAP >R 60 /MOD SWAP >R
    DUP 10 < IF 48 EMIT THEN 0 <# #S #> TYPE
    58 EMIT R> .2DIG 58 EMIT R> .2DIG 46 EMIT R> .3DIG
    R> BASE ! ;
DOC" ELAPSED ( 'name' -- ) run name once and print elapsed time"
: ELAPSED  ( "name" -- )  ' MS@ >R EXECUTE MS@ R> - .ELAPSED CR ;

\ --- Flags for FILE-ECHO etc. -----------------------------------------------
DOC" ON ( addr -- ) store true (-1) at addr"
: ON   -1 SWAP ! ;
DOC" OFF ( addr -- ) store 0 at addr"
: OFF   0 SWAP ! ;

\ --- Search-Order display helpers (64Forth lineage; DICT_THREADS=1) ----------
DOC" U.R ( u n -- ) print u right-justified in n field"
: U.R  >R 0 <# #S #> R> OVER - 0 MAX SPACES TYPE ;
DOC" .R ( n n -- ) print n right-justified in field (no trailing space)"
: .R  >R DUP ABS 0 <# #S ROT SIGN #> R> OVER - 0 MAX SPACES TYPE ;
DOC" (THREAD-DEPTH) ( head -- n ) count words in one hash chain"
: (THREAD-DEPTH)  0 SWAP BEGIN DUP WHILE SWAP 1+ SWAP 2 CELLS - @ REPEAT DROP ;
DOC" (WID.THREADS) ( wid -- ) print thread depths for wid"
: (WID.THREADS)  DICT-THREADS 0 DO DUP I CELLS + @ (THREAD-DEPTH) 5 .R LOOP DROP ;
DOC" .THREADS ( -- ) print CONTEXT wordlist chain depths"
: .THREADS  (CONTEXT) (WID.THREADS) CR ;
DOC" (TYPE-FIELD) ( c-addr u n -- ) type string left-justified in field n"
: (TYPE-FIELD)  >R 2DUP TYPE NIP R> SWAP - 0 MAX SPACES ;
DOC" (IS-VOCAB) ( nt -- flag ) true if nt was defined by VOCABULARY"
: (IS-VOCAB)  CELL+ @ ['] FP CELL+ @ = ;
DOC" (SHOW-VOCAB) ( nt -- true ) print vocabulary name and thread depths"
: (SHOW-VOCAB)  DUP (IS-VOCAB) IF DUP NAME>STRING 16 (TYPE-FIELD) 2 CELLS + (WID.THREADS) CR ELSE DROP THEN TRUE ;
VARIABLE (VW-T)  VARIABLE (VW-F)
DOC" (CHK-VOC-WID) ( nt -- cont ) TRAVERSE helper for (VOCAB-WID?)"
: (CHK-VOC-WID)  DUP (IS-VOCAB) IF 2 CELLS + (VW-T) @ = IF -1 (VW-F) ! FALSE ELSE TRUE THEN ELSE DROP TRUE THEN ;
DOC" (VOCAB-WID?) ( wid -- flag ) true if wid is a named VOCABULARY head array"
: (VOCAB-WID?)  (VW-T) ! 0 (VW-F) ! ['] (CHK-VOC-WID) FORTH-WORDLIST TRAVERSE-WORDLIST (VW-F) @ ;
DOC" (SHOW-BARE-WL) ( wid -- ) print one non-named wordlist from the registry"
: (SHOW-BARE-WL)
  DUP FORTH-WORDLIST = IF DROP EXIT THEN
  DUP (VOCAB-WID?) IF DROP EXIT THEN
  S" (wordlist)" 16 (TYPE-FIELD) (WID.THREADS) CR ;
DOC" (SHOW-WL-REG) ( -- ) print bare WORDLIST entries not already named"
: (SHOW-WL-REG)  WORDLISTS 0 ?DO DUP I CELLS + @ (SHOW-BARE-WL) LOOP DROP ;
DOC" .VOCABULARIES ( -- ) list FORTH, VOCABULARY lists, and bare WORDLISTs"
: .VOCABULARIES
  S" FORTH" 16 (TYPE-FIELD) FORTH-WORDLIST (WID.THREADS) CR
  ['] (SHOW-VOCAB) FORTH-WORDLIST TRAVERSE-WORDLIST (SHOW-WL-REG) ;
DOC" .WORDLISTS ( -- ) synonym of .VOCABULARIES"
: .WORDLISTS  .VOCABULARIES ;

\ --- Unsigned compare + DUMP (from 64Forth) ---------------------------------
DOC" U< ( u1 u2 -- flag ) unsigned less than"
: U<  ( u1 u2 -- flag )
    2DUP XOR 0< IF SWAP DROP 0< ELSE - 0< THEN ;
DOC" WITHIN ( n1 n2 n3 -- flag ) true if n2 <= n1 < n3 (unsigned wrap)"
: WITHIN  ( n1 n2 n3 -- flag )  OVER - >R - R> U< ;

DOC" .H2 ( b -- ) print byte as 2 hex digits"
: .H2  255 AND 0 <# # # #> TYPE ;
DOC" .HA ( addr -- ) print address as 16 hex digits"
: .HA  0 <# # # # # # # # # # # # # # # # # #> TYPE ;
DOC" DUMP-END ( -- addr ) variable end of DUMP range"
VARIABLE DUMP-END
DOC" DUMP-LINE ( addr -- addr' ) dump one line"
: DUMP-LINE
    DUP .HA SPACE SPACE DUP
    16 0 DO
        DUP I + DUMP-END @ U< IF DUP I + C@ .H2 SPACE ELSE SPACE SPACE SPACE THEN
    LOOP
    SPACE SPACE
    16 0 DO
        DUP I + DUMP-END @ U< IF
            DUP I + C@ DUP BL 127 WITHIN 0= IF DROP BL THEN EMIT
        ELSE BL EMIT THEN
    LOOP
    DROP 16 + ;
DOC" DUMP ( addr u -- ) hex dump u bytes from addr (16 per line, ASCII gutter)"
: DUMP
    BASE @ >R HEX OVER + DUMP-END !
    BEGIN DUP DUMP-END @ U< WHILE CR DUMP-LINE REPEAT
    DROP CR R> BASE ! ;

\\ Don't want to load smoke tests for now

\ --- Smoke tests (left INLINE-OFF so the image boots debuggable) ------------
: SQUARE  DUP * ;
: TEST    5 SQUARE . CR ;

\ After load, user may:  INLINE-ON  and redefine app words for speed.
\ Or wrap a single threaded definition:  D: DEBUGGY ... ;

\ S" hi" TYPE CR
\ TEST
{

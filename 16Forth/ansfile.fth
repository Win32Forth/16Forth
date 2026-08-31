\  ansfile.fth
\  16ForthCLI
\
\  Created by Tom's MacBook Air on 8/25/26.
\
\ ansfile.fth — ANS File-Access word set (minimal useful subset)
\ Requires the (FILE-OP) multiplexor in the kernel.
\ DOC" before each defining word so SEE shows help (same as kernel.fth).

\ Family constants
DOC" R/O ( -- fam ) read-only file access method"
1 CONSTANT R/O
DOC" W/O ( -- fam ) write-only file access method"
2 CONSTANT W/O
DOC" R/W ( -- fam ) read/write file access method"
3 CONSTANT R/W
DOC" BIN ( -- fam ) binary file access modifier"
16 CONSTANT BIN

\ Internal helper: call the multiplexor
\ ( op a b c ptr -- ior )
\ : (FILE-OP)  (FILE-OP) ; \no helper for now, trying to geet it to run

DOC" (FNAME) ( -- addr ) NUL-terminated filename scratch"
CREATE (FNAME) 256 ALLOT

\ Copy a Forth string to a NUL-terminated C string in (FNAME)
DOC" >FNAME ( c-addr u -- c-addr' ) copy to NUL-terminated (FNAME)"
: >FNAME  ( c-addr u -- c-addr' )
    DUP 255 > IF DROP 255 THEN
    (FNAME) 2dup c!             \ ( c-adr u -- c-adr ) store count in (FNAME)
    1+ >R                       \ inc dest, addr on R stack
                                \ ( c-addr u )
    BEGIN DUP WHILE             \ ( c-addr u )
        OVER C@ R@ C!           \ ( c-addr u ) store first char in dest addr
        1- SWAP 1+ SWAP         \ ( c-addr+1 u-1 ) bump to next char in string
        R> 1+ >R                \ Adjust dest addr to next char
    REPEAT
    2DROP                       \ ( -- ) clean up stack
    0 R> C!                     \ NUL terminate destination string
    (FNAME) 1+ ;                \ ( -- dest addr of null term string )

\ ---- Standard words -------------------------------------------------------

\ (In practice you will expose FILE-O1/FILE-O2 as CONSTANTs or VALUEs)

\ Because the result cells are in assembly, the cleanest high-level interface is:
\ We define thin wrappers that push the results.

\ For simplicity in this first version we assume the assembly also
\ pushes the results or we add two more tiny CODE words.
\ Here is a pragmatic version that works with the multiplexor returning ior
\ and storing results in known locations.

\ ---- Practical high-level definitions (recommended) -----------------------

\ You will need two small CODE words or VALUEs that fetch FILE-O1 / FILE-O2.
\ Add these two lines in assembly (or expose them):

\ BOOT_WORD "FILE-O1", "...", 0, XFO1
\ XFO1: adrp x0, FILE-O1@page ; add x0,x0,FILE-O1@pageoff ; ldr x0,[x0] ; DPUSH ; NEXT
\ (same for FILE-O2)

\ Then the high-level words become:

\ Same pattern for OPEN-FILE
DOC" OPEN-FILE ( c-addr u fam -- fileid ior ) open existing file"
: OPEN-FILE  ( c-addr u fam -- fileid ior )
    >R >FNAME
    R> SWAP
    (OPEN-FILE) ;

DOC" CREATE-FILE ( c-addr u fam -- fileid ior ) create or truncate file"
: CREATE-FILE  ( c-addr u fam -- fileid ior )
    >R                  \ R: fam
    >FNAME              \ ptr
    R> SWAP             \ fam ptr
    (CREATE-FILE) ;

DOC" CLOSE-FILE ( fileid -- ior ) close file"
: CLOSE-FILE  ( fileid -- ior )
    (CLOSE-FILE) ;

DOC" READ-FILE ( c-addr u fileid -- u2 ior ) read u bytes"
: READ-FILE  ( c-addr u fileid -- u2 ior )
    (READ-FILE) ;

DOC" WRITE-FILE ( c-addr u fileid -- ior ) write u bytes"
: WRITE-FILE  ( c-addr u fileid -- ior )
    (WRITE-FILE) ;

DOC" READ-LINE ( c-addr u1 fileid -- u2 flag ior ) read one line"
: READ-LINE  ( c-addr u1 fileid -- u2 flag ior )
    (READ-LINE) ;

DOC" WRITE-LINE ( c-addr u fileid -- ior ) write line plus newline"
: WRITE-LINE  ( c-addr u fileid -- ior )
    (WRITE-LINE) ;

DOC" FILE-SIZE ( fileid -- ud ior ) file size in bytes"
: FILE-SIZE  ( fileid -- ud ior )
    (FILE-SIZE) ;

DOC" FILE-POSITION ( fileid -- ud ior ) current file position"
: FILE-POSITION  ( fileid -- ud ior )
    (FILE-POSITION) ;

DOC" DELETE-FILE ( c-addr u -- ior ) delete named file"
: DELETE-FILE  ( c-addr u -- ior )
    >FNAME
    (DELETE-FILE) ;

DOC" REPOSITION-FILE ( ud fileid -- ior ) set file position"
: REPOSITION-FILE  ( ud fileid -- ior )
    (REPOSITION-FILE) ;
    
\ Optional convenience
DOC" INCLUDE-FILE ( i*x fileid -- j*x ) interpret file then close (stub)"
: INCLUDE-FILE  ( i*x fileid -- j*x )
    \ simplistic version – read whole file into a temporary buffer later
    CLOSE-FILE DROP ;

\\
: FILE-SMOKE  ( -- )
    S" smoke.txt" R/W CREATE-FILE
    DUP IF ." create ior=" . CR DROP EXIT THEN
    DROP
    >R
    S" line one" R@ WRITE-LINE .
    S" line two" R@ WRITE-LINE .
    R@ CLOSE-FILE .
    R> DROP

    S" smoke.txt" R/O OPEN-FILE
    DUP IF ." open ior=" . CR DROP EXIT THEN
    DROP
    >R
    PAD 80 R@ READ-LINE
    DUP IF ." read1 ior=" . CR 2DROP R> DROP EXIT THEN
    DROP
    IF PAD SWAP TYPE CR ELSE DROP THEN
    PAD 80 R@ READ-LINE
    DUP IF ." read2 ior=" . CR 2DROP R> DROP EXIT THEN
    DROP
    IF PAD SWAP TYPE CR ELSE DROP THEN
    R> CLOSE-FILE .
    .S ;

: T-SIZE  ( -- )
    S" smoke.txt" R/O OPEN-FILE
    IF ." open " . CR EXIT THEN DROP
    >R
    R@ FILE-SIZE
    IF ." size ior " . CR 2DROP
    ELSE ." size " . . CR THEN
    R> CLOSE-FILE DROP ;

: T-POS  ( -- )
    S" smoke.txt" R/O OPEN-FILE
    IF ." open " . CR EXIT THEN DROP
    >R
    R@ FILE-POSITION
    IF ." pos ior " . CR 2DROP
    ELSE ." pos " . . CR THEN
    R> CLOSE-FILE DROP ;

: T-REPOS  ( -- )
    S" smoke.txt" R/W OPEN-FILE
    IF ." open " . CR EXIT THEN DROP
    >R
    0 0 R@ REPOSITION-FILE .
    R@ FILE-POSITION
    IF ." pos ior " . CR 2DROP
    ELSE ." pos " . . CR THEN
    R> CLOSE-FILE DROP ;

: T-DELETE  ( -- )
    S" smoke.txt" DELETE-FILE .
    S" smoke.txt" R/O OPEN-FILE
    IF ." deleted ok, open ior=" . CR DROP
    ELSE ." still exists " DROP CLOSE-FILE DROP THEN ;
    
{

\ -----------------------------------------------------------------------------
\ End of ansfile.fth

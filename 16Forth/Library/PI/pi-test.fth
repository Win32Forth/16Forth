\ pi-test.fth - high-precision PI demo (shipped in Resources/Library/PI)
\
\ Run:  FROMLIB FLOAD PI/pi-test.fth
\
DECIMAL

.( === Loading BigInteger/big-int.fth ===) CR
FROMLIB REQUIRE BigInteger/big-int.fth
ALSO BIG-INTEGER

.( === Loading PI/pi-chudnovsky.fth ===) CR
FROMLIB REQUIRE PI/pi-chudnovsky.fth

.( === pi to 20 places ===) CR
20 PI. CR

.( === pi to 50 places ===) CR
50 PI. CR

.( === pi to 100 places ===) CR
100 PI. CR

.( === Reference 20 decimals ===) CR
.( 3.14159265358979323846) CR
.( === pi-test done ===) CR

\S

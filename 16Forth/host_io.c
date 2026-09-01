#include <stdio.h>
#include <stdint.h>
#include <string.h>

void forth_io_init(void)
{
    setvbuf(stdin,  NULL, _IONBF, 0);
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
}

/* UM/MOD helper: unsigned 128-bit dividend / 64-bit divisor → rem, quot. */
void forth_udivmod128(uint64_t lo, uint64_t hi, uint64_t d,
                      uint64_t *rem, uint64_t *quot)
{
    unsigned __int128 n = ((unsigned __int128)hi << 64) | lo;
    if (d == 0) {
        *rem = 0;
        *quot = 0;
        return;
    }
    *quot = (uint64_t)(n / d);
    *rem  = (uint64_t)(n % d);
}

// Prompt, then one line from stdin. Returns length, or 0 on EOF.
long forth_readline(char *buf, long n)
{
    fputs(" ok\n", stdout);
    fflush(stdout);
    if (n < 2)
        return 0;
    if (fgets(buf, (int)n, stdin) == NULL)
        return 0;
    return (long)strlen(buf);
}

long long host_file_op(long long op,
                       long long a, long long b, long long c,
                       void *ptr,
                       long long *o1, long long *o2);

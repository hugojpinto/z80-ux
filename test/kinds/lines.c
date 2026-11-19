/* z80-ux test: a stream-kind program (putchar and puts only) */
#include <c48.h>

int main(void)
{
    int i;
    for (i = 1; i <= 3; i++) {
        putchar('0' + i);
        puts(" line");
    }
    return 0;
}

/* z80-ux test: floats through the platform's engine (platform/float.md).
 * Each result, scaled and truncated, is far from a whole number, so every
 * binding - the Spectrum ROM, the clean-room engine - prints the same:
 * 14142 8414 5403 1218 23025 31415 1024 5463 5235 10471 350 -3 */
#include <c48.h>

static void pn(int n)
{
    char b[8];
    int i;
    i = 0;
    if (n < 0) {
        putchar('-');
        n = -n;
    }
    do {
        b[i] = '0' + n % 10;
        i++;
        n = n / 10;
    } while (n);
    while (i) {
        i--;
        putchar(b[i]);
    }
    putchar(' ');
}

int main(void)
{
    float x;
    pn((int)(sqrt(2.0) * 10000.0));
    pn((int)(sin(1.0) * 10000.0));
    pn((int)(cos(1.0) * 10000.0));
    pn((int)(exp(2.5) * 100.0));
    pn((int)(log(10.0) * 10000.0));
    pn((int)(atan(1.0) * 40000.0));
    pn((int)pow(2.0, 10.0));
    pn((int)(tan(0.5) * 10000.0));
    pn((int)(asin(0.5) * 10000.0));
    pn((int)(acos(0.5) * 10000.0));
    x = 7.0;
    pn((int)(x / 2.0 * 100.0));
    pn((int)(-3.7));
    putchar('\n');
    puts("float ok");
    return 0;
}

/* z80-ux test: floats through the platform's engine (platform/float.md).
 * Each result, scaled and truncated, is far from a whole number, so every
 * binding - the Spectrum ROM, the clean-room engine - prints the same:
 * 14142 8414 5403 1218 23025 31415 1024 5463 5235 10471 350 -3
 * then numbers as text (ftoa, atof: libux/fstr.asm), whose eighth digits
 * are far from a rounding boundary:
 * 1.4142136 0.33333333 1E+10 -.05 65535 -1250 6.2831853 */
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

static void pf(float x)
{
    char b[16];
    char *p;
    ftoa(x, b);
    for (p = b; *p; p++)
        putchar(*p);
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
    pf(sqrt(2.0));
    pf(1.0 / 3.0);
    pf(pow(10.0, 10.0));
    pf(-0.05);
    pf(65535.0);
    pf(atof("  -12.5e2"));
    pf(atof("3.14159265") * 2.0);
    putchar('\n');
    puts("float ok");
    return 0;
}

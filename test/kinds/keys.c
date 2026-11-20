/* zx-ux test: kbd_down and kbdmatrix.  Waits up to 3 seconds for A to be
 * held, then prints what it saw: "a:1" on a Spectrum while A is held,
 * "a:0" behind a terminal (the FDD3000), where no key is ever down. */
#include <c48.h>

int kbdmatrix(void);

int main(void)
{
    unsigned int t;
    int a, m;
    a = 0;
    m = 0;
    t = ticks();
    while (ticks() - t < 150) {
        if (kbd_down('a'))
            a = 1;
        if (kbdmatrix())
            m = 1;
        if (a)
            break;
        yield();
    }
    putchar('a');
    putchar(':');
    putchar('0' + a);
    putchar(' ');
    putchar('m');
    putchar(':');
    putchar('0' + m);
    putchar('\n');
    return 0;
}

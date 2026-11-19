/* z80-ux test: beep() with no screen - three short beeps (a terminal's
 * bell on the FDD3000, at most one every fifth of a second), then a line. */
#include <c48.h>

int main(void)
{
    int i;
    for (i = 0; i < 3; i++)
        beep(0.05, 0.0);
    puts("bell ok");
    return 0;
}

/* z80-ux test: a console-kind program with colour (test/spectrum/kinds.py) */
#include <c48.h>

int main(void)
{
    cls();
    ink(2);
    paper(5);
    print_at(5, 6, "red on cyan");
    ink(7);
    paper(0);
    print_at(7, 6, "plain");
    return 0;
}

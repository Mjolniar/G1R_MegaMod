/* Solver for the lock minigame of Gothic 1 Remake (dev/facts/locks.md, L2 and L3 for the rules).
 *
 *   gcc -O2 -o solver solver.c
 *   ./solver < locks.txt > solved.txt
 *
 * Input, one lock per line:   name  n  p0 .. p(n-1)  c  (id connectedId direction) x c
 * Output, one lock per line:  name  n  c  then for every depth k = 0 .. c (the first k connections of the list
 *                             taken away) either "-" (cannot be opened) or a shortest way to open it, written as
 *                             moves "<piece><+|->" without separators (piece ids are single digits).
 *
 * The rules: every piece has a position -3 .. 3 and the lock is open when all are 0. A move takes piece s one
 * step up or down and every piece connected FROM s by step x direction; a move that would take any piece out of
 * -3 .. 3 is not made. The search is breadth first over all positions (at most 7^7), so "-" is a proof that no
 * way exists, and a way that is printed is a shortest one.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAXP 8
#define MAXC 64

static int n, nc, ca[MAXC], cb[MAXC], cd[MAXC], start[MAXP];
static int pw[MAXP + 1];
static int *parent, *queue;
static unsigned char *via;
static signed char *seen;

static void solve(int k, int total)
{
    int vec[MAXP][MAXP];
    int p[MAXP];
    int head = 0, tail = 0, si = 0, goal = 0, found = -1;
    memset(vec, 0, sizeof vec);
    for (int s = 0; s < n; s++) vec[s][s] = 1;
    for (int i = k; i < nc; i++) vec[ca[i]][cb[i]] += cd[i];
    memset(seen, 0, (size_t)total);
    for (int i = 0; i < n; i++) { si += (start[i] + 3) * pw[i]; goal += 3 * pw[i]; }
    seen[si] = 1; parent[si] = -1; queue[tail++] = si;
    if (si == goal) found = si;
    while (found < 0 && head < tail) {
        int cur = queue[head++], c = cur;
        for (int i = 0; i < n; i++) { p[i] = c % 7 - 3; c /= 7; }
        for (int s = 0; s < n && found < 0; s++)
            for (int d = -1; d <= 1; d += 2) {
                int ok = 1, idx = 0;
                for (int i = 0; i < n; i++) {
                    int v = p[i] + d * vec[s][i];
                    if (v < -3 || v > 3) { ok = 0; break; }
                    idx += (v + 3) * pw[i];
                }
                if (!ok || seen[idx]) continue;
                seen[idx] = 1; parent[idx] = cur; via[idx] = (unsigned char)(s * 2 + (d > 0));
                if (idx == goal) { found = idx; break; }
                queue[tail++] = idx;
            }
    }
    if (found < 0) { printf(" -"); return; }
    {
        static char buf[4096];
        int len = 0, at = found;
        while (parent[at] >= 0) {
            if (len + 2 > (int)sizeof buf) { fprintf(stderr, "a way of more than %d moves\n", (int)sizeof buf / 2); exit(1); }
            buf[len++] = (via[at] & 1) ? '+' : '-'; buf[len++] = (char)('0' + via[at] / 2); at = parent[at];
        }
        putchar(' ');
        if (len == 0) putchar('=');
        for (int i = len - 1; i >= 0; i--) putchar(buf[i]);
    }
}

int main(void)
{
    char name[256];
    pw[0] = 1;
    for (int i = 1; i <= MAXP; i++) pw[i] = pw[i - 1] * 7;
    parent = malloc(sizeof(int) * (size_t)pw[MAXP]);
    queue = malloc(sizeof(int) * (size_t)pw[MAXP]);
    via = malloc((size_t)pw[MAXP]);
    seen = malloc((size_t)pw[MAXP]);
    while (scanf("%255s %d", name, &n) == 2) {
        if (n < 1 || n > MAXP) return 1;
        for (int i = 0; i < n; i++) if (scanf("%d", &start[i]) != 1) return 1;
        if (scanf("%d", &nc) != 1 || nc < 0 || nc > MAXC) return 1;
        for (int i = 0; i < nc; i++) if (scanf("%d %d %d", &ca[i], &cb[i], &cd[i]) != 3) return 1;
        printf("%s %d %d", name, n, nc);
        for (int k = 0; k <= nc; k++) solve(k, pw[n]);
        printf("\n");
    }
    return 0;
}

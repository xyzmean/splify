/*
 * splify-dnsd — transparent DNS forwarding proxy that routes matched domains
 * into splify's existing nftables sets (splify_vpn_v4 / splify_direct_v4) at
 * resolve time, based on richer domain-rule matching (exact / namespace /
 * wildcard / regex) than dnsmasq's `nftset=` directive supports.
 *
 * It NEVER resolves anything itself: every client query is forwarded
 * byte-for-byte to the real resolver (dnsmasq, 127.0.0.1:53). For a domain
 * that does NOT match a rule (the overwhelming majority), the answer is
 * relayed back byte-for-byte, unmodified. For a domain that DOES match, the
 * real answer is NOT relayed — the client is instead handed a synthetic,
 * domain-exclusive "fake" IPv4 from a private pool (198.18.0.0/15) that this
 * daemon allocates and persists 1:1 per domain (see the fakeip_* pool
 * below); an nftables DNAT rule (installed by splify-apply) then rewrites
 * that fake IP back to the real backend before the packet leaves the
 * router. This sidesteps two problems a real-IP-based approach can't: real
 * CDN IPs (Cloudflare etc.) are shared across many unrelated domains from a
 * dynamic pool, so tagging the real IP is collision-prone; and the decision
 * here is made from the DNS question name — always visible in plaintext —
 * rather than from the TLS SNI, so it works even when ECH hides the SNI.
 * AAAA answers for a matched domain are suppressed (NODATA) rather than
 * relayed, since splify has no IPv6 routing at all and letting a real AAAA
 * through would let a dual-stack client bypass the split entirely.
 *
 * A parsing failure, an unmatched domain, or anything this daemon can't
 * substitute (pool exhausted, no real A answer yet, non-A/AAAA query type)
 * NEVER blocks or alters the DNS transaction — fail open, always: relay the
 * real answer unchanged.
 *
 * Usage:
 *   splify-dnsd --listen-port P --upstream-port P --vpn-set NAME
 *               --direct-set NAME --vpn-rules PATH --direct-rules PATH
 *               --fakeip-state PATH [--fakeip-map NAME]
 *               [--table inet fw4] [--nft /usr/sbin/nft]
 *   splify-dnsd --selftest
 *   splify-dnsd --match RULES_PATH HOSTNAME
 *   splify-dnsd --fakeip STATE_PATH DOMAIN
 *
 * SIGHUP reloads both rule files without dropping in-flight queries.
 */

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <netinet/in.h>
#include <regex.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_PKT 4096
#define MAX_PENDING 256
#define PENDING_TTL_SEC 5
#define MAX_RULE_LINES 65536
#define MAX_HOSTNAME 256

/* ---------------------------------------------------------------------- */
/* rule matching                                                          */
/* ---------------------------------------------------------------------- */

enum rule_type { RULE_EXACT, RULE_NAMESPACE, RULE_WILDCARD, RULE_REGEX };

struct rule {
    enum rule_type type;
    char *pattern;   /* lowercased source pattern, kept for EXACT/NAMESPACE/WILDCARD */
    regex_t re;      /* compiled only when type == RULE_REGEX */
    int re_valid;
};

struct ruleset {
    struct rule *rules;
    size_t n;
    size_t cap;
};

static void ruleset_free(struct ruleset *rs) {
    for (size_t i = 0; i < rs->n; i++) {
        free(rs->rules[i].pattern);
        if (rs->rules[i].re_valid)
            regfree(&rs->rules[i].re);
    }
    free(rs->rules);
    rs->rules = NULL;
    rs->n = 0;
    rs->cap = 0;
}

static void str_lower(char *s) {
    for (; *s; s++) *s = (char)tolower((unsigned char)*s);
}

/* strip \r, comments (#...), surrounding whitespace; returns 0 for a blank
 * line the caller should skip. */
static int clean_line(char *line) {
    char *h = strchr(line, '#');
    if (h) *h = '\0';
    size_t n = strlen(line);
    while (n > 0 && (line[n - 1] == '\r' || line[n - 1] == '\n' ||
                     line[n - 1] == ' ' || line[n - 1] == '\t')) {
        line[--n] = '\0';
    }
    char *start = line;
    while (*start == ' ' || *start == '\t') start++;
    if (start != line) memmove(line, start, strlen(start) + 1);
    return line[0] != '\0';
}

static int ruleset_add(struct ruleset *rs, const char *raw) {
    if (rs->n >= MAX_RULE_LINES) return -1;
    if (rs->n == rs->cap) {
        size_t newcap = rs->cap ? rs->cap * 2 : 64;
        struct rule *nr = realloc(rs->rules, newcap * sizeof(*nr));
        if (!nr) return -1;
        rs->rules = nr;
        rs->cap = newcap;
    }
    struct rule *r = &rs->rules[rs->n];
    memset(r, 0, sizeof(*r));

    if (strncmp(raw, "re:", 3) == 0) {
        r->type = RULE_REGEX;
        if (regcomp(&r->re, raw + 3, REG_EXTENDED | REG_ICASE | REG_NOSUB) != 0)
            return -1; /* bad pattern: skip this rule, don't crash the daemon */
        r->re_valid = 1;
        r->pattern = strdup(raw + 3);
    } else if (raw[0] == '=') {
        r->type = RULE_EXACT;
        r->pattern = strdup(raw + 1);
        str_lower(r->pattern);
    } else if (strchr(raw, '*') || strchr(raw, '?')) {
        r->type = RULE_WILDCARD;
        r->pattern = strdup(raw);
        str_lower(r->pattern);
    } else {
        r->type = RULE_NAMESPACE;
        r->pattern = strdup(raw);
        str_lower(r->pattern);
    }
    if (!r->pattern && r->type != RULE_REGEX) return -1;
    rs->n++;
    return 0;
}

static int load_rules(const char *path, struct ruleset *rs) {
    struct ruleset tmp = {0};
    FILE *f = fopen(path, "r");
    if (!f) return -1; /* missing file: caller keeps empty ruleset, not an error */
    char line[512];
    while (fgets(line, sizeof(line), f)) {
        if (!clean_line(line)) continue;
        ruleset_add(&tmp, line);
    }
    fclose(f);
    ruleset_free(rs);
    *rs = tmp;
    return 0;
}

/* namespace match: exact hostname match, or hostname ends with "." + pattern */
static int match_namespace(const char *pattern, const char *host) {
    size_t hl = strlen(host), pl = strlen(pattern);
    if (hl == pl) return strcmp(host, pattern) == 0;
    if (hl > pl + 1 && host[hl - pl - 1] == '.')
        return strcmp(host + hl - pl, pattern) == 0;
    return 0;
}

static int rule_matches(const struct rule *r, const char *host_lower) {
    switch (r->type) {
        case RULE_EXACT:
            return strcmp(r->pattern, host_lower) == 0;
        case RULE_NAMESPACE:
            return match_namespace(r->pattern, host_lower);
        case RULE_WILDCARD:
            return fnmatch(r->pattern, host_lower, 0) == 0;
        case RULE_REGEX:
            return r->re_valid && regexec(&r->re, host_lower, 0, NULL, 0) == 0;
    }
    return 0;
}

static int ruleset_match(const struct ruleset *rs, const char *host) {
    char lower[MAX_HOSTNAME];
    size_t n = strlen(host);
    if (n >= sizeof(lower)) n = sizeof(lower) - 1;
    memcpy(lower, host, n);
    lower[n] = '\0';
    str_lower(lower);
    for (size_t i = 0; i < rs->n; i++)
        if (rule_matches(&rs->rules[i], lower)) return 1;
    return 0;
}

/* ---------------------------------------------------------------------- */
/* DNS wire-format parsing (read-only; never mutates the packet)          */
/* ---------------------------------------------------------------------- */

/* Decodes a (possibly compressed) name starting at pos into out (dot-joined,
 * NUL terminated), and returns via *next the stream position right after the
 * name (following RFC1035 compression-pointer semantics: only the FIRST
 * pointer counts toward the caller's next-field offset). */
static int parse_name_adv(const uint8_t *pkt, size_t len, size_t pos, char *out,
                           size_t outlen, size_t *next) {
    size_t start = pos;
    size_t opos = 0;
    int jumps = 0;
    size_t cursor = pos;
    size_t advance_to = 0;
    int pointer_taken = 0;

    for (;;) {
        if (cursor >= len) return -1;
        uint8_t lbl = pkt[cursor];
        if (lbl == 0) {
            if (!pointer_taken) advance_to = cursor + 1;
            break;
        }
        if ((lbl & 0xC0) == 0xC0) {
            if (cursor + 1 >= len) return -1;
            size_t target = ((size_t)(lbl & 0x3F) << 8) | pkt[cursor + 1];
            if (!pointer_taken) {
                advance_to = cursor + 2;
                pointer_taken = 1;
            }
            if (++jumps > 32) return -1;
            cursor = target;
            continue;
        }
        if ((lbl & 0xC0) != 0) return -1;
        size_t label_len = lbl;
        cursor++;
        if (cursor + label_len > len) return -1;
        if (opos + label_len + 1 >= outlen) return -1;
        if (opos > 0) out[opos++] = '.';
        memcpy(out + opos, pkt + cursor, label_len);
        opos += label_len;
        cursor += label_len;
    }
    out[opos] = '\0';
    (void)start;
    *next = advance_to;
    return 0;
}

#define DNS_TYPE_A    1
#define DNS_TYPE_AAAA 28

struct answer_ip {
    uint32_t addr; /* network byte order */
    uint32_t ttl;
};

/* Parses a DNS response: extracts the question name (out_qname), question
 * type (out_qtype), the stream offset right after the question section
 * (out_qend — the header[0,12) + question[12,*out_qend) prefix is byte-
 * identical between the real response and anything we build to replace it,
 * so callers can reuse it verbatim), and every A-record (class IN) answer
 * IP+TTL, up to max_ips entries. Only correct for qdcount==1 (universally
 * true for a resolver's own queries) — anything else is treated as
 * unparseable. Returns the number of A-record IPs found, or -1 on a
 * malformed/short/multi-question packet (caller must still relay the raw
 * bytes to the client regardless). */
static int parse_response(const uint8_t *pkt, size_t len, char *out_qname,
                           size_t qname_len, uint16_t *out_qtype,
                           size_t *out_qend, struct answer_ip *ips,
                           int max_ips) {
    if (len < 12) return -1;
    uint16_t qdcount = (pkt[4] << 8) | pkt[5];
    uint16_t ancount = (pkt[6] << 8) | pkt[7];

    size_t pos = 12;
    if (qdcount != 1) return -1;

    size_t next = 0;
    if (parse_name_adv(pkt, len, pos, out_qname, qname_len, &next) != 0)
        return -1;
    pos = next;
    if (pos + 4 > len) return -1;
    *out_qtype = (uint16_t)((pkt[pos] << 8) | pkt[pos + 1]);
    pos += 4; /* qtype + qclass */
    *out_qend = pos;

    int found = 0;
    for (uint16_t a = 0; a < ancount && pos < len; a++) {
        char rrname[MAX_HOSTNAME];
        if (parse_name_adv(pkt, len, pos, rrname, sizeof(rrname), &next) != 0)
            break;
        pos = next;
        if (pos + 10 > len) break;
        uint16_t rtype = (pkt[pos] << 8) | pkt[pos + 1];
        uint16_t rclass = (pkt[pos + 2] << 8) | pkt[pos + 3];
        uint32_t ttl = ((uint32_t)pkt[pos + 4] << 24) | ((uint32_t)pkt[pos + 5] << 16) |
                       ((uint32_t)pkt[pos + 6] << 8) | pkt[pos + 7];
        uint16_t rdlen = (pkt[pos + 8] << 8) | pkt[pos + 9];
        pos += 10;
        if (pos + rdlen > len) break;
        if (rtype == DNS_TYPE_A && rclass == 1 /* IN */ && rdlen == 4 &&
            found < max_ips) {
            uint32_t addr;
            memcpy(&addr, pkt + pos, 4);
            ips[found].addr = addr;
            ips[found].ttl = ttl;
            found++;
        }
        pos += rdlen;
    }
    return found;
}

/* ---------------------------------------------------------------------- */
/* nft integration                                                        */
/* ---------------------------------------------------------------------- */

static const char *g_nft_path = "/usr/sbin/nft";
static const char *g_nft_table = "inet fw4";

/* Splits g_nft_table ("inet fw4") into family/table for argv — shared by
 * every nft_add_* call below. */
static void nft_family_table(char *out_fam, char *out_tbl, size_t out_tbl_sz) {
    char copy[64];
    snprintf(copy, sizeof(copy), "%s", g_nft_table);
    char *sp = strchr(copy, ' ');
    if (sp) {
        *sp = '\0';
        strcpy(out_fam, copy);
        snprintf(out_tbl, out_tbl_sz, "%s", sp + 1);
    } else {
        strcpy(out_fam, copy);
        snprintf(out_tbl, out_tbl_sz, "fw4");
    }
}

/* Every nft mutation goes through a bounded queue with AT MOST ONE `nft`
 * child running at a time. Two things converged to make this necessary,
 * both confirmed on real hardware: (1) `nft add element` against a real
 * router's live ruleset (tens of thousands of existing set/map elements —
 * ipsum/nozapret alone routinely run 5-6 figures) can take several seconds,
 * so a synchronous wait would stall every LAN client's DNS resolution, not
 * just the one triggering the add (measured up to ~35s for two sequential
 * blocking calls) — the first fix was firing children without waiting at
 * all. But (2) each `nft` invocation loads/parses that ruleset into its OWN
 * memory (measured 15-70MB per process) — a burst of new domains (e.g.
 * importing a large list) previously fired one child per resolved query
 * with no limit, and two such children running concurrently on a memory-
 * constrained router (~240MB total) is exactly what got one OOM-killed
 * live during testing. Serializing bounds peak memory to one `nft` process
 * regardless of how bursty the traffic is — mutations simply queue and
 * land slightly later, which is fine: they were always best-effort/
 * eventually-consistent (see the timeout-clamp comment below).
 *
 * No SIGCHLD tracking needed: run_proxy() sets it to SIG_IGN (auto-reap,
 * per POSIX), so completion is instead detected via kill(pid, 0) — ESRCH
 * once the kernel has reaped it. That poll happens once per main-loop
 * iteration (nft_pump()), which runs at least every ~1s (epoll_wait's
 * timeout) even under zero other traffic. */
#define NFT_QUEUE_MAX 512

struct nft_queued_cmd {
    char *fam, *tbl, *name, *spec;
};

static struct nft_queued_cmd *g_nft_queue;
static size_t g_nft_queue_n, g_nft_queue_cap;
static pid_t g_nft_current_pid = -1;

static void nft_enqueue(const char *fam, const char *tbl, const char *name, const char *spec) {
    if (g_nft_queue_n >= NFT_QUEUE_MAX) return; /* fail open: drop, never block on a full queue */
    if (g_nft_queue_n == g_nft_queue_cap) {
        size_t newcap = g_nft_queue_cap ? g_nft_queue_cap * 2 : 32;
        struct nft_queued_cmd *nq = realloc(g_nft_queue, newcap * sizeof(*nq));
        if (!nq) return;
        g_nft_queue = nq;
        g_nft_queue_cap = newcap;
    }
    struct nft_queued_cmd *c = &g_nft_queue[g_nft_queue_n];
    c->fam = strdup(fam);
    c->tbl = strdup(tbl);
    c->name = strdup(name);
    c->spec = strdup(spec);
    if (!c->fam || !c->tbl || !c->name || !c->spec) {
        free(c->fam); free(c->tbl); free(c->name); free(c->spec);
        return;
    }
    g_nft_queue_n++;
}

/* Call once per main-loop iteration. Starts the next queued command only
 * once the previous one has actually exited, so at most one `nft` process
 * ever runs at a time. */
static void nft_pump(void) {
    if (g_nft_current_pid != -1) {
        if (kill(g_nft_current_pid, 0) == 0) return; /* still running */
        g_nft_current_pid = -1;
    }
    if (g_nft_queue_n == 0) return;

    struct nft_queued_cmd c = g_nft_queue[0];
    memmove(g_nft_queue, g_nft_queue + 1, (--g_nft_queue_n) * sizeof(*g_nft_queue));

    pid_t pid = fork();
    if (pid == 0) {
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) { dup2(devnull, 1); dup2(devnull, 2); close(devnull); }
        char *argv[] = {(char *)g_nft_path, (char *)"add", (char *)"element",
                         c.fam, c.tbl, c.name, (char *)"{", c.spec, (char *)"}", NULL};
        execv(g_nft_path, argv);
        _exit(127);
    }
    if (pid > 0) g_nft_current_pid = pid;
    free(c.fam); free(c.tbl); free(c.name); free(c.spec);
}

static void nft_add_element(const char *set_name, const char *ip_str, uint32_t ttl) {
    if (ttl < 1) ttl = 1;
    if (ttl > 86400) ttl = 86400; /* clamp: never let a hostile/huge TTL pin an entry forever */

    char fam[32], tbl[32];
    nft_family_table(fam, tbl, sizeof(tbl));

    char spec[160];
    snprintf(spec, sizeof(spec), "%s timeout %us", ip_str, ttl);
    nft_enqueue(fam, tbl, set_name, spec);
}

/* Maps a fake IP to its real backend for the DNAT chain splify-apply installs
 * (`ip daddr 198.18.0.0/15 dnat ip to ip daddr map @<map_name>`). No timeout
 * here — the fake IP is a stable, exclusive, persistent allocation for this
 * domain (see the fakeip_* pool below), so its map entry should live as long
 * as the mapping does; it's simply overwritten with a fresh real IP on the
 * next query if the backend moves. */
static void nft_add_map_element(const char *map_name, const char *fake_ip_str,
                                 const char *real_ip_str) {
    char fam[32], tbl[32];
    nft_family_table(fam, tbl, sizeof(tbl));

    char spec[96];
    snprintf(spec, sizeof(spec), "%s : %s", fake_ip_str, real_ip_str);
    nft_enqueue(fam, tbl, map_name, spec);
}

static int is_valid_ipv4_str(const char *s) {
    struct in_addr a;
    return inet_aton(s, &a) != 0;
}

/* ---------------------------------------------------------------------- */
/* fake-IP pool: one stable, exclusive synthetic IPv4 per matched domain    */
/* ---------------------------------------------------------------------- */
/* Real CDN-fronted IPs (Cloudflare etc.) are shared across many unrelated
 * customer domains from a dynamic anycast pool — there is no fixed 1:1
 * domain->IP mapping, so tagging the real resolved IP into a set (as
 * nft_add_element above does) is collision-prone: two configured domains
 * can end up sharing one real IP, and then whichever one's set entry is
 * freshest decides routing for BOTH. Handing the client a synthetic IP that
 * THIS daemon allocates and owns 1:1 per domain makes that collision
 * structurally impossible, and — since the decision is made from the DNS
 * question name, always visible in plaintext — sidesteps ECH entirely (no
 * TLS/SNI parsing needed at all). Pool: 198.18.0.0/15, the RFC 2544
 * benchmarking range, the same convention already used by Clash/sing-box/
 * mihomo for this exact purpose; effectively never a real destination. */
#define FAKEIP_POOL_BASE 0xC6120000u /* 198.18.0.0 */
#define FAKEIP_POOL_SIZE 131072u     /* 198.18.0.0 - 198.19.255.255 */

struct fakeip_entry {
    char *domain; /* lowercased, matches the ruleset's own lowercasing */
    uint32_t addr; /* host byte order */
};

struct fakeip_table {
    struct fakeip_entry *entries;
    size_t n, cap;
};

static struct fakeip_table g_fakeip;
static const char *g_fakeip_state_path;

static uint32_t fakeip_index_to_addr(size_t idx) { return FAKEIP_POOL_BASE + (uint32_t)idx; }

static int fakeip_table_add(struct fakeip_table *t, const char *domain, uint32_t addr) {
    if (t->n == t->cap) {
        size_t newcap = t->cap ? t->cap * 2 : 64;
        struct fakeip_entry *ne = realloc(t->entries, newcap * sizeof(*ne));
        if (!ne) return -1;
        t->entries = ne;
        t->cap = newcap;
    }
    t->entries[t->n].domain = strdup(domain);
    if (!t->entries[t->n].domain) return -1;
    t->entries[t->n].addr = addr;
    t->n++;
    return 0;
}

/* One line per entry, "domain\tip". Missing file -> empty table, not an
 * error (first run). A malformed line is skipped, not fatal — the domain
 * simply gets re-allocated (a fresh index) on next match. */
static void fakeip_state_load(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[MAX_HOSTNAME + 32];
    while (fgets(line, sizeof(line), f)) {
        char *nl = strchr(line, '\n'); if (nl) *nl = '\0';
        char *tab = strchr(line, '\t');
        if (!tab) continue;
        *tab = '\0';
        struct in_addr a;
        if (inet_aton(tab + 1, &a) == 0) continue;
        fakeip_table_add(&g_fakeip, line, ntohl(a.s_addr));
    }
    fclose(f);
}

static void fakeip_state_append(const char *path, const char *domain, uint32_t addr) {
    FILE *f = fopen(path, "a");
    if (!f) return;
    struct in_addr a; a.s_addr = htonl(addr);
    char ipstr[INET_ADDRSTRLEN];
    if (inet_ntop(AF_INET, &a, ipstr, sizeof(ipstr)))
        fprintf(f, "%s\t%s\n", domain, ipstr);
    fclose(f);
}

/* Looks up domain's existing fake IP, or allocates the next free one and
 * persists it. Returns 0 and fills *out_addr (host order) on success; -1 if
 * the pool is exhausted (caller falls back to relaying the real answer
 * unchanged — fail open, never block DNS over an exhausted pool). */
static int fakeip_lookup_or_alloc(const char *domain, uint32_t *out_addr) {
    for (size_t i = 0; i < g_fakeip.n; i++) {
        if (strcmp(g_fakeip.entries[i].domain, domain) == 0) {
            *out_addr = g_fakeip.entries[i].addr;
            return 0;
        }
    }
    if (g_fakeip.n >= FAKEIP_POOL_SIZE) return -1;
    uint32_t addr = fakeip_index_to_addr(g_fakeip.n);
    if (fakeip_table_add(&g_fakeip, domain, addr) != 0) return -1;
    if (g_fakeip_state_path) fakeip_state_append(g_fakeip_state_path, domain, addr);
    *out_addr = addr;
    return 0;
}

/* ---------------------------------------------------------------------- */
/* proxy state                                                           */
/* ---------------------------------------------------------------------- */

struct pending {
    int fd;
    int in_use;
    struct sockaddr_in client;
    socklen_t client_len;
    time_t expire;
};

static struct pending g_pending[MAX_PENDING];
static int g_epfd = -1;
static int g_listen_fd = -1;
static struct ruleset g_vpn_rules;
static struct ruleset g_direct_rules;
static const char *g_vpn_set = "splify_vpn_v4";
static const char *g_direct_set = "splify_direct_v4";
static const char *g_vpn_rules_path;
static const char *g_direct_rules_path;
static const char *g_fakeip_map = "splify_fakeip_map";
static volatile int g_reload_pending = 0;
static volatile int g_running = 1;

static void on_sighup(int sig) { (void)sig; g_reload_pending = 1; }
static void on_sigterm(int sig) { (void)sig; g_running = 0; }

static void reload_rules(void) {
    if (g_vpn_rules_path) load_rules(g_vpn_rules_path, &g_vpn_rules);
    if (g_direct_rules_path) load_rules(g_direct_rules_path, &g_direct_rules);
    fprintf(stderr, "splify-dnsd: reloaded rules (vpn=%zu direct=%zu)\n",
            g_vpn_rules.n, g_direct_rules.n);
}

static struct pending *pending_alloc(void) {
    time_t now = time(NULL);
    for (int i = 0; i < MAX_PENDING; i++) {
        if (g_pending[i].in_use && g_pending[i].expire < now) {
            epoll_ctl(g_epfd, EPOLL_CTL_DEL, g_pending[i].fd, NULL);
            close(g_pending[i].fd);
            g_pending[i].in_use = 0;
        }
    }
    for (int i = 0; i < MAX_PENDING; i++)
        if (!g_pending[i].in_use) return &g_pending[i];
    return NULL;
}

static void handle_client_query(int upstream_port) {
    uint8_t buf[MAX_PKT];
    struct sockaddr_in from;
    socklen_t fromlen = sizeof(from);
    ssize_t n = recvfrom(g_listen_fd, buf, sizeof(buf), 0, (struct sockaddr *)&from, &fromlen);
    if (n <= 0) return;

    struct pending *p = pending_alloc();
    if (!p) return; /* under load: drop, client's own resolver will retry/timeout */

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return;
    struct sockaddr_in up = {0};
    up.sin_family = AF_INET;
    up.sin_port = htons((uint16_t)upstream_port);
    up.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&up, sizeof(up)) != 0) { close(fd); return; }
    if (send(fd, buf, (size_t)n, 0) < 0) { close(fd); return; }

    p->fd = fd;
    p->in_use = 1;
    p->client = from;
    p->client_len = fromlen;
    p->expire = time(NULL) + PENDING_TTL_SEC;

    struct epoll_event ev = {0};
    ev.events = EPOLLIN;
    ev.data.ptr = p;
    epoll_ctl(g_epfd, EPOLL_CTL_ADD, fd, &ev);
}

/* FAKEIP_ANSWER_TTL is independent of the real record's TTL — the fake IP
 * itself never needs to expire from the client's cache the way a real
 * record does (it's a stable, persistent allocation); this just needs to be
 * short enough that the client re-queries periodically, e.g. after a NAT-map
 * refresh. */
#define FAKEIP_ANSWER_TTL 60

/* Builds a reply reusing the original response's header+question bytes
 * verbatim ([0, qend) — same transaction ID, same echoed question), with
 * ancount/nscount/arcount patched and (if with_answer) exactly one A record
 * appended pointing at fake_addr_host. nscount/arcount are always zeroed:
 * dropping any authority/additional section (e.g. an upstream EDNS OPT
 * record) is fine, our substitute answer is tiny and needs neither. Returns
 * the built length, or 0 if it wouldn't fit (defensive only — qend is
 * bounded by MAX_HOSTNAME and the answer is a fixed 16 bytes, so this never
 * actually happens with out_cap sized as callers use it below). */
static size_t build_rewritten_response(const uint8_t *orig, size_t qend,
                                        uint8_t *out, size_t out_cap,
                                        int with_answer, uint32_t fake_addr_host) {
    if (qend > out_cap) return 0;
    memcpy(out, orig, qend);
    out[6] = 0; out[7] = with_answer ? 1 : 0;               /* ancount */
    out[8] = 0; out[9] = 0; out[10] = 0; out[11] = 0;       /* nscount, arcount */

    size_t pos = qend;
    if (with_answer) {
        if (pos + 16 > out_cap) return 0;
        out[pos++] = 0xC0; out[pos++] = 0x0C; /* name: pointer to question @ offset 12 */
        out[pos++] = 0x00; out[pos++] = 0x01; /* type A */
        out[pos++] = 0x00; out[pos++] = 0x01; /* class IN */
        out[pos++] = 0x00; out[pos++] = 0x00;
        out[pos++] = 0x00; out[pos++] = FAKEIP_ANSWER_TTL;  /* ttl (fits in one byte) */
        out[pos++] = 0x00; out[pos++] = 0x04;               /* rdlength */
        uint32_t addr_net = htonl(fake_addr_host);
        memcpy(out + pos, &addr_net, 4);
        pos += 4;
    }
    return pos;
}

static void handle_upstream_response(struct pending *p) {
    uint8_t buf[MAX_PKT];
    ssize_t n = recv(p->fd, buf, sizeof(buf), 0);

    epoll_ctl(g_epfd, EPOLL_CTL_DEL, p->fd, NULL);
    close(p->fd);
    p->in_use = 0;

    if (n <= 0) return;

    char qname[MAX_HOSTNAME];
    uint16_t qtype = 0;
    size_t qend = 0;
    struct answer_ip ips[32];
    int nips = parse_response(buf, (size_t)n, qname, sizeof(qname), &qtype, &qend, ips, 32);

    /* Unparseable (malformed, or the rare qdcount != 1) or no rule match:
     * relay the real answer unchanged, exactly as before this feature. */
    int is_vpn = 0, is_direct = 0;
    if (nips >= 0) {
        is_vpn = ruleset_match(&g_vpn_rules, qname);
        is_direct = ruleset_match(&g_direct_rules, qname);
    }
    if (nips < 0 || (!is_vpn && !is_direct)) {
        sendto(g_listen_fd, buf, (size_t)n, 0, (struct sockaddr *)&p->client, p->client_len);
        return;
    }

    /* Matched a rule. AAAA is suppressed outright (NODATA) rather than
     * relayed: splify has no IPv6 routing at all (VPN_SET/DIRECT_SET are
     * IPv4-only, same as the rest of the project), so letting a real AAAA
     * answer through would hand a dual-stack client a real, completely
     * unmanaged address that bypasses the split entirely — and Happy-
     * Eyeballs-style clients commonly PREFER IPv6 when it's offered. */
    if (qtype == DNS_TYPE_AAAA) {
        uint8_t out[512];
        size_t len = build_rewritten_response(buf, qend, out, sizeof(out), 0, 0);
        sendto(g_listen_fd, len ? out : buf, len ? len : (size_t)n, 0,
               (struct sockaddr *)&p->client, p->client_len);
        return;
    }

    if (qtype == DNS_TYPE_A && nips > 0) {
        uint32_t fake_addr;
        if (fakeip_lookup_or_alloc(qname, &fake_addr) == 0) {
            struct in_addr fa; fa.s_addr = htonl(fake_addr);
            struct in_addr ra; ra.s_addr = ips[0].addr;
            char fake_str[INET_ADDRSTRLEN], real_str[INET_ADDRSTRLEN];
            if (inet_ntop(AF_INET, &fa, fake_str, sizeof(fake_str)) &&
                inet_ntop(AF_INET, &ra, real_str, sizeof(real_str)) &&
                is_valid_ipv4_str(real_str)) {
                nft_add_map_element(g_fakeip_map, fake_str, real_str);
                if (is_vpn)    nft_add_element(g_vpn_set,    fake_str, ips[0].ttl);
                if (is_direct) nft_add_element(g_direct_set, fake_str, ips[0].ttl);

                uint8_t out[512];
                size_t len = build_rewritten_response(buf, qend, out, sizeof(out), 1, fake_addr);
                if (len > 0) {
                    sendto(g_listen_fd, out, len, 0, (struct sockaddr *)&p->client, p->client_len);
                    return;
                }
            }
        }
    }

    /* Fallback: matched but nothing to substitute (qtype other than A/AAAA
     * — e.g. HTTPS/SVCB — zero real A answers yet, or the fake-IP pool is
     * exhausted). Relay the real answer unchanged — fail open, never block
     * the DNS transaction. */
    sendto(g_listen_fd, buf, (size_t)n, 0, (struct sockaddr *)&p->client, p->client_len);
}

static int run_proxy(int listen_port, int upstream_port) {
    g_listen_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (g_listen_fd < 0) { perror("socket"); return 1; }
    int reuse = 1;
    setsockopt(g_listen_fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)listen_port);
    /* MUST bind the wildcard address, not loopback: nft's `redirect` DNATs
     * the destination to the box's own address on the inbound (LAN)
     * interface, not to 127.0.0.1 — only LAN-sourced traffic ever reaches
     * this port because splify-apply scopes the redirect rule to LAN_CIDR. */
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(g_listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("bind");
        return 1;
    }

    g_epfd = epoll_create1(0);
    if (g_epfd < 0) { perror("epoll_create1"); return 1; }
    struct epoll_event ev = {0};
    ev.events = EPOLLIN;
    ev.data.ptr = NULL; /* NULL marks the listen socket */
    epoll_ctl(g_epfd, EPOLL_CTL_ADD, g_listen_fd, &ev);

    signal(SIGHUP, on_sighup);
    signal(SIGTERM, on_sigterm);
    signal(SIGINT, on_sigterm);
    signal(SIGPIPE, SIG_IGN);
    /* Auto-reap nft_run()'s children (kernel does it, per POSIX, when
     * SIGCHLD is SIG_IGN) — no zombies, no blocking wait anywhere. */
    signal(SIGCHLD, SIG_IGN);

    reload_rules();
    if (g_fakeip_state_path) fakeip_state_load(g_fakeip_state_path);
    fprintf(stderr, "splify-dnsd: listening on :%d -> upstream 127.0.0.1:%d (fakeip: %zu loaded)\n",
            listen_port, upstream_port, g_fakeip.n);

    struct epoll_event events[32];
    while (g_running) {
        if (g_reload_pending) { g_reload_pending = 0; reload_rules(); }
        int n = epoll_wait(g_epfd, events, 32, 1000);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        for (int i = 0; i < n; i++) {
            if (events[i].data.ptr == NULL)
                handle_client_query(upstream_port);
            else
                handle_upstream_response((struct pending *)events[i].data.ptr);
        }
        nft_pump(); /* start the next queued nft mutation, if the previous one has exited */
    }

    close(g_listen_fd);
    close(g_epfd);
    ruleset_free(&g_vpn_rules);
    ruleset_free(&g_direct_rules);
    return 0;
}

/* ---------------------------------------------------------------------- */
/* CLI                                                                    */
/* ---------------------------------------------------------------------- */

static int cmd_match(const char *path, const char *host) {
    struct ruleset rs = {0};
    if (load_rules(path, &rs) != 0) {
        fprintf(stderr, "cannot read rules file: %s\n", path);
        return 2;
    }
    int m = ruleset_match(&rs, host);
    ruleset_free(&rs);
    printf("%s\n", m ? "match" : "nomatch");
    return m ? 0 : 1;
}

static int cmd_selftest(void) {
    int fails = 0;
    struct ruleset rs = {0};

    ruleset_add(&rs, "example.com");             /* namespace */
    ruleset_add(&rs, "=exact-only.com");          /* exact */
    ruleset_add(&rs, "*.wild.example.net");       /* wildcard */
    ruleset_add(&rs, "re:^.*\\.regex\\.example$"); /* regex */

#define CHECK(host, want) do { \
    int got = ruleset_match(&rs, host); \
    if (got != (want)) { \
        fprintf(stderr, "FAIL: %s expected=%d got=%d\n", host, (want), got); \
        fails++; \
    } else { \
        fprintf(stderr, "ok: %s -> %d\n", host, got); \
    } \
} while (0)

    CHECK("example.com", 1);
    CHECK("sub.example.com", 1);
    CHECK("notexample.com", 0);
    CHECK("exact-only.com", 1);
    CHECK("sub.exact-only.com", 0);
    CHECK("foo.wild.example.net", 1);
    CHECK("wild.example.net", 0); /* wildcard pattern requires the "*." prefix segment */
    CHECK("a.regex.example", 1);
    CHECK("a.b.regex.example", 1);
    CHECK("regex.example", 0);

#undef CHECK

    ruleset_free(&rs);
    fprintf(stderr, fails ? "SELFTEST: %d failure(s)\n" : "SELFTEST: all passed\n", fails);
    return fails ? 1 : 0;
}

/* --fakeip STATE_PATH DOMAIN: loads (or creates) the state file, allocates or
 * looks up DOMAIN's fake IP exactly as the running daemon would, persists it,
 * and prints it. A second invocation against the same path/domain must print
 * the SAME address (persistence); a different domain must print a different
 * one (collision-freedom) — that's what the bats coverage exercises. */
static int cmd_fakeip(const char *state_path, const char *domain) {
    g_fakeip_state_path = state_path;
    fakeip_state_load(state_path);
    uint32_t addr;
    if (fakeip_lookup_or_alloc(domain, &addr) != 0) {
        fprintf(stderr, "fake-ip pool exhausted\n");
        return 1;
    }
    struct in_addr a; a.s_addr = htonl(addr);
    char ipstr[INET_ADDRSTRLEN];
    if (!inet_ntop(AF_INET, &a, ipstr, sizeof(ipstr))) return 1;
    printf("%s\n", ipstr);
    return 0;
}

static void usage(const char *argv0) {
    fprintf(stderr,
        "usage: %s --listen-port P --upstream-port P --vpn-set NAME\n"
        "          --direct-set NAME --vpn-rules PATH --direct-rules PATH\n"
        "          --fakeip-state PATH [--fakeip-map NAME]\n"
        "          [--table \"inet fw4\"] [--nft /usr/sbin/nft]\n"
        "       %s --selftest\n"
        "       %s --match RULES_PATH HOSTNAME\n"
        "       %s --fakeip STATE_PATH DOMAIN\n",
        argv0, argv0, argv0, argv0);
}

int main(int argc, char **argv) {
    int listen_port = 5300;
    int upstream_port = 53;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--selftest") == 0) {
            return cmd_selftest();
        } else if (strcmp(argv[i], "--match") == 0 && i + 2 < argc) {
            return cmd_match(argv[i + 1], argv[i + 2]);
        } else if (strcmp(argv[i], "--fakeip") == 0 && i + 2 < argc) {
            return cmd_fakeip(argv[i + 1], argv[i + 2]);
        } else if (strcmp(argv[i], "--listen-port") == 0 && i + 1 < argc) {
            listen_port = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--upstream-port") == 0 && i + 1 < argc) {
            upstream_port = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--vpn-set") == 0 && i + 1 < argc) {
            g_vpn_set = argv[++i];
        } else if (strcmp(argv[i], "--direct-set") == 0 && i + 1 < argc) {
            g_direct_set = argv[++i];
        } else if (strcmp(argv[i], "--vpn-rules") == 0 && i + 1 < argc) {
            g_vpn_rules_path = argv[++i];
        } else if (strcmp(argv[i], "--direct-rules") == 0 && i + 1 < argc) {
            g_direct_rules_path = argv[++i];
        } else if (strcmp(argv[i], "--fakeip-state") == 0 && i + 1 < argc) {
            g_fakeip_state_path = argv[++i];
        } else if (strcmp(argv[i], "--fakeip-map") == 0 && i + 1 < argc) {
            g_fakeip_map = argv[++i];
        } else if (strcmp(argv[i], "--table") == 0 && i + 1 < argc) {
            g_nft_table = argv[++i];
        } else if (strcmp(argv[i], "--nft") == 0 && i + 1 < argc) {
            g_nft_path = argv[++i];
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    if (!g_vpn_rules_path || !g_direct_rules_path || !g_fakeip_state_path) {
        usage(argv[0]);
        return 2;
    }

    return run_proxy(listen_port, upstream_port);
}

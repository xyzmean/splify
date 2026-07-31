/*
 * splify-dnsd — transparent DNS forwarding proxy that tags resolved IPv4
 * addresses into splify's existing nftables sets (splify_vpn_v4 /
 * splify_direct_v4) at resolve time, based on richer domain-rule matching
 * (exact / namespace / wildcard / regex) than dnsmasq's `nftset=` directive
 * supports.
 *
 * It NEVER resolves anything itself: every client query is forwarded
 * byte-for-byte to the real resolver (dnsmasq, 127.0.0.1:53) and its answer
 * is relayed back byte-for-byte, unmodified. Only the question name and the
 * A-record answers are inspected, read-only, to decide whether to add an
 * element to an nft set. A parsing failure or rule miss NEVER blocks or
 * alters the DNS transaction — fail open, always.
 *
 * Usage:
 *   splify-dnsd --listen-port P --upstream-port P --vpn-set NAME
 *               --direct-set NAME --vpn-rules PATH --direct-rules PATH
 *               [--table inet fw4] [--nft /usr/sbin/nft]
 *   splify-dnsd --selftest
 *   splify-dnsd --match PATH HOSTNAME
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

struct answer_ip {
    uint32_t addr; /* network byte order */
    uint32_t ttl;
};

/* Parses a DNS response: extracts the question name (out_qname) and every
 * A-record (class IN) answer IP+TTL, up to max_ips entries. Returns the
 * number of A-record IPs found, or -1 on a malformed/short packet (caller
 * must still relay the raw bytes to the client regardless). */
static int parse_response(const uint8_t *pkt, size_t len, char *out_qname,
                           size_t qname_len, struct answer_ip *ips,
                           int max_ips) {
    if (len < 12) return -1;
    uint16_t qdcount = (pkt[4] << 8) | pkt[5];
    uint16_t ancount = (pkt[6] << 8) | pkt[7];

    size_t pos = 12;
    if (qdcount < 1) return -1;

    size_t next = 0;
    if (parse_name_adv(pkt, len, pos, out_qname, qname_len, &next) != 0)
        return -1;
    pos = next;
    if (pos + 4 > len) return -1;
    pos += 4; /* qtype + qclass */

    /* remaining questions (rare, but be correct) */
    for (uint16_t q = 1; q < qdcount; q++) {
        char tmp[MAX_HOSTNAME];
        if (parse_name_adv(pkt, len, pos, tmp, sizeof(tmp), &next) != 0)
            return -1;
        pos = next;
        if (pos + 4 > len) return -1;
        pos += 4;
    }

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
        if (rtype == 1 /* A */ && rclass == 1 /* IN */ && rdlen == 4 &&
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

/* argv-based exec — never a shell, so the ip/ttl/set strings (all of which we
 * validate the shape of before calling this) cannot inject anything even if
 * they somehow didn't validate cleanly. */
static void nft_add_element(const char *set_name, const char *ip_str, uint32_t ttl) {
    if (ttl < 1) ttl = 1;
    if (ttl > 86400) ttl = 86400; /* clamp: never let a hostile/huge TTL pin an entry forever */

    char table_copy[64];
    snprintf(table_copy, sizeof(table_copy), "%s", g_nft_table);
    char *fam = table_copy;
    char *tbl = strchr(table_copy, ' ');
    if (tbl) { *tbl = '\0'; tbl++; } else { tbl = (char *)"fw4"; }

    char spec[160];
    snprintf(spec, sizeof(spec), "%s timeout %us", ip_str, ttl);

    pid_t pid = fork();
    if (pid < 0) return;
    if (pid == 0) {
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) { dup2(devnull, 1); dup2(devnull, 2); close(devnull); }
        char *argv[] = {(char *)g_nft_path, (char *)"add", (char *)"element",
                         fam, tbl, (char *)set_name, (char *)"{", spec, (char *)"}", NULL};
        execv(g_nft_path, argv);
        _exit(127);
    }
    int status;
    waitpid(pid, &status, 0);
}

static int is_valid_ipv4_str(const char *s) {
    struct in_addr a;
    return inet_aton(s, &a) != 0;
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

static void handle_upstream_response(struct pending *p) {
    uint8_t buf[MAX_PKT];
    ssize_t n = recv(p->fd, buf, sizeof(buf), 0);

    epoll_ctl(g_epfd, EPOLL_CTL_DEL, p->fd, NULL);
    close(p->fd);
    p->in_use = 0;

    if (n <= 0) return;

    /* Relay to the client FIRST and unconditionally — inspection below must
     * never delay or gate delivery of the real answer. */
    sendto(g_listen_fd, buf, (size_t)n, 0, (struct sockaddr *)&p->client, p->client_len);

    char qname[MAX_HOSTNAME];
    struct answer_ip ips[32];
    int nips = parse_response(buf, (size_t)n, qname, sizeof(qname), ips, 32);
    if (nips <= 0) return;

    int is_vpn = ruleset_match(&g_vpn_rules, qname);
    int is_direct = ruleset_match(&g_direct_rules, qname);
    if (!is_vpn && !is_direct) return;

    for (int i = 0; i < nips; i++) {
        struct in_addr a;
        a.s_addr = ips[i].addr;
        char ipstr[INET_ADDRSTRLEN];
        if (!inet_ntop(AF_INET, &a, ipstr, sizeof(ipstr))) continue;
        if (!is_valid_ipv4_str(ipstr)) continue; /* defense in depth */
        if (is_vpn) nft_add_element(g_vpn_set, ipstr, ips[i].ttl);
        if (is_direct) nft_add_element(g_direct_set, ipstr, ips[i].ttl);
    }
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

    reload_rules();
    fprintf(stderr, "splify-dnsd: listening on :%d -> upstream 127.0.0.1:%d\n",
            listen_port, upstream_port);

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

static void usage(const char *argv0) {
    fprintf(stderr,
        "usage: %s --listen-port P --upstream-port P --vpn-set NAME\n"
        "          --direct-set NAME --vpn-rules PATH --direct-rules PATH\n"
        "          [--table \"inet fw4\"] [--nft /usr/sbin/nft]\n"
        "       %s --selftest\n"
        "       %s --match RULES_PATH HOSTNAME\n",
        argv0, argv0, argv0);
}

int main(int argc, char **argv) {
    int listen_port = 5300;
    int upstream_port = 53;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--selftest") == 0) {
            return cmd_selftest();
        } else if (strcmp(argv[i], "--match") == 0 && i + 2 < argc) {
            return cmd_match(argv[i + 1], argv[i + 2]);
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
        } else if (strcmp(argv[i], "--table") == 0 && i + 1 < argc) {
            g_nft_table = argv[++i];
        } else if (strcmp(argv[i], "--nft") == 0 && i + 1 < argc) {
            g_nft_path = argv[++i];
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    if (!g_vpn_rules_path || !g_direct_rules_path) {
        usage(argv[0]);
        return 2;
    }

    return run_proxy(listen_port, upstream_port);
}

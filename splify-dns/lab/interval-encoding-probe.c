/* Which wire form does nf_tables accept for a single address in a set declared
 * `flags interval,timeout; auto-merge`? Tries the plausible encodings against a
 * real set and prints the kernel's verdict for each. Lab-only probe. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <linux/netlink.h>
#include <linux/netfilter.h>
#include <linux/netfilter/nfnetlink.h>
#include <linux/netfilter/nf_tables.h>

#define CAP 4096
static int fd;
static uint32_t seq = 1000;

struct b { uint8_t *p; };
static struct nlattr *hdr(struct b *b, uint16_t t, size_t l) {
    struct nlattr *a = (struct nlattr *)b->p;
    a->nla_type = t; a->nla_len = (uint16_t)(NLA_HDRLEN + l);
    b->p += NLMSG_ALIGN(a->nla_len);
    return a;
}
static void pstr(struct b *b, uint16_t t, const char *s) {
    size_t n = strlen(s) + 1; struct nlattr *a = hdr(b, t, n);
    memcpy((char *)a + NLA_HDRLEN, s, n);
}
static void pdata(struct b *b, uint16_t t, const void *d, size_t n) {
    struct nlattr *a = hdr(b, t, n); memcpy((char *)a + NLA_HDRLEN, d, n);
}
static void pbe32(struct b *b, uint16_t t, uint32_t v) { uint32_t x = htonl(v); pdata(b, t, &x, 4); }
static void pbe64(struct b *b, uint16_t t, uint64_t v) {
    uint8_t be[8]; for (int i = 0; i < 8; i++) be[i] = (uint8_t)(v >> (56 - 8 * i));
    pdata(b, t, be, 8);
}
static struct nlattr *nb(struct b *b, uint16_t t) {
    struct nlattr *a = (struct nlattr *)b->p; a->nla_type = t | NLA_F_NESTED;
    b->p += NLA_HDRLEN; return a;
}
static void ne(struct b *b, struct nlattr *a) { a->nla_len = (uint16_t)((uint8_t *)b->p - (uint8_t *)a); }

/* variant: 0 = start only, 1 = start+end marker (timeout on both),
 * 2 = start+end marker (timeout on start only), 3 = start+end, no timeout,
 * 4 = single element with KEY_END */
static int try_variant(const char *table, const char *set, uint32_t addr_host,
                       int variant, uint64_t timeout_ms) {
    uint8_t msg[CAP], bb[64], be_[64];
    struct b b = { msg };
    struct nlmsghdr *nh = (struct nlmsghdr *)b.p; memset(nh, 0, sizeof(*nh));
    b.p += NLMSG_ALIGN(sizeof(*nh));
    struct nfgenmsg *ng = (struct nfgenmsg *)b.p;
    ng->nfgen_family = NFPROTO_INET; ng->version = NFNETLINK_V0; ng->res_id = 0;
    b.p += NLMSG_ALIGN(sizeof(*ng));

    pstr(&b, NFTA_SET_ELEM_LIST_TABLE, table);
    pstr(&b, NFTA_SET_ELEM_LIST_SET, set);
    struct nlattr *els = nb(&b, NFTA_SET_ELEM_LIST_ELEMENTS);

    uint32_t k = htonl(addr_host), kend = htonl(addr_host + 1);
    struct nlattr *e1 = nb(&b, NFTA_LIST_ELEM);
    struct nlattr *k1 = nb(&b, NFTA_SET_ELEM_KEY); pdata(&b, NFTA_DATA_VALUE, &k, 4); ne(&b, k1);
    if (variant == 4) { struct nlattr *ke = nb(&b, NFTA_SET_ELEM_KEY_END);
                        pdata(&b, NFTA_DATA_VALUE, &k, 4); ne(&b, ke); }
    if (timeout_ms && variant != 3) pbe64(&b, NFTA_SET_ELEM_TIMEOUT, timeout_ms);
    ne(&b, e1);

    if (variant >= 1 && variant <= 3) {
        struct nlattr *e2 = nb(&b, NFTA_LIST_ELEM);
        struct nlattr *k2 = nb(&b, NFTA_SET_ELEM_KEY); pdata(&b, NFTA_DATA_VALUE, &kend, 4); ne(&b, k2);
        pbe32(&b, NFTA_SET_ELEM_FLAGS, NFT_SET_ELEM_INTERVAL_END);
        if (timeout_ms && variant == 1) pbe64(&b, NFTA_SET_ELEM_TIMEOUT, timeout_ms);
        ne(&b, e2);
    }
    ne(&b, els);

    nh->nlmsg_len = (uint32_t)(b.p - msg);
    nh->nlmsg_type = (NFNL_SUBSYS_NFTABLES << 8) | NFT_MSG_NEWSETELEM;
    nh->nlmsg_flags = NLM_F_REQUEST | NLM_F_CREATE | NLM_F_ACK;
    uint32_t s = (seq += 3);
    nh->nlmsg_seq = s;

    struct nlmsghdr *h1 = (struct nlmsghdr *)bb, *h2 = (struct nlmsghdr *)be_;
    size_t blen = NLMSG_ALIGN(sizeof(*h1)) + NLMSG_ALIGN(sizeof(struct nfgenmsg));
    memset(bb, 0, blen); memset(be_, 0, blen);
    h1->nlmsg_len = h2->nlmsg_len = (uint32_t)blen;
    h1->nlmsg_type = NFNL_MSG_BATCH_BEGIN; h2->nlmsg_type = NFNL_MSG_BATCH_END;
    h1->nlmsg_flags = h2->nlmsg_flags = NLM_F_REQUEST;
    h1->nlmsg_seq = s - 1; h2->nlmsg_seq = s + 1;
    ((struct nfgenmsg *)(bb + NLMSG_ALIGN(sizeof(*h1))))->res_id = htons(NFNL_SUBSYS_NFTABLES);
    ((struct nfgenmsg *)(be_ + NLMSG_ALIGN(sizeof(*h2))))->res_id = htons(NFNL_SUBSYS_NFTABLES);

    struct sockaddr_nl dst = { .nl_family = AF_NETLINK };
    struct iovec iov[3] = { { bb, blen }, { msg, nh->nlmsg_len }, { be_, blen } };
    struct msghdr m = { .msg_name = &dst, .msg_namelen = sizeof(dst), .msg_iov = iov, .msg_iovlen = 3 };
    if (sendmsg(fd, &m, 0) < 0) { printf("sendmsg errno=%d\n", errno); return -1; }

    uint8_t rb[512];
    for (;;) {
        ssize_t r = recv(fd, rb, sizeof(rb), 0);
        if (r < (ssize_t)NLMSG_HDRLEN) return -ETIMEDOUT;
        struct nlmsghdr *rh = (struct nlmsghdr *)rb;
        if (rh->nlmsg_type == NLMSG_ERROR) {
            struct nlmsgerr *e = NLMSG_DATA(rh);
            if (rh->nlmsg_seq != s) continue;
            return e->error;
        }
    }
}

int main(int argc, char **argv) {
    const char *table = argc > 1 ? argv[1] : "fw4";
    const char *set   = argc > 2 ? argv[2] : "splify_vpn_v4";
    fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_NETFILTER);
    struct sockaddr_nl sa = { .nl_family = AF_NETLINK };
    bind(fd, (struct sockaddr *)&sa, sizeof(sa));
    struct timeval tv = { .tv_sec = 1 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    const char *names[] = { "start only (no end marker)",
                            "start + end marker, timeout on both",
                            "start + end marker, timeout on start only",
                            "start + end marker, no timeout",
                            "single element with KEY_END" };
    uint32_t base;
    inet_pton(AF_INET, "198.18.9.0", &base);
    base = ntohl(base);
    /* One variant per run: the caller flushes the set in between, because an
     * open-ended interval left by an earlier variant makes every later insert
     * report EEXIST. */
    int v = argc > 3 ? atoi(argv[3]) : 0;
    int rc = try_variant(table, set, base, v, 69000);
    printf("  v%d %-42s -> %s\n", v, names[v], rc == 0 ? "OK" : strerror(-rc));
    close(fd);
    return 0;
}

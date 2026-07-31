# Shared bats helper for splify unit tests.
#
# The runtime scripts are battle-tested OpenWrt shell that source
# /lib/functions.sh and call uci/nft/ip — none of which exist in CI. Rather than
# refactor working code for testability, we EXTRACT the pure, self-contained
# functions verbatim from the source files and eval them into the test shell.
# extract_fn copies a function by name from its `name()` line until the brace
# count returns to zero, so the extracted text is byte-identical to what ships.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON_SH="$REPO_ROOT/splify/files/usr/local/lib/splify/common.sh"
DOCTOR_SH="$REPO_ROOT/splify/files/usr/local/sbin/splify-doctor"
FAILOVER_SH="$REPO_ROOT/splify/files/usr/local/sbin/splify-failover"

# extract_fn FILE FNNAME -> prints the function's source.
#
# Ends at the first line that is just a closing brace in column 0 — the style
# every function in these scripts is written in.
#
# It used to count braces instead, which silently mis-extracted any function
# embedding an awk program: awk bodies carry braces of their own, and string
# literals carry UNBALANCED ones (`printf "… { %s"`, `print " }"`). The count
# then returned to zero early, eval got a truncated function and failed with
# "unexpected EOF while looking for matching quote" — which is why
# emit_nft_set_chunks appeared untestable. Tracking quote state instead is worse:
# an apostrophe in a comment ("the peer's key") flips it and breaks a different
# set of functions. Column-0 `}` has neither failure mode; nested closes in this
# codebase are always indented.
extract_fn() {
    awk -v fn="$2" '
        # A one-liner (json_esc, nft_capped, …) opens and closes on its own line.
        !cap && $0 ~ "^"fn"\\(\\)" {
            cap = 1; print
            if ($0 ~ /\{.*\}/) exit
            next
        }
        cap { print; if (/^}[ \t]*$/) exit }
    ' "$1"
}

# load_fn FILE FNNAME -> defines the function in the current shell.
load_fn() { eval "$(extract_fn "$1" "$2")"; }

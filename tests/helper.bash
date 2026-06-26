# Shared bats helper for wg-split unit tests.
#
# The runtime scripts are battle-tested OpenWrt shell that source
# /lib/functions.sh and call uci/nft/ip — none of which exist in CI. Rather than
# refactor working code for testability, we EXTRACT the pure, self-contained
# functions verbatim from the source files and eval them into the test shell.
# extract_fn copies a function by name from its `name()` line until the brace
# count returns to zero, so the extracted text is byte-identical to what ships.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON_SH="$REPO_ROOT/wg-split/files/usr/local/lib/wg-split/common.sh"
DOCTOR_SH="$REPO_ROOT/wg-split/files/usr/local/sbin/wg-split-doctor"

# extract_fn FILE FNNAME -> prints the function's source.
extract_fn() {
    awk -v fn="$2" '
        !cap && $0 ~ "^"fn"\\(\\)" { cap=1 }
        cap {
            print
            o = gsub(/{/, "{"); c = gsub(/}/, "}")
            opens += o; n += o - c
            if (opens>0 && n==0) exit
        }
    ' "$1"
}

# load_fn FILE FNNAME -> defines the function in the current shell.
load_fn() { eval "$(extract_fn "$1" "$2")"; }

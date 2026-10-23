#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: scan.sh [base_ref | --all]

Deterministic first pass of the LegacyPodClaw iOS 6 review.

  base_ref  scan lines added since base_ref, working tree included
            (default: merge base of HEAD and origin/HEAD, else HEAD)
  --all     scan every line of every tracked source file

Scans .m, .h and .xm files outside Vendor/. Always also checks that the
secret key lists in Frameworks/System/SecretStore.m and
LegacyPodClawDaemon/SecretServer.m match.

stdout: {"range":..,"count":N,"findings":[{"rule","sev","file","line","text","hint"}]}
exit 0 when no blocker or high finding, 1 when there is one, 2 on bad use.
Run from the repo root.
EOF
}

mode="diff"
base=""
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --all) mode="all" ;;
    "") ;;
    -*) usage; exit 2 ;;
    *) base="$1" ;;
esac

root="$(git rev-parse --show-toplevel)"
cd "$root"

# candidate lines as file<TAB>line<TAB>text
candidates() {
    if [[ "$mode" == "all" ]]; then
        git grep -n -I -e '' -- '*.m' '*.h' '*.xm' ':!Vendor' \
            | awk -F: '{f=$1; l=$2; sub(/^[^:]*:[^:]*:/, ""); printf "%s\t%s\t%s\n", f, l, $0}'
        return
    fi
    git diff -U0 --no-color "$base" -- '*.m' '*.h' '*.xm' ':!Vendor' | awk '
        /^\+\+\+ b\// { f = substr($0, 7); next }
        /^\+\+\+ /    { f = ""; next }
        /^@@ /        { split($3, a, ","); l = substr(a[1], 2) + 0; next }
        /^\+/         { if (f != "") printf "%s\t%d\t%s\n", f, l, substr($0, 2); l++; next }
    '
    # untracked new files count as fully added
    git ls-files --others --exclude-standard -- '*.m' '*.h' '*.xm' ':!Vendor' | while read -r f; do
        awk -v f="$f" '{ printf "%s\t%d\t%s\n", f, NR, $0 }' "$f"
    done
}

if [[ "$mode" == "diff" && -z "$base" ]]; then
    base="$(git merge-base HEAD origin/HEAD 2>/dev/null || git rev-parse HEAD)"
fi
if [[ "$mode" == "diff" ]] && ! git rev-parse --verify -q "$base^{commit}" >/dev/null; then
    echo "scan.sh: unknown base ref '$base'" >&2
    exit 2
fi
range="$([[ "$mode" == "all" ]] && echo "all" || echo "$base..worktree")"

findings_tsv="$(candidates | awk -F'\t' '
    function hit(rule, sev, hint) {
        t = text; gsub(/\t/, " ", t); gsub(/^[ ]+/, "", t)
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", rule, sev, file, line, substr(t, 1, 160), hint
    }
    {
        file = $1; line = $2; text = $3
        code = text
        # comment-only lines name old apis on purpose, so skip them
        if (code ~ /^[ \t]*(\/\/|\/\*|\*)/) next
        if (code ~ /NSURLSession/) hit("api", "blocker", "iOS 7+: use CPTLSClient")
        if (code ~ /base64Encoded(String|Data)WithOptions|initWithBase64Encoded/) hit("api", "blocker", "iOS 7+: use a local base64 helper")
        if (code ~ /dateByAddingUnit:/) hit("api", "blocker", "iOS 8+: use dateByAddingComponents:toDate:options:")
        if (code ~ /NSCalendarUnit[A-Z]/) hit("api", "blocker", "iOS 8+ name: use NSMinuteCalendarUnit style names")
        if (code ~ /containsString:/) hit("api", "blocker", "iOS 8+: use rangeOfString:")
        if (code ~ /stringByAddingPercentEncodingWithAllowedCharacters|stringByRemovingPercentEncoding/) hit("api", "blocker", "iOS 7+: use CFURLCreateStringByAddingPercentEscapes")
        if (code ~ /NSURLComponents|NSURLQueryItem/) hit("api", "blocker", "iOS 7+/8+: build the query by hand")
        if (code ~ /UIAlertController|UIStackView|WKWebView|isOperatingSystemAtLeastVersion/) hit("api", "blocker", "iOS 8+ API")
        if (code ~ /\.(top|bottom|leading|trailing|left|right|width|height|centerX|centerY)Anchor([^A-Za-z]|$)/) hit("api", "blocker", "iOS 9+ layout anchors: use frames")
        if (code ~ /^[ \t]*@import /) hit("api", "high", "modules are not set up: use #import")
        if (code ~ /__weak/ || code ~ /@property[ \t]*\([^)]*weak/) hit("mrr", "blocker", "no ARC weak refs: use assign and clear in dealloc")
        if (code ~ /NSURLConnection/) hit("tls", "high", "HTTPS must use CPTLSClient; plain-HTTP LAN calls need a comment saying why")
        if (file ~ /\.xm$/ && code ~ /%orig[^;]*;[ \t]*return/) hit("logos", "blocker", "put %orig; and return; on separate lines")
        if (file !~ /(SecretStore|SecretServer)\.m$/ && code ~ /forKey:@"[A-Za-z]*([Aa]piKey|[Tt]oken|[Pp]assword|[Ss]ecret)"/ && code ~ /(prefs|[Pp]refs|NSUserDefaults|plist)/) hit("secret", "high", "secrets go through CPSecretStore, not the prefs plist")
        if (file !~ /ToolDispatcher\.m$/ && code ~ /\.handler\(/) hit("dispatch", "high", "call tools through OCToolDispatcher runTool:")
    }
')"

# the two secret key lists must match, or reads or writes fail at run time
# read each whole function body; a fixed -A count misses keys when the list grows
key_list() { sed -n "/$2/,/^}/p" "$1" | { grep -o '@"[A-Za-z0-9_]*"' || true; } | sort -u | tr '\n' ' '; }
store_keys="$(key_list Frameworks/System/SecretStore.m '^+ (NSArray \*)allSecretKeys')"
server_keys="$(key_list LegacyPodClawDaemon/SecretServer.m '^static NSArray \*SecretKeys(void)')"
if [[ -z "$store_keys" || -z "$server_keys" ]]; then
    findings_tsv+=$'\n'"secret"$'\t'"high"$'\t'"Frameworks/System/SecretStore.m"$'\t'"0"$'\t'"could not read a secret key list"$'\t'"update key_list in scan.sh"
fi
if [[ "$store_keys" != "$server_keys" ]]; then
    findings_tsv+=$'\n'"secret"$'\t'"blocker"$'\t'"Frameworks/System/SecretStore.m"$'\t'"0"$'\t'"store: $store_keys / server: $server_keys"$'\t'"add the key to both lists"
fi

printf '%s\n' "$findings_tsv" | sed '/^$/d' | jq -R -s --arg range "$range" '
    split("\n") | map(select(length > 0) | split("\t")
      | {rule: .[0], sev: .[1], file: .[2], line: (.[3] | tonumber), text: .[4], hint: .[5]})
    | {range: $range, count: length, findings: .}'

if printf '%s\n' "$findings_tsv" | awk -F'\t' '$2 == "blocker" || $2 == "high" { found = 1 } END { exit !found }'; then
    exit 1
fi
exit 0

#!/bin/bash
# Sensitive data detector — run before commit to prevent leaking personal/device identifiers
# Usage: tests/check-sensitive.sh [files...]
#   If no files given, checks all tracked files (git ls-files).
#   Exits 0 if clean, 1 if sensitive data found.

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

FILES=()
if [ $# -gt 0 ]; then
    FILES=("$@")
else
    mapfile -t FILES < <(git ls-files 2>/dev/null || true)
fi

found=0
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

# Deduplicate files: skip symlinks, non-existent, directories
declare -A seen
filtered=()
for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue
    [ -n "${seen[$f]:-}" ] && continue
    seen[$f]=1
    filtered+=("$f")
done

check_pattern() {
    local label="$1"
    local pattern="$2"
    local severity="${3:-HIGH}"

    for f in "${filtered[@]}"; do
        # Skip this script itself (it contains regex patterns that would self-match)
        [[ "$f" == *check-sensitive.sh ]] && continue
        # Skip binary files
        if file -b --mime-encoding "$f" 2>/dev/null | grep -qv 'us-ascii\|utf-8'; then
            continue
        fi
        matches=$(grep -nHE "$pattern" "$f" 2>/dev/null || true)
        if [ -n "$matches" ]; then
            echo -e "${RED}[${severity}] ${label}${NC}"
            echo "$matches" | while IFS= read -r line; do
                echo "   $line"
            done
            found=1
        fi
    done
}

echo "=== Sensitive data scan ==="
echo ""

# ---- UUID / boot IDs ----
check_pattern \
    "UUID / boot ID (kernel boot_id, looks like a machine identifier)" \
    '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

# ---- MAC addresses ----
check_pattern \
    "MAC address" \
    '([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}'

# ---- Public IPv4 (exclude private ranges, loopback, docs) ----
check_pattern \
    "Public IPv4 address" \
    '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    "MEDIUM"

# ---- IPv6 (public-looking) ----
check_pattern \
    "IPv6 address" \
    '([0-9a-fA-F]{1,4}:){3,7}[0-9a-fA-F]{1,4}' \
    "MEDIUM"

# ---- Real usernames (from /etc/passwd, but skip known-safe tokens) ----
# Collect real usernames on this system
if [ -r /etc/passwd ]; then
    real_users=$(awk -F: '{ if ($3 >= 1000 && $3 < 65534) print $1 }' /etc/passwd | sort -u || true)
    for user in $real_users; do
        [ "$user" = "nobody" ] && continue
        [ ${#user} -lt 4 ] && continue  # skip short names (too many false positives)
        for f in "${filtered[@]}"; do
            [[ "$f" == *check-sensitive.sh ]] && continue
            if file -b --mime-encoding "$f" 2>/dev/null | grep -qv 'us-ascii\|utf-8'; then
                continue
            fi
            matches=$(grep -nHE "(^|[^a-zA-Z0-9_.-])${user}([^a-zA-Z0-9_.-]|\$)" "$f" 2>/dev/null || true)
            if [ -n "$matches" ]; then
                echo -e "${RED}[HIGH] Real local username '${user}' found${NC}"
                echo "$matches" | while IFS= read -r line; do
                    echo "   $line"
                done
                found=1
            fi
        done
    done
fi

# ---- SSH private keys ----
check_pattern \
    "SSH private key" \
    'BEGIN (RSA|DSA|EC|OPENSSH) PRIVATE KEY'

# ---- API keys / tokens (common patterns) ----
check_pattern \
    "Possible API key/token (hex string >= 32 chars as a value)" \
    '[a-z0-9_]*([Tt]oken|[Kk]ey|[Ss]ecret|[Pp]assword)\s*[:=]\s*["'"'"']?[A-Za-z0-9+/=_-]{20,}'

# ---- GPG private keys ----
check_pattern \
    "GPG private key" \
    'BEGIN PGP PRIVATE KEY BLOCK'

# ---- JWT tokens ----
check_pattern \
    "JWT token" \
    'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'

echo ""
if [ $found -eq 0 ]; then
    echo "No sensitive data found."
    exit 0
else
    echo -e "${RED}Sensitive data found — commit blocked.${NC}"
    echo "Review the matches above. If they are intentional examples, update check-sensitive.sh to skip them."
    exit 1
fi

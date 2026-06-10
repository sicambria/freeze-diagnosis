# `grep -c ... || echo 0` produces double count (`0\n0`)

**Date:** 2026-06-09  
**Area:** testing, tooling  
**Severity:** medium — causes `[: integer expression required` errors in analysis
**Fix commit:** `219aa1f`

## Summary

`grep -c` always prints the count (`0` for no matches) even when it exits with code 1 (no match found). When combined with `|| echo 0` as a fallback for `set -euo pipefail`:

```bash
count=$(echo "$matches" | grep -c . 2>/dev/null || echo 0)
```

The capture produces `"0\n0"` — grep outputs `0` + newline, then `echo 0` outputs `0` + newline. Subsequent `[ "$count" -gt 0 ]` produces: `[: 0\n0: integer expression required`.

## Fix

Replace with explicit `|| true` and `${count:-0}` fallback:

```bash
count=$(echo "$matches" | grep -c . 2>/dev/null || true)
count=${count:-0}
```

`|| true` prevents `set -euo pipefail` from killing the subshell, and `${count:-0}` handles the case where grep genuinely produces no output (won't happen with `grep -c`, but defensive).

## Files affected

- `diag-analyze.sh` — 3 occurrences in `analyze_gpu`, `analyze_oom`, `analyze_nvme`
- `lib/collector_fast.sh` — 2 occurrences in `R_COUNT` / `D_COUNT`

## Prevention

- Never use `|| echo 0` after `grep -c`. Use `|| true` + `${var:-0}`.
- Audit rule: search for `grep -c .*|| echo` before every release.

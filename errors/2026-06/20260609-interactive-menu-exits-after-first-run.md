# Interactive menu exits after first analysis instead of looping

**Date:** 2026-06-09  
**Area:** tooling  
**Severity:** medium — prevents repeated use of interactive analyzer
**Fix commits:** `b4eee47` (while loop), `ff6e1f9` (remove recursive calls, fix option 3)

## Summary

The `diag-analyze.sh` main execution body had a linear flow: call `interactive_menu` → run one analysis → call `interactive_menu` again. When the second `interactive_menu` call returned, the script hit end-of-file and exited instead of looping.

```
interactive_menu()          # user picks option 6
    ↓ (returns)
[run analysis + show report]
    ↓
interactive_menu()          # user picks option 6 again
    ↓ (returns)
[end of file]               # EXITS — no more code!
```

## Root Cause

The analysis loop was implicit — the script relied on a second `interactive_menu` call at the end of the main body to provide "return to menu" behavior. But since the main body has no `while` loop, the second call returns into empty space and the script terminates.

Compounding: `interactive_menu` called itself recursively in options 2 (list sessions) and `*` (invalid choice), growing the call stack.

## Fix

1. Wrapped the interactive path in `while true; do ... done`
2. Removed recursive `interactive_menu()` calls in options 2 and `*` — they now just `return`, and the while loop re-invokes the menu
3. Added state reset (`ANALYZE_BOOT=""`, `ANALYZE_CURRENT=false`, etc.) at the end of each iteration
4. Non-interactive CLI mode (`--quick`, `--current`, etc.) preserved as the `else` branch

## Files affected

- `diag-analyze.sh` — main execution block (lines ~410–449)

## Prevention

- When building interactive menu loops, always use `while true` wrapping, not implicit "call again at end" patterns
- Never use recursive menu calls; rely on the controlling loop for re-display

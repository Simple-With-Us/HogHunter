# HH-222: tmp-build-trees report rule

Agents leave throwaway checkouts in /private/tmp, such as `hh212-candidate-3` and `feature-rebase`.  The `tmp-build-trees` rule in `scripts/hoghunter-clean` lists them.  It is report only, tier `ask-first`, and never deletes, whatever the disk level.

The original request asked for deletes when a tree passed the safety checks.  AGENTS.md (HH-213) says stale-build style rules stay report only until the owner decides otherwise, so AGENTS.md wins.  Giving the rule a delete path needs a new owner decision.

Direct children of /private/tmp are considered when the name matches `*-candidate-*` or `*-rebase[-*]`, the folder is a real directory owned by the user on the same volume, and it is at least 8 MB.  Each row says what the checks found, or that nothing the checks can see keeps it:

- protected path, or a `.janitor-keep` marker inside
- written to in the last hour
- held open (lsof), or a running process names it
- a linked git worktree (its branch may hold unpushed work)
- uncommitted changes, a stash, or commits no remote holds

Like the other report rules it runs on a scan and not on a clean run (`REPORT_ONLY_WALK_RULES`).  It is not in `CleanRegimen.schedulableRules`.  Tests: `scripts/test-hoghunter-clean.py` (`test_tmp_build_trees_*`).

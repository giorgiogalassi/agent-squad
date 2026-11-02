# Atlas change graph: prototype for #410

A standalone prototype of the page #410 proposes. It is the starting point for the real
implementation, not part of the plugin: no skill calls it, and nothing under `claude/` imports it.

```bash
python3 docs/prototypes/atlas-graph/atlas_graph.py <project_dir> <base_ref> <head_ref> \
  <brief.md> <out.html> <commit_url_prefix> <src_url_prefix> [<title>]
```

- `project_dir`: the folder that holds the project's declarations (here `project.json` files and
  `tsconfig.base.json`); it may sit below the repository root.
- `commit_url_prefix` / `src_url_prefix`: the host's commit and source URLs, for example
  `https://github.com/<owner>/<repo>/commit/` and `https://github.com/<owner>/<repo>/blob/`.

Python 3.8+, standard library only, about 3 s on a 49-file change in a monorepo with 100+ units.

## What it does

- **Units** are the folders that hold a `project.json`; **edges** are imports resolved through the
  `tsconfig.base.json` path aliases, or through relative paths.
- **Centre, changed:** units owning a changed file.
- **Left, affected:** units outside the change that import, through a changed unit's alias, an
  export whose declaration a diff hunk touches. New, deleted and cross-unit moved files count
  all their exports. The side panel lists the names each unit uses.
- **Right:** only dependencies the change added or removed, comparing each changed unit's imports
  at base and head.
- **Node panel:** the unit's files in the change (linked to the host at head) and the commits
  that touched it (linked to the host).
- **Below:** the brief, rendered from Markdown. No inline diffs, no commit list.

## What the real implementation must change

- Unit discovery is hard-wired to `project.json` + `tsconfig.base.json`. #410 asks for the
  project's own declarations in general (package or project manifests, workspace folders, path
  aliases), with a folder fallback.
- Files outside any unit (for example a workspace config) are listed but get no node; #410 wants
  a "workspace" node.
- No cache: every run re-reads the changed units at both refs. #410 asks for a vault cache.
- Extraction lives in this script; per #411 it belongs in `claude/hooks/squad-graph.py` behind
  `extract` / `diff`, with Atlas only rendering.

## Lessons from the runs

The full list is in the #410 discussion. The ones that shape the code:

1. Compare edges per unit at base and head, not per edited file: a moved file's existing
   dependencies otherwise show up as "added".
2. "Added" and "removed" are relative to the base: an edge introduced and removed within the
   branch does not appear (that is the timeline in #411).
3. `git grep -E` is POSIX: no `\s`, use `[[:space:]]`.
4. Affected means "uses an export whose declaration changed", matched per declaration with the
   `-U0` hunk ranges; per file it over-reports.
5. `git show <ref>:<path>` takes a repository-root path, but a pathspec after `--` is relative to
   the working directory; keep the two apart when the project sits below the root.

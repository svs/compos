# code-mode, worktrees-mode, and diff-mode

compos isolates agent coding tasks in linked Git worktrees and gives you a dedicated review surface for diffs.

## `code-mode` (`M-x code-mode`)

Starts an agent coding workspace from the current source buffer.

- Asks before creating a new linked Git worktree at `<repo>-worktrees/<NAME>` on branch `agent/<NAME>`.
- Opening a buffer already inside a worktree enters that workspace directly.
- Every buffer inside a linked worktree wears `worktree-mode`, displaying its Git status (`UNCOMMITTED`, `NEEDS REBASE`, `UNMERGED`, or `READY TO TEARDOWN`).

## `worktrees-mode` (`M-x workspace-manage`)

Lists all task worktrees for the current repository with branch, commits ahead, dirty count, and owning agent chat.

| Key | What it does |
| --- | --- |
| `RET` | Open the worktree in Dired |
| `=` | Open a diff against the primary branch (`diff-mode`) |
| `r` | Hand a rebase to the workspace's agent chat |
| `L` | Merge (land) the worktree into the primary checkout |
| `c` | Create a new workspace |
| `a` | Jump to the workspace's chat |
| `d`, then `x` | Flag a clean worktree for cancellation and confirm (branch stays for recovery) |
| `g` / `q` | Refresh or quit |

## `diff-mode`

Displays unstaged/staged changes (`1`) and commit history (`2`) in tabs.

| Key | What it does |
| --- | --- |
| `Tab` / `f` / `F` | Fold hunk / fold file / fold all files |
| `n` / `p` | Step between visible hunks (or files when folded) |
| `N` / `P` | Always step between files |
| `RET` | Jump to the file at that line |
| `s` | Stage the hunk at point, or the file from its header |
| `?` | Ask the model to explain the selected hunk or file (`ESC` clears selection to explain the full diff) |
| `g` / `w` | Refresh diff / follow the tree |

See also: [prog-mode](prog-mode.md), [buffer-log-mode](buffer-log-mode.md), [05. CODE](../05.%20CODE.md).

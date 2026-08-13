# Instructions for Claude

## Keep DEVLOG.md updated

After any code change — not just big ones — add one or two lines to
`DEVLOG.md`, newest entry at the top of its date section. Say what changed
and why, not a line-by-line diff. The point is that a past session is
outside the context window once it's compacted or ended, so without this a
change gets silently re-suggested, or contradicted, later. Read the top of
`DEVLOG.md` at the start of a session (or when picking work back up after a
gap) before proposing something that touches recently-changed code — check
it hasn't already been done or already been tried and reverted.

Skip the entry only for something with no lasting effect: a one-off
verification run, a question answered, exploration that changed nothing.

# Naming & Scoping Conventions

This document defines how variables and functions in `borgsnap_ng` are
named and scoped. It exists so that new functions follow the existing
pattern automatically, without needing to reverse-engineer it from
examples scattered across the codebase.

## Why this matters

POSIX shell has no block or function scope for variables by default:
every variable is global unless you do something deliberate about it.
This codebase makes that "something deliberate" an explicit, consistent
convention rather than relying on `local` (see the Appendix for why).

## The convention

### 1. Prefix every function-scoped variable with a short function tag

Pick a short, unique tag for the function — typically the first letters
of each word in its name, camelCase — and prefix every variable that
function introduces with `<tag>_`.

```sh
createBorg(){
    crtBorg_pathlist="$1"
    crtBorg_backuplabel="$2"
    crtBorg_borgopts="$3"
    # ...
}

startBackupMachine(){
    strtBckpMchn_dataset="$1"
    strtBckpMchn_repo="$2"
    # ...
}
```

The tag doesn't need to be pretty, it needs to be **unique across the
whole codebase**. Before introducing a new tag, grep for it:

```sh
grep -rn "yourTag_" .
```

If it's already used by a different function, pick a different tag or
make it more specific.

### 2. Save and restore `LASTFUNC` in every function

`LASTFUNC` is the one deliberately global piece of state in this
codebase — it lets the error handler (`err_hdlr` in
`common/msg_and_err_hdlr.sh`) report which function was active when
something failed. Every function that can fail follows this pattern:

```sh
someFunction(){
    someFunc_CALLINGFUCNTION="$LASTFUNC"
    LASTFUNC="someFunction"
    # ... function body ...
    LASTFUNC="$someFunc_CALLINGFUCNTION"
    unset someFunc_CALLINGFUCNTION
}
```

(Yes, `CALLINGFUCNTION` is a historic typo. It's kept as-is rather than
"fixed", because renaming it churns every function for zero functional
benefit — pick your battles.)

### 3. `unset` every variable you introduced, at the end of the function

Because these variables are global by construction, they don't
disappear on their own when the function returns. Every prefixed
variable gets an explicit `unset` before the function ends, mirroring
the assignments at the top:

```sh
someFunction(){
    someFunc_CALLINGFUCNTION="$LASTFUNC"
    LASTFUNC="someFunction"
    someFunc_foo="$1"
    someFunc_bar="$2"

    # ... function body ...

    LASTFUNC="$someFunc_CALLINGFUCNTION"
    unset someFunc_CALLINGFUCNTION
    unset someFunc_foo
    unset someFunc_bar
}
```

If you add a variable to a function, add its `unset` line too. If you
remove one, remove the `unset` line too. Treat the assignment block and
the `unset` block as a matched pair that must stay in sync — this is
exactly the kind of thing that's easy to forget, so double-check it in
review.

### 4. Command substitutions: don't let `local`-style patterns hide exit codes

This isn't about `local` specifically (we don't use it — see the
Appendix), but the same mistake is possible with a plain assignment:

```sh
# Bad: if `command` fails, this line still "succeeds" as a shell statement
someFunc_result="$(command)"

# Good, if the exit code actually matters here:
someFunc_result=$(command)
someFunc_rc=$?
[ "$someFunc_rc" -eq 0 ] || die "command failed"
```

Prefer routing anything whose exit code matters through `exec_cmd`
(see `common/`) rather than a bare command substitution.

---

## Appendix: Why this codebase deliberately does not use `local`

Short version: `local` is supported by every shell we actually target
(dash, bash, ksh, BusyBox ash), but it doesn't behave the way most
programmers expect from a "local variable", and the difference is a
recurring, hard-to-spot source of bugs. We chose predictability over
brevity.

### `local` in shell is dynamically scoped, not lexically scoped

In most languages, a local variable's visibility is determined by
*where it's written in the source* (lexical/static scoping): once you
leave the block or function, the name is gone, full stop, regardless of
what gets called from where.

Shell's `local` doesn't work that way. It's scoped to the *call stack*
instead (dynamic scoping): a `local` variable in a function remains
visible to every function that function calls, for as long as that
call chain is active — unless the callee happens to declare its own
`local` with the same name, which shadows it for the duration of that
call.

```sh
foo() {
    local x="set by foo"
    bar
}

bar() {
    echo "$x"        # prints "set by foo" - bar never declared x itself
    x="changed by bar"
}

foo
echo "$x"             # empty/unset at top level - x was local to foo,
                       # but bar was able to read AND overwrite it while
                       # foo's call was still active
```

This is documented behavior of bash, dash, and mksh's `local`, not a
bug in any of them — it's simply not the C-like/lexical model most
people assume from the name "local". The
[ShellCheck SC3043 wiki page](https://github.com/koalaman/shellcheck/wiki/SC3043)
confirms `local` is widely supported (bash, ksh, dash, BusyBox ash) but
explicitly not part of POSIX, and the *behavior* of that non-standard
feature also isn't standardized across implementations.

A good post regarding `local` and shells can also be found in this stackexchange
post: https://unix.stackexchange.com/a/493743

### Why that matters for a codebase like this one

`startBackupMachine` calls `snapshotZFS`, `mountZFSSnapshot`,
`createBorg`, `pruneBorg`, and others, several layers deep, often in
loops. With `local`, correctness would depend on **every function in
that whole call graph** consistently declaring `local` for every name
it uses that happens to collide with a name used somewhere else in the
chain — a contract that's invisible at the call site, isn't checked by
any tool, and silently breaks the moment one function in the chain
forgets it. The bug that results depends on *call order*, not on
anything visible in the function you're looking at, which makes it
exactly the kind of thing that's easy to introduce and painful to
debug (see the linked
[nvm.sh issue #574](https://github.com/nvm-sh/nvm/issues/574) for a
real-world example of this class of problem).

The prefix convention in this document sidesteps the issue entirely:
every variable name is unique across the whole codebase by
construction, so there is no call stack for a collision to hide in.
`crtBorg_pathlist` cannot collide with `strtBckpMchn_dataset` no matter
which function calls which, in what order, or how deep the call chain
gets. The cost is more typing and the discipline of keeping the
assignment/`unset` blocks in sync (see section 3) — a mechanical,
locally-checkable cost, traded for not having to reason about dynamic
scope across the entire call graph.

### When `local` would be the better trade-off

If this were a single-host, single-purpose admin script with a shallow
call graph and one maintainer, `local` would likely be the more
pragmatic choice — the collision risk is low and the code is shorter.
That's not the situation here: this project targets multiple
deployment contexts (see the project's stated goal of supporting
different backup providers and both ZFS-send and Borg backends) and is
meant to be extended over time, possibly by more than one person. The
prefix convention is the more conservative choice for that scope, even
though it's more verbose to write.

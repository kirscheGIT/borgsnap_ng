# check-unset.awk
# Called by check-unset.sh - see that file for usage and rationale.
#
# State machine over the input file:
#   - Not in a function: only watch for a function-start line.
#   - In a function: track brace depth (POSIX sh only uses braces for
#     function bodies and ${...} expansions, and the latter open+close on
#     the same line in virtually all real-world code, so a simple net
#     count per line is reliable here); collect assigned/unset names;
#     when depth returns to 0, the function has ended - diff the two sets.

BEGIN {
    infunc = 0
    depth = 0
    funcname = ""
    nignored = 0
    if (ignorefile != "") {
        while ((getline line < ignorefile) > 0) {
            if (line == "" || line ~ /^#/) continue
            nignored++
            ignored[nignored] = line
        }
        close(ignorefile)
    }
}

function is_ignored(fn, var,    i, pat) {
    pat = fn ":" var
    for (i = 1; i <= nignored; i++) {
        if (ignored[i] == pat) return 1
    }
    return 0
}

function reset_func_state() {
    infunc = 0
    depth = 0
    funcname = ""
    delete assigned
    delete unsetd
    delete assign_line
}

function finish_function(   name, cnt) {
    for (name in assigned) {
        if (!(name in unsetd) && !is_ignored(funcname, name)) {
            printf "MISSING  %s:%d  %s()  assigns %s but never unsets it\n", \
                fname, assign_line[name], funcname, name
        }
    }
    for (name in unsetd) {
        if (!(name in assigned) && !is_ignored(funcname, name)) {
            printf "STALE    %s:%d  %s()  unsets %s but never assigns it (dead code?)\n", \
                fname, unset_line[name], funcname, name
        }
    }
    reset_func_state()
}

# --- not currently inside a function: look for a function start --------
infunc == 0 {
    if (match($0, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{[ \t]*(#.*)?$/)) {
        funcname = $0
        sub(/^[ \t]*/, "", funcname)
        sub(/\(\).*/, "", funcname)
        infunc = 1
        depth = 1
        delete assigned
        delete unsetd
        delete assign_line
        delete unset_line
    }
    next
}

# --- inside a function ---------------------------------------------------
{
    line = $0

    # Net brace delta for this line (handles both the function's own
    # closing brace and any ${...} expansions, which net to zero).
    opens = gsub(/\{/, "{", line)
    closes = gsub(/\}/, "}", line)
    depth += (opens - closes)

    trimmed = $0
    sub(/^[ \t]+/, "", trimmed)

    # for identifier in ... (POSIX for-loop - the loop variable is
    # effectively assigned on each iteration, even though it's not
    # "identifier=..." syntax)
    if (match(trimmed, /^for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in([ \t]|;|$)/)) {
        ident = trimmed
        sub(/^for[ \t]+/, "", ident)
        sub(/[ \t]+in([ \t]|;|$).*/, "", ident)
        if (ident ~ /^[a-z][A-Za-z0-9]*_[A-Za-z]/ && trimmed !~ /#[ \t]*noqa:unset/) {
            assigned[ident] = 1
            if (!(ident in assign_line)) assign_line[ident] = FNR
        }
    }
    # unset name [name2 ...]
    if (trimmed ~ /^unset[ \t]+/) {
        rest = trimmed
        sub(/^unset[ \t]+/, "", rest)
        sub(/[ \t]*#.*/, "", rest)
        n = split(rest, names, /[ \t]+/)
        for (i = 1; i <= n; i++) {
            nm = names[i]
            if (nm ~ /^[a-z][A-Za-z0-9]*_[A-Za-z]/) {
                unsetd[nm] = 1
                unset_line[nm] = FNR
            }
        }
    }
    # identifier=... (assignment: identifier is the very first token on
    # the line, immediately followed by "=" - excludes "if [ x = y ]",
    # "[ x = y ]", "for x in ...", etc. since those don't start with
    # "identifier=" as the first token)
    else if (match(trimmed, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
        ident = trimmed
        sub(/=.*/, "", ident)
        if (ident ~ /^[a-z][A-Za-z0-9]*_[A-Za-z]/ && trimmed !~ /#[ \t]*noqa:unset/) {
            assigned[ident] = 1
            if (!(ident in assign_line)) assign_line[ident] = FNR
        }
    }

    if (depth <= 0) {
        finish_function()
    }
}

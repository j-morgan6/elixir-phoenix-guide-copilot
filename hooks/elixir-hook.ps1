# elixir-hook.ps1 - Elixir/Phoenix guard hooks for the Copilot edition of
# elixir-phoenix-guide (PowerShell twin of elixir-hook.sh; Windows PowerShell
# 5.1 and PowerShell 7+). Configured in .github/hooks/elixir-guard.json.
# Must stay behaviourally identical to elixir-hook.sh: tests/run_tests.sh runs
# the same cases against both (`PWSH=... bash tests/run_tests.sh ps1`).
#
# Usage: <hook JSON on stdin> | elixir-hook.ps1 <pre|post> <bash|edit>
#   pre bash   block destructive commands (Elixir projects only)
#   pre edit   block near-certain bugs in the text about to be written
#   post edit  review notes on the lines just written
#
# Input: Copilot's {"cwd", "toolArgs"} (object or JSON string) or the
# VS Code-compatible {"cwd", "tool_input"}. Edit arguments are read from
# file_path|filePath|path and new_string|newString|new_str (edits),
# content|file_text (whole-file writes), plus a MultiEdit-style edits[].
#
# Output contract:
#   deny     {"permissionDecision":"deny","permissionDecisionReason":"..."}
#            on stdout, exit 2 (preToolUse only)
#   advisory {"additionalContext":"..."} on stdout, exit 0 (postToolUse only;
#            Copilot ignores additionalContext from preToolUse)
#   nothing  exit 0, no output
# A preToolUse hook that exits non-zero for any other reason denies the tool
# call, so every error is caught and the script fails open (exit 0).
# No jq needed. git is used, when present, for whole-file writes in post edit.

param(
    [string]$Phase,
    [string]$Type
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

function Exit-Deny([string]$Reason) {
    $obj = [ordered]@{ permissionDecision = 'deny'; permissionDecisionReason = $Reason }
    [Console]::Out.WriteLine(($obj | ConvertTo-Json -Compress))
    [Console]::Out.Flush()
    exit 2
}

function Exit-Advise([string]$Text) {
    $obj = [ordered]@{ additionalContext = $Text }
    [Console]::Out.WriteLine(($obj | ConvertTo-Json -Compress))
    [Console]::Out.Flush()
    exit 0
}

# --- small helpers ----------------------------------------------------------
function Get-Prop($Obj, [string]$Name) {
    if ($null -eq $Obj -or -not ($Obj -is [System.Management.Automation.PSCustomObject])) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}
function Test-Prop($Obj, [string]$Name) {
    if ($null -eq $Obj -or -not ($Obj -is [System.Management.Automation.PSCustomObject])) { return $false }
    return ($null -ne $Obj.PSObject.Properties[$Name])
}
# jq's `a // b // c | if string then . else "" end`
function Get-FirstString($Obj, [string[]]$Names) {
    foreach ($n in $Names) {
        $v = Get-Prop $Obj $n
        if ($null -ne $v -and -not ($v -is [bool] -and -not $v)) {
            if ($v -is [string]) { return $v }
            return ''
        }
    }
    return ''
}
function Get-NlCount([string]$S) {
    return ($S.Length - $S.Replace("`n", '').Length)
}
# Lines of a text the way awk reads records: split on LF, drop the empty
# element after a final newline, strip a trailing CR.
function Get-Lines([string]$Text) {
    $parts = $Text.Split([char]10)
    $n = $parts.Length
    if ($n -gt 0 -and $parts[$n - 1] -eq '') { $n-- }
    $out = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt $n; $i++) { $out.Add(($parts[$i] -replace "`r$", '')) }
    return ,$out
}
function Split-Ordinal([string]$S, [string]$Sep) {
    return ,($S.Split([string[]]@($Sep), [System.StringSplitOptions]::None))
}

# Nearest ancestor of $Start (inclusive) that is an Elixir project: has
# mix.exs, or apps/*/mix.exs. An umbrella child resolves to the umbrella root.
function Find-ProjectRoot([string]$Start) {
    $dir = $Start
    while ($dir) {
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }   # filesystem root
        if (Test-Path -LiteralPath (Join-Path $dir 'mix.exs') -PathType Leaf) {
            if ((Split-Path -Leaf $parent) -ceq 'apps') {
                $gp = Split-Path -Parent $parent
                if ($gp -and (Test-Path -LiteralPath (Join-Path $gp 'mix.exs') -PathType Leaf)) { return $gp }
            }
            return $dir
        }
        $apps = Join-Path $dir 'apps'
        if (Test-Path -LiteralPath $apps -PathType Container) {
            foreach ($a in @(Get-ChildItem -LiteralPath $apps -Directory -ErrorAction SilentlyContinue)) {
                if (Test-Path -LiteralPath (Join-Path $a.FullName 'mix.exs') -PathType Leaf) { return $dir }
            }
        }
        $dir = $parent
    }
    return $null
}

# ============================================================================
# pre bash - destructive commands
#   mix ecto.reset / mix ecto.drop, unless MIX_ENV=test for that command
#   git push --force / -f / combined short flags with f / +refspec
#   (--force-with-lease and --force-if-includes are allowed)
# Opt-out: EPG_ALLOW=force_push,ecto_reset,ecto_drop in the hook's
# environment, exported earlier in the same command line, or as a prefix.
# ============================================================================

# One segment per output line. Inside quotes, whitespace and shell
# metacharacters become "_" so quoted text stays a single inert word.
# Port of the awk scanner in elixir-hook.sh (0-based indices here).
function Split-Segments([string]$S) {
    $L = $S.Length
    $sb = New-Object System.Text.StringBuilder
    $st = 0
    $hd = New-Object 'System.Collections.Generic.List[string]'
    $meta = '^[\s;&|()<>`$]$'
    $i = 0
    while ($i -lt $L) {
        $c = $S.Substring($i, 1)
        if ($st -eq 1) {
            if ($c -ceq "'") { $st = 0 }
            elseif ($c -match $meta) { [void]$sb.Append('_') } else { [void]$sb.Append($c) }
            $i++; continue
        }
        if ($st -eq 2) {
            if ($c -ceq '\') { $i += 2; [void]$sb.Append('_'); continue }
            if ($c -ceq '"') { $st = 0 }
            elseif ($c -match $meta) { [void]$sb.Append('_') } else { [void]$sb.Append($c) }
            $i++; continue
        }
        if ($c -ceq '\') {
            $i++
            $n2 = if ($i -lt $L) { $S.Substring($i, 1) } else { '' }
            if ($n2 -ceq "`n") { [void]$sb.Append(' ') }
            elseif ($n2 -match '^\s$') { [void]$sb.Append('_') }
            else { [void]$sb.Append($n2) }
            $i++; continue
        }
        if ($c -ceq "'") { $st = 1; $i++; continue }
        if ($c -ceq '"') { $st = 2; $i++; continue }
        if ($c -ceq '#' -and ($i -eq 0 -or $S.Substring($i - 1, 1) -match '^[\s;&|()]$')) {
            while ($i + 1 -lt $L -and $S.Substring($i + 1, 1) -cne "`n") { $i++ }
            $i++; continue
        }
        if ($c -ceq '<' -and $i + 1 -lt $L -and $S.Substring($i + 1, 1) -ceq '<' -and -not ($i + 2 -lt $L -and $S.Substring($i + 2, 1) -ceq '<')) {
            $j = $i + 2
            if ($j -lt $L -and $S.Substring($j, 1) -ceq '-') { $j++ }
            while ($j -lt $L -and $S.Substring($j, 1) -match '^[ \t]$') { $j++ }
            $w = ''
            while ($j -lt $L -and $S.Substring($j, 1) -notmatch '^[\s;&|()<>]$') { $w += $S.Substring($j, 1); $j++ }
            $w = $w -replace '[''"\\]', ''
            if ($w -ne '') { $hd.Add($w) }
            $i = $j
            [void]$sb.Append(' ')
            continue
        }
        if ($c -ceq "`n") {
            [void]$sb.Append("`n")
            if ($hd.Count -gt 0) {
                $pos = $i + 1
                foreach ($h in $hd) {
                    while ($pos -lt $L) {
                        $e = $S.IndexOf("`n", $pos)
                        if ($e -lt 0) { $t = $S.Substring($pos); $pos = $L } else { $t = $S.Substring($pos, $e - $pos); $pos = $e + 1 }
                        if ($t.Trim() -ceq $h) { break }
                    }
                }
                $hd.Clear(); $i = $pos
                continue
            }
            $i++; continue
        }
        if ($c -ceq '&') {
            $p = if ($i -gt 0) { $S.Substring($i - 1, 1) } else { '' }
            $q = if ($i + 1 -lt $L) { $S.Substring($i + 1, 1) } else { '' }
            if ($p -ceq '>' -or $p -ceq '<' -or $q -ceq '>') { [void]$sb.Append($c) } else { [void]$sb.Append("`n") }
            $i++; continue
        }
        if ($c -ceq '$' -and $i + 1 -lt $L -and $S.Substring($i + 1, 1) -ceq '(') { [void]$sb.Append("`n"); $i += 2; continue }
        if ($c -ceq ';' -or $c -ceq '|' -or $c -ceq '(' -or $c -ceq ')' -or $c -ceq '`') { [void]$sb.Append("`n"); $i++; continue }
        [void]$sb.Append($c)
        $i++
    }
    return $sb.ToString()
}

function Test-Allow([string]$Tok, [string[]]$Lists) {
    foreach ($list in $Lists) {
        $padded = ",$list,"
        if ($padded.Contains(",$Tok,") -or $padded.Contains(',all,')) { return $true }
    }
    return $false
}

function Block-Command([string]$Why) {
    Exit-Deny ('elixir-phoenix-guide blocked this command: ' + $Why)
}

$script:ExpMixEnv = ''
$script:ExpAllow = ''
$script:HookMixEnv = if ($env:MIX_ENV) { $env:MIX_ENV } else { '' }
$script:HookAllow = if ($env:EPG_ALLOW) { $env:EPG_ALLOW } else { '' }

function Test-Segment([string[]]$Words) {
    $segEnv = ''; $segAllow = ''
    $k = 0; $n = $Words.Count
    while ($k -lt $n) {
        $w = $Words[$k]
        if ($w.Contains('=')) {
            $name = $w.Substring(0, $w.IndexOf('='))
            $val = $w.Substring($w.IndexOf('=') + 1)
            if ($name -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') { break }
            if ($name -ceq 'MIX_ENV') { $segEnv = $val }
            if ($name -ceq 'EPG_ALLOW') { $segAllow = $val }
            $k++; continue
        }
        if ($w -ceq 'env') {
            $k++
            while ($k -lt $n) {
                $o = $Words[$k]
                if ($o -ceq '-u' -or $o -ceq '-C' -or $o -ceq '-S') { $k += 2 }
                elseif ($o.StartsWith('-')) { $k++ }
                else { break }
            }
            continue
        }
        if (@('{', '}', '!', 'if', 'then', 'else', 'elif', 'do', 'while', 'until', 'time', 'nohup', 'command', 'exec', 'builtin', 'sudo', 'xargs') -ccontains $w) { $k++; continue }
        break
    }
    if ($k -ge $n) { return }
    $cmd = $Words[$k]
    $slash = $cmd.LastIndexOf('/')
    if ($slash -ge 0) { $cmd = $cmd.Substring($slash + 1) }
    $rest = @(); if ($k + 1 -lt $n) { $rest = @($Words[($k + 1)..($n - 1)]) }

    if ($cmd -ceq 'export') {
        foreach ($a in $rest) {
            if ($a.StartsWith('MIX_ENV=')) { $script:ExpMixEnv = $a.Substring(8) }
            elseif ($a.StartsWith('EPG_ALLOW=')) { $script:ExpAllow = $a.Substring(10) }
        }
    }
    elseif ($cmd -ceq 'mix') {
        $m = 0
        while ($m -lt $rest.Count -and $rest[$m].StartsWith('-')) { $m++ }
        if ($m -ge $rest.Count) { return }
        if ($rest[$m] -ceq 'do') {
            $joined = ''
            if ($m + 1 -lt $rest.Count) { $joined = ($rest[($m + 1)..($rest.Count - 1)] -join ' ') }
            $tasks = @(($joined -replace '[,+]', ' ') -split '\s+' | Where-Object { $_ -ne '' })
        } else {
            $tasks = @($rest[$m])
        }
        $envName = if ($segEnv) { $segEnv } elseif ($script:ExpMixEnv) { $script:ExpMixEnv } elseif ($script:HookMixEnv) { $script:HookMixEnv } else { 'dev' }
        foreach ($task in $tasks) {
            if ($task -ceq 'ecto.reset' -or $task -ceq 'ecto.drop') {
                if ($envName -ceq 'test') { continue }
                $tok = if ($task -ceq 'ecto.drop') { 'ecto_drop' } else { 'ecto_reset' }
                if (Test-Allow $tok @($segAllow, $script:ExpAllow, $script:HookAllow)) { continue }
                Block-Command ('`mix {0}` drops the {1} database and all of its data. For the test database run `MIX_ENV=test mix {0}`; for schema changes use `mix ecto.rollback` / `mix ecto.migrate`. If the user explicitly asked for this, re-run it prefixed with `EPG_ALLOW={2}`.' -f $task, $envName, $tok)
            }
        }
    }
    elseif ($cmd -ceq 'git') {
        $g = 0
        while ($g -lt $rest.Count) {
            $o = $rest[$g]
            if (@('-C', '-c', '--git-dir', '--work-tree', '--namespace', '--config-env', '--exec-path', '--super-prefix') -ccontains $o) { $g += 2 }
            elseif ($o.StartsWith('-')) { $g++ }
            else { break }
        }
        if ($g -ge $rest.Count) { return }
        if ($rest[$g] -cne 'push') { return }
        $force = $false
        for ($x = $g + 1; $x -lt $rest.Count; $x++) {
            $a = $rest[$x]
            if ($a -ceq '--force-with-lease' -or $a.StartsWith('--force-with-lease=') -or $a -ceq '--force-if-includes') { }
            elseif ($a -ceq '--force') { $force = $true }
            elseif ($a.StartsWith('--')) { }
            elseif ($a.StartsWith('-') -and $a.Length -ge 2) {
                $cluster = $a.Substring(1)
                $oi = $cluster.IndexOf('o')                   # -o takes an argument
                if ($oi -ge 0) { $cluster = $cluster.Substring(0, $oi) }
                if ($cluster.Contains('f')) { $force = $true }
            }
            elseif ($a.StartsWith('+') -and $a.Length -ge 2) { $force = $true }
        }
        if ($force) {
            if (Test-Allow 'force_push' @($segAllow, $script:ExpAllow, $script:HookAllow)) { return }
            Block-Command 'force push (--force, -f or a +refspec) overwrites remote history. Use `git push --force-with-lease` instead. If the user explicitly asked for a force push, re-run it prefixed with `EPG_ALLOW=force_push`.'
        }
    }
}

function Invoke-BashPre($ToolArgs, [string]$Cwd) {
    $cmd = Get-Prop $ToolArgs 'command'
    if (-not ($cmd -is [string]) -or -not $cmd) { exit 0 }
    if (-not (Find-ProjectRoot $Cwd)) { exit 0 }
    $segments = Split-Segments $cmd
    foreach ($seg in $segments.Split([char]10)) {
        $words = @($seg -split '\s+' | Where-Object { $_ -ne '' })
        if ($words.Count -gt 0) { Test-Segment $words }
    }
    exit 0
}

# ============================================================================
# pre/post edit - file checks (see elixir-hook.sh for the full description)
#   block  - near-certain bugs. pre edit denies the write.
#   review - heuristics. post edit returns them as additionalContext.
# ============================================================================

# Lines of $Content where any of $News occurs ("a-b a-b ..."), else lines
# whose trimmed text equals a trimmed new line, else "ALL"; "NONE" when every
# new string is empty.
function Get-LocatedLines([string]$Content, $News) {
    $news2 = @($News | Where-Object { $_ -ne '' })
    if ($news2.Count -eq 0) { return 'NONE' }
    $exact = New-Object 'System.Collections.Generic.List[string]'
    foreach ($s in $news2) {
        $parts = Split-Ordinal $Content $s
        if ($parts.Length -lt 2) { continue }
        $snl = Get-NlCount $s
        $span = if ($s.EndsWith("`n") -and $snl -gt 0) { $snl - 1 } else { $snl }
        $line = 1
        for ($i = 0; $i -lt $parts.Length - 1; $i++) {
            $line += (Get-NlCount $parts[$i])
            $start = $line
            $line += $snl
            $exact.Add("$start-$($start + $span)")
        }
    }
    if ($exact.Count -gt 0) { return ($exact -join ' ') }
    $want = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($s in $news2) {
        foreach ($l in $s.Split([char]10)) {
            $t = $l -replace '^\s+|\s+$', ''
            if ($t -ne '') { [void]$want.Add($t) }
        }
    }
    $hits = New-Object 'System.Collections.Generic.List[string]'
    $all = $Content.Split([char]10)
    for ($i = 0; $i -lt $all.Length; $i++) {
        $t = $all[$i] -replace '^\s+|\s+$', ''
        if ($want.Contains($t)) { $hits.Add("$($i + 1)-$($i + 1)") }
    }
    if ($hits.Count -gt 0) { return ($hits -join ' ') }
    return 'ALL'
}

# Lines of $New not present in $Old (multiset match on exact line text).
function Get-NewLines([string]$Old, [string]$New) {
    $have = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([System.StringComparer]::Ordinal)
    foreach ($l in (Get-Lines $Old)) { if ($have.ContainsKey($l)) { $have[$l]++ } else { $have[$l] = 1 } }
    $out = New-Object 'System.Collections.Generic.List[string]'
    $nl = Get-Lines $New
    for ($i = 0; $i -lt $nl.Count; $i++) {
        $l = $nl[$i]
        if ($have.ContainsKey($l) -and $have[$l] -gt 0) { $have[$l]-- } else { $out.Add("$($i + 1)-$($i + 1)") }
    }
    if ($out.Count -eq 0) { return 'NONE' }
    return ($out -join ' ')
}

# Added lines of a tracked file vs the git index; ALL when untracked/no git.
function Get-GitAddedLines([string]$File) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return 'ALL' }
    $dir = Split-Path -Parent $File; $base = Split-Path -Leaf $File
    $eap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $null = & git -C $dir ls-files --error-unmatch -- $base 2>$null
        if ($LASTEXITCODE -ne 0) { return 'ALL' }
        $diff = @(& git -C $dir diff -U0 --no-color --no-ext-diff -- $base 2>$null)
    } catch { return 'ALL' } finally { $ErrorActionPreference = $eap }
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($d in $diff) {
        if ($d -cmatch '^@@') {
            $m = [regex]::Match($d, '\+[0-9]+(,[0-9]+)?')
            if ($m.Success) {
                $p = $m.Value.Substring(1).Split(',')
                $start = [int]$p[0]; $cnt = if ($p.Length -gt 1) { [int]$p[1] } else { 1 }
                if ($cnt -gt 0) { $out.Add("$start-$($start + $cnt - 1)") }
            }
        }
    }
    if ($out.Count -eq 0) { return 'NONE' }
    return ($out -join ' ')
}

# Phoenix 1.8 scopes: a Scope module, or current_scope in *user_auth.ex,
# under lib/ or apps/*/lib of the project containing $File.
function Test-ProjectHasScope([string]$File) {
    $root = Find-ProjectRoot (Split-Path -Parent $File)
    if (-not $root) { return $false }
    $dirs = @(Join-Path $root 'lib')
    $apps = Join-Path $root 'apps'
    if (Test-Path -LiteralPath $apps -PathType Container) {
        foreach ($a in @(Get-ChildItem -LiteralPath $apps -Directory -ErrorAction SilentlyContinue)) { $dirs += (Join-Path $a.FullName 'lib') }
    }
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $d -Recurse -File -Filter '*.ex' -ErrorAction SilentlyContinue)) {
            $txt = [System.IO.File]::ReadAllText($f.FullName)
            if ([regex]::IsMatch($txt, '(?m)defmodule\s+[A-Za-z0-9_.]+\.Scope(\s|,|$)')) { return $true }
            if ($f.Name -like '*user_auth.ex' -and $txt.Contains('current_scope')) { return $true }
        }
    }
    return $false
}

# --- the checks: port of the awk program in elixir-hook.sh ------------------
$script:Tier = [ordered]@{
    sql = 'block'; fragment = 'block'; extredir = 'block'; formfor = 'block'; livenav = 'block'
    toatom = 'review'; raw = 'review'; logger = 'review'; inspect = 'review'; timing = 'review'
    impl = 'review'; migidx = 'review'; ondelete = 'review'; curuser = 'review'; repolive = 'review'
}
$script:Msg = @{
    sql      = 'SQL built by string interpolation in Repo.query/SQL.query - SQL injection. Pass values as parameters: Repo.query("... WHERE id = $1", [id]).'
    fragment = 'Interpolation inside fragment() - Ecto rejects this at compile time and it would be SQL injection. Use ? placeholders: fragment("lower(?)", field).'
    extredir = 'redirect(external: params...) - open redirect to a user-supplied URL. Use redirect(to: ~p"...") or check the host against an allowlist first.'
    formfor  = 'form_for was removed in phoenix_html 4 - use <.form for={@form} ...> with to_form/1.'
    livenav  = 'live_redirect/live_patch/push_redirect are deprecated - use <.link navigate={...}>/<.link patch={...}> or push_navigate/push_patch.'
    toatom   = 'String.to_atom/1 - atoms are never garbage-collected; on user input this can exhaust the atom table. Map known strings explicitly or use String.to_existing_atom/1.'
    raw      = 'raw/1 bypasses HTML escaping - XSS if the content can contain user input. Make sure it is sanitized or trusted.'
    logger   = 'Logger message interpolates a sensitive value (password/token/secret/key) - redact it or log an identifier instead.'
    inspect  = 'IO.inspect/dbg left in lib code - remove before committing (use Logger for intentional output).'
    timing   = 'Secret/token compared with == - not constant-time. Use Plug.Crypto.secure_compare/2.'
    impl     = 'Callback without @impl true on its first clause - add @impl true above it.'
    migidx   = 'references() column with no index on that table in this migration - add create index(:table, [:column]) (Postgres does not index foreign keys automatically).'
    ondelete = 'references() without on_delete: - the default is :nothing; choose :delete_all, :nilify_all or :restrict explicitly.'
    curuser  = 'This project uses Phoenix 1.8 scopes - use @current_scope (and @current_scope.user) rather than @current_user.'
    repolive = 'Repo called directly in a LiveView module - move the query into a context function (scoped to @current_scope where the project uses scopes).'
}

function Remove-Comment([string]$S) {
    if ($S.IndexOf('#') -lt 0) { return $S }
    $q = $false; $L = $S.Length
    for ($i = 0; $i -lt $L; $i++) {
        $c = $S[$i]
        if ($c -ceq '\') { $i++; continue }
        if ($c -ceq '"') { $q = -not $q }
        elseif ($c -ceq '#' -and -not $q -and -not ($i + 1 -lt $L -and $S[$i + 1] -ceq '{')) { return $S.Substring(0, $i) }
    }
    return $S
}
function Test-DynInterp([string]$S) {
    $t = [regex]::Replace($S, '#\{@[A-Za-z_][A-Za-z0-9_]*\}', '')
    return $t.Contains('#{')
}
# name and arity (-1 when the head spans lines) of a def line
function Get-DefHead([string]$S) {
    $rest = [regex]::Replace($S, '^\s*def(p|macro|macrop)?\s+', '')
    $m = [regex]::Match($rest, '^[a-z_][A-Za-z0-9_]*[?!]?')
    if (-not $m.Success) { return @('', -1) }
    $name = $m.Value; $rest = $rest.Substring($m.Length)
    if (-not $rest.StartsWith('(')) {
        if ($rest -cmatch '^\s+[^,d]') { return @($name, -1) }
        return @($name, 0)
    }
    $depth = 0; $commas = 0; $q = $false; $sawarg = $false; $L = $rest.Length
    for ($i = 0; $i -lt $L; $i++) {
        $c = $rest[$i]
        if ($q) { if ($c -ceq '\') { $i++ } elseif ($c -ceq '"') { $q = $false }; continue }
        if ($c -ceq '"') { $q = $true; $sawarg = $true; continue }
        if ($c -ceq '(' -or $c -ceq '[' -or $c -ceq '{') { $depth++; if ($depth -gt 1) { $sawarg = $true }; continue }
        if ($c -ceq ')' -or $c -ceq ']' -or $c -ceq '}') {
            $depth--
            if ($depth -eq 0) { if ($sawarg) { return @($name, ($commas + 1)) } else { return @($name, 0) } }
            continue
        }
        if ($c -ceq ',' -and $depth -eq 1) { $commas++ }
        elseif ($c -notmatch '\s') { $sawarg = $true }
    }
    return @($name, -1)
}
function Get-Capture([string]$S, [string]$Re, [string]$PrefixRe) {
    $m = [regex]::Match($S, $Re)
    if (-not $m.Success) { return '' }
    return [regex]::Replace($m.Value, $PrefixRe, '', [System.Text.RegularExpressions.RegexOptions]::None)
}

# Returns a list of "<tier>`t<message> (line N, M)".
function Invoke-Checks([string]$Text, [string]$Ranges, [hashtable]$Ctx) {
    $all = ($Ranges -ceq 'ALL')
    $chg = @{}
    if (-not $all) {
        foreach ($r in ($Ranges -split ' ')) {
            if (-not $r) { continue }
            $ab = $r.Split('-')
            for ($x = [int]$ab[0]; $x -le [int]$ab[1]; $x++) { $chg[$x] = $true }
        }
    }
    $kind = $Ctx.Kind
    $isEx = ($kind -ceq 'ex' -or $kind -ceq 'exs')
    $where = [ordered]@{}
    $seen = @{}
    $flag = {
        param($id, $ln)
        if (-not ($all -or $chg.ContainsKey($ln))) { return }
        $key = "$id,$ln"
        if ($seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        if ($where.Contains($id)) { $where[$id] = $where[$id] + ', ' + $ln } else { $where[$id] = "$ln" }
    }

    $raw = Get-Lines $Text
    $n = $raw.Count
    # 1-based arrays to mirror the awk program
    $rawA = @('') + @($raw)
    $code = New-Object 'string[]' ($n + 1)

    # ---- pass 1: blank out comments and @doc/@moduledoc/@typedoc text ----
    $indoc = ''; $inhc = $false
    for ($i = 1; $i -le $n; $i++) {
        $line = $rawA[$i]
        if ($indoc -ne '') { if ($line.Contains($indoc)) { $indoc = '' }; $code[$i] = ''; continue }
        if ($inhc) {
            $e = $line.IndexOf('--%>')
            if ($e -ge 0) { $inhc = $false; $line = $line.Substring($e + 4) }
            else { $code[$i] = ''; continue }
        }
        if ($isEx -and $line -cmatch '^\s*@(moduledoc|doc|typedoc|shortdoc)(\s|$)') {
            $code[$i] = '@doc'
            if ($line.Contains('"""')) { $indoc = '"""' }
            elseif ($line.Contains("'''")) { $indoc = "'''" }
            continue
        }
        if ($isEx -and $line -cmatch '^\s*#') { $code[$i] = ''; continue }
        while (($s0 = $line.IndexOf('<%!--')) -ge 0) {
            $rest = $line.Substring($s0 + 5)
            $e = $rest.IndexOf('--%>')
            if ($e -ge 0) { $line = $line.Substring(0, $s0) + $rest.Substring($e + 4) }
            else { $line = $line.Substring(0, $s0); $inhc = $true; break }
        }
        $line = [regex]::Replace($line, '<!--.*-->', '')
        if ($isEx) { $code[$i] = Remove-Comment $line } else { $code[$i] = $line }
    }

    # ---- pass 2: line checks ----
    $implPending = $false; $lastName = ''; $lastArity = -2
    $curTable = ''
    $refs = New-Object System.Collections.ArrayList
    $idx = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    for ($i = 1; $i -le $n; $i++) {
        $c = $code[$i]
        if ($c -cmatch '^\s*$') { continue }
        $isdef = ($c -cmatch '^\s*def(p|macro|macrop)?\s+[a-z_]')

        if ($isEx) {
            $m = [regex]::Match($c, '(Repo|SQL)\.query!?\(')
            if ($m.Success) {
                $rest = $c.Substring($m.Index + $m.Length - 1)
                if ($rest -cmatch '^\(([A-Za-z_][A-Za-z0-9_.]*,\s*)?~?[sS]?"""') {
                    for ($j = $i + 1; $j -le $n -and $j -le $i + 200; $j++) {
                        if ($rawA[$j].Contains('"""')) { break }
                        if (Test-DynInterp $rawA[$j]) { if ($all -or $chg.ContainsKey($j)) { & $flag 'sql' $j } else { & $flag 'sql' $i } }
                    }
                } else {
                    $m2 = [regex]::Match($rest, '^\(([A-Za-z_][A-Za-z0-9_.]*,\s*)?"([^"\\]|\\.)*"')
                    if ($m2.Success) {
                        if (Test-DynInterp $m2.Value) { & $flag 'sql' $i }
                    } elseif ($rest -cmatch '^\(([A-Za-z_][A-Za-z0-9_.]*,\s*)?"' -and (Test-DynInterp $rest)) {
                        & $flag 'sql' $i
                    }
                }
            }
            if ($c -cmatch 'fragment\("[^"]*#\{') { & $flag 'fragment' $i }
            if ($c -cmatch 'external:\s*(conn\.)?(query_|body_|path_)?params([^A-Za-z0-9_]|$)') { & $flag 'extredir' $i }
            if ($c -cmatch 'String\.to_atom([^A-Za-z0-9_?!]|$)') { & $flag 'toatom' $i }
            $lc = $c.ToLowerInvariant()
            if ($lc -cmatch 'logger\.[a-z_]+\(' -and $lc -cmatch '#\{[^}]*(password|passwd|secret|token|api_key|apikey|private_key|credential|authorization)') { & $flag 'logger' $i }
            if ($kind -ceq 'ex' -and -not $Ctx.SkipInspect -and ($c -cmatch 'IO\.inspect([^A-Za-z0-9_]|$)' -or $c -cmatch '(^|[^A-Za-z0-9_.:])dbg\(')) { & $flag 'inspect' $i }
            if ($c -cmatch '(token|secret|api_key|signature)\s*==\s*[a-z_]' -or $c -cmatch '[a-z_]\s*==\s*(token|secret|api_key|signature)([^A-Za-z0-9_]|$)') {
                if ($c -cnotmatch '==\s*(nil|true|false)([^A-Za-z0-9_]|$)' -and $c -cnotmatch '(^|[^A-Za-z0-9_.])(nil|true|false)\s*==') { & $flag 'timing' $i }
            }
            if ($kind -ceq 'ex' -and $Ctx.IsLive -and $c -cmatch '(^|[^A-Za-z0-9_])Repo\.(all|one|get|get_by|insert|insert_all|update|update_all|delete|delete_all|aggregate|exists\?|preload|transact|transaction)(!?)\(') { & $flag 'repolive' $i }
        }

        $defines = ''
        if ($isdef) { $defines = Get-Capture $c 'def(p|macro|macrop)?\s+[a-z_]+' '^def(p|macro|macrop)?\s+' }
        if ($defines -cne 'form_for' -and $c -cmatch '(^|[^A-Za-z0-9_:])form_for(\(|\s+[@a-z])') { & $flag 'formfor' $i }
        if ($defines -cnotmatch '^(live_redirect|live_patch|push_redirect)$' -and $c -cmatch '(^|[^A-Za-z0-9_:])(live_redirect|live_patch|push_redirect)([^A-Za-z0-9_]|$)') { & $flag 'livenav' $i }
        if ($defines -cne 'raw' -and ($c -cmatch '(^|[^A-Za-z0-9_.:])raw(\(|\s+@)' -or $c -cmatch 'HTML\.raw\(')) { & $flag 'raw' $i }
        if ($Ctx.HasScope -and $c -cmatch '(@|assigns\.)current_user([^A-Za-z0-9_]|$)') { & $flag 'curuser' $i }

        if ($kind -ceq 'ex') {
            if ($c -cmatch '^\s*defmodule\s') { $lastName = ''; $implPending = $false }
            elseif ($isdef) {
                $dh = Get-DefHead $c
                $dhName = $dh[0]; $dhArity = [int]$dh[1]
                $same = ($dhName -ceq $lastName -and ($dhArity -eq $lastArity -or $dhArity -lt 0 -or $lastArity -lt 0))
                if ($c -cmatch '^\s*def\s+(mount|handle_params|handle_event|handle_info|handle_call|handle_cast|handle_continue|handle_async|terminate)\(' -and -not $same -and -not $implPending) { & $flag 'impl' $i }
                $lastName = $dhName; $lastArity = $dhArity; $implPending = $false
            }
            elseif ($c -cmatch '^\s*@impl(\s|$)') { $implPending = $true }
            elseif ($c -cmatch '^\s*@') { }
            else { $implPending = $false }
        }

        if ($Ctx.IsMigration) {
            if ($c -cmatch '(create|create_if_not_exists|alter)\s*\(?\s*table\(') {
                $curTable = Get-Capture $c 'table\(\s*:?"?[A-Za-z0-9_]+' '^table\(\s*:?"?'
            }
            if ($c -cmatch '(add|add_if_not_exists|modify)\s+:?[A-Za-z0-9_]+,\s*references\(') {
                $col = Get-Capture $c '(add|add_if_not_exists|modify)\s+:?[A-Za-z0-9_]+' '^(add|add_if_not_exists|modify)\s+:?'
                [void]$refs.Add(@($curTable, $col, $i))
                $buf = $c
                $depth = ([regex]::Matches($buf, '\(')).Count - ([regex]::Matches($buf, '\)')).Count
                for ($j = $i + 1; $depth -gt 0 -and $j -le $n -and $j -le $i + 6; $j++) {
                    $buf = $buf + ' ' + $code[$j]
                    $depth += ([regex]::Matches($code[$j], '\(')).Count - ([regex]::Matches($code[$j], '\)')).Count
                }
                if ($buf -cnotmatch 'on_delete:') { & $flag 'ondelete' $i }
            }
            if ($c -cmatch '(unique_)?index\(\s*:?"?[A-Za-z0-9_]+"?\s*,\s*\[?\s*:?"?[A-Za-z0-9_]+') {
                $t = Get-Capture $c 'index\(\s*:?"?[A-Za-z0-9_]+"?\s*,\s*\[?\s*:?"?[A-Za-z0-9_]+' '^index\(\s*:?"?'
                $parts = [regex]::Split($t, '"?\s*,\s*\[?\s*:?"?')
                [void]$idx.Add("$($parts[0])`0$($parts[1])")
            }
        }
    }
    if ($Ctx.IsMigration) {
        foreach ($r in $refs) {
            if (-not $idx.Contains("$($r[0])`0$($r[1])")) { & $flag 'migidx' $r[2] }
        }
    }

    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($id in $where.Keys) {
        $w = $where[$id]
        $word = if ($w.Contains(',')) { 'lines' } else { 'line' }
        $out.Add("$($script:Tier[$id])`t$($script:Msg[$id]) ($word $w)")
    }
    return ,$out
}

function Invoke-Edit($ToolArgs, [string]$Cwd) {
    $file = Get-FirstString $ToolArgs @('file_path', 'filePath', 'path')
    if (-not $file) { exit 0 }
    if (-not [System.IO.Path]::IsPathRooted($file)) { $file = Join-Path $Cwd $file }
    $norm = $file -replace '\\', '/'
    if ($norm -like '*/deps/*' -or $norm -like '*/_build/*' -or $norm -like '*/node_modules/*' -or $norm -like '*/.elixir_ls/*') { exit 0 }
    if ($norm -like '*_test.exs' -or $norm -like '*/test/*') { exit 0 }
    if ($norm -like '*.ex') { $kind = 'ex' } elseif ($norm -like '*.exs') { $kind = 'exs' } elseif ($norm -like '*.heex') { $kind = 'heex' } else { exit 0 }
    $ctx = @{
        Kind = $kind
        IsMigration = ($norm -like '*/migrations/*.exs')
        SkipInspect = ($norm -like '*/mix/tasks/*')
        IsLive = ($norm -like '*_live.ex' -or $norm -like '*/live/*')
        HasScope = $false
    }

    # edit: list of @{old; new; all}; write: whole new content
    $mode = $null; $edits = @(); $content = ''
    $editsProp = Get-Prop $ToolArgs 'edits'
    if ((Test-Prop $ToolArgs 'edits') -and ($editsProp -is [array])) {
        $mode = 'edit'
        foreach ($e in $editsProp) {
            $edits += ,@{ old = (Get-FirstString $e @('old_string', 'oldString', 'old_str')); new = (Get-FirstString $e @('new_string', 'newString', 'new_str')); all = ((Get-Prop $e 'replace_all') -eq $true) }
        }
    } elseif ((Test-Prop $ToolArgs 'new_string') -or (Test-Prop $ToolArgs 'newString') -or (Test-Prop $ToolArgs 'new_str')) {
        $mode = 'edit'
        $edits = @(,@{ old = (Get-FirstString $ToolArgs @('old_string', 'oldString', 'old_str')); new = (Get-FirstString $ToolArgs @('new_string', 'newString', 'new_str')); all = ((Get-Prop $ToolArgs 'replace_all') -eq $true) })
    } elseif ((Test-Prop $ToolArgs 'content') -or (Test-Prop $ToolArgs 'file_text')) {
        $mode = 'write'
        $content = Get-FirstString $ToolArgs @('content', 'file_text')
    } else { exit 0 }
    $news = @($edits | ForEach-Object { $_.new })

    $note = ''
    $exists = Test-Path -LiteralPath $file -PathType Leaf
    if ($Phase -ceq 'pre') {
        if ($mode -ceq 'write') {
            if ($content -eq '') { exit 0 }
            $scan = $content
            if ($exists) { $ranges = Get-NewLines ([System.IO.File]::ReadAllText($file)) $scan } else { $ranges = 'ALL' }
        } else {
            $ranges = 'NONE'
            $sim = $null
            if ($exists) {
                $sim = [System.IO.File]::ReadAllText($file)
                foreach ($e in $edits) {
                    if ($null -eq $sim -or $e.old -eq '') { $sim = $null; break }
                    $p = Split-Ordinal $sim $e.old
                    if ($p.Length -lt 2) { $sim = $null; break }
                    if ($e.all) { $sim = $p -join $e.new }
                    else { $sim = $p[0] + $e.new + (($p[1..($p.Length - 1)]) -join $e.old) }
                }
            }
            if ($null -ne $sim) {
                $scan = $sim
                $ranges = Get-LocatedLines $scan $news
            } else {
                # can't reproduce the edit: scan the new text on its own
                $scan = (@($news | Where-Object { $_ -ne '' }) -join "`n")
                if ($scan -ne '') { $ranges = 'ALL' }
                $note = ' (line numbers count from the start of the new text)'
            }
        }
    } else {
        if (-not $exists) { exit 0 }
        $scan = [System.IO.File]::ReadAllText($file)
        if ($mode -ceq 'write') { $ranges = Get-GitAddedLines $file } else { $ranges = Get-LocatedLines $scan $news }
    }
    if (-not $ranges) { $ranges = 'ALL' }
    if ($ranges -ceq 'NONE') { exit 0 }

    if ($scan.Contains('current_user') -and (Test-ProjectHasScope $file)) { $ctx.HasScope = $true }

    $findings = Invoke-Checks $scan $ranges $ctx
    if ($findings.Count -eq 0) { exit 0 }
    $block = @($findings | Where-Object { $_.StartsWith("block`t") } | ForEach-Object { '- ' + $_.Substring(6) })
    $review = @($findings | Where-Object { $_.StartsWith("review`t") } | ForEach-Object { '- ' + $_.Substring(7) })
    $nl = "`n"

    if ($Phase -ceq 'pre') {
        if ($block.Count -eq 0) { exit 0 }
        $text = "elixir-phoenix-guide blocked this write to $file$note`:" + $nl + ($block -join $nl)
        if ($review.Count -gt 0) { $text += $nl + 'Also review (may be intentional):' + $nl + ($review -join $nl) }
        Exit-Deny ($text + $nl + 'Fix these and write the file again.')
    }

    $text = "elixir-phoenix-guide review notes for $file (lines just written; fix or confirm they are intentional):"
    if ($block.Count -gt 0) {
        $text += $nl + 'Must fix:' + $nl + ($block -join $nl)
        if ($review.Count -gt 0) { $text += $nl + 'Also review (may be intentional):' + $nl + ($review -join $nl) }
    } else {
        $text += $nl + ($review -join $nl)
    }
    Exit-Advise $text
}

# --- main: any unexpected error fails open ---------------------------------
try {
    if (-not $Phase -or -not $Type) { exit 0 }
    try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw -or -not $raw.Trim()) { exit 0 }
    try { $hook = $raw | ConvertFrom-Json } catch { exit 0 }
    if (-not ($hook -is [System.Management.Automation.PSCustomObject])) { exit 0 }

    $toolArgs = Get-Prop $hook 'tool_input'
    if ($null -eq $toolArgs -or ($toolArgs -is [bool] -and -not $toolArgs)) { $toolArgs = Get-Prop $hook 'toolArgs' }
    if ($toolArgs -is [string]) {
        try { $toolArgs = $toolArgs | ConvertFrom-Json } catch { $toolArgs = $null }
    }
    if (-not ($toolArgs -is [System.Management.Automation.PSCustomObject])) { exit 0 }

    $cwd = Get-Prop $hook 'cwd'
    if (-not ($cwd -is [string]) -or -not $cwd -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { $cwd = $PWD.Path }

    switch -CaseSensitive ("${Phase}_${Type}") {
        'pre_bash'  { Invoke-BashPre $toolArgs $cwd }
        'pre_edit'  { Invoke-Edit $toolArgs $cwd }
        'post_edit' { Invoke-Edit $toolArgs $cwd }
    }
    exit 0
} catch {
    exit 0
}

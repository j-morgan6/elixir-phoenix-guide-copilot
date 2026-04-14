# elixir-hook.ps1 — Elixir/Phoenix guard hooks for Copilot plugin (PowerShell)
#
# Called by Copilot's PreToolUse/PostToolUse hooks (configured in hooks.json).
# Receives hook JSON on stdin, runs Elixir/Phoenix code checks.
#
# Usage: echo '{"tool_input":{"command":"..."}}' | powershell -File elixir-hook.ps1 <pre|post> <bash|edit>
#
# Exit codes:
#   0 — Allow (with optional advisory message on stderr)
#   2 — Deny (block the tool call in PreToolUse context)

param(
    [string]$Phase,
    [string]$Type
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginRoot = Split-Path -Parent $ScriptDir

# Exit early if missing arguments
if (-not $Phase -or -not $Type) { exit 0 }

# Read hook input from stdin
$RawInput = $input | Out-String
if (-not $RawInput) { exit 0 }

try {
    $HookInput = $RawInput | ConvertFrom-Json
} catch {
    exit 0
}

# Extract tool args
$ToolArgs = if ($HookInput.tool_input) { $HookInput.tool_input } elseif ($HookInput.toolArgs) { $HookInput.toolArgs } else { $null }
$Cwd = if ($HookInput.cwd) { $HookInput.cwd } else { "" }

# Use CWD from JSON if available, fall back to PWD
$ProjectDir = if ($Cwd) { $Cwd } else { $PWD.Path }

# --- Lazy project detection ---
$CacheFile = Join-Path $ProjectDir ".elixir-phoenix-guide-project.json"
$DetectScript = Join-Path $PluginRoot "scripts/detect_project.sh"
if (-not (Test-Path $CacheFile) -and (Test-Path $DetectScript)) {
    try {
        Push-Location $ProjectDir
        bash $DetectScript 2>$null
        Pop-Location
    } catch {
        Pop-Location
    }
}

# Read project cache for context-aware checks
$HasLV = "true"
$HasScope = "false"
if (Test-Path $CacheFile) {
    try {
        $CacheContent = Get-Content $CacheFile -Raw | ConvertFrom-Json
        if ($null -ne $CacheContent.has_liveview) { $HasLV = $CacheContent.has_liveview.ToString().ToLower() }
        if ($null -ne $CacheContent.phoenix_has_scope) { $HasScope = $CacheContent.phoenix_has_scope.ToString().ToLower() }
    } catch {}
}

# ============================================================
# PreToolUse — Bash checks
# ============================================================
function Check-BashPre {
    if (-not $ToolArgs) { exit 0 }
    $cmd = if ($ToolArgs.command) { $ToolArgs.command } else { "" }
    if (-not $cmd) { exit 0 }

    # Hook 1: Block mix ecto.reset
    if ($cmd -match 'mix\s+ecto\.reset') {
        Write-Error 'Dangerous: mix ecto.reset destroys and recreates the database. Use mix ecto.rollback for safe rollbacks.'
        exit 2
    }

    # Hook 2: Block force push
    if ($cmd -match 'git\s+push\s+.*(-f|--force)') {
        Write-Error 'Dangerous: Force push overwrites remote history. Use --force-with-lease for safer force pushes.'
        exit 2
    }

    # Hook 3: Block MIX_ENV=prod
    if ($cmd -match 'MIX_ENV=prod') {
        Write-Error 'Dangerous: Running with MIX_ENV=prod locally risks unintended production effects.'
        exit 2
    }

    exit 0
}

# ============================================================
# PreToolUse — Write/Edit checks
# ============================================================
function Check-EditPre {
    if (-not $ToolArgs) { exit 0 }
    $filePath = if ($ToolArgs.file_path) { $ToolArgs.file_path } else { "" }
    if (-not $filePath) { exit 0 }

    $ext = [System.IO.Path]::GetExtension($filePath).TrimStart('.')
    $isTest = $filePath -match '_test\.exs$|/test/'

    # Only check Elixir/HEEx files
    if ($ext -notin @('ex', 'exs', 'heex')) { exit 0 }

    # Get file content (new_string for Edit, content for Write, or read existing file)
    $content = ""
    if ($ToolArgs.new_string) { $content = $ToolArgs.new_string }
    elseif ($ToolArgs.content) { $content = $ToolArgs.content }
    # Fallback: read the file
    if (-not $content -and (Test-Path $filePath)) {
        $content = Get-Content $filePath -Raw -ErrorAction SilentlyContinue
    }
    if (-not $content) { exit 0 }

    # Strip comments for analysis
    $filtered = ($content -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

    # --- Blocking checks (exit 2) ---

    # Hook: Missing @impl true before callbacks
    if ($HasLV -ne 'false') {
        if ($filtered -match 'def\s+(mount|handle_event|handle_info|handle_call|handle_cast|render|init|terminate)\(' -and
            $filtered -notmatch '@impl[\s\S]{0,20}def\s+(mount|handle_event|handle_info|handle_call|handle_cast|render|init|terminate)\(') {
            # More thorough check: look for @impl on the line before each callback
            $lines = $filtered -split "`n"
            $missingImpl = $false
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match 'def\s+(mount|handle_event|handle_info|handle_call|handle_cast|render|init|terminate)\(') {
                    if ($i -eq 0 -or $lines[$i - 1] -notmatch '@impl') {
                        $missingImpl = $true
                        break
                    }
                }
            }
            if ($missingImpl) {
                Write-Error 'Missing @impl true before callback function. Add @impl true on the line before each callback.'
                exit 2
            }
        }
    }

    # Hook: Hardcoded file paths
    if ($content -match '(upload_path|file_path|uploads_dir)\s*=\s*["''](/|priv/)') {
        Write-Error 'Hardcoded file path detected. Move to Application config: config :my_app, :upload_path, "priv/static/uploads"'
        exit 2
    }

    # Hook: Hardcoded file size limits
    if ($content -match '(max_file_size|file_size_limit|max_upload|max_size)\s*=\s*[0-9]{7,}') {
        Write-Error 'Hardcoded file size limit detected (7+ digits). Move to Application config.'
        exit 2
    }

    # Hook: Block String.to_atom/1 (security — not in test files)
    if (-not $isTest -and $ext -ne 'heex') {
        if ($content -match 'String\.to_atom\(') {
            Write-Error 'String.to_atom/1 detected — atom table exhaustion risk! Use a whitelist or keep as strings.'
            exit 2
        }
    }

    # Hook: Block SQL injection in fragment
    if (-not $isTest -and $ext -ne 'heex') {
        if ($content -match 'fragment\(".*#\{') {
            Write-Error 'String interpolation inside Ecto fragment — SQL injection risk! Use parameterized fragments with ? placeholders.'
            exit 2
        }
    }

    # Hook: Block open redirect
    if (-not $isTest -and $ext -ne 'heex') {
        if ($content -match 'redirect\(.*to:\s*(params|conn\.params|socket\.assigns)\[') {
            Write-Error 'Open redirect detected — redirecting to user-controlled URL! Validate against a whitelist or use verified routes.'
            exit 2
        }
    }

    # Hook: Block deprecated Phoenix components
    if ($content -match '<\.(flash_group|flash)') {
        Write-Error '.flash_group is deprecated in Phoenix 1.8+. Flash handling is automatic in layouts.'
        exit 2
    }
    if ($content -match 'form_for\(') {
        Write-Error 'form_for is deprecated. Use <.form for={to_form(@changeset)}> instead.'
        exit 2
    }
    if ($content -match 'live_redirect|live_patch') {
        Write-Error 'live_redirect/live_patch are deprecated. Use <.link navigate={path}> or push_navigate/push_patch.'
        exit 2
    }
    if ($HasScope -eq 'true' -and ($content -match '@current_user|current_user') -and ($content -notmatch '@current_scope|current_scope')) {
        Write-Error 'Phoenix 1.8+ detected: Use @current_scope instead of @current_user. Access user via @current_scope.user'
        exit 2
    }

    # Hook: Block static_paths mismatch
    if ($content -match 'def static_paths') {
        $pathsMatch = [regex]::Matches($content, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        $refsMatch = [regex]::Matches($content, '/([a-z_]+)/') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        foreach ($ref in $refsMatch) {
            if ($pathsMatch -notcontains $ref) {
                Write-Error "Path reference '/$ref/' found but '$ref' not in static_paths(). Add it to your static_paths definition."
                exit 2
            }
        }
    }

    # Hook: Block raw SQL with string interpolation
    if (-not $isTest -and $ext -ne 'heex') {
        if ($content -match 'Ecto\.Adapters\.SQL\.(query|query!)|SQL\.query') {
            if ($content -match '".*#\{.*\}.*"|".*\$\{.*\}.*"' -or $content -match 'query.*<>|<>.*query') {
                Write-Error 'Raw SQL with string interpolation detected — SQL injection risk! Use parameterized queries ($1, $2, ...).'
                exit 2
            }
        }
    }

    # --- Warning checks (exit 0 with message) ---

    # Hook: Nested if/else
    $collapsed = $content -replace "`n", " "
    if ($collapsed -match 'if\s+[^d]+\s+do\s+[^e]*if\s+[^d]+\s+do') {
        Write-Error 'Warning: Nested if/else detected. Replace with case or multi-clause function.'
    }

    # Hook: Inefficient Enum chains
    if ($collapsed -match '\|>\s*Enum\.(map|filter)\([^)]+\)\s*\|>\s*Enum\.(map|filter)\(') {
        Write-Error 'Warning: Multiple Enum.map/filter chain detected. Use a for comprehension or combine into one pass.'
    }

    # Hook: String concatenation in loops
    if ($content -match 'Enum\.(map|reduce|each).*<>') {
        Write-Error 'Warning: String concatenation with <> in Enum operations. Use IO lists or Enum.join.'
    }

    # Hook: auto_upload warning
    if ($HasLV -ne 'false' -and ($content -match 'auto_upload:\s*true')) {
        Write-Error 'Warning: auto_upload: true detected. Requires handle_progress/3. Most apps should use manual upload.'
    }

    # Hook: Debug statements (not in test files)
    if (-not $isTest -and $ext -ne 'heex') {
        if ($content -match 'IO\.inspect\(|dbg\(|IO\.puts\(') {
            Write-Error 'Warning: Debug statement detected (IO.inspect, dbg, or IO.puts). Remove before committing.'
        }
    }

    # Hook: Migration safety check
    if ($filePath -match 'migrations/.*\.exs$') {
        $issues = ""
        if ($content -match 'references\(' -and $content -notmatch 'create\s+(unique_)?index') {
            $issues += "`n   - Missing index on foreign key column(s)"
        }
        if ($content -match 'references\(' -and $content -notmatch 'on_delete:') {
            $issues += "`n   - Missing on_delete strategy on references()"
        }
        if ($content -match 'remove\s+:' -and $content -notmatch '#.*safety|#.*two-step|#.*deploy') {
            $issues += "`n   - Removing column without safety comment. Use a two-step migration."
        }
        if ($content -match 'modify.*null:\s*false' -and $content -notmatch 'default:') {
            $issues += "`n   - Adding NOT NULL without default. This locks the table on large datasets."
        }
        if ($issues) {
            Write-Error "Warning: Migration Safety Check:$issues"
        }
    }

    # Hook: Warn on raw/1 (XSS) — not in test files
    if (-not $isTest) {
        if ($content -match '(^|[^a-zA-Z_])raw\(|Phoenix\.HTML\.raw\(') {
            Write-Error 'Warning: raw/1 detected — XSS risk! Remove raw/1 and let Phoenix auto-escape, or sanitize with HtmlSanitizeEx.'
        }
    }

    # Hook: Sensitive data in Logger
    if (-not $isTest -and $ext -ne 'heex') {
        if ($content -match 'Logger\.(info|warn|warning|error|debug|notice)\(.*\b(password|token|secret|api_key|credentials|private_key)\b') {
            Write-Error 'Warning: Sensitive data in Logger call detected! Redact before logging.'
        }
    }

    # Hook: Timing-unsafe comparison
    if (-not $isTest -and $ext -ne 'heex') {
        if ($content -match '(token|secret|api_key|password_hash|digest|signature)\s*==\s*|==\s*(token|secret|api_key|password_hash|digest|signature)') {
            Write-Error 'Warning: Timing-unsafe comparison with secret/token! Use Plug.Crypto.secure_compare/2.'
        }
    }

    exit 0
}

# ============================================================
# PostToolUse — Write/Edit checks (advisory only)
# ============================================================
function Check-EditPost {
    if (-not $ToolArgs) { exit 0 }
    $filePath = if ($ToolArgs.file_path) { $ToolArgs.file_path } else { "" }
    if (-not $filePath) { exit 0 }

    $ext = [System.IO.Path]::GetExtension($filePath).TrimStart('.')
    $isTest = $filePath -match '_test\.exs$|/test/'

    # Hook: Skill invocation reminder (Elixir/HEEx files only)
    if ($ext -in @('ex', 'exs', 'heex')) {
        if ($HasLV -eq 'false') {
            Write-Error 'Reminder: API-only project detected (no LiveView). LiveView skills/hooks are inactive. Did you invoke the relevant elixir-phoenix-guide skill?'
        } else {
            Write-Error 'Reminder: Did you invoke the relevant elixir-phoenix-guide skill before writing this file? If not, invoke it now and verify your code follows the rules.'
        }
    }

    # Hook: mix.exs security audit reminder
    if ($filePath -match 'mix\.exs$') {
        Write-Error 'Dependencies file (mix.exs) modified. Consider running: mix deps.audit, mix hex.audit, mix sobelow'
    }

    # Hook: Template duplication (HEEx files)
    $DuplicationScript = Join-Path $PluginRoot "scripts/detect_template_duplication.sh"
    if ($ext -eq 'heex' -and (Test-Path $DuplicationScript)) {
        try { bash $DuplicationScript $filePath 2>$null } catch {}
        exit 0
    }

    # Only continue for .ex/.exs files
    if ($ext -notin @('ex', 'exs')) { exit 0 }

    $content = ""
    if (Test-Path $filePath) {
        $content = Get-Content $filePath -Raw -ErrorAction SilentlyContinue
    }
    if (-not $content) { exit 0 }

    # Hook: Code quality analysis (if Elixir is available)
    $QualityScript = Join-Path $PluginRoot "scripts/code_quality.exs"
    if ((Get-Command elixir -ErrorAction SilentlyContinue) -and (Test-Path $QualityScript)) {
        try { elixir $QualityScript all $filePath 2>$null } catch {}
    }

    # Hook: Missing preload warning (not in test files)
    if (-not $isTest) {
        if ($content -match '\.(posts|comments|users|items|entries|tasks|categories|tags|orders|products|messages|notifications|accounts|roles|permissions|memberships|addresses|invoices|images|attachments|events|sessions|tokens)\b' -and
            $content -notmatch 'preload|Repo\.preload|from.*preload|join.*assoc') {
            Write-Error 'Warning: Possible missing preload — association accessor found without a visible preload.'
        }
    }

    # Hook: with missing else clause
    if ($content -match 'with\s' -and $content -notmatch 'with.*do.*else|else\s*do') {
        $collapsed = $content -replace "`n", " "
        if ($collapsed -match 'with\s+[^}]+<-[^}]+do\s+[^}]+end' -and
            $collapsed -notmatch 'with\s+[^}]+<-[^}]+do\s+[^}]+else[^}]+end') {
            Write-Error 'Warning: with statement without else clause. Add an else clause to handle errors.'
        }
    }

    # Hook: Repo calls in LiveView (context boundary violation)
    if ($HasLV -ne 'false') {
        if ($filePath -match '_live\.ex$|_live/|live/') {
            if ($content -match 'Repo\.(all|one|get|get!|get_by|insert|update|delete|aggregate|exists\?|preload)') {
                Write-Error 'Warning: Context boundary violation — Repo called directly in a LiveView module. Use context functions instead.'
            }
        }
    }

    exit 0
}

# --- Route to appropriate checks ---
$RouteKey = "${Phase}_${Type}"
switch ($RouteKey) {
    "pre_bash"  { Check-BashPre }
    "pre_edit"  { Check-EditPre }
    "post_edit" { Check-EditPost }
    default     { exit 0 }
}

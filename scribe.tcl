#!/usr/bin/env wish9.0
package require Tk 9

# Scribe — take text you type, dictate, or hold on the clipboard, optionally
# restyle it, and deliver it by typing, pasting, or leaving it on the clipboard.
#
# Behaviour is five independent axes; reading the flags tells the whole story:
#   --input  keyboard | voice | clipboard  where the text comes from (default keyboard)
#   --window | --no-window                 review window, or unattended
#   --deliver type | paste | clipboard | stdout   how the result leaves (stdout: print it)
#   --style                                (no-window) style the text; a window always offers styling
#   --quotes double|single|straight  --dialect off|british   normalisation
#
# With no --input, scribe opens an empty editable window and waits for you to
# type. Legacy tools are presets:
#   dictate            : --input voice --no-window --deliver type
#   dictate-stylist    : --input voice --window --style --auto-style-delay 1000 --deliver paste
#   language-stylist   : --input clipboard --window --style --auto-style-delay 1 --deliver clipboard
#
# Bind presets to GNOME custom shortcuts launching the custom Wayland wish with
# LD_LIBRARY_PATH set, the way the companion dictation tool is bound.
#
# Requires: whisper-cli plus per-platform helpers.
#   Recording : pw-record (PipeWire, Linux; sox as fallback); sox (macOS).
#   Keystrokes: dotool (Linux, uinput); osascript System Events (macOS).
#   Clipboard : wl-copy under Wayland, xclip under X11, pbcopy on macOS.
#
# The style pass is optional. AI providers are configured in config.ini
# (~/.config/scribe/config.ini): a [provider.NAME] section per provider plus a
# top-level default_provider; --provider NAME overrides the default. With no
# config and no keys, scribe still runs as a dictation tool — the style pass and
# the styled review pane are simply absent (see CLAUDE.md).

#==============================================================================
# CONFIGURATION
#==============================================================================

set ::APP_DIR          [file dirname [file normalize [info script]]]
set ::DEEPSEEK_CONFIG  [file join $::APP_DIR "deepseek.json"]
set ::STYLES_DIR       [file join $::APP_DIR "styles"]
set ::SYSTEM_PROMPTS   [file join $::APP_DIR "system-prompts.yaml"]
set ::CONFIG_FILE      [file join $::APP_DIR "current-mode.conf"]
set ::STATE_STYLE_FILE [file join [expr {[info exists ::env(XDG_STATE_HOME)] && $::env(XDG_STATE_HOME) ne "" ? $::env(XDG_STATE_HOME) : "$::env(HOME)/.local/state"}] scribe style]
set ::STATE_PIPELINE_FILE [file join [file dirname $::STATE_STYLE_FILE] pipeline]
set ::DIALECT_FILE     [file join $::APP_DIR "dialect-us-to-british.tsv"]
set ::LOG_DIR          /var/local/log/dictation
set ::CACHE_DIR        [file join [expr {[info exists ::env(XDG_CACHE_HOME)] && $::env(XDG_CACHE_HOME) ne "" ? $::env(XDG_CACHE_HOME) : "$::env(HOME)/.cache"}] scribe]

set ::VERSION          0.6.2
set ::PORT             4212
set ::SOCKET_TIMEOUT_MS 2000   ;# second-press protocol deadline, both sides
set ::APPNAME          "scribe-[pid]"
set ::MACOS            [expr {$::tcl_platform(os) eq "Darwin"}]

# --- axes ---
set ::INPUT            ""          ;# keyboard | voice | clipboard ("" -> keyboard)
set ::WINDOW           1
set ::DELIVER          paste       ;# type | paste | clipboard
set ::STYLE_ON         0
set ::STYLE_NAME       ""
set ::STYLE_AUTO       ""          ;# "" = manual; integer ms = auto after delay
set ::QUOTES           ""          ;# "" = unset (resolve from dialect) | double | single | straight
set ::QSTYLE           double      ;# resolved: double | single | straight
set ::DIALECT          off         ;# off | british

# --- whisper / recording ---
set ::MODEL            ""          ;# whisper model path; set by --model or [whisper] model (no built-in default)
set ::LANG             en
set ::TIMEOUT_S        300
set ::THREADS          4
set ::CAPTURE          ""
set ::PROMPT           ""
set ::NO_FALLBACK      1
set ::NO_GPU           0
set ::FLASH_ATTN       0
set ::NO_FLASH_ATTN    0
set ::PRINT_SPECIAL    0
# Transcription backend: local whisper-cli (default) or a whisper.cpp server.
set ::WHISPER_SERVER   ""          ;# base URL; empty = local whisper-cli
set ::WHISPER_FALLBACK ""          ;# "" until resolved; 1 = run whisper-cli if the server fails
set ::WHISPER_TIMEOUT_S 120        ;# whole server request cap (seconds)
set ::WHISPER_CONNECT_TIMEOUT_S 5  ;# fail fast when the server is unreachable
set ::KEY_DELAY        2
set ::WORD_DELAY       100
set ::CMD              stop
set ::debug_mode       0

# --- paste/enter (window UI trick) ---
set ::PASTE_KEY          "key ctrl+v"
set ::ENTER_KEY          "key enter"
set ::PASTE_ENTER_GAP_MS 100

# --- test hooks ---
set ::TEST_TEXT        ""
set ::TEST_FILE        ""
set ::SELF_TEST        0

# --- AI provider (resolved from config.ini; optional) ---
set ::PROVIDER     ""        ;# CLI override of which [provider.NAME] to use
set ::AI_AVAILABLE 0         ;# 1 once a provider with an api_key resolves
set ::apiKey  ""
set ::apiBase ""
set ::apiModel ""
set ::UNLOAD_AFTER 0         ;# provider opt-in: drop the model from VRAM after a successful style pass
set ::apiThinkingModel ""    ;# optional; 1-pass mode falls back to ::apiModel
set ::userTextPrefix   ""
set ::singlePassPrefix ""
set ::preprocessPrefix ""
set ::mergedPassPrefix ""
set ::styleGuide       ""
set ::PASSES           2     ;# 1 | 2 rewrite calls when a style is picked; loadPasses applies the persisted pick

# --- runtime ---
set ::recorder_pid  0
set ::tmpfile       ""
set ::log_stem      ""
set ::auto_stop_id  ""
set ::poll_id       ""
set ::wdog_id       ""          ;# local-transcription watchdog timer
set ::wchan         ""          ;# transcription pipe (whisper-cli or curl)
set ::transcribe_ms 0           ;# when the transcription attempt began
set ::capture_sink  launch      ;# launch: transcript builds/fills the window; window: it lands in the open pane
set ::win_pulse_id  ""          ;# in-window recording indicator pulse timer
set ::start_ms      0
set ::state         idle
set ::done          0
set ::httpToken     ""
set ::autosend_id   ""
set ::inject_pid    0
set ::inject_id     ""
set ::ukmap         ""
set ::clipBackend   ""          ;# resolved once: wayland (wl-copy) | x11 (xclip)

# --- review ---
set ::sourceText     ""
set ::rewriteText    ""
set ::preprocessText ""         ;# 2-pass: output of the preprocess call
set ::pipelineModel  ""         ;# model the current pipeline runs (1-pass may pick thinking_model)
set ::activeArea     1
set ::rewriteState   idle

#==============================================================================
# ARGUMENT PARSING
#==============================================================================

proc fatal {msg} { catch {exec logger -t scribe -p user.err -- $msg}; puts stderr "scribe: $msg"; exit 1 }

set prompt_seen 0
for {set i 0} {$i < [llength $::argv]} {incr i} {
    set arg [lindex $::argv $i]
    switch -- $arg {
        --input            { set ::INPUT [lindex $::argv [incr i]] }
        --window           { set ::WINDOW 1 }
        --no-window        { set ::WINDOW 0 }
        --deliver          { set ::DELIVER [lindex $::argv [incr i]] }
        --style            { set ::STYLE_ON 1 }
        --auto-style-delay { set ::STYLE_ON 1; set ::STYLE_AUTO [lindex $::argv [incr i]] }
        --quotes           { set ::QUOTES [lindex $::argv [incr i]] }
        --dialect          { set ::DIALECT [lindex $::argv [incr i]] }
        --provider         { set ::PROVIDER [lindex $::argv [incr i]] }
        -m  - --model      { set ::MODEL     [lindex $::argv [incr i]] }
        -l  - --language   { set ::LANG      [lindex $::argv [incr i]] }
        -t  - --threads    { set ::THREADS   [lindex $::argv [incr i]] }
        -c  - --capture    { set ::CAPTURE   [lindex $::argv [incr i]] }
        -to - --timeout    { set ::TIMEOUT_S [lindex $::argv [incr i]] }
        --key-delay        { set ::KEY_DELAY  [lindex $::argv [incr i]] }
        --word-delay       { set ::WORD_DELAY [lindex $::argv [incr i]] }
        --prompt {
            if {$prompt_seen} { fatal "--prompt and --prompt-file are mutually exclusive" }
            set prompt_seen 1; set ::PROMPT [lindex $::argv [incr i]]
        }
        --prompt-file {
            if {$prompt_seen} { fatal "--prompt and --prompt-file are mutually exclusive" }
            set prompt_seen 1
            set pf [lindex $::argv [incr i]]
            if {[catch {set fh [open $pf r]; set ::PROMPT [string trim [read $fh]]; close $fh} err]} {
                fatal "cannot read --prompt-file $pf: $err"
            }
        }
        -nf  - --no-fallback   { set ::NO_FALLBACK 1 }
        -ng  - --no-gpu        { set ::NO_GPU 1 }
        -fa  - --flash-attn    { set ::FLASH_ATTN 1 }
        -nfa - --no-flash-attn { set ::NO_FLASH_ATTN 1 }
        -ps  - --print-special { set ::PRINT_SPECIAL 1 }
        --whisper-server      { set ::WHISPER_SERVER [lindex $::argv [incr i]] }
        --whisper-fallback    { set ::WHISPER_FALLBACK 1 }
        --no-whisper-fallback { set ::WHISPER_FALLBACK 0 }
        --debug      { set ::debug_mode 1 }
        --self-test  { set ::SELF_TEST 1 }
        --test-text  { set ::TEST_TEXT [lindex $::argv [incr i]] }
        -tf - --test-file { set ::TEST_FILE [lindex $::argv [incr i]] }
        --cmd {
            set ::CMD [lindex $::argv [incr i]]
            if {$::CMD ni {stop status pause resume}} { fatal "--cmd must be stop|status|pause|resume" }
        }
        -v - --version { puts "scribe $::VERSION"; exit 0 }
        -h - --help {
            puts "Usage: scribe \[options\]"
            puts "  --input keyboard|voice|clipboard  source (default keyboard; --no-window needs voice|clipboard)"
            puts "  --window | --no-window         draw the review window, or run unattended"
            puts "  --deliver type|paste|clipboard|stdout  how the result leaves (default paste; stdout prints it, for headless runs)"
            puts "  --style                        (no-window) style the text; a window offers styling whenever a provider is configured"
            puts "  --provider NAME                use \[provider.NAME\] from config.ini (else default_provider)"
            puts "  --auto-style-delay MS          (window) auto-style after MS ms; 1 = immediate"
            puts "  --quotes double|single|straight   double: “ ” · single: ‘ ’ · straight: ASCII"
            puts "  --dialect off|british          british: US→UK spelling; default quotes -> single"
            puts "  voice: -m -l -t -to -c --prompt|--prompt-file --key-delay --word-delay -nf -ng -fa -ps"
            puts "  --whisper-server URL           transcribe via a whisper.cpp server (else local whisper-cli)"
            puts "  --whisper-fallback             if the server fails, fall back to local whisper-cli"
            puts "  --cmd stop|status|pause|resume  --self-test --test-text S --test-file WAV"
            puts "  --debug                        keep the recording; write a replay .sh of the transcription call"
            exit 0
        }
        default { fatal "unknown argument: $arg" }
    }
}

proc dbg {msg} { if {$::debug_mode} { puts stderr "scribe \[debug\]: $msg" } }

# Log to the systemd journal under a stable tag and syslog priority, so errors
# are visible in normal mode with: journalctl -t scribe (e.g. -p err). Ubuntu's
# scope-launched apps already capture stderr, but untagged; logger gives the tag
# and level. Also echo to stderr for terminal runs. level: err|warning|notice|info.
proc logsys {level msg} {
    catch {exec logger -t scribe -p user.$level -- $msg}
    puts stderr "scribe: $msg"
}

# Last of whisper-cli's captured stderr, trimmed, for a failure log line.
proc whisper_stderr {} {
    if {![info exists ::werrfile] || ![file exists $::werrfile]} { return "" }
    set txt ""
    catch { set fh [open $::werrfile r]; set txt [read $fh]; close $fh }
    set txt [string trim $txt]
    if {[string length $txt] > 2000} { set txt "…[string range $txt end-1999 end]" }
    return $txt
}
# A short, plain-language dialog line for a whisper failure. The out-of-memory
# case is common and fixable, so name the fix; anything else points at the log,
# where ui_error has written the full backend output. "out of memory" is the
# wording CUDA, Vulkan, and Metal all use.
proc transcribe_error_msg {tail} {
    if {[string match -nocase "*out of memory*" $tail]} {
        return "Couldn't transcribe: the GPU ran out of memory.\n\nFree some VRAM (another model may be loaded), or start scribe with --no-gpu to transcribe on the CPU."
    }
    return "Couldn't transcribe the recording. The details were written to the log."
}
# The server counterpart: a remote failure has no GPU-OOM special case (the server
# owns its GPU), so point at the server and the log. Worded for any server failure
# (unreachable, error status, or bad body); the specific reason goes to the log via
# ui_error's detail, so this message does not use it.
proc transcribe_server_error_msg {_reason} {
    return "Couldn't get a transcription from the server at $::WHISPER_SERVER.\n\nIs whisper-server running and reachable there? The details were written to the log."
}

#==============================================================================
# CONFIG LOADING
#==============================================================================

# Minimal INI reader for scribe's config: [section] / [a.b] headers and
# key = value lines, values optionally "double" or 'single' quoted (a bare value
# has any trailing # comment stripped). Enough for provider sections plus the
# top-level default_provider. A deliberately small subset: no value continuation,
# # comments only, which is all scribe's config needs. Returns a dict keyed by section
# name (top-level keys live under ""), each value a dict of key->value.
proc parse_ini {data} {
    set sections [dict create "" [dict create]]
    set cur ""
    foreach raw [split $data \n] {
        set line [string trim $raw]
        if {$line eq "" || [string index $line 0] eq "#"} continue
        if {[regexp {^\[(.+)\]$} $line -> name]} {
            set cur [string trim $name]
            if {![dict exists $sections $cur]} { dict set sections $cur [dict create] }
            continue
        }
        if {[regexp {^([^=]+?)\s*=\s*(.+)$} $line -> k v]} {
            set v [string trim $v]
            if {[regexp {^"([^"]*)"\s*(?:#.*)?$} $v -> inner]} { set v $inner } \
            elseif {[regexp {^'([^']*)'\s*(?:#.*)?$} $v -> inner]} { set v $inner } \
            else { set v [string trim [regsub {\s+#.*$} $v ""]] }
            dict set sections $cur [string trim $k] $v
        }
    }
    return $sections
}

# Candidate config paths, in order: XDG user config, then the app dir (dev).
proc config_candidates {} {
    set xdg [expr {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne "" ? $::env(XDG_CONFIG_HOME) : "$::env(HOME)/.config"}]
    return [list [file join $xdg scribe config.ini] [file join $::APP_DIR config.ini]]
}

# Apply the [whisper] section (the transcription backend), independent of any AI
# provider. Called from loadConfig before its provider-selection returns, so it
# takes effect even when no provider is configured. Globals already set on the CLI
# win over config (left untouched here), matching --provider over default_provider.
proc applyWhisperConfig {ini} {
    if {![dict exists $ini whisper]} return
    set w [dict get $ini whisper]
    if {$::MODEL eq "" && [dict exists $w model]} {
        set ::MODEL [dict get $w model]
    }
    if {$::WHISPER_SERVER eq "" && [dict exists $w server_url]} {
        set ::WHISPER_SERVER [dict get $w server_url]
    }
    if {$::WHISPER_FALLBACK eq "" && [dict exists $w fallback_local]} {
        set ::WHISPER_FALLBACK [expr {[string is true -strict [dict get $w fallback_local]]}]
    }
}

# Resolve an AI provider from config.ini, if one is configured. This NEVER
# fatals: scribe must run as a dictation tool with no config and no keys (see
# CLAUDE.md). On success sets ::AI_AVAILABLE 1 and ::apiKey/::apiBase/::apiModel;
# otherwise leaves ::AI_AVAILABLE 0 and the style pass stays disabled.
proc loadConfig {} {
    set ::AI_AVAILABLE 0
    set ::UNLOAD_AFTER 0
    set path ""
    foreach c [config_candidates] { if {[file exists $c]} { set path $c; break } }
    if {$path eq ""} { loadLegacyDeepseek; return }

    if {[catch {set fh [open $path r]; set data [read $fh]; close $fh} err]} {
        logsys warning "cannot read config $path: $err — running without AI"; return
    }
    set ini [parse_ini $data]
    applyWhisperConfig $ini
    set providers [dict create]
    dict for {sec kv} $ini {
        if {[regexp {^provider\.(.+)$} $sec -> pname]} { dict set providers [string trim $pname] $kv }
    }
    set choice $::PROVIDER
    if {$choice eq "" && [dict exists $ini "" default_provider]} { set choice [dict get $ini "" default_provider] }
    if {$choice eq "" && [dict size $providers] == 1} { set choice [lindex [dict keys $providers] 0] }
    if {$choice eq ""} { dbg "no provider selected in $path — running without AI"; return }
    if {![dict exists $providers $choice]} {
        logsys warning "provider '$choice' not found in $path — running without AI"; return
    }
    set p [dict get $providers $choice]
    set ::apiKey   [expr {[dict exists $p api_key]  ? [dict get $p api_key]  : ""}]
    set ::apiBase  [expr {[dict exists $p api_base] ? [dict get $p api_base] : "https://api.deepseek.com"}]
    set ::apiModel [expr {[dict exists $p model]    ? [dict get $p model]    : "deepseek-chat"}]
    set ::UNLOAD_AFTER [expr {[dict exists $p unload_after_style] && [string is true -strict [dict get $p unload_after_style]]}]
    set ::apiThinkingModel [expr {[dict exists $p thinking_model] ? [dict get $p thinking_model] : ""}]
    if {$::apiKey ne ""} {
        set ::AI_AVAILABLE 1; dbg "provider = $choice ($path)"
    } else {
        logsys warning "provider '$choice' has no api_key — running without AI"
    }
}

# Backward compatibility: the pre-0.6.1 single-provider deepseek.json in the app
# dir, used when no config.ini is present.
proc loadLegacyDeepseek {} {
    if {![file exists $::DEEPSEEK_CONFIG]} return
    if {[catch {
        package require json
        set f [open $::DEEPSEEK_CONFIG r]; set data [read $f]; close $f
        set cfg [json::json2dict $data]
        set ::apiKey   [expr {[dict exists $cfg api_key]  ? [dict get $cfg api_key]  : ""}]
        set ::apiBase  [expr {[dict exists $cfg api_base] ? [dict get $cfg api_base] : "https://api.deepseek.com"}]
        set ::apiModel [expr {[dict exists $cfg model]    ? [dict get $cfg model]    : "deepseek-chat"}]
        if {$::apiKey ne ""} { set ::AI_AVAILABLE 1; dbg "provider = deepseek (legacy deepseek.json)" }
    } err]} { logsys warning "cannot read legacy deepseek.json: $err — running without AI" }
}

proc loadSystemPrompts {} {
    if {![file exists $::SYSTEM_PROMPTS]} { fatal "missing system-prompts.yaml" }
    if {[catch {
        package require yaml
        set f [open $::SYSTEM_PROMPTS r]; set data [read $f]; close $f
        set cfg [yaml::yaml2dict $data]
        set ::userTextPrefix   [expr {[dict exists $cfg user_text_prefix]   ? [dict get $cfg user_text_prefix]   : ""}]
        set ::singlePassPrefix [expr {[dict exists $cfg single_pass_prefix] ? [dict get $cfg single_pass_prefix] : ""}]
        set ::preprocessPrefix [expr {[dict exists $cfg preprocess_prefix]  ? [dict get $cfg preprocess_prefix]  : ""}]
        set ::mergedPassPrefix [expr {[dict exists $cfg merged_pass_prefix] ? [dict get $cfg merged_pass_prefix] : ""}]
    } err]} { fatal "error loading system-prompts.yaml: $err" }
}

proc loadStyle {} {
    set name $::STYLE_NAME
    if {$name eq ""} {
        # The window's own persisted pick wins; a mode-switcher default in
        # current-mode.conf applies when no state file exists; else "none".
        foreach src [list $::STATE_STYLE_FILE $::CONFIG_FILE] {
            if {$name ne ""} break
            if {[file exists $src]} {
                catch { set f [open $src r]; set name [string trim [read $f]]; close $f }
            }
        }
        if {$name eq ""} { set name "none" }
    }
    # "none" is the reserved No-style pick, not a style file: a Rewrite runs
    # the clean-up pass alone, so there is no guide to load.
    if {$name eq "none"} {
        set ::styleGuide ""
        set ::STYLE_NAME "none"
        dbg "style = none (clean-up only)"
        return
    }
    set path [file join $::STYLES_DIR "$name.txt"]
    if {![file exists $path]} {
        set files [lsort [glob -nocomplain -directory $::STYLES_DIR *.txt]]
        if {[llength $files] == 0} { fatal "no style files in $::STYLES_DIR" }
        set path [lindex $files 0]; set name [file rootname [file tail $path]]
    }
    set f [open $path r]; set ::styleGuide [read $f]; close $f
    set ::STYLE_NAME $name
    dbg "style = $name"
}

# Style names available to the picker: the basename of every styles/*.txt.
proc styleNames {} {
    set names {}
    foreach p [lsort [glob -nocomplain -directory $::STYLES_DIR *.txt]] {
        lappend names [file rootname [file tail $p]]
    }
    return $names
}

# Persist the window's style pick to the XDG state file (bare name, one line),
# separate from current-mode.conf so the external mode-switcher stays sole writer.
proc saveStyleChoice {name} {
    catch {
        file mkdir [file dirname $::STATE_STYLE_FILE]
        set f [open $::STATE_STYLE_FILE w]; puts -nonewline $f $name; close $f
    }
}

# The style radios set ::STYLE_NAME; reload the guide for it, persist the pick,
# and refresh the controls that depend on it. The pass itself runs only on a
# Rewrite click.
proc on_style_change {} {
    loadStyle
    saveStyleChoice $::STYLE_NAME
    refresh_rewrite_controls
}

# What a Rewrite click runs is picked by two independent, persisted choices.
#   style:  a styles/NAME.txt guide, or "none" for the clean-up pass alone
#           (repetitions merged, self-corrections resolved, points reordered)
#   passes: with a style picked, 2 = clean-up call, then the style call on the
#           repaired text; 1 = one merged call doing both, on thinking_model
#           when configured. Moot under "none": always the one clean-up call.

# The window's persisted passes pick (sibling of the style pick), default 2.
proc loadPasses {} {
    set v ""
    if {[file exists $::STATE_PIPELINE_FILE]} {
        catch { set f [open $::STATE_PIPELINE_FILE r]; set v [string trim [read $f]]; close $f }
    }
    # Values persisted by the former pipeline picker map onto the passes axis;
    # its style-only mode is gone (a Rewrite always cleans up).
    switch -- $v { 2pass { set v 2 } 1pass { set v 1 } style { set v 2 } }
    if {$v ni {1 2}} { set v 2 }
    set ::PASSES $v
    dbg "passes = $v"
}

proc savePasses {v} {
    catch {
        file mkdir [file dirname $::STATE_PIPELINE_FILE]
        set f [open $::STATE_PIPELINE_FILE w]; puts -nonewline $f $v; close $f
    }
}

proc on_passes_change {} {
    savePasses $::PASSES
    refresh_rewrite_controls
}

#==============================================================================
# TEXT NORMALISATION: quotes + dialect
#==============================================================================

# style ∈ {double, single}: apostrophe/elision -> ’; quotations -> “ ” or ‘ ’.
proc smarten_quotes {text style} {
    set openers [list ( \[ \{]
    if {$style eq "single"} { set qo "‘"; set qc "’" } else { set qo "“"; set qc "”" }
    set out ""
    set n [string length $text]
    for {set i 0} {$i < $n} {incr i} {
        set ch [string index $text $i]
        if {$ch eq "\""} {
            if {$i == 0} {
                set open 1
            } else {
                set prev [string index $text [expr {$i - 1}]]
                set open [expr {[string is space -strict $prev] || $prev in $openers}]
            }
            append out [expr {$open ? $qo : $qc}]
        } elseif {$ch eq "'"} {
            append out "’"
        } else {
            append out $ch
        }
    }
    return $out
}

# Dialect supports off|british only — there is deliberately no "us" target.
# Converting *to* US English is not the mirror of converting to British: a
# blanket -ise->-ize rule corrupts the many English words that end in -ise but
# are not the -ize suffix (praise->praize, cruise->cruize, noise->noize,
# advertise->advertize, exercise->exercize). A safe ->US pass would need a full
# explicit dictionary of the real -ize verbs, which is not worth carrying. "off"
# already leaves whisper's output untouched, so omit -ise normalisation rather
# than do it wrongly.
proc loadDialect {} {
    set ::ukmap [dict create]
    if {![file exists $::DIALECT_FILE]} { return }
    catch {
        set f [open $::DIALECT_FILE r]; set data [read $f]; close $f
        foreach line [split $data \n] {
            if {$line eq "" || [string index $line 0] eq "#"} continue
            set cols [split $line \t]
            if {[llength $cols] < 2} continue
            dict set ::ukmap [string tolower [string trim [lindex $cols 0]]] [string trim [lindex $cols 1]]
        }
    }
}

# Words that end in -ize but are not -ise in British English.
set ::IZE_EXCEPTIONS {capsize downsize upsize oversize resize size prize seize maize baize assize}
proc britishize_word {lower} {
    if {[dict exists $::ukmap $lower]} { return [dict get $::ukmap $lower] }
    if {$lower in $::IZE_EXCEPTIONS} { return $lower }
    foreach {pat repl} {
        {^(.{3,})izations$} isations
        {^(.{3,})ization$}  isation
        {^(.{3,})izing$}    ising
        {^(.{3,})ized$}     ised
        {^(.{3,})izes$}     ises
        {^(.{3,})ize$}      ise
        {^(.{3,})yzing$}    ysing
        {^(.{3,})yzed$}     ysed
        {^(.{3,})yzes$}     yses
        {^(.{3,})yze$}      yse
    } {
        if {[regexp $pat $lower -> stem]} { return "${stem}${repl}" }
    }
    return $lower
}

proc apply_case {orig mapped} {
    if {$orig eq $mapped} { return $orig }
    if {$orig eq [string toupper $orig]} { return [string toupper $mapped] }
    if {[string index $orig 0] eq [string toupper [string index $orig 0]]} {
        return "[string toupper [string index $mapped 0]][string range $mapped 1 end]"
    }
    return $mapped
}

proc britishize {text} {
    set out ""
    foreach tok [regexp -all -inline {[A-Za-z]+|[^A-Za-z]+} $text] {
        if {[regexp {^[A-Za-z]+$} $tok]} {
            append out [apply_case $tok [britishize_word [string tolower $tok]]]
        } else {
            append out $tok
        }
    }
    return $out
}

proc normalize_text {text} {
    if {$::QSTYLE ne "straight"} { set text [smarten_quotes $text $::QSTYLE] }
    if {$::DIALECT eq "british"} { set text [britishize $text] }
    return $text
}

#==============================================================================
# JSON + DEEPSEEK STYLE PASS
#==============================================================================

proc jsonEscape {str} {
    set result ""
    set len [string length $str]
    for {set i 0} {$i < $len} {incr i} {
        set char [string index $str $i]
        set code [scan $char %c]
        switch -- $char {
            "\\" { append result "\\\\" }
            "\"" { append result "\\\"" }
            "\n" { append result "\\n" }
            "\r" { append result "\\r" }
            "\t" { append result "\\t" }
            "\b" { append result "\\b" }
            "\f" { append result "\\f" }
            default { if {$code < 32} { append result [format "\\u%04x" $code] } else { append result $char } }
        }
    }
    return $result
}

proc buildJSONPayload {model systemPrompt userText {maxTokens 2000}} {
    set json "\{\"model\":\"[jsonEscape $model]\","
    append json "\"messages\":\["
    append json "\{\"role\":\"system\",\"content\":\"[jsonEscape $systemPrompt]\"\},"
    append json "\{\"role\":\"user\",\"content\":\"[jsonEscape $userText]\"\}"
    append json "\],\"temperature\":0.7,\"max_tokens\":$maxTokens\}"
    return $json
}

# POST one chat completion; the callback receives the http token. Any launch
# failure ends the pipeline through api_fail.
proc api_call {model systemPrompt userText callback {maxTokens 2000}} {
    package require http
    package require tls
    if {[catch { ::tls::init -autoservername true; http::register https 443 [list ::tls::socket -autoservername true] }]} {
        http::register https 443 ::tls::socket
    }
    set payload [encoding convertto utf-8 [buildJSONPayload $model $systemPrompt "${::userTextPrefix}${userText}\n" $maxTokens]]
    set headers [list Authorization "Bearer $::apiKey" Content-Type "application/json; charset=utf-8"]
    if {[catch {
        set ::httpToken [http::geturl "${::apiBase}/chat/completions" \
            -method POST -headers $headers -type "application/json" \
            -query $payload -timeout 60000 -command $callback]
    } err]} {
        api_fail "Error: $err"
    }
}

# Terminal failure of any pipeline stage: report in the styled pane and end
# the run (self-test release, windowless delivery fallback).
proc api_fail {msg} {
    set ::rewriteState error
    paneRewriteStatus $msg
    signalTestDone
    styleDone
}

# Shared tail of the pipeline callbacks: unwrap the HTTP token to normalised
# assistant text. On failure routes through api_fail and returns ""; callers
# must check ::rewriteState before using the result.
proc api_response_text {token} {
    set ::httpToken ""
    set status [http::status $token]
    set ncode  [http::ncode $token]
    set data   [encoding convertfrom utf-8 [http::data $token]]
    after idle [list http::cleanup $token]
    if {$status ne "ok"} { api_fail "Network error: $status"; return "" }
    if {$ncode != 200}   { api_fail "API error $ncode"; return "" }
    if {[catch {
        package require json
        set resp [json::json2dict $data]
        set content [dict get [lindex [dict get $resp choices] 0] message content]
    } err]} { api_fail "Parse error: $err"; return "" }
    # llama.cpp's OpenAI endpoint returns thinking-model reasoning inline as a
    # leading <think> block (Ollama keeps it in a separate field); drop it.
    regsub {^\s*<think>.*?</think>\s*} $content {} content
    set content [string map {— " - "} $content]
    return [normalize_text [string trim $content]]
}

# Run the rewrite pipeline picked by ::STYLE_NAME and ::PASSES on what is
# currently in the source pane (the user may have edited the transcription/
# clipboard text); fall back to the variable when windowless.
proc run_rewrite {} {
    set ::autosend_id ""
    if {$::rewriteState ni {idle error}} return
    set ::rewriteState running
    if {!$::WINDOW} { enter_state styling }

    set src [expr {[winfo exists .pane1.txt] ? [string trim [.pane1.txt get 1.0 end]] : $::sourceText}]
    set ::preprocessText ""
    set ::pipelineModel $::apiModel
    if {$::STYLE_NAME eq "none"} {
        # No style: the clean-up call is the whole pipeline, so it terminates it.
        paneRewriteStatus "Cleaning up…"
        api_call $::pipelineModel $::preprocessPrefix $src handle_rewrite
    } elseif {$::PASSES == 1} {
        paneRewriteStatus "Rewriting (one merged call)…"
        if {$::apiThinkingModel ne ""} { set ::pipelineModel $::apiThinkingModel }
        # Thinking models can spend the completion budget on reasoning
        # before the answer, so the merged call gets a larger cap.
        api_call $::pipelineModel "${::mergedPassPrefix}\n${::styleGuide}" $src handle_rewrite 4000
    } else {
        paneRewriteStatus "Cleaning up (call 1 of 2)…"
        api_call $::pipelineModel $::preprocessPrefix $src handle_preprocess
    }
}

# 2-pass call 1 returned: show the repaired text in the styled pane (it stays
# visible while the style call runs, and the styled text replaces it), then
# chain the style call on it. The source pane keeps the raw text. No
# signalTestDone/styleDone here on success: only the terminal handler signals,
# or the self-test's vwait would release (and windowless delivery fire) after
# half the pipeline. No unload_model either: the style call is about to reuse
# the loaded model.
proc handle_preprocess {token} {
    set text [api_response_text $token]
    if {$::rewriteState eq "error"} return
    set ::preprocessText $text
    paneSetRewrite $text
    api_call $::apiModel "${::singlePassPrefix}\n${::styleGuide}" $text handle_rewrite
}

proc handle_rewrite {token} {
    set text [api_response_text $token]
    if {$::rewriteState eq "error"} return
    set ::rewriteText $text
    set ::rewriteState done
    paneSetRewrite $::rewriteText
    setActiveArea 2
    unload_model
    signalTestDone
    styleDone
}

# Opt-in (provider's unload_after_style): after a style pass, ask a local Ollama to
# drop the model from VRAM so whisper has the GPU on the next recording. The style
# request goes through the OpenAI-compatible endpoint, which ignores keep_alive, so
# the unload is a separate call to Ollama's native /api/generate (keep_alive 0 and
# no prompt, so it returns in milliseconds without generating). Best-effort: a failure
# here never disturbs the delivered text. Costs a cold model reload on the next pass.
proc unload_model {} {
    if {!$::UNLOAD_AFTER || !$::AI_AVAILABLE} return
    regsub {/v1/?$} $::apiBase {} base
    set m [expr {$::pipelineModel ne "" ? $::pipelineModel : $::apiModel}]
    set body [encoding convertto utf-8 "{\"model\":\"$m\",\"keep_alive\":0}"]
    catch {
        set tok [http::geturl "${base}/api/generate" -method POST \
            -type "application/json" -query $body -timeout 4000]
        http::cleanup $tok
    }
}

proc signalTestDone {} { if {$::SELF_TEST} { set ::testDone 1 } }

# Unattended: once the pipeline returns, deliver. A style failure after a
# successful preprocess still delivers the repaired text.
proc styleDone {} {
    if {$::WINDOW || $::SELF_TEST} return
    if {$::rewriteState eq "done"} { deliver_now $::rewriteText; return }
    deliver_now [expr {$::preprocessText ne "" ? $::preprocessText : $::sourceText}]
}

#==============================================================================
# DELIVERY
#==============================================================================

# Clipboard write. macOS uses pbcopy, Wayland wl-copy, X11 xclip; the backend
# is decided once from the platform and the session's Wayland socket. Injection
# is display-agnostic on each platform, so only the clipboard needs this split.
proc clip_backend {} {
    if {$::clipBackend ne ""} { return $::clipBackend }
    if {$::MACOS} {
        set ::clipBackend macos
    } elseif {[info exists ::env(WAYLAND_DISPLAY)] && $::env(WAYLAND_DISPLAY) ne "" \
            && ![catch {exec which wl-copy}]} {
        set ::clipBackend wayland
    } else {
        set ::clipBackend x11
    }
    return $::clipBackend
}
proc set_clipboard {txt} {
    switch -- [clip_backend] {
        macos   { exec pbcopy << $txt }
        wayland { exec wl-copy -- $txt }
        x11     {
            # xclip daemonises to hold the X11 selection; redirect its
            # stdout/stderr off Tcl's pipe or exec blocks waiting for the
            # child to close inherited fds.
            exec xclip -selection clipboard >/dev/null 2>/dev/null << $txt
        }
    }
}
# The panes are editable, so the widget is the source of truth once it exists;
# fall back to the variables for the windowless path and for self-test checks
# that run before the window is built.
proc active_text {} {
    set w [expr {$::activeArea == 2 ? ".pane2.txt" : ".pane1.txt"}]
    if {[winfo exists $w]} { return [string trim [$w get 1.0 end]] }
    return [expr {$::activeArea == 2 ? $::rewriteText : $::sourceText}]
}

# dotool actions to type TEXT, two-rate cadence + IBus Ctrl+Shift+U for
# non-ASCII (curly quotes, accented proper nouns). From the companion tool.
proc build_inject_actions {text} {
    set text [string trim $text]
    set out {}
    set first 1
    foreach line [split $text \n] {
        if {!$first} { lappend out "key enter" }
        set first 0
        if {$line eq ""} continue
        set buf ""; set buf_is_sp 0
        set llen [string length $line]
        for {set i 0} {$i < $llen} {incr i} {
            set ch [string index $line $i]
            scan $ch %c cp
            if {$cp > 127} {
                _emit_run out $buf; set buf ""
                lappend out "typedelay $::KEY_DELAY"
                lappend out "key ctrl+shift+u"
                lappend out [format "type %04x" $cp]
                lappend out "key space"
                continue
            }
            set ch_is_sp [string is space -strict $ch]
            if {$buf eq "" || $ch_is_sp == $buf_is_sp} {
                append buf $ch; set buf_is_sp $ch_is_sp
            } else {
                _emit_run out $buf; set buf $ch; set buf_is_sp $ch_is_sp
            }
        }
        _emit_run out $buf
    }
    return [join $out \n]
}
proc _emit_run {out_var buf} {
    upvar 1 $out_var out
    if {$buf eq ""} return
    set is_sp [string is space -strict [string index $buf 0]]
    lappend out "typedelay [expr {$is_sp ? $::WORD_DELAY : $::KEY_DELAY}]"
    lappend out "type $buf"
}

# AppleScript string literal for TEXT: escape backslash and quote, encode
# newlines as \n (System Events keystroke sends them as Return).
proc applescript_quote {text} {
    return "\"[string map [list \\ \\\\ \" \\\" \n \\n \r \\r] $text]\""
}
proc inject_text {text} {
    if {$::MACOS} {
        set text [string trim $text]
        if {$text eq ""} { finish 0; return }
        enter_state typing
        set script "tell application \"System Events\" to keystroke [applescript_quote $text]"
        if {[catch {set ::inject_pid [exec osascript -e $script &]} err]} {
            ui_error "osascript keystroke failed: $err"; return
        }
        poll_inject
        return
    }
    set actions [build_inject_actions $text]
    if {$actions eq ""} { finish 0; return }
    enter_state typing
    if {[catch {set ::inject_pid [exec dotool << $actions &]} err]} {
        ui_error "dotool failed: $err"; return
    }
    poll_inject
}
proc poll_inject {} {
    if {$::inject_pid == 0} return
    if {[catch {exec kill -0 $::inject_pid}]} { set ::inject_pid 0; finish 0 } \
    else { set ::inject_id [after 150 poll_inject] }
}

proc deliver_now {text {withEnter 0}} {
    cancel_pending
    logsys notice "delivering [string length $text] chars via $::DELIVER"
    # In window mode, hide the review window first so focus returns to the prior
    # window before we type/paste. In no-window mode there is no window to hide;
    # calling `wm withdraw .` on this Tk build maps-then-unmaps the toplevel (a
    # visible flash) and steals focus, so the paste would race focus return and
    # land the prior clipboard. Skip the window poke entirely, as the windowless
    # typing path always has.
    switch -- $::DELIVER {
        stdout { puts $text; flush stdout; finish 0 }
        clipboard { set_clipboard $text; finish 0 }
        type {
            if {$::WINDOW} { catch {wm withdraw .}; after 150 [list inject_text $text] } \
            else { inject_text $text }
        }
        paste {
            set_clipboard $text
            if {$::WINDOW} { catch {wm withdraw .}; after 200 [list do_paste_exec $withEnter] } \
            else { after 50 [list do_paste_exec $withEnter] }
        }
    }
}
proc do_paste_exec {withEnter} {
    if {$::MACOS} {
        # Cmd+V through System Events; needs Accessibility permission.
        set cmd [list osascript -e {tell application "System Events" to keystroke "v" using command down}]
    } else {
        set cmd [list dotool << $::PASTE_KEY]
    }
    if {[catch {exec {*}$cmd} err]} { ui_error "paste keystroke failed: $err"; return }
    if {$withEnter} { after $::PASTE_ENTER_GAP_MS do_paste_enter } else { finish 0 }
}
proc do_paste_enter {} {
    if {$::MACOS} { catch {exec osascript -e {tell application "System Events" to key code 36}} } \
    else          { catch {exec dotool << $::ENTER_KEY} }
    finish 0
}

proc cancel_pending {} {
    if {$::autosend_id ne ""} { after cancel $::autosend_id; set ::autosend_id "" }
    if {$::httpToken ne ""}   { catch {http::reset $::httpToken}; set ::httpToken "" }
}
proc finish {code} {
    logsys notice "exit $code"
    catch {after cancel $::autosend_id}
    # The window can close mid-capture (Listen running): take the recorder and
    # any in-flight whisper-cli with it, or the mic stays hot in an orphan.
    if {$::recorder_pid > 0} { catch {exec kill $::recorder_pid} }
    catch { if {$::wchan ne ""} { foreach p [pid $::wchan] { exec kill $p } } }
    catch {tk systray destroy}
    if {$::tmpfile ne "" && $::TEST_FILE eq "" && !$::debug_mode} { catch {file delete $::tmpfile} }
    after 0 [list exit $code]
}
# A copyable modal message dialog. tk_messageBox draws its text as a static label
# that X11 will not let you select, so a message a user may want to paste elsewhere
# (a GPU error to search, a config path to open) goes through here: the body sits
# in a read-only text widget that selects and copies, with a Copy button for the
# whole message. Blocks until dismissed, like tk_messageBox.
proc show_dialog {title body} {
    set w .dlg
    catch {destroy $w}
    toplevel $w
    wm title $w $title
    wm transient $w .
    set nlines [llength [split $body \n]]
    set h [expr {$nlines < 3 ? 3 : ($nlines > 18 ? 18 : $nlines)}]
    text $w.msg -wrap word -width 56 -height $h -relief flat -takefocus 0 \
        -padx 8 -pady 8 -highlightthickness 0
    $w.msg insert 1.0 $body
    $w.msg configure -state disabled
    pack $w.msg -fill both -expand 1 -padx 8 -pady {10 4}
    pack [ttk::frame $w.btns] -fill x -padx 8 -pady {0 8}
    ttk::button $w.btns.ok   -text "OK"   -command [list destroy $w]
    ttk::button $w.btns.copy -text "Copy" -takefocus 0 -command [list set_clipboard $body]
    pack $w.btns.ok -side right
    pack $w.btns.copy -side right -padx 4
    bind $w <Return> [list destroy $w]
    bind $w <Escape> [list destroy $w]
    focus $w.btns.ok
    catch {grab set $w}
    tkwait window $w
}

# A hard failure after the app has launched (recorder, whisper, delivery). In a
# window session, surface it as a dialog so it is not lost to stderr/journal;
# always log it and exit non-zero. There is no cheap, portable pre-flight for
# GPU/VRAM sufficiency — nvidia-smi is NVIDIA-only and Vulkan/Metal/ROCm/CPU each
# differ — so scribe reports the backend's own failure rather than guessing.
proc ui_error {msg {detail ""}} {
    logsys err "$msg[expr {$detail ne "" ? " ($detail)" : ""}]"
    # A failure inside an in-window recording (recorder, transcription) costs
    # the attempt, not the window: the pane may hold typed work.
    if {$::capture_sink eq "window"} {
        win_capture_reset
        catch {show_dialog "Scribe" $msg}
        return
    }
    catch {tk systray destroy}
    if {$::WINDOW} {
        # Keep the dialog readable: show the short human message, never the raw
        # backend dump (a whisper stderr tail runs taller than the screen). The
        # full detail is in the log above.
        set shown [expr {[string length $msg] > 400 ? "[string range $msg 0 399]…" : $msg}]
        catch {wm withdraw .; show_dialog "Scribe" $shown}
    }
    finish 1
}

#==============================================================================
# REVIEW WINDOW
#==============================================================================

set ::HL_COLOR "#cfe8ff"
set ::PANE_BG  "#ffffff"

# Rewrite with the configured provider. With none configured, tell the user how
# to add one instead of doing nothing, so the Rewrite button stays meaningful in
# the zero-config case rather than hiding (see the CLAUDE.md invariant).
proc rewrite_or_prompt {} {
    if {$::AI_AVAILABLE} { run_rewrite; return }
    set cfg [lindex [config_candidates] 0]
    show_dialog "Rewriting needs an AI provider" \
        "No AI provider is configured yet.\n\nAdd one to:\n$cfg\n\nSee config.example.ini for the format (any OpenAI-compatible endpoint, including a local Ollama model). Reopen Scribe once it is set."
}

# The passes row, hint line, and result placeholder all depend on the current
# style/passes picks; one refresher keeps them consistent. Under "No style" the
# passes row greys out rather than hides, so the layout never jumps and the
# moot choice explains itself.
proc refresh_rewrite_controls {} {
    if {![winfo exists .ctrl]} return
    set styled [expr {$::STYLE_NAME ne "none"}]
    foreach w [winfo children .ctrl.passrow] {
        if {[winfo class $w] in {TRadiobutton TLabel}} {
            $w state [expr {$styled ? "!disabled" : "disabled"}]
        }
    }
    .ctrl.hint configure -text [rewrite_hint]
    if {$::rewriteState in {idle error}} { paneRewriteStatus [result_placeholder] }
}
proc rewrite_hint {} {
    if {$::STYLE_NAME eq "none"} { return "No style selected → always a single clean-up pass (stutter, self-corrections, reordering)." }
    if {$::PASSES == 1} { return "One call: clean-up and styling merged into a single prompt — suits thinking models." }
    return "Two calls: clean up first, then apply the style to the cleaned text — most reliable."
}
proc result_placeholder {} {
    if {$::STYLE_NAME eq "none"} { return "Press Rewrite to clean up the dictation." }
    return "Press Rewrite to clean up and apply the $::STYLE_NAME style."
}

proc build_review_ui {} {
    wm title . "Scribe"
    set srcLabel [expr {$::INPUT eq "clipboard" ? "Clipboard" : ($::INPUT eq "voice" ? "Dictated" : "Text")}]
    # The rewrite controls and result pane exist only when an AI provider is
    # configured; with none, scribe shows a single dictation pane (see CLAUDE.md).
    set styleable $::AI_AVAILABLE

    pack [ttk::frame .pane1 -padding 6] -fill both -expand 1
    pack [ttk::frame .pane1.hdr] -fill x
    pack [ttk::label .pane1.hdr.lbl -text $srcLabel] -side left
    # In-window dictation, whatever --input opened the window: Listen records
    # into this pane; while recording it reads Stop and the indicator pulses.
    ttk::label .pane1.hdr.rec -foreground #e01b24 -text "● recording…"
    ttk::button .pane1.hdr.listen -text "Listen" -command win_listen_toggle -takefocus 0
    pack .pane1.hdr.listen -side right
    text .pane1.txt -height 8 -width 80 -wrap word -relief solid -borderwidth 2 -takefocus 0
    pack .pane1.txt -fill both -expand 1
    bind .pane1.txt <Button-1> {setActiveArea 1}

    if {$styleable} {
        pack [ttk::frame .ctrl -padding {6 0}] -fill x
        pack [ttk::frame .ctrl.stylerow] -fill x
        pack [ttk::label .ctrl.stylerow.lbl -text "Style" -width 7] -side left
        pack [ttk::radiobutton .ctrl.stylerow.none -text "No style" -variable ::STYLE_NAME \
                  -value none -command on_style_change -takefocus 0] -side left -padx {0 12}
        set i 0
        foreach name [styleNames] {
            pack [ttk::radiobutton .ctrl.stylerow.s[incr i] -text $name -variable ::STYLE_NAME \
                      -value $name -command on_style_change -takefocus 0] -side left -padx {0 12}
        }
        pack [ttk::frame .ctrl.passrow] -fill x -pady {4 0}
        pack [ttk::label .ctrl.passrow.lbl -text "Passes" -width 7] -side left
        pack [ttk::radiobutton .ctrl.passrow.p1 -text "1 — merged prompt" -variable ::PASSES \
                  -value 1 -command on_passes_change -takefocus 0] -side left -padx {0 12}
        pack [ttk::radiobutton .ctrl.passrow.p2 -text "2 — clean up, then style" -variable ::PASSES \
                  -value 2 -command on_passes_change -takefocus 0] -side left -padx {0 12}
        catch {
            ttk::style configure Rewrite.TButton -foreground #ffffff -background #3584e4
            ttk::style map Rewrite.TButton -background {active #1c5fad}
        }
        ttk::button .ctrl.passrow.rewrite -text "Rewrite" -style Rewrite.TButton \
            -command rewrite_or_prompt -takefocus 0
        pack .ctrl.passrow.rewrite -side right
        pack [ttk::label .ctrl.hint -foreground #98989d] -fill x -pady {4 0}

        pack [ttk::frame .pane2 -padding 6] -fill both -expand 1
        pack [ttk::label .pane2.lbl -text "Result"] -anchor w
        text .pane2.txt -height 8 -width 80 -wrap word -relief solid -borderwidth 2 -takefocus 0
        pack .pane2.txt -fill both -expand 1
        bind .pane2.txt <Button-1> {setActiveArea 2}
    }

    set primary [expr {$::DELIVER eq "type" ? "Type" : ($::DELIVER eq "clipboard" ? "Copy" : ($::DELIVER eq "stdout" ? "Print" : "Paste"))}]
    pack [ttk::frame .btns -padding 6] -fill x
    ttk::button .btns.go -text "$primary  (Space · Ctrl+↵ while editing)" -command {deliver_now [active_text] 0} -takefocus 0
    pack .btns.go -side left -padx 4
    if {!$styleable} {
        # Rewriting stays discoverable even unconfigured: the button points the
        # user at config.ini rather than hiding (see rewrite_or_prompt).
        ttk::button .btns.rewrite -text "Rewrite" -command rewrite_or_prompt -takefocus 0
        pack .btns.rewrite -side left -padx 4
    }
    ttk::button .btns.copy -text "Copy to clipboard" -command {set_clipboard [active_text]; finish 0} -takefocus 0
    pack .btns.copy -side left -padx 4

    .pane1.txt insert 1.0 $::sourceText
    if {$styleable} { refresh_rewrite_controls }

    # Focus-dependent keys: when a text pane holds focus the Text class inserts the
    # character first (bindtags: {.paneN.txt Text . all}) and the guarded toplevel
    # binding no-ops, so Space/Enter type. When focus is on the toplevel (pre-filled
    # voice/clipboard modes) they deliver, as before. Ctrl+Enter always delivers.
    bind . <space>          {if {![typing_focus]} {deliver_now [active_text] 0; break}}
    bind . <Return>         {if {![typing_focus]} {deliver_now [active_text] 1; break}}
    bind . <Control-Return> {deliver_now [active_text] 0; break}
    bind . <Escape>         {if {$::state eq "recording"} {stop_recording escape} else {finish 0}; break}
    if {$styleable} {
        bind . <Up>   {if {![typing_focus]} {setActiveArea 1; break}}
        bind . <Down> {if {![typing_focus]} {setActiveArea 2; break}}
    }
    wm protocol . WM_DELETE_WINDOW {set_clipboard [active_text]; finish 0}
    refresh_highlight
}
# In-window dictation. Listen starts the same recorder the voice launch path
# uses; ::capture_sink routes the transcript into the open pane instead of
# through on_source_ready. The listener socket is served while recording, so
# the global shortcut's second press stops this recording like any other.
proc win_listen_toggle {} {
    if {$::capture_sink eq "window"} {
        # A capture is already in flight: recording toggles to stop, a
        # transcription just waits. (::state alone cannot gate this: a window
        # opened by the voice launch path keeps its "transcribing" residue.)
        if {$::state eq "recording"} { stop_recording window-stop }
        return
    }
    set ::capture_sink window
    set ::done 0
    serve_listener
    start_recording
    if {$::recorder_pid == 0} { win_capture_reset; return }
    set ::state recording
    win_update_rec_ui
}
# The transcript lands in the source pane: appended when the pane holds text
# (typed work is kept), replacing the pane when it is empty. The pane is the
# source of truth, so ::sourceText follows it.
proc win_capture_done {text} {
    win_capture_reset
    set text [normalize_text [string trim $text]]
    if {$text eq ""} return
    set cur [string trim [.pane1.txt get 1.0 end]]
    if {$cur ne ""} { set text "$cur $text" }
    .pane1.txt delete 1.0 end
    .pane1.txt insert 1.0 $text
    set ::sourceText $text
    setActiveArea 1
}
proc win_capture_reset {} {
    set ::capture_sink launch
    set ::done 0
    stop_listener
    stop_animate
    if {$::state ne "idle"} { set ::state idle }
    win_update_rec_ui
}
proc win_update_rec_ui {} {
    if {![winfo exists .pane1.hdr.listen]} return
    if {$::capture_sink eq "window" && $::state eq "recording"} {
        .pane1.hdr.listen configure -text "Stop  (Esc)"
        pack .pane1.hdr.rec -side left -padx 8 -after .pane1.hdr.lbl
        if {$::win_pulse_id eq ""} { win_rec_pulse }
        return
    }
    if {$::win_pulse_id ne ""} { after cancel $::win_pulse_id; set ::win_pulse_id "" }
    pack forget .pane1.hdr.rec
    if {$::capture_sink eq "window"} {
        .pane1.hdr.listen configure -text "Transcribing…"
        .pane1.hdr.listen state disabled
    } else {
        .pane1.hdr.listen configure -text "Listen"
        .pane1.hdr.listen state !disabled
    }
}
proc win_rec_pulse {} {
    if {![winfo exists .pane1.hdr.rec] || $::state ne "recording"} { set ::win_pulse_id ""; return }
    set lit [expr {[.pane1.hdr.rec cget -foreground] eq "#e01b24"}]
    .pane1.hdr.rec configure -foreground [expr {$lit ? "#f2b0b4" : "#e01b24"}]
    set ::win_pulse_id [after 600 win_rec_pulse]
}

proc paneSetRewrite {txt} {
    if {![winfo exists .pane2.txt]} return
    .pane2.txt delete 1.0 end; .pane2.txt insert 1.0 $txt
}
proc paneRewriteStatus {msg} { paneSetRewrite $msg }
# True when an editable text pane holds keyboard focus, so Space/Enter should type
# rather than deliver. [focus] is "" on a backgrounded/unmapped window — guard it.
proc typing_focus {} {
    set w [focus]
    expr {$w ne "" && [winfo exists $w] && [winfo class $w] eq "Text"}
}
proc setActiveArea {n} { set ::activeArea $n; refresh_highlight }
proc refresh_highlight {} {
    if {![winfo exists .pane1.txt]} return
    .pane1.txt configure -background [expr {$::activeArea == 1 ? $::HL_COLOR : $::PANE_BG}]
    if {[winfo exists .pane2.txt]} {
        .pane2.txt configure -background [expr {$::activeArea == 2 ? $::HL_COLOR : $::PANE_BG}]
    }
}

#==============================================================================
# DISPATCH
#==============================================================================

proc on_source_ready {text} {
    set ::sourceText [normalize_text [string trim $text]]
    set ::activeArea 1
    catch {tk systray destroy}
    if {$::WINDOW} {
        build_review_ui
        wm deiconify .; raise .
        # Empty source (keyboard mode): put the cursor in the pane so the user can
        # type. Pre-filled (voice/clipboard): keep focus on the toplevel so Space
        # delivers, and re-assert it against the WM's post-map focus.
        if {$::sourceText eq ""} {
            focus .pane1.txt
        } else {
            focus -force .
            after 120 {catch {focus -force .}}
        }
        if {$::STYLE_ON && $::STYLE_AUTO ne "" && $::sourceText ne ""} { set ::autosend_id [after $::STYLE_AUTO run_rewrite] }
    } else {
        if {$::STYLE_ON} { run_rewrite } else { deliver_now $::sourceText }
    }
}

#==============================================================================
# TRAY ICON
#==============================================================================

set ::ICON_SCALE [expr {[::tk::ScalingPct] / 100.0}]
set ::_probe [image create photo -format [list svg -scale $::ICON_SCALE] \
    -data {<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><circle cx="16" cy="16" r="15" fill="#000"/></svg>}]
set ::ICON_SIZE [image width $::_probe]
image delete $::_probe
set ::TWOPI [expr {2.0 * acos(-1.0)}]
set ::icon_image [image create photo -width $::ICON_SIZE -height $::ICON_SIZE]
set ::BLINK_MS 1000
set ::TYPE_BLINK_MS 250
set ::blink 1
set ::anim_id ""
set ::TRANSPARENT_SVG {<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"></svg>}

# Recording glyph: lit = red countdown disc, unlit = transparent (blink to
# background). First frame is lit, so the icon shows red first.
proc pie_svg {frac lit} {
    if {!$lit} { return $::TRANSPARENT_SVG }
    set cx 16.0; set cy 16.0; set r 15.5
    set s "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\">"
    append s "<circle cx=\"$cx\" cy=\"$cy\" r=\"$r\" fill=\"#444444\"/>"
    if {$frac >= 0.999} {
        append s "<circle cx=\"$cx\" cy=\"$cy\" r=\"$r\" fill=\"#dd3333\"/>"
    } elseif {$frac > 0.001} {
        set a [expr {$frac * $::TWOPI}]
        set ex [expr {$cx + $r * sin($a)}]; set ey [expr {$cy - $r * cos($a)}]
        set large [expr {$frac > 0.5 ? 1 : 0}]
        append s "<path d=\"M$cx,$cy L$cx,[expr {$cy - $r}] A$r,$r 0 $large,1 $ex,$ey Z\" fill=\"#dd3333\"/>"
    }
    append s "</svg>"
    return $s
}
proc busy_svg {lit} {
    set s "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\">"
    append s "<circle cx=\"16\" cy=\"16\" r=\"15.5\" fill=\"#f67400\"/>"
    if {$lit} { foreach x {8.5 16 23.5} { append s "<circle cx=\"$x\" cy=\"16\" r=\"2.4\" fill=\"#ffffff\"/>" } }
    append s "</svg>"
    return $s
}
proc type_svg {lit} {
    set l [expr {$lit ? "#ffd400" : "#3a3a3a"}]; set r [expr {$lit ? "#3a3a3a" : "#ffd400"}]
    set s "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\">"
    append s "<rect x=\"3\"  y=\"8\" width=\"11\" height=\"16\" rx=\"2\" fill=\"$l\"/>"
    append s "<rect x=\"18\" y=\"8\" width=\"11\" height=\"16\" rx=\"2\" fill=\"$r\"/>"
    append s "</svg>"
    return $s
}
proc draw_icon {frac state lit} {
    switch -- $state {
        styling - transcribing { set svg [busy_svg $lit] }
        typing                 { set svg [type_svg $lit] }
        default                { set svg [pie_svg $frac $lit] }
    }
    set tmp [image create photo -data $svg -format [list svg -scale $::ICON_SCALE]]
    $::icon_image copy $tmp -compositingrule set
    image delete $tmp
}
proc recording_frac {} {
    set max_s [expr {double($::TIMEOUT_S)}]
    set rem [expr {max(0.0, $max_s - ([clock milliseconds] - $::start_ms) / 1000.0)}]
    return [expr {$rem / $max_s}]
}
proc animate {} {
    set ms $::BLINK_MS
    switch -- $::state {
        recording    { draw_icon [recording_frac] recording $::blink }
        transcribing { draw_icon 1.0 transcribing $::blink }
        styling      { draw_icon 1.0 styling $::blink }
        typing       { draw_icon 1.0 typing $::blink; set ms $::TYPE_BLINK_MS }
        default      { set ::anim_id ""; return }
    }
    set ::blink [expr {!$::blink}]
    set ::anim_id [after $ms animate]
}
proc start_animate {} { if {$::anim_id eq ""} animate }
proc stop_animate {}  { if {$::anim_id ne ""} { after cancel $::anim_id; set ::anim_id "" } }
proc enter_state {newstate} { stop_animate; set ::state $newstate; set ::blink 1; start_animate; win_update_rec_ui }

#==============================================================================
# VOICE INPUT
#==============================================================================

proc resolve_source {capture} {
    if {![string is integer -strict $capture]} { return $capture }
    if {$::MACOS} { fatal "--capture N (numeric) needs pactl and is Linux-only; pass the CoreAudio device name" }
    set sources {}
    foreach line [split [exec pactl list sources short] \n] {
        set name [lindex $line 1]
        if {$name ne "" && ![string match *.monitor $name]} { lappend sources $name }
    }
    set idx [expr {int($capture)}]
    if {$idx < [llength $sources]} { return [lindex $sources $idx] }
    return ""
}
proc sweep_stale_recordings {} {
    foreach f [glob -nocomplain -directory $::CACHE_DIR "scribe-*.wav"] {
        if {![regexp {scribe-(\d+)\.wav$} [file tail $f] -> opid]} continue
        if {$opid eq [pid]} continue
        if {[catch {exec kill -0 $opid}]} { catch {file delete -- $f} }
    }
}
# The .wav half of the pair is written by transcribe, ahead of the attempt.
proc save_log {text} {
    if {$::log_stem eq ""} return
    if {[catch {file mkdir $::LOG_DIR}]} return
    catch {
        set fh [open [file join $::LOG_DIR "$::log_stem.txt"] w]; puts -nonewline $fh $text; close $fh
    }
}
# Shell-quote a Tcl list into a copy-pasteable command line.
proc shell_quote {words} {
    set out {}
    foreach w $words {
        if {$w eq "" || [regexp {[^A-Za-z0-9_./:=-]} $w]} {
            set w [string map [list ' "'\\''"] $w]
            lappend out '$w'
        } else {
            lappend out $w
        }
    }
    return [join $out " "]
}

# --debug capture. scribe runs whisper-cli with stderr discarded; this writes a
# runnable copy of the exact call (stderr intact) beside the kept recording, so
# the transcription can be replayed by hand to see timings or a GPU crash.
proc save_debug_command {wcmd {kind whisper-cli}} {
    # kind picks the replay file's name so a fallback run keeps both the server
    # (curl) and the local (whisper-cli) replays side by side.
    set cmdfile [file rootname $::tmpfile][expr {$kind eq "curl" ? ".curl.sh" : ".sh"}]
    if {[catch {
        set fh [open $cmdfile w]
        puts $fh "#!/bin/sh"
        puts $fh "# scribe --debug replay of the $kind call on [file tail $::tmpfile]."
        puts $fh "# scribe itself runs this with 2>/dev/null; kept here so you see timings/errors."
        puts $fh [shell_quote $wcmd]
        close $fh
        file attributes $cmdfile -permissions 0755
    } err]} { dbg "could not write $cmdfile: $err"; return }
    dbg "replay script: $cmdfile"
    dbg "audio kept:    $::tmpfile"
}

# Transcribe the recording. With a whisper server configured, POST to it; else run
# whisper-cli locally. The ::done guard and cache dir stay here so a server->local
# fallback (which re-enters transcribe_local) does not re-trip them.
proc transcribe {} {
    if {$::done} return
    set ::done 1
    # The --test-file path reaches here without start_recording, so ensure the
    # cache dir (home of the stderr file below) exists on both paths.
    file mkdir $::CACHE_DIR
    # The audio reaches the dictation log before any transcription attempt: a
    # hung, killed, or crashed run must not cost the recording (the cache copy
    # is swept by the next instance). save_log adds the .txt beside it on
    # success. No log_stem means no recording of ours (--test-file).
    if {$::log_stem ne ""} {
        catch {
            file mkdir $::LOG_DIR
            file copy -force -- $::tmpfile [file join $::LOG_DIR "$::log_stem.wav"]
        }
    }
    set ::transcribe_ms [clock milliseconds]
    logsys notice "transcribing ~[expr {int([file size $::tmpfile] / 32000.0)}]s of audio via [expr {[transcribe_use_server] ? "server" : "whisper-cli"}]"
    if {[transcribe_use_server]} { transcribe_server } else { transcribe_local }
}
proc transcribe_use_server {} { expr {$::WHISPER_SERVER ne ""} }

# Local backend: run whisper-cli on the recording. The model-exists check lives
# here, so server-only mode needs no local model; server-with-fallback still does.
proc transcribe_local {} {
    # Fail loudly on a missing model rather than let whisper-cli emit nothing and
    # deliver blank. --model is often given relative; report the cwd it resolved
    # against so a wrong relative path is obvious.
    if {$::MODEL eq ""} {
        ui_error "no whisper model configured: set model in the \[whisper\] section of config.ini, or pass --model"
        return
    }
    if {![file exists $::MODEL]} {
        ui_error "whisper model not found: $::MODEL (resolved from cwd [pwd]); pass an absolute --model or set \[whisper\] model"
        return
    }
    set wcmd [list whisper-cli -m $::MODEL -f $::tmpfile -nt -l $::LANG -t $::THREADS]
    if {$::PROMPT ne ""}   { lappend wcmd --prompt $::PROMPT }
    if {$::NO_FALLBACK}    { lappend wcmd --no-fallback }
    if {$::NO_GPU}         { lappend wcmd --no-gpu }
    if {$::FLASH_ATTN}     { lappend wcmd --flash-attn }
    if {$::NO_FLASH_ATTN}  { lappend wcmd --no-flash-attn }
    if {$::PRINT_SPECIAL}  { lappend wcmd --print-special }
    if {$::debug_mode}     { save_debug_command $wcmd }
    # Capture whisper's stderr to a file rather than discarding it, so a failure
    # (or a GPU/driver fault) is logged. Keeping it off the read pipe avoids
    # mixing diagnostics into the transcript.
    set ::werrfile [file join $::CACHE_DIR "scribe-[pid].stderr"]
    if {[catch {set ::wchan [open "|$wcmd 2>$::werrfile" r]} err]} {
        ui_error "whisper-cli failed to start: $err"; return
    }
    set ::wbuf ""
    fconfigure $::wchan -blocking 0
    fileevent $::wchan readable transcribe_collect
    # Watchdog, sized to the audio (16kHz mono s16 = 32kB/s) plus the server
    # path's request cap, so a CPU run on a long recording is never killed while
    # it still makes progress. Without one, a wedged whisper-cli (GPU held by
    # another model, driver fault) hangs scribe forever with no error and no
    # transcript.
    set audio_s [expr {int([file size $::tmpfile] / 32000.0)}]
    set ::wdog_id [after [expr {($::WHISPER_TIMEOUT_S + $audio_s) * 1000}] transcribe_local_timeout]
}
proc transcribe_local_timeout {} {
    set ::wdog_id ""
    logsys err "whisper-cli still running after its ${::WHISPER_TIMEOUT_S}s-plus-audio budget; killing it"
    set chan $::wchan
    set ::wchan ""
    # Nothing here waits on the child: a GPU-wedged process can sit in
    # uninterruptible sleep where even kill -9 lands late, so waiting for its
    # EOF would hang exactly when the watchdog is needed. Unhook the reader,
    # kill, and let the nonblocking close detach rather than wait.
    catch { fileevent $chan readable {} }
    catch { foreach p [pid $chan] { exec kill -9 $p } }
    catch { close $chan }
    set tail [whisper_stderr]
    if {!$::debug_mode} { catch {file delete $::werrfile} }
    ui_error [transcribe_error_msg $tail] "whisper-cli killed after its time budget[expr {$tail ne "" ? ": $tail" : ""}]"
}
proc transcribe_collect {} {
    if {$::wchan eq ""} return
    append ::wbuf [read $::wchan]
    if {![eof $::wchan]} return
    if {$::wdog_id ne ""} { after cancel $::wdog_id; set ::wdog_id "" }
    fileevent $::wchan readable {}
    # A non-blocking channel's close does not wait for the child or report its
    # exit status, so whisper-cli failures (missing model, GPU OOM) would pass
    # silently and deliver blank. Restore blocking so close surfaces the status.
    fconfigure $::wchan -blocking 1
    if {[catch {close $::wchan} cerr]} {
        set tail [whisper_stderr]
        if {!$::debug_mode} { catch {file delete $::werrfile} }
        ui_error [transcribe_error_msg $tail] "whisper-cli failed: $cerr[expr {$tail ne "" ? ": $tail" : ""}]"
        return
    }
    if {!$::debug_mode} { catch {file delete $::werrfile} }
    transcribe_succeeded $::wbuf
}

# Server backend: POST the WAV to a whisper.cpp server. curl frames the multipart
# body and streams the bytes; scribe reuses the local path's non-blocking pipe and
# flip-to-blocking-close-for-exit-status machinery rather than build multipart in
# Tcl. whisper-cli-only knobs (-m, -ng, -fa, --prompt) do not apply: the server's
# model and flags are fixed when the user starts it.
proc build_server_curl_cmd {} {
    return [list curl -sS --fail-with-body \
        --connect-timeout $::WHISPER_CONNECT_TIMEOUT_S --max-time $::WHISPER_TIMEOUT_S \
        -X POST -F file=@$::tmpfile -F response_format=json -F language=$::LANG \
        "[string trimright $::WHISPER_SERVER /]/inference"]
}
proc transcribe_server {} {
    set curl [build_server_curl_cmd]
    if {$::debug_mode} { save_debug_command $curl curl }
    set ::werrfile [file join $::CACHE_DIR "scribe-[pid].curl.stderr"]
    if {[catch {set ::wchan [open "|$curl 2>$::werrfile" r]} err]} {
        server_transcribe_failed "curl failed to start: $err"; return
    }
    set ::wbuf ""
    fconfigure $::wchan -blocking 0
    fileevent $::wchan readable transcribe_server_collect
}
proc transcribe_server_collect {} {
    append ::wbuf [read $::wchan]
    if {![eof $::wchan]} return
    fileevent $::wchan readable {}
    fconfigure $::wchan -blocking 1
    if {[catch {close $::wchan} cerr]} {
        # curl exit 7 = connection refused, 28 = timeout, 22 = HTTP >= 400.
        set tail [whisper_stderr]
        server_transcribe_failed "curl: $cerr[expr {$tail ne "" ? " ($tail)" : ""}]"
        return
    }
    if {[catch {
        package require json
        set text [dict get [json::json2dict $::wbuf] text]
    } perr]} {
        server_transcribe_failed "unreadable server response: $perr"; return
    }
    if {!$::debug_mode} { catch {file delete $::werrfile} }
    transcribe_succeeded $text
}
# A server request that never produced a usable transcript. With fallback on, log
# it and run the local backend; otherwise surface it. An empty-but-valid transcript
# is NOT a failure (handled in transcribe_succeeded), so silence does not fall back.
proc server_transcribe_failed {reason} {
    if {!$::debug_mode} { catch {file delete $::werrfile} }
    if {$::WHISPER_FALLBACK} {
        logsys notice "whisper-server ($::WHISPER_SERVER) failed ($reason); falling back to local whisper-cli"
        transcribe_local
    } else {
        ui_error [transcribe_server_error_msg $reason] "whisper-server failed: $reason"
    }
}
# Shared success tail for both backends: an empty transcript after a clean run is
# not an error, but it is the other way a blank result happens (silence, wrong
# audio format, wrong model), so say so rather than deliver nothing unexplained.
proc transcribe_succeeded {text} {
    stop_animate
    logsys notice "transcript: [string length [string trim $text]] chars in [expr {([clock milliseconds] - $::transcribe_ms) / 1000}]s"
    if {[string trim $text] eq ""} {
        logsys warning "transcription is empty (silence, wrong audio format, or wrong model?)"
    }
    catch {save_log $text}
    if {$::capture_sink eq "window"} { win_capture_done $text } else { on_source_ready $text }
}
proc poll_recorder {} {
    if {$::recorder_pid == 0} return
    if {[catch {exec kill -0 $::recorder_pid}]} {
        set ::recorder_pid 0
        # Ended without stop_recording (recorder crash, audio-stack death):
        # close the same doors a stop does (listener, auto-stop timer, state)
        # so a later press starts fresh instead of reaching a corpse's
        # listener, then transcribe what was captured.
        if {$::state eq "recording"} { stop_recording recorder-death }
        transcribe
    } else { set ::poll_id [after 200 poll_recorder] }
}
# Linux: pw-record, else sox. macOS: sox.
proc resolve_recorder {} {
    if {!$::MACOS && ![catch {exec which pw-record}]} { return pw-record }
    if {![catch {exec which sox}]} { return sox }
    return ""
}
proc start_recording {} {
    file mkdir $::CACHE_DIR
    sweep_stale_recordings
    set ::log_stem "[clock format [clock seconds] -format {%Y-%m-%dT%H-%M-%S}]-[pid]"
    # In --debug, name the recording so sweep_stale_recordings (scribe-<pid>.wav
    # only) never reaps it: the kept audio and its replay script survive later runs.
    if {$::debug_mode} {
        set ::tmpfile [file join $::CACHE_DIR "scribe-debug-$::log_stem.wav"]
    } else {
        set ::tmpfile [file join $::CACHE_DIR "scribe-[pid].wav"]
    }
    set ::start_ms [clock milliseconds]
    set source ""
    if {$::CAPTURE ne ""} { set source [resolve_source $::CAPTURE] }
    # Both recorders drain their capture buffer and finalise the WAV header on
    # SIGTERM, which stop_recording relies on (parecord discarded ~2s of buffer,
    # losing the tail of every recording). For sox, --input-buffer 3200 caps the
    # tail at 0.1s of audio (16kHz mono s16); the pulse default buffered ~2s.
    switch -- [resolve_recorder] {
        sox {
            set atype [expr {$::MACOS ? "coreaudio" : "pulseaudio"}]
            if {$source eq ""} { set source default }
            set pcmd [list sox -q --input-buffer 3200 -t $atype $source \
                          -r 16000 -c 1 -b 16 -e signed-integer $::tmpfile]
        }
        pw-record {
            set pcmd [list pw-record --rate=16000 --channels=1 --format=s16]
            if {$source ne ""} { lappend pcmd "--target=$source" }
            lappend pcmd $::tmpfile
        }
        default {
            ui_error "no recorder found: install sox (or pw-record on Linux)"
            return
        }
    }
    if {[catch {set ::recorder_pid [exec {*}$pcmd &]} err]} {
        ui_error "failed to start [lindex $pcmd 0]: $err"; return
    }
    logsys notice "recording started: [lindex $pcmd 0] pid $::recorder_pid → $::tmpfile (auto-stop ${::TIMEOUT_S}s)"
    set ::poll_id [after 200 poll_recorder]
    set ::auto_stop_id [after [expr {$::TIMEOUT_S * 1000}] [list stop_recording auto-stop]]
}

#==============================================================================
# SECOND-PRESS SOCKET (voice): stop / status / pause / resume
#==============================================================================

# The exchange runs non-blocking against a deadline: a healthy peer answers in
# milliseconds, and a wedged one must not hang the press invisibly (a hung probe
# is a keystroke that silently did nothing). On timeout, exit nonzero without
# recording: the peer still holds the port, so a second recorder could not
# bind; the log line is what tells the user which pid to kill.
proc probe_running {cmd} {
    if {[catch {socket 127.0.0.1 $::PORT} sock]} { return }
    fconfigure $sock -buffering line -translation lf -blocking 0
    set ::probe_reply ""
    set ::probe_done ""
    set ::probe_banner_seen 0
    fileevent $sock readable [list probe_read $sock $cmd]
    set deadline [after $::SOCKET_TIMEOUT_MS {set ::probe_done timeout}]
    vwait ::probe_done
    after cancel $deadline
    catch {close $sock}
    if {$::probe_done eq "timeout"} {
        logsys warning "running scribe on port $::PORT did not answer '$cmd' within [expr {$::SOCKET_TIMEOUT_MS / 1000}]s — instance wedged? find it with: pgrep -af scribe.tcl"
        exit 1
    }
    logsys notice "press forwarded to running instance: '$cmd' → [expr {$::probe_reply ne "" ? $::probe_reply : $::probe_done}]"
    if {[string match "OK*" $::probe_reply]} { exit 0 }
    exit 1
}
proc probe_read {sock cmd} {
    while {[gets $sock line] >= 0} {
        if {!$::probe_banner_seen} { set ::probe_banner_seen 1; puts $sock $cmd; continue }
        if {[string match "OK*" $line] || [string match "ACK*" $line]} {
            set ::probe_reply $line; set ::probe_done reply; return
        }
    }
    if {[eof $sock]} { set ::probe_done eof }
}
proc serve_listener {} {
    if {[catch {socket -server handle_client -myaddr 127.0.0.1 $::PORT} sock]} {
        logsys err "cannot bind 127.0.0.1:$::PORT: $sock"; return
    }
    set ::listener $sock
}
proc stop_listener {} { if {[info exists ::listener]} { catch {close $::listener}; unset ::listener } }
# The command is read via fileevent with a per-connection deadline, never a
# blocking gets. One client that connects and goes silent would otherwise stall
# the whole event loop: icon animation, the --timeout auto-stop, and recorder
# polling all dead while the mic keeps recording.
proc handle_client {sock _addr _port} {
    fconfigure $sock -buffering line -translation lf -blocking 0
    puts $sock "OK scribe 1"
    set timer [after $::SOCKET_TIMEOUT_MS [list client_expire $sock]]
    fileevent $sock readable [list client_read $sock $timer]
}
proc client_expire {sock} {
    logsys warning "second-press client sent no command within [expr {$::SOCKET_TIMEOUT_MS / 1000}]s — dropping it"
    catch {close $sock}
}
proc client_read {sock timer} {
    if {[gets $sock cmd] < 0} {
        if {[eof $sock]} { after cancel $timer; catch {close $sock} }
        return
    }
    after cancel $timer
    client_dispatch $sock [string trim $cmd]
    catch {close $sock}
}
proc client_dispatch {sock cmd} {
    switch -- $cmd {
        stop  { puts $sock "OK"; after idle [list stop_recording second-press] }
        pause {
            if {$::state eq "paused"} { puts $sock "ACK already-paused" } \
            elseif {$::recorder_pid > 0 && ![catch {exec kill -STOP $::recorder_pid}]} {
                set ::state paused; stop_animate; draw_icon [recording_frac] recording 1; puts $sock "OK"
            } else { puts $sock "ACK pause-failed" }
        }
        resume {
            if {$::state ne "paused"} { puts $sock "ACK not-paused" } \
            elseif {$::recorder_pid > 0 && ![catch {exec kill -CONT $::recorder_pid}]} {
                enter_state recording; puts $sock "OK"
            } else { puts $sock "ACK resume-failed" }
        }
        status { puts $sock "state $::state"; puts $sock "OK" }
        default { puts $sock "ACK unknown-command" }
    }
}
proc stop_recording {{reason request}} {
    stop_listener
    if {$::auto_stop_id ne ""} { after cancel $::auto_stop_id; set ::auto_stop_id "" }
    logsys notice "recording stopped ($reason) after [expr {$::start_ms > 0 ? ([clock milliseconds] - $::start_ms) / 1000 : 0}]s"
    if {$::recorder_pid > 0} {
        if {$::state eq "paused"} { catch {exec kill -CONT $::recorder_pid} }
        catch {exec kill $::recorder_pid}
    }
    if {$::state ne "transcribing"} { enter_state transcribing }
}

#==============================================================================
# CLIPBOARD INPUT
#==============================================================================

proc read_clipboard {} {
    if {[catch {clipboard get -type UTF8_STRING} content]} {
        if {[catch {clipboard get} content]} { return "" }
    }
    return [string trim $content]
}
proc acquire_clipboard {} {
    set txt [read_clipboard]
    if {$txt eq ""} { after 300 acquire_clipboard; return }
    on_source_ready $txt
}

#==============================================================================
# SELF-TEST
#==============================================================================

proc check {label cond {detail ""}} {
    upvar 1 fail fail
    if {[uplevel 1 [list expr $cond]]} { puts "PASS: $label" } \
    else { puts "FAIL: $label $detail"; set fail 1 }
}
proc run_self_test {} {
    set fail 0
    loadDialect

    set ::DIALECT off
    set ::QSTYLE double
    check "double apostrophe" {[normalize_text "I'm"] eq "I’m"}
    check "double quotation pair" {[normalize_text "say \"hi\""] eq "say “hi”"}
    set ::QSTYLE single
    check "single quotation pair" {[normalize_text "say \"hi\""] eq "say ‘hi’"}
    check "single apostrophe still ’" {[normalize_text "I'm"] eq "I’m"}
    set ::QSTYLE straight
    check "straight leaves ASCII" {[normalize_text "I'm \"x\""] eq "I'm \"x\""}
    set ::QSTYLE double

    set ::DIALECT british
    check "ize->ise" {[britishize "I realize this"] eq "I realise this"}
    check "ization->isation" {[britishize "organization"] eq "organisation"}
    check "ize exception size" {[britishize "the size"] eq "the size"}
    check "case preserved" {[britishize "Realize"] eq "Realise"}
    if {[dict size $::ukmap] > 0} { check "dictionary colour" {[britishize "color"] eq "colour"} }
    set ::DIALECT off

    if {$::MACOS} {
        check "applescript quote escapes" {[applescript_quote "a\"b\\c\nd"] eq "\"a\\\"b\\\\c\\nd\""}
    } else {
        set acts [build_inject_actions "ab cd"]
        check "inject types words" {[string match "*type ab*" $acts] && [string match "*type cd*" $acts]}
        check "inject ibus for curly" {[string match "*ctrl+shift+u*" [build_inject_actions "x’y"]]}
        check "paste key" {$::PASTE_KEY eq "key ctrl+v"}
        check "enter key" {$::ENTER_KEY eq "key enter"}
    }
    if {$::MACOS} {
        if {![catch {exec which sox}]} { check "recorder is sox" {[resolve_recorder] eq "sox"} }
    } elseif {![catch {exec which pw-record}]} {
        check "recorder prefers pw-record" {[resolve_recorder] eq "pw-record"}
    }

    set _ini [parse_ini "default_provider = \"x\"\n# a comment\n\[provider.x\]\napi_key = \"k\"\nmodel = 'm'  # inline\nunload_after_style = true\n"]
    check "ini default_provider" {[dict get $_ini "" default_provider] eq "x"}
    check "ini provider section"  {[dict get $_ini "provider.x" api_key] eq "k"}
    check "ini single-quote val"  {[dict get $_ini "provider.x" model] eq "m"}
    check "ini boolean opt-in"    {[string is true -strict [dict get $_ini "provider.x" unload_after_style]]}

    # --- transcription backend (whisper server) ---
    set _w [parse_ini "\[whisper\]\nmodel = /m/ggml.bin\nserver_url = http://localhost:8080\nfallback_local = true\n"]
    check "ini whisper server_url" {[dict get $_w whisper server_url] eq "http://localhost:8080"}
    set _sv $::WHISPER_SERVER; set _fb $::WHISPER_FALLBACK; set _md $::MODEL
    set ::WHISPER_SERVER ""; set ::WHISPER_FALLBACK ""; set ::MODEL ""
    applyWhisperConfig $_w
    check "applyWhisperConfig model"    {$::MODEL eq "/m/ggml.bin"}
    check "applyWhisperConfig server"   {$::WHISPER_SERVER eq "http://localhost:8080"}
    check "applyWhisperConfig fallback" {$::WHISPER_FALLBACK == 1}
    check "transcribe_use_server on"    {[transcribe_use_server]}
    set ::WHISPER_SERVER ""
    check "transcribe_use_server off"   {![transcribe_use_server]}
    set ::WHISPER_SERVER "http://localhost:8080/"; set _tf $::tmpfile; set ::tmpfile "/tmp/x.wav"
    set _curl [build_server_curl_cmd]
    check "curl posts the wav"    {[lsearch -exact $_curl "file=@/tmp/x.wav"] >= 0}
    check "curl asks json"        {[lsearch -exact $_curl "response_format=json"] >= 0}
    check "curl hits /inference"  {[lindex $_curl end] eq "http://localhost:8080/inference"}
    set ::tmpfile $_tf; set ::WHISPER_SERVER $_sv; set ::WHISPER_FALLBACK $_fb; set ::MODEL $_md

    set ::sourceText "src"; set ::rewriteText "rw"; setActiveArea 1
    check "active=source pane1" {[active_text] eq "src"}
    setActiveArea 2
    check "active=rewrite pane2" {[active_text] eq "rw"}
    check "typing_focus null-safe when nothing focused" {[typing_focus] == 0}

    set ::WINDOW 1; set ::SELF_TEST 1; set ::QSTYLE double
    if {$::AI_AVAILABLE} {
        loadSystemPrompts; loadStyle
        # Dictation-shaped source: a self-correction, a repetition, and a
        # prerequisite recalled late, so the clean-up call has work to do.
        set ::sourceText "so the meeting moves to thursday, no wait, friday, the meeting moves to friday because the client called, oh and before that someone has to book the room"
        foreach {_style _passes _label} {none 2 clean-up-only clear 2 2-pass clear 1 1-pass} {
            set ::STYLE_NAME $_style; loadStyle
            set ::PASSES $_passes
            set ::rewriteState idle; set ::testDone 0
            run_rewrite
            set aid [after 65000 {set ::testDone timeout}]
            vwait ::testDone
            after cancel $aid
            check "$_label rewrite returned" {$::rewriteState eq "done" && [string length $::rewriteText] > 0} "(state=$::rewriteState)"
            if {$_label eq "2-pass"} {
                check "2-pass clean-up call completed" {[string length $::preprocessText] > 0}
                puts "    CLEANED: $::preprocessText"
            }
            puts "    RESULT ($_label): $::rewriteText"
        }
        set ::PASSES 2
    } else {
        puts "SKIP: style pass (no AI provider configured)"
    }

    # Second-press protocol: a client that connects and sends nothing must leave
    # the event loop running (timers still fire) and be dropped at the deadline.
    set _saveT $::SOCKET_TIMEOUT_MS
    set ::SOCKET_TIMEOUT_MS 200
    serve_listener
    if {[info exists ::listener]} {
        set _silent [socket 127.0.0.1 $::PORT]
        set ::_beat 0; after 80 {set ::_beat 1}; vwait ::_beat
        check "silent client leaves event loop alive" {$::_beat == 1}
        set ::_drop 0; after 400 {set ::_drop 1}; vwait ::_drop
        fconfigure $_silent -blocking 0
        gets $_silent _banner
        gets $_silent _dummy
        check "silent client dropped at deadline" {[eof $_silent]}
        catch {close $_silent}
        stop_listener
    } else { puts "SKIP: second-press socket (port $::PORT busy)" }
    set ::SOCKET_TIMEOUT_MS $_saveT

    set ::DELIVER clipboard
    if {![catch {set_clipboard "round-trip-probe"}]} {
        set back ""
        switch -- [clip_backend] {
            macos   { catch {set back [exec pbpaste]} }
            wayland { catch {set back [exec wl-paste -n]} }
            x11     { catch {set back [exec xclip -selection clipboard -o]} }
        }
        check "clipboard round-trip" {$back eq "round-trip-probe"}
    }

    set ::STYLE_ON 0; set ::INPUT voice; set ::STYLE_NAME "clear"; set ::DELIVER paste
    if {![catch {build_review_ui} e]} {
        set ok [expr {[winfo exists .pane1.txt] && [winfo exists .btns.go]}]
        if {$::AI_AVAILABLE} {
            check "review UI builds (rewrite controls present without --style)" \
                {$ok && [winfo exists .pane2.txt] && [winfo exists .ctrl.stylerow.none] && [winfo exists .ctrl.passrow.p1] && [winfo exists .ctrl.passrow.rewrite] && [winfo exists .pane1.hdr.listen] && ![winfo exists .btns.rewrite] && ![winfo exists .tip]}
            # Under "No style" the passes row greys (moot choice), never hides.
            set ::STYLE_NAME none; set ::styleGuide ""; refresh_rewrite_controls
            check "passes row greys under No style" {[.ctrl.passrow.p1 instate disabled]}
            set ::STYLE_NAME clear; refresh_rewrite_controls
            check "passes row re-enables with a style" {[.ctrl.passrow.p1 instate !disabled]}
        } else {
            check "review UI builds (single pane; Rewrite button invites config)" {$ok && ![winfo exists .pane2.txt] && ![winfo exists .ctrl] && [winfo exists .btns.rewrite] && [winfo exists .pane1.hdr.listen] && ![winfo exists .tip]}
        }
    } else { check "review UI builds" 0 "($e)" }

    # Panes are an editable workspace, and delivery/styling read the live widget.
    if {[winfo exists .pane1.txt]} {
        check "source pane editable" {[.pane1.txt cget -state] eq "normal"}
        .pane1.txt delete 1.0 end; .pane1.txt insert 1.0 "hello"; setActiveArea 1
        check "active_text reads edited pane" {[active_text] eq "hello"}
        if {[winfo exists .pane2.txt]} { check "styled pane editable" {[.pane2.txt cget -state] eq "normal"} }
    }

    # Style picker: setting ::STYLE_NAME + on_style_change reloads the guide and
    # persists the pick, against a scratch state file so the real one is untouched.
    set _saveState $::STATE_STYLE_FILE
    set ::STATE_STYLE_FILE [file join "/tmp" "scribe-selftest-[pid].style"]
    set _other [lindex [styleNames] end]
    set ::STYLE_NAME $_other; set ::styleGuide ""
    on_style_change
    set _persisted ""
    catch { set _fh [open $::STATE_STYLE_FILE r]; set _persisted [string trim [read $_fh]]; close $_fh }
    check "style picker reloads guide and persists pick" \
        {[string length $::styleGuide] > 0 && $::STYLE_NAME eq $_other && $_persisted eq $_other}
    catch {file delete $::STATE_STYLE_FILE}
    set ::STATE_STYLE_FILE $_saveState

    # Passes pick: round-trips through its state file, maps the former pipeline
    # picker's values onto the passes axis, and defaults to 2 when no file
    # exists. Scratch file, so the real pick is untouched.
    set _saveP $::STATE_PIPELINE_FILE
    set _scratchP [file join "/tmp" "scribe-selftest-[pid].pipeline"]
    set ::STATE_PIPELINE_FILE $_scratchP
    savePasses 1
    loadPasses
    check "passes pick persists and reloads" {$::PASSES == 1}
    foreach {_legacy _expect} {2pass 2 1pass 1 style 2} {
        set _fh [open $_scratchP w]; puts -nonewline $_fh $_legacy; close $_fh
        loadPasses
        check "former pipeline pick '$_legacy' maps to $_expect passes" {$::PASSES == $_expect}
    }
    set ::STATE_PIPELINE_FILE [file join "/tmp" "scribe-selftest-[pid].absent"]
    loadPasses
    check "passes default to 2" {$::PASSES == 2}
    catch {file delete $_scratchP}
    set ::STATE_PIPELINE_FILE $_saveP

    puts [expr {$fail ? "SELF-TEST: FAIL" : "SELF-TEST: PASS"}]
    exit $fail
}

#==============================================================================
# MAIN
#==============================================================================

wm withdraw .

if {$::INPUT ni {keyboard voice clipboard ""}} { fatal "--input must be keyboard, voice, or clipboard" }
if {$::DELIVER ni {type paste clipboard stdout}} { fatal "--deliver must be type, paste, clipboard, or stdout" }
if {$::QUOTES ni {"" double single straight}} { fatal "--quotes must be double, single, or straight" }
if {$::DIALECT ni {off british}} { fatal "--dialect must be off or british" }
if {$::STYLE_AUTO ne "" && ![string is integer -strict $::STYLE_AUTO]} { fatal "--auto-style-delay must be an integer (ms)" }
if {$::INPUT eq ""} { set ::INPUT keyboard }
if {!$::WINDOW && $::INPUT eq "keyboard"} { fatal "--no-window requires --input voice|clipboard" }

# Resolve quote style: explicit --quotes wins; else british -> single; else double.
if {$::QUOTES ne ""} {
    set ::QSTYLE $::QUOTES
} else {
    set ::QSTYLE [expr {$::DIALECT eq "british" ? "single" : "double"}]
}

# Voice launch claims the second-press socket here, before the config and style
# loads below, so a second press's blind window (when it cannot yet reach this
# instance) is only the interpreter start, not that plus the loads. The bind is
# the arbiter: win it and this instance is the recorder; find the port already
# held and another instance is recording, so forward this press's command
# ($::CMD, default stop) to it and exit, rather than start a second recorder.
# Only a voice launch takes this path and claims it here; the self-test,
# --test-*, clipboard, and keyboard modes divert to their own wait first.
if {$::INPUT eq "voice" && !$::SELF_TEST && $::TEST_TEXT eq "" && $::TEST_FILE eq ""} {
    probe_running $::CMD
    serve_listener
    if {![info exists ::listener]} {
        # The probe found no instance, yet the bind failed: a rival claimed the
        # port in the gap between probe and bind. Forward to it and exit rather
        # than fall through to recording without owning the port.
        probe_running $::CMD
        exit 1
    }
}

loadConfig
if {$::WHISPER_FALLBACK eq ""} { set ::WHISPER_FALLBACK 0 }  ;# tri-state -> boolean once config+CLI are in
loadDialect
# The style pass is strictly additive (see CLAUDE.md): with no AI provider
# configured, scribe degrades to a dictation tool rather than failing.
if {$::STYLE_ON && !$::AI_AVAILABLE} {
    logsys notice "no AI provider configured — style pass disabled; running as dictation"
    set ::STYLE_ON 0
}
# In a window the Style button is always offered when a provider is configured,
# so load the guide and prompts whenever the feature is reachable; --no-window
# needs them only when --style forces the pass.
if {$::AI_AVAILABLE && ($::WINDOW || $::STYLE_ON)} { loadStyle; loadSystemPrompts; loadPasses }

if {$::SELF_TEST} { after idle run_self_test; vwait forever }
if {$::TEST_TEXT ne ""} { after idle [list on_source_ready $::TEST_TEXT]; vwait forever }
if {$::TEST_FILE ne ""} {
    if {![file readable $::TEST_FILE]} { fatal "--test-file not readable: $::TEST_FILE" }
    set ::tmpfile $::TEST_FILE
    after idle transcribe
    vwait forever
}

if {$::INPUT eq "clipboard"} { after idle acquire_clipboard; vwait forever }

# Keyboard (default): open an empty editable window and wait for the user to type.
if {$::INPUT eq "keyboard"} { after idle [list on_source_ready ""]; vwait forever }

# Voice. The second-press socket was claimed above, before the config load;
# reaching here means this instance won the bind and is the recorder. A second
# press reaches this recorder over that socket.
start_recording
draw_icon 1.0 recording 1
tk systray create -image $::icon_image -text $::APPNAME -button1 {stop_recording tray-click}
enter_state recording
vwait forever

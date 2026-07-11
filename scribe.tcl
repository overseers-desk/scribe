#!/usr/bin/env wish9.0
package require Tk 9

# Scribe — take text you type, dictate, or hold on the clipboard, optionally
# restyle it, and deliver it by typing, pasting, or leaving it on the clipboard.
#
# Behaviour is five independent axes; reading the flags tells the whole story:
#   --input  keyboard | voice | clipboard  where the text comes from (default keyboard)
#   --window | --no-window                 review window, or unattended
#   --deliver type | paste | clipboard     how the result leaves
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
set ::DIALECT_FILE     [file join $::APP_DIR "dialect-us-to-british.tsv"]
set ::LOG_DIR          /var/local/log/dictation
set ::CACHE_DIR        [file join [expr {[info exists ::env(XDG_CACHE_HOME)] && $::env(XDG_CACHE_HOME) ne "" ? $::env(XDG_CACHE_HOME) : "$::env(HOME)/.cache"}] scribe]

set ::VERSION          0.6.2
set ::PORT             4212
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
set ::MODEL            "$::env(HOME)/code/whisper.cpp/models/ggml-medium.en.bin"
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
set ::userTextPrefix   ""
set ::singlePassPrefix ""
set ::styleGuide       ""

# --- runtime ---
set ::recorder_pid  0
set ::tmpfile       ""
set ::log_stem      ""
set ::auto_stop_id  ""
set ::poll_id       ""
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
set ::sourceText    ""
set ::rewriteText   ""
set ::activeArea    1
set ::rewriteState  idle

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
            puts "  --deliver type|paste|clipboard how the result leaves (default paste)"
            puts "  --style                        (no-window) style the text; a window offers styling whenever a provider is configured"
            puts "  --provider NAME                use \[provider.NAME\] from config.ini (else default_provider)"
            puts "  --auto-style-delay MS          (window) auto-style after MS ms; 1 = immediate"
            puts "  --quotes double|single|straight   double: “ ” · single: ‘ ’ · straight: ASCII"
            puts "  --dialect off|british          british: US→UK spelling; default quotes -> single"
            puts "  voice: -m -l -t -to -c --prompt|--prompt-file --key-delay --word-delay -nf -ng -fa -ps"
            puts "  --cmd stop|status|pause|resume  --self-test --test-text S --test-file WAV"
            puts "  --debug                        keep the recording; write a replay .sh of the whisper-cli call"
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

# Resolve an AI provider from config.ini, if one is configured. This NEVER
# fatals: scribe must run as a dictation tool with no config and no keys (see
# CLAUDE.md). On success sets ::AI_AVAILABLE 1 and ::apiKey/::apiBase/::apiModel;
# otherwise leaves ::AI_AVAILABLE 0 and the style pass stays disabled.
proc loadConfig {} {
    set ::AI_AVAILABLE 0
    set path ""
    foreach c [config_candidates] { if {[file exists $c]} { set path $c; break } }
    if {$path eq ""} { loadLegacyDeepseek; return }

    if {[catch {set fh [open $path r]; set data [read $fh]; close $fh} err]} {
        logsys warning "cannot read config $path: $err — running without AI"; return
    }
    set ini [parse_ini $data]
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
    } err]} { fatal "error loading system-prompts.yaml: $err" }
}

proc loadStyle {} {
    set name $::STYLE_NAME
    if {$name eq ""} {
        # The window's own persisted pick wins; a mode-switcher default in
        # current-mode.conf applies when no state file exists; else "clear".
        foreach src [list $::STATE_STYLE_FILE $::CONFIG_FILE] {
            if {$name ne ""} break
            if {[file exists $src]} {
                catch { set f [open $src r]; set name [string trim [read $f]]; close $f }
            }
        }
        if {$name eq ""} { set name "clear" }
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

# The style combobox set ::STYLE_NAME via -textvariable; reload the guide for it
# and persist the pick. The pass itself runs only on a Style click.
proc on_style_change {} {
    loadStyle
    saveStyleChoice $::STYLE_NAME
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

proc buildJSONPayload {model systemPrompt userText} {
    set json "\{\"model\":\"[jsonEscape $model]\","
    append json "\"messages\":\["
    append json "\{\"role\":\"system\",\"content\":\"[jsonEscape $systemPrompt]\"\},"
    append json "\{\"role\":\"user\",\"content\":\"[jsonEscape $userText]\"\}"
    append json "\],\"temperature\":0.7,\"max_tokens\":2000\}"
    return $json
}

proc run_rewrite {} {
    set ::autosend_id ""
    if {$::rewriteState ni {idle error}} return
    set ::rewriteState running
    paneRewriteStatus "Styling…"
    if {!$::WINDOW} { enter_state styling }

    package require http
    package require tls
    if {[catch { ::tls::init -autoservername true; http::register https 443 [list ::tls::socket -autoservername true] }]} {
        http::register https 443 ::tls::socket
    }

    # Style what is currently in the source pane (the user may have edited the
    # transcription/clipboard text); fall back to the variable when windowless.
    set src [expr {[winfo exists .pane1.txt] ? [string trim [.pane1.txt get 1.0 end]] : $::sourceText}]
    set systemPrompt "${::singlePassPrefix}\n${::styleGuide}"
    set wrappedText  "${::userTextPrefix}${src}\n"
    set payload [encoding convertto utf-8 [buildJSONPayload $::apiModel $systemPrompt $wrappedText]]
    set headers [list Authorization "Bearer $::apiKey" Content-Type "application/json; charset=utf-8"]
    if {[catch {
        set ::httpToken [http::geturl "${::apiBase}/chat/completions" \
            -method POST -headers $headers -type "application/json" \
            -query $payload -timeout 60000 -command handle_rewrite]
    } err]} {
        set ::rewriteState error; paneRewriteStatus "Error: $err"; signalTestDone; styleDone
    }
}

proc handle_rewrite {token} {
    set ::httpToken ""
    set status [http::status $token]
    set ncode  [http::ncode $token]
    set data   [encoding convertfrom utf-8 [http::data $token]]
    after idle [list http::cleanup $token]
    if {$status ne "ok"} { set ::rewriteState error; paneRewriteStatus "Network error: $status"; signalTestDone; styleDone; return }
    if {$ncode != 200}   { set ::rewriteState error; paneRewriteStatus "API error $ncode"; signalTestDone; styleDone; return }
    if {[catch {
        package require json
        set resp [json::json2dict $data]
        set content [dict get [lindex [dict get $resp choices] 0] message content]
        set content [string map {— " - "} $content]
        set ::rewriteText [normalize_text [string trim $content]]
        set ::rewriteState done
        paneSetRewrite $::rewriteText
        setActiveArea 2
    } err]} {
        set ::rewriteState error; paneRewriteStatus "Parse error: $err"
    }
    signalTestDone
    styleDone
}

proc signalTestDone {} { if {$::SELF_TEST} { set ::testDone 1 } }

# Unattended: once the (blocking) style pass returns, deliver.
proc styleDone {} {
    if {$::WINDOW || $::SELF_TEST} return
    deliver_now [expr {$::rewriteState eq "done" ? $::rewriteText : $::sourceText}]
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
    # In window mode, hide the review window first so focus returns to the prior
    # window before we type/paste. In no-window mode there is no window to hide;
    # calling `wm withdraw .` on this Tk build maps-then-unmaps the toplevel (a
    # visible flash) and steals focus, so the paste would race focus return and
    # land the prior clipboard. Skip the window poke entirely, as the windowless
    # typing path always has.
    switch -- $::DELIVER {
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
    catch {after cancel $::autosend_id}
    catch {tk systray destroy}
    if {$::tmpfile ne "" && $::TEST_FILE eq "" && !$::debug_mode} { catch {file delete $::tmpfile} }
    after 0 [list exit $code]
}
# A hard failure after the app has launched (recorder, whisper, delivery). In a
# window session, surface it as a dialog so it is not lost to stderr/journal;
# always log it and exit non-zero. There is no cheap, portable pre-flight for
# GPU/VRAM sufficiency — nvidia-smi is NVIDIA-only and Vulkan/Metal/ROCm/CPU each
# differ — so scribe reports the backend's own failure rather than guessing.
proc ui_error {msg {detail ""}} {
    logsys err "$msg[expr {$detail ne "" ? " ($detail)" : ""}]"
    catch {tk systray destroy}
    if {$::WINDOW} {
        # Keep the dialog readable: show the short human message, never the raw
        # backend dump (a whisper stderr tail runs taller than the screen). The
        # full detail is in the log above.
        set shown [expr {[string length $msg] > 400 ? "[string range $msg 0 399]…" : $msg}]
        catch {wm withdraw .; tk_messageBox -type ok -icon error -title "Scribe" -message $shown}
    }
    finish 1
}

#==============================================================================
# REVIEW WINDOW
#==============================================================================

set ::HL_COLOR "#cfe8ff"
set ::PANE_BG  "#ffffff"

# Style with the configured provider. With none configured, tell the user how to
# add one instead of doing nothing, so the Style button stays meaningful in the
# zero-config case rather than hiding (see the CLAUDE.md invariant).
proc style_or_prompt {} {
    if {$::AI_AVAILABLE} { run_rewrite; return }
    set cfg [lindex [config_candidates] 0]
    tk_messageBox -parent . -type ok -icon info \
        -title "Styling needs an AI provider" \
        -message "No AI provider is configured yet." \
        -detail "Add one to:\n$cfg\n\nSee config.example.ini for the format — any OpenAI-compatible endpoint, including a local Ollama model. Reopen Scribe once it is set."
}

proc build_review_ui {} {
    wm title . "Scribe"
    set srcLabel [expr {$::INPUT eq "clipboard" ? "Clipboard" : ($::INPUT eq "voice" ? "Dictated" : "Text")}]
    # The styled pane and its controls exist only when an AI provider is
    # configured; with none, scribe shows a single dictation pane (see CLAUDE.md).
    set styleable $::AI_AVAILABLE

    pack [ttk::frame .pane1 -padding 6] -fill both -expand 1
    pack [ttk::label .pane1.lbl -text $srcLabel] -anchor w
    text .pane1.txt -height 8 -width 80 -wrap word -relief solid -borderwidth 2 -takefocus 0
    pack .pane1.txt -fill both -expand 1
    bind .pane1.txt <Button-1> {setActiveArea 1}

    if {$styleable} {
        pack [ttk::frame .pane2 -padding 6] -fill both -expand 1
        pack [ttk::frame .pane2.hdr] -anchor w -fill x
        pack [ttk::label .pane2.hdr.lbl -text "Styled"] -side left
        ttk::combobox .pane2.hdr.style -state readonly -width 12 \
            -values [styleNames] -textvariable ::STYLE_NAME -takefocus 0
        bind .pane2.hdr.style <<ComboboxSelected>> {on_style_change; focus .}
        pack .pane2.hdr.style -side left -padx 6
        text .pane2.txt -height 8 -width 80 -wrap word -relief solid -borderwidth 2 -takefocus 0
        pack .pane2.txt -fill both -expand 1
        bind .pane2.txt <Button-1> {setActiveArea 2}
    }

    set primary [expr {$::DELIVER eq "type" ? "Type" : ($::DELIVER eq "clipboard" ? "Copy" : "Paste")}]
    pack [ttk::frame .btns -padding 6] -fill x
    ttk::button .btns.go -text "$primary  (Space · Ctrl+↵ while editing)" -command {deliver_now [active_text] 0} -takefocus 0
    pack .btns.go -side left -padx 4
    # The Style button is always offered so styling is discoverable; unconfigured,
    # it points the user at config.ini rather than being hidden (see style_or_prompt).
    ttk::button .btns.style -text "Style" -command {style_or_prompt} -takefocus 0
    pack .btns.style -side left -padx 4
    ttk::button .btns.copy -text "Copy to clipboard" -command {set_clipboard [active_text]; finish 0} -takefocus 0
    pack .btns.copy -side left -padx 4

    .pane1.txt insert 1.0 $::sourceText
    if {$styleable} {
        if {!$::STYLE_ON} { paneRewriteStatus "Press Style to rewrite in the selected style." }
    }

    # Focus-dependent keys: when a text pane holds focus the Text class inserts the
    # character first (bindtags: {.paneN.txt Text . all}) and the guarded toplevel
    # binding no-ops, so Space/Enter type. When focus is on the toplevel (pre-filled
    # voice/clipboard modes) they deliver, as before. Ctrl+Enter always delivers.
    bind . <space>          {if {![typing_focus]} {deliver_now [active_text] 0; break}}
    bind . <Return>         {if {![typing_focus]} {deliver_now [active_text] 1; break}}
    bind . <Control-Return> {deliver_now [active_text] 0; break}
    bind . <Escape>         {finish 0; break}
    if {$styleable} {
        bind . <Up>   {if {![typing_focus]} {setActiveArea 1; break}}
        bind . <Down> {if {![typing_focus]} {setActiveArea 2; break}}
    }
    wm protocol . WM_DELETE_WINDOW {set_clipboard [active_text]; finish 0}
    refresh_highlight
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
proc enter_state {newstate} { stop_animate; set ::state $newstate; set ::blink 1; start_animate }

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
proc save_log {text} {
    if {$::log_stem eq ""} return
    if {[catch {file mkdir $::LOG_DIR}]} return
    catch {
        if {[file exists $::tmpfile]} { file copy -force -- $::tmpfile [file join $::LOG_DIR "$::log_stem.wav"] }
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
proc save_debug_command {wcmd} {
    set cmdfile [file rootname $::tmpfile].sh
    if {[catch {
        set fh [open $cmdfile w]
        puts $fh "#!/bin/sh"
        puts $fh "# scribe --debug replay of the whisper-cli call on [file tail $::tmpfile]."
        puts $fh "# scribe itself runs this with 2>/dev/null; kept here so you see timings/errors."
        puts $fh [shell_quote $wcmd]
        close $fh
        file attributes $cmdfile -permissions 0755
    } err]} { dbg "could not write $cmdfile: $err"; return }
    dbg "replay script: $cmdfile"
    dbg "audio kept:    $::tmpfile"
}

proc transcribe {} {
    if {$::done} return
    set ::done 1
    # The --test-file path reaches here without start_recording, so ensure the
    # cache dir (home of the whisper stderr file below) exists on both paths.
    file mkdir $::CACHE_DIR
    # Fail loudly on a missing model rather than let whisper-cli emit nothing and
    # deliver blank. --model is often given relative; report the cwd it resolved
    # against so a wrong relative path is obvious.
    if {![file exists $::MODEL]} {
        ui_error "whisper model not found: $::MODEL (resolved from cwd [pwd]); pass an absolute --model"
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
}
proc transcribe_collect {} {
    append ::wbuf [read $::wchan]
    if {![eof $::wchan]} return
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
    stop_animate
    # An empty transcript after a clean exit is not an error, but it is the other
    # way a blank result happens (silence, wrong audio format, wrong model), so
    # say so rather than deliver nothing without explanation.
    if {[string trim $::wbuf] eq ""} {
        logsys warning "whisper returned an empty transcript (silence, wrong audio format, or wrong model?)"
    }
    catch {save_log $::wbuf}
    on_source_ready $::wbuf
}
proc poll_recorder {} {
    if {$::recorder_pid == 0} return
    if {[catch {exec kill -0 $::recorder_pid}]} { set ::recorder_pid 0; transcribe } \
    else { set ::poll_id [after 200 poll_recorder] }
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
    set ::poll_id [after 200 poll_recorder]
    set ::auto_stop_id [after [expr {$::TIMEOUT_S * 1000}] stop_recording]
}

#==============================================================================
# SECOND-PRESS SOCKET (voice): stop / status / pause / resume
#==============================================================================

proc probe_running {cmd} {
    if {[catch {socket 127.0.0.1 $::PORT} sock]} { return }
    fconfigure $sock -buffering line -translation lf
    gets $sock _banner; puts $sock $cmd
    set reply ""
    while {[gets $sock line] >= 0} {
        if {[string match "OK*" $line] || [string match "ACK*" $line]} { set reply $line; break }
    }
    close $sock
    if {[string match "OK*" $reply]} { exit 0 }
    exit 1
}
proc serve_listener {} {
    if {[catch {socket -server handle_client -myaddr 127.0.0.1 $::PORT} sock]} {
        logsys err "cannot bind 127.0.0.1:$::PORT: $sock"; return
    }
    set ::listener $sock
}
proc stop_listener {} { if {[info exists ::listener]} { catch {close $::listener}; unset ::listener } }
proc handle_client {sock _addr _port} {
    fconfigure $sock -buffering line -translation lf
    puts $sock "OK scribe 1"
    if {[gets $sock cmd] < 0} { close $sock; return }
    switch -- [string trim $cmd] {
        stop  { puts $sock "OK"; after idle stop_recording }
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
    close $sock
}
proc stop_recording {} {
    stop_listener
    if {$::auto_stop_id ne ""} { after cancel $::auto_stop_id; set ::auto_stop_id "" }
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

    set _ini [parse_ini "default_provider = \"x\"\n# a comment\n\[provider.x\]\napi_key = \"k\"\nmodel = 'm'  # inline\n"]
    check "ini default_provider" {[dict get $_ini "" default_provider] eq "x"}
    check "ini provider section"  {[dict get $_ini "provider.x" api_key] eq "k"}
    check "ini single-quote val"  {[dict get $_ini "provider.x" model] eq "m"}

    set ::sourceText "src"; set ::rewriteText "rw"; setActiveArea 1
    check "active=source pane1" {[active_text] eq "src"}
    setActiveArea 2
    check "active=rewrite pane2" {[active_text] eq "rw"}
    check "typing_focus null-safe when nothing focused" {[typing_focus] == 0}

    set ::WINDOW 1; set ::SELF_TEST 1; set ::QSTYLE double
    if {$::AI_AVAILABLE} {
        loadSystemPrompts; loadStyle
        set ::sourceText "so the meeting moves to friday because the client called"
        set ::rewriteState idle; set ::testDone 0
        run_rewrite
        set aid [after 65000 {set ::testDone timeout}]
        vwait ::testDone
        after cancel $aid
        check "style pass returned" {$::rewriteState eq "done" && [string length $::rewriteText] > 0} "(state=$::rewriteState)"
        puts "    STYLED: $::rewriteText"
    } else {
        puts "SKIP: style pass (no AI provider configured)"
    }

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
            check "review UI builds (style controls present without --style)" \
                {$ok && [winfo exists .pane2.txt] && [winfo exists .btns.style] && [winfo exists .pane2.hdr.style] && ![winfo exists .tip]}
        } else {
            check "review UI builds (single pane; Style button invites config)" {$ok && ![winfo exists .pane2.txt] && [winfo exists .btns.style] && ![winfo exists .tip]}
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

    puts [expr {$fail ? "SELF-TEST: FAIL" : "SELF-TEST: PASS"}]
    exit $fail
}

#==============================================================================
# MAIN
#==============================================================================

wm withdraw .

if {$::INPUT ni {keyboard voice clipboard ""}} { fatal "--input must be keyboard, voice, or clipboard" }
if {$::DELIVER ni {type paste clipboard}} { fatal "--deliver must be type, paste, or clipboard" }
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

loadConfig
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
if {$::AI_AVAILABLE && ($::WINDOW || $::STYLE_ON)} { loadStyle; loadSystemPrompts }

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

# Voice. A second press reaches the running recorder over the socket.
probe_running $::CMD
serve_listener
start_recording
draw_icon 1.0 recording 1
tk systray create -image $::icon_image -text $::APPNAME -button1 stop_recording
enter_state recording
vwait forever

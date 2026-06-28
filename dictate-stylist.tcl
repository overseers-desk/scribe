#!/usr/bin/env wish9.0
package require Tk 9

# Dictate-Stylist — voice-driven style/reorder tool.
#
# Press a hotkey to start recording; press again (or click the tray icon) to
# stop. whisper-cli transcribes; a review window shows the raw transcript and,
# one second later, an AI rewrite. Choose the version you prefer and either
# copy it to the clipboard or copy-and-paste it into the previously focused
# window (Ctrl+V, optionally followed by Enter).
#
# Bind it to a GNOME custom shortcut, the same way the companion dictation tool
# is bound, e.g.
#   env LD_LIBRARY_PATH=/usr/local/src/tk-wayland/unix \
#       /usr/local/src/tk-wayland/unix/wish \
#       ~/path/to/dictate-stylist.tcl \
#       --timeout 300 \
#       --model ~/path/to/whisper.cpp/models/ggml-medium.en.bin \
#       --prompt-file ~/path/to/.whisper-prompt-file
# Use a key other than the dictation tool's, so the two can run side by side.
#
# Requires: dotool, whisper-cli, parecord (PulseAudio), wl-copy (wl-clipboard).
# The recording pipeline is copied/adapted from the companion dictation tool;
# the DeepSeek call is copied from this repo's language-stylist.tcl. Step 1
# does a single style pass only — reordering (two-pass analysis) is deferred.

#==============================================================================
# CONFIGURATION
#==============================================================================

set ::APP_DIR          [file dirname [file normalize [info script]]]
set ::DEEPSEEK_CONFIG  [file join $::APP_DIR "deepseek.json"]
set ::STYLES_DIR       [file join $::APP_DIR "styles"]
set ::SYSTEM_PROMPTS   [file join $::APP_DIR "system-prompts.yaml"]
set ::CONFIG_FILE      [file join $::APP_DIR "current-mode.conf"]
set ::LOG_DIR          /var/local/log/dictation
set ::CACHE_DIR        [file join [expr {[info exists ::env(XDG_CACHE_HOME)] && $::env(XDG_CACHE_HOME) ne "" ? $::env(XDG_CACHE_HOME) : "$::env(HOME)/.cache"}] dictate-stylist]

# Own port + appname so the two tools (the dictation tool uses 4211) never
# cross their second-press re-entry signals.
set ::PORT             4212
set ::APPNAME          "dictate-stylist-[pid]"

set ::MODEL            "$::env(HOME)/code/whisper.cpp/models/ggml-medium.en.bin"
set ::LANG             en
set ::TIMEOUT_S        300
set ::THREADS          4
set ::CAPTURE          ""
set ::PROMPT           ""
set ::NO_FALLBACK      1
set ::NO_GPU           0
set ::CMD              stop
set ::debug_mode       0

# Auto-style: rewrite the transcript automatically this long after the review
# window appears. Off by default — set --auto-style-delay (e.g. 1s) to enable.
# AUTO_STYLE_RAW holds the unparsed flag value; AUTO_STYLE_MS the parsed ms
# ("" = off).
set ::AUTO_STYLE_RAW   ""
set ::AUTO_STYLE_MS    ""

# Test hooks. --test-text skips the mic and seeds the transcript directly.
# --self-test runs the headless assertion harness and exits.
set ::TEST_TEXT        ""
set ::SELF_TEST        0

# DeepSeek config (filled by loadDeepSeekConfig)
set ::apiKey  ""
set ::apiBase ""
set ::apiModel ""

# Prompt components (filled by loadSystemPrompts / loadStyle)
set ::userTextPrefix   ""
set ::singlePassPrefix ""
set ::styleName        ""
set ::styleGuide       ""

# Runtime state
set ::parecord_pid  0
set ::tmpfile       ""
set ::log_stem      ""
set ::auto_stop_id  ""
set ::poll_id       ""
set ::start_ms      0
set ::state         idle
set ::done          0
set ::httpToken     ""
set ::autosend_id   ""

# Review state
set ::dictatedText  ""
set ::rewriteText   ""
set ::activeArea    1            ;# 1 = dictated, 2 = rewritten
set ::rewriteState  idle         ;# idle | running | done | error

#==============================================================================
# ARGUMENT PARSING  (manual switch, like the dictation tool)
#==============================================================================

set prompt_seen 0
for {set i 0} {$i < [llength $::argv]} {incr i} {
    set arg [lindex $::argv $i]
    switch -- $arg {
        -m  - --model      { set ::MODEL     [lindex $::argv [incr i]] }
        -l  - --language   { set ::LANG      [lindex $::argv [incr i]] }
        -t  - --threads    { set ::THREADS   [lindex $::argv [incr i]] }
        -c  - --capture    { set ::CAPTURE   [lindex $::argv [incr i]] }
        -to - --timeout    { set ::TIMEOUT_S [lindex $::argv [incr i]] }
        --prompt {
            if {$prompt_seen} { puts stderr "dictate-stylist: --prompt and --prompt-file are mutually exclusive"; exit 1 }
            set prompt_seen 1
            set ::PROMPT [lindex $::argv [incr i]]
        }
        --prompt-file {
            if {$prompt_seen} { puts stderr "dictate-stylist: --prompt and --prompt-file are mutually exclusive"; exit 1 }
            set prompt_seen 1
            set pf [lindex $::argv [incr i]]
            if {[catch {set fh [open $pf r]; set ::PROMPT [string trim [read $fh]]; close $fh} err]} {
                puts stderr "dictate-stylist: cannot read --prompt-file $pf: $err"; exit 1
            }
        }
        -nf - --no-fallback { set ::NO_FALLBACK 1 }
        -ng - --no-gpu      { set ::NO_GPU      1 }
        --debug             { set ::debug_mode  1 }
        --auto-style-delay  { set ::AUTO_STYLE_RAW [lindex $::argv [incr i]] }
        --test-text         { set ::TEST_TEXT [lindex $::argv [incr i]] }
        --self-test         { set ::SELF_TEST 1 }
        --cmd {
            set ::CMD [lindex $::argv [incr i]]
            if {$::CMD ni {stop status}} {
                puts stderr "dictate-stylist: --cmd must be stop|status, got: $::CMD"; exit 1
            }
        }
        -h - --help {
            puts "Usage: dictate-stylist \[options\]"
            puts "  -m/--model PATH   -l/--language LANG   -t/--threads N"
            puts "  -to/--timeout S   -c/--capture SRC"
            puts "  --prompt STR | --prompt-file PATH   (whisper prompt)"
            puts "  -nf/--no-fallback  -ng/--no-gpu  --debug"
            puts "  --auto-style-delay DUR   auto-rewrite after DUR (e.g. 1s, 500ms); off if unset"
            puts "  --test-text STR   seed transcript, skip the mic"
            puts "  --self-test       run headless assertions and exit"
            exit 0
        }
        default { puts stderr "dictate-stylist: unknown argument: $arg"; exit 1 }
    }
}

proc dbg {msg} { if {$::debug_mode} { puts stderr "dictate-stylist \[debug\]: $msg" } }

proc fatal {msg} { puts stderr "dictate-stylist: $msg"; exit 1 }

# Parse an auto-style delay into milliseconds. Accepts "1s", "500ms", or a bare
# number (read as seconds, since the user thinks in seconds).
proc parse_delay {s} {
    set s [string trim $s]
    if {[regexp {^([0-9]+)ms$} $s -> n]} { return $n }
    if {[regexp {^([0-9]+)s$}  $s -> n]} { return [expr {$n * 1000}] }
    if {[regexp {^([0-9]+)$}   $s -> n]} { return [expr {$n * 1000}] }
    fatal "bad --auto-style-delay: '$s' (use e.g. 1s, 500ms)"
}

#==============================================================================
# CONFIG LOADING  (copied/adapted from language-stylist.tcl)
#==============================================================================

proc loadDeepSeekConfig {} {
    if {![file exists $::DEEPSEEK_CONFIG]} { fatal "missing deepseek.json at $::DEEPSEEK_CONFIG" }
    if {[catch {
        package require json
        set f [open $::DEEPSEEK_CONFIG r]; set data [read $f]; close $f
        set cfg [json::json2dict $data]
        set ::apiKey   [expr {[dict exists $cfg api_key]  ? [dict get $cfg api_key]  : ""}]
        set ::apiBase  [expr {[dict exists $cfg api_base] ? [dict get $cfg api_base] : "https://api.deepseek.com"}]
        set ::apiModel [expr {[dict exists $cfg model]    ? [dict get $cfg model]    : "deepseek-chat"}]
    } err]} { fatal "error loading deepseek.json: $err" }
    if {$::apiKey eq ""} { fatal "api_key not found in deepseek.json" }
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

# Pick the style. current-mode.conf holds the last-used style name; if it is
# unreadable (it is permission-restricted here) fall back to "clear".
proc loadStyle {} {
    set name "clear"
    if {[file exists $::CONFIG_FILE]} {
        catch {
            set f [open $::CONFIG_FILE r]; set name [string trim [read $f]]; close $f
        }
    }
    if {$name eq ""} { set name "clear" }
    set path [file join $::STYLES_DIR "$name.txt"]
    if {![file exists $path]} {
        set files [lsort [glob -nocomplain -directory $::STYLES_DIR *.txt]]
        if {[llength $files] == 0} { fatal "no style files in $::STYLES_DIR" }
        set path [lindex $files 0]
        set name [file rootname [file tail $path]]
    }
    set f [open $path r]; set ::styleGuide [read $f]; close $f
    set ::styleName $name
    dbg "style = $name"
}

#==============================================================================
# JSON HELPERS  (copied from language-stylist.tcl)
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
            default {
                if {$code < 32} {
                    append result [format "\\u%04x" $code]
                } else {
                    append result $char
                }
            }
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

#==============================================================================
# DEEPSEEK REWRITE (single-pass style edit)
#==============================================================================

proc run_rewrite {} {
    set ::autosend_id ""
    if {$::rewriteState ne "idle"} return
    set ::rewriteState running
    paneRewriteStatus "Rewriting…"

    package require http
    package require tls
    if {[catch {
        ::tls::init -autoservername true
        http::register https 443 [list ::tls::socket -autoservername true]
    }]} {
        http::register https 443 ::tls::socket
    }

    set systemPrompt "${::singlePassPrefix}\n${::styleGuide}"
    set wrappedText  "${::userTextPrefix}${::dictatedText}\n"
    set payload [encoding convertto utf-8 [buildJSONPayload $::apiModel $systemPrompt $wrappedText]]

    set headers [list Authorization "Bearer $::apiKey" Content-Type "application/json; charset=utf-8"]
    if {[catch {
        set ::httpToken [http::geturl "${::apiBase}/chat/completions" \
            -method POST -headers $headers -type "application/json" \
            -query $payload -timeout 60000 -command handle_rewrite]
    } err]} {
        set ::rewriteState error
        paneRewriteStatus "Error: $err"
        signalTestDone
    }
}

proc handle_rewrite {token} {
    set ::httpToken ""
    set status [http::status $token]
    set ncode  [http::ncode $token]
    set data   [encoding convertfrom utf-8 [http::data $token]]
    after idle [list http::cleanup $token]

    if {$status ne "ok"} { set ::rewriteState error; paneRewriteStatus "Network error: $status"; signalTestDone; return }
    if {$ncode != 200}   { set ::rewriteState error; paneRewriteStatus "API error $ncode"; signalTestDone; return }

    if {[catch {
        package require json
        set resp [json::json2dict $data]
        set content [dict get [lindex [dict get $resp choices] 0] message content]
        set content [string map {— " - "} $content]
        set ::rewriteText [string trim $content]
        set ::rewriteState done
        paneSetRewrite $::rewriteText
        setActiveArea 2
    } err]} {
        set ::rewriteState error
        paneRewriteStatus "Parse error: $err"
    }
    signalTestDone
}

# In self-test the harness blocks on this flag.
proc signalTestDone {} { if {$::SELF_TEST} { set ::testDone 1 } }

#==============================================================================
# CLIPBOARD + PASTE PRIMITIVES
#==============================================================================

proc active_text {} {
    return [expr {$::activeArea == 2 ? $::rewriteText : $::dictatedText}]
}

proc set_clipboard {txt} {
    # wl-copy forks a persistent daemon that serves the paste request.
    exec wl-copy -- $txt
}

# dotool chords. The return is a separate keystroke sent after a gap, so the
# terminal finishes ingesting the bracketed paste before the Enter arrives —
# otherwise the return is swallowed into the paste instead of submitting.
set ::PASTE_KEY          "key ctrl+v"
set ::ENTER_KEY          "key enter"
set ::PASTE_ENTER_GAP_MS 100

#==============================================================================
# BUTTON ACTIONS
#==============================================================================

proc on_copy {} {
    cancel_pending
    set_clipboard [active_text]
    finish 0
}

# Space -> paste only; Enter -> paste, then a separate return keystroke.
proc on_paste {withEnter} {
    cancel_pending
    set_clipboard [active_text]
    # Hide the window so Mutter returns focus to the prior window, then paste.
    catch {wm withdraw .}
    after 200 [list do_paste_exec $withEnter]
}

proc do_paste_exec {withEnter} {
    if {[catch {exec dotool << $::PASTE_KEY} err]} {
        puts stderr "dictate-stylist: dotool paste failed: $err"
        finish 1
        return
    }
    if {$withEnter} {
        # Let the paste settle, then send Enter as its own keystroke.
        after $::PASTE_ENTER_GAP_MS do_paste_enter
    } else {
        finish 0
    }
}

proc do_paste_enter {} {
    if {[catch {exec dotool << $::ENTER_KEY} err]} {
        puts stderr "dictate-stylist: dotool enter failed: $err"
    }
    finish 0
}

# Cancel an in-flight or scheduled rewrite (the user acted first; wasted spend
# is acceptable per design).
proc cancel_pending {} {
    if {$::autosend_id ne ""} { after cancel $::autosend_id; set ::autosend_id "" }
    if {$::httpToken ne ""}   { catch {http::reset $::httpToken}; set ::httpToken "" }
}

proc finish {code} {
    catch {after cancel $::autosend_id}
    catch {tk systray destroy}
    if {$::tmpfile ne "" && $::TEST_TEXT eq ""} { catch {file delete $::tmpfile} }
    after 0 [list exit $code]
}

#==============================================================================
# REVIEW UI
#==============================================================================

set ::HL_COLOR "#cfe8ff"     ;# highlighted pane background
set ::PANE_BG  "#ffffff"

proc build_review_ui {} {
    wm title . "Dictate-Stylist"

    # Panes and buttons take no keyboard focus: focus stays on the toplevel so
    # the window-level key bindings below always fire. Buttons remain
    # mouse-clickable.
    pack [ttk::frame .pane1 -padding 6] -fill both -expand 1
    pack [ttk::label .pane1.lbl -text "Dictated"] -anchor w
    text .pane1.txt -height 8 -width 80 -wrap word -relief solid -borderwidth 2 -takefocus 0
    pack .pane1.txt -fill both -expand 1
    bind .pane1.txt <Button-1> {setActiveArea 1; focus .; break}

    pack [ttk::frame .pane2 -padding 6] -fill both -expand 1
    pack [ttk::label .pane2.lbl -text "Rewritten ($::styleName)"] -anchor w
    text .pane2.txt -height 8 -width 80 -wrap word -relief solid -borderwidth 2 -takefocus 0
    pack .pane2.txt -fill both -expand 1
    bind .pane2.txt <Button-1> {setActiveArea 2; focus .; break}

    pack [ttk::frame .btns -padding 6] -fill x
    ttk::button .btns.paste -text "Copy & paste  (Space; Enter = paste+↵)" -command {on_paste 0} -takefocus 0
    ttk::button .btns.copy  -text "Copy to clipboard" -command {on_copy} -takefocus 0
    pack .btns.paste -side left -padx 4
    pack .btns.copy  -side left -padx 4

    .pane1.txt insert 1.0 $::dictatedText
    .pane1.txt configure -state disabled
    .pane2.txt configure -state disabled

    # Window-level keys (fire whenever the window has focus, no button focus
    # needed): Space = paste, Enter = paste+Enter, Up/Down switch the pane.
    bind . <space>  {on_paste 0; break}
    bind . <Return> {on_paste 1; break}
    bind . <Up>     {setActiveArea 1; break}
    bind . <Down>   {setActiveArea 2; break}
    # Closing the window copies-without-paste of the active pane.
    wm protocol . WM_DELETE_WINDOW {on_copy}

    refresh_highlight
}

proc paneSetRewrite {txt} {
    if {![winfo exists .pane2.txt]} return
    .pane2.txt configure -state normal
    .pane2.txt delete 1.0 end
    .pane2.txt insert 1.0 $txt
    .pane2.txt configure -state disabled
}

proc paneRewriteStatus {msg} {
    if {![winfo exists .pane2.txt]} return
    .pane2.txt configure -state normal
    .pane2.txt delete 1.0 end
    .pane2.txt insert 1.0 $msg
    .pane2.txt configure -state disabled
}

proc setActiveArea {n} {
    set ::activeArea $n
    refresh_highlight
}

proc refresh_highlight {} {
    if {![winfo exists .pane1.txt]} return
    .pane1.txt configure -background [expr {$::activeArea == 1 ? $::HL_COLOR : $::PANE_BG}]
    .pane2.txt configure -background [expr {$::activeArea == 2 ? $::HL_COLOR : $::PANE_BG}]
}

# Entry point once a transcript exists: show the window, default highlight to
# the dictated pane, and schedule the rewrite one second out.
proc show_review_ui {text} {
    set ::dictatedText [string trim $text]
    set ::activeArea 1
    catch {tk systray destroy}
    build_review_ui
    wm deiconify .
    raise .
    # Keep keyboard focus on the toplevel, not a button, so the window-level
    # Space/Enter bindings fire without the user clicking a button first.
    focus -force .
    after 120 {catch {focus -force .}}
    if {$::AUTO_STYLE_MS ne ""} {
        set ::autosend_id [after $::AUTO_STYLE_MS run_rewrite]
    } else {
        paneRewriteStatus "(auto-style off — pass --auto-style-delay to enable)"
    }
}

#==============================================================================
# RECORDING PIPELINE  (copied/adapted from the companion dictation tool)
#==============================================================================

# --- tray icon ---------------------------------------------------------------
set ::ICON_SCALE [expr {[::tk::ScalingPct] / 100.0}]
set ::_probe [image create photo -format [list svg -scale $::ICON_SCALE] \
    -data {<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><circle cx="16" cy="16" r="15" fill="#000"/></svg>}]
set ::ICON_SIZE [image width $::_probe]
image delete $::_probe
set ::TWOPI [expr {2.0 * acos(-1.0)}]
set ::icon_image [image create photo -width $::ICON_SIZE -height $::ICON_SIZE]
set ::BLINK_MS 1000
set ::blink 1
set ::anim_id ""

proc pie_svg {frac lit} {
    set cx 16.0; set cy 16.0; set r 15.5
    set s "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\">"
    append s "<circle cx=\"$cx\" cy=\"$cy\" r=\"$r\" fill=\"#444444\"/>"
    if {$lit} {
        if {$frac >= 0.999} {
            append s "<circle cx=\"$cx\" cy=\"$cy\" r=\"$r\" fill=\"#dd3333\"/>"
        } elseif {$frac > 0.001} {
            set a [expr {$frac * $::TWOPI}]
            set ex [expr {$cx + $r * sin($a)}]
            set ey [expr {$cy - $r * cos($a)}]
            set large [expr {$frac > 0.5 ? 1 : 0}]
            append s "<path d=\"M$cx,$cy L$cx,[expr {$cy - $r}] A$r,$r 0 $large,1 $ex,$ey Z\" fill=\"#dd3333\"/>"
        }
    }
    append s "</svg>"
    return $s
}

proc busy_svg {lit} {
    set s "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\">"
    append s "<circle cx=\"16\" cy=\"16\" r=\"15.5\" fill=\"#f67400\"/>"
    if {$lit} {
        foreach x {8.5 16 23.5} {
            append s "<circle cx=\"$x\" cy=\"16\" r=\"2.4\" fill=\"#ffffff\"/>"
        }
    }
    append s "</svg>"
    return $s
}

proc draw_icon {frac state lit} {
    switch -- $state {
        transcribing { set svg [busy_svg $lit] }
        default      { set svg [pie_svg $frac $lit] }
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
    switch -- $::state {
        recording    { draw_icon [recording_frac] recording $::blink }
        transcribing { draw_icon 1.0 transcribing $::blink }
        default      { set ::anim_id ""; return }
    }
    set ::blink [expr {!$::blink}]
    set ::anim_id [after $::BLINK_MS animate]
}
proc start_animate {} { if {$::anim_id eq ""} animate }
proc stop_animate {}  { if {$::anim_id ne ""} { after cancel $::anim_id; set ::anim_id "" } }
proc enter_state {newstate} { stop_animate; set ::state $newstate; set ::blink 1; start_animate }

# --- audio source ------------------------------------------------------------
proc resolve_source {capture} {
    if {![string is integer -strict $capture]} { return $capture }
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
    foreach f [glob -nocomplain -directory $::CACHE_DIR "ds-*.wav"] {
        if {![regexp {ds-(\d+)\.wav$} [file tail $f] -> opid]} continue
        if {$opid eq [pid]} continue
        if {[catch {exec kill -0 $opid}]} { catch {file delete -- $f} }
    }
}

# --- whisper transcription ---------------------------------------------------
proc smarten_quotes {text} {
    set openers [list ( \[ \{]
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
            append out [expr {$open ? "‘" : "’"}]
        } elseif {$ch eq "'"} {
            append out "’"
        } else {
            append out $ch
        }
    }
    return $out
}

proc save_log {text} {
    if {$::log_stem eq ""} return
    if {[catch {file mkdir $::LOG_DIR}]} return
    set txt [file join $::LOG_DIR "$::log_stem.txt"]
    catch {
        if {[file exists $::tmpfile]} { file copy -force -- $::tmpfile [file join $::LOG_DIR "$::log_stem.wav"] }
        set fh [open $txt w]; puts -nonewline $fh $text; close $fh
    }
}

proc transcribe {} {
    if {$::done} return
    set ::done 1
    set wcmd [list whisper-cli -m $::MODEL -f $::tmpfile -nt -l $::LANG -t $::THREADS]
    if {$::PROMPT ne ""}  { lappend wcmd --prompt $::PROMPT }
    if {$::NO_FALLBACK}   { lappend wcmd --no-fallback }
    if {$::NO_GPU}        { lappend wcmd --no-gpu }
    if {[catch {set ::wchan [open "|$wcmd 2>/dev/null" r]} err]} {
        puts stderr "dictate-stylist: whisper-cli failed: $err"; finish 1; return
    }
    set ::wbuf ""
    fconfigure $::wchan -blocking 0
    fileevent $::wchan readable transcribe_collect
}

proc transcribe_collect {} {
    append ::wbuf [read $::wchan]
    if {![eof $::wchan]} return
    fileevent $::wchan readable {}
    if {[catch {close $::wchan} cerr]} {
        puts stderr "dictate-stylist: whisper-cli failed: $cerr"; finish 1; return
    }
    set text [smarten_quotes $::wbuf]
    catch {save_log $text}
    stop_animate
    show_review_ui $text
}

proc poll_parecord {} {
    if {$::parecord_pid == 0} return
    if {[catch {exec kill -0 $::parecord_pid}]} {
        set ::parecord_pid 0
        transcribe
    } else {
        set ::poll_id [after 200 poll_parecord]
    }
}

# --- second-press socket protocol -------------------------------------------
proc probe_running {cmd} {
    if {[catch {socket 127.0.0.1 $::PORT} sock]} { return }
    fconfigure $sock -buffering line -translation lf
    gets $sock _banner
    puts $sock $cmd
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
        puts stderr "dictate-stylist: cannot bind 127.0.0.1:$::PORT: $sock"; return
    }
    set ::listener $sock
}
proc stop_listener {} {
    if {[info exists ::listener]} { catch {close $::listener}; unset ::listener }
}
proc handle_client {sock _addr _port} {
    fconfigure $sock -buffering line -translation lf
    puts $sock "OK dictate-stylist 1"
    if {[gets $sock cmd] < 0} { close $sock; return }
    switch -- [string trim $cmd] {
        stop   { puts $sock "OK"; after idle stop_recording }
        status { puts $sock "state $::state"; puts $sock "OK" }
        default { puts $sock "ACK unknown-command" }
    }
    close $sock
}

proc stop_recording {} {
    stop_listener
    if {$::auto_stop_id ne ""} { after cancel $::auto_stop_id; set ::auto_stop_id "" }
    if {$::parecord_pid > 0} { catch {exec kill $::parecord_pid} }
    if {$::state ne "transcribing"} { enter_state transcribing }
}

proc start_recording {} {
    file mkdir $::CACHE_DIR
    sweep_stale_recordings
    set ::tmpfile [file join $::CACHE_DIR "ds-[pid].wav"]
    set ::log_stem "[clock format [clock seconds] -format {%Y-%m-%dT%H-%M-%S}]-[pid]"
    set ::start_ms [clock milliseconds]

    set source ""
    if {$::CAPTURE ne ""} { set source [resolve_source $::CAPTURE] }

    set pcmd [list parecord --channels=1 --rate=16000 --format=s16ne --file-format=wav]
    if {$source ne ""} { lappend pcmd "--device=$source" }
    lappend pcmd $::tmpfile
    if {[catch {set ::parecord_pid [exec {*}$pcmd &]} err]} {
        puts stderr "dictate-stylist: failed to start parecord: $err"; finish 1; return
    }
    set ::poll_id [after 200 poll_parecord]
    set ::auto_stop_id [after [expr {$::TIMEOUT_S * 1000}] stop_recording]
}

#==============================================================================
# SELF-TEST HARNESS
#==============================================================================

proc check {label cond {detail ""}} {
    upvar 1 fail fail
    set ok [uplevel 1 [list expr $cond]]
    if {$ok} {
        puts "PASS: $label"
    } else {
        puts "FAIL: $label $detail"
        set fail 1
    }
}

proc run_self_test {} {
    set fail 0

    set sample "so the thing is we need to move the meeting, it's because the client called this morning, and they want friday instead of monday"

    # 1. highlight default
    set ::dictatedText $sample
    set ::activeArea 1
    check "default highlight is dictated pane" {$::activeArea == 1}

    # 2. real API rewrite
    set ::testDone 0
    set ::autosend_id ""
    set ::rewriteState idle
    run_rewrite
    set after_id [after 65000 {set ::testDone timeout}]
    vwait ::testDone
    after cancel $after_id
    check "rewrite returned" {$::rewriteState eq "done" && [string length $::rewriteText] > 0} \
        "(state=$::rewriteState)"
    check "highlight moved to rewrite pane after API" {$::activeArea == 2}
    puts "    REWRITE: $::rewriteText"

    # 3. active_text follows highlight
    setActiveArea 2
    check "active_text returns rewrite when pane 2" {[active_text] eq $::rewriteText}
    setActiveArea 1
    check "active_text returns dictated when pane 1" {[active_text] eq $::dictatedText}

    # 4. up/down toggle
    setActiveArea 2
    check "Down selects pane 2" {$::activeArea == 2}
    setActiveArea 1
    check "Up selects pane 1" {$::activeArea == 1}

    # 5. clipboard round-trip
    setActiveArea 2
    if {[catch {set_clipboard [active_text]} e]} {
        check "wl-copy succeeded" 0 "($e)"
    } else {
        check "wl-copy succeeded" 1
        set back ""
        catch {set back [exec wl-paste -n]}
        check "wl-paste matches active text" {$back eq [active_text]}
    }

    # 6. paste chords (return is a separate, delayed keystroke)
    check "paste key = ctrl+v" {$::PASTE_KEY eq "key ctrl+v"}
    check "enter key = enter"  {$::ENTER_KEY eq "key enter"}
    check "paste/enter gap set" {$::PASTE_ENTER_GAP_MS > 0}

    # 6b. auto-style delay parsing
    check "parse_delay 1s = 1000"    {[parse_delay 1s] == 1000}
    check "parse_delay 500ms = 500"  {[parse_delay 500ms] == 500}
    check "parse_delay bare 2 = 2000" {[parse_delay 2] == 2000}

    # 7. UI smoke (build withdrawn, do not deiconify)
    if {[catch {build_review_ui} e]} {
        check "review UI builds without error" 0 "($e)"
    } else {
        check "review UI builds without error" {[winfo exists .pane1.txt] && [winfo exists .pane2.txt] && [winfo exists .btns.paste]}
        catch {paneSetRewrite $::rewriteText}
        check "rewrite pane shows text" {[string trim [.pane2.txt get 1.0 end]] eq $::rewriteText}
    }

    puts [expr {$fail ? "SELF-TEST: FAIL" : "SELF-TEST: PASS"}]
    exit $fail
}

#==============================================================================
# MAIN
#==============================================================================

wm withdraw .

# Load configuration up front so failures surface immediately.
loadDeepSeekConfig
loadSystemPrompts
loadStyle
if {$::AUTO_STYLE_RAW ne ""} { set ::AUTO_STYLE_MS [parse_delay $::AUTO_STYLE_RAW] }

if {$::SELF_TEST} {
    after idle run_self_test
    vwait forever
}

if {$::TEST_TEXT ne ""} {
    after idle [list show_review_ui $::TEST_TEXT]
    vwait forever
}

# Live mode. A second press of the hotkey reaches the running recorder over
# the socket and stops it; otherwise this process becomes the recorder.
probe_running $::CMD

serve_listener
draw_icon 1.0 recording 1
tk systray create -image $::icon_image -text $::APPNAME -button1 stop_recording
enter_state recording
start_recording

vwait forever

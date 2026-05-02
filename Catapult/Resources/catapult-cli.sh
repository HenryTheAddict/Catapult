#!/usr/bin/env bash
# catapult — terminal companion for the catapult menu-bar app
# h3 design — lowercase first-person, em dashes welcome, sky-blue gradients.
#
# shares settings and bundled binaries with the macOS app:
#   settings   ← defaults read h3nry.Catapult
#   binaries   ← ~/Library/Application Support/Catapult/bin/{yt-dlp,ffmpeg}

set -u
IFS=$'\n\t'

readonly APP_BUNDLE="h3nry.Catapult"
readonly SUPPORT_DIR="$HOME/Library/Application Support/Catapult"
readonly BIN_DIR="$SUPPORT_DIR/bin"
readonly YTDLP="$BIN_DIR/yt-dlp"
readonly FFMPEG="$BIN_DIR/ffmpeg"
readonly VERSION="1.0"

# ── h3 palette (24-bit ANSI) ────────────────────────────────────────────────
readonly C_SKY=$'\033[38;2;0;187;255m'
readonly C_AQUA=$'\033[38;2;0;255;195m'
readonly C_LAV=$'\033[38;2;131;141;255m'
readonly C_BLUE=$'\033[38;2;0;116;224m'
readonly C_DEEP=$'\033[38;2;0;61;153m'
readonly C_INK=$'\033[38;2;30;31;38m'
readonly C_DIM=$'\033[38;2;154;155;163m'
readonly C_MUTED=$'\033[38;2;85;88;96m'
readonly C_WHITE=$'\033[38;2;255;255;255m'
readonly C_MAGENTA=$'\033[38;2;212;0;255m'
readonly C_RED=$'\033[38;2;228;3;3m'
readonly C_GREEN=$'\033[38;2;0;224;30m'
readonly BG_DEEP=$'\033[48;2;0;61;153m'
readonly BG_SOFT=$'\033[48;2;230;245;255m'
readonly BOLD=$'\033[1m'
readonly DIM=$'\033[2m'
readonly ITAL=$'\033[3m'
readonly RST=$'\033[0m'

# ── helpers ─────────────────────────────────────────────────────────────────

has_tool() { command -v "$1" >/dev/null 2>&1; }

get_default() {
    # get_default KEY FALLBACK
    local val
    val=$(defaults read "$APP_BUNDLE" "$1" 2>/dev/null || true)
    if [[ -z "$val" ]]; then echo "$2"; else echo "$val"; fi
}

download_folder() {
    get_default "downloadFolderPath" "$HOME/Downloads/Catapult"
}
filename_template() {
    get_default "filenameTemplate" "%(title)s [%(height)sp].%(ext)s"
}
cookie_source() {
    local raw
    raw=$(get_default "cookieSource" "off")
    [[ "$raw" == "off" ]] && echo "" || echo "$raw"
}
proxy_url() {
    get_default "proxyURL" ""
}
rate_limit() {
    # In KB/s. 0 means unlimited.
    get_default "rateLimitKBps" "0"
}
prefer_compat() {
    # YES is stored as "1"
    [[ "$(get_default preferCompatibleCodecs 1)" == "1" ]]
}
video_quality() {
    get_default "videoQuality" "1080"
}
audio_format() {
    get_default "audioFormat" "mp3"
}
audio_quality() {
    get_default "audioQualityKbps" "192"
}

ytdlp_cmd() {
    # Prefer the app's bundled binary; fall back to PATH if the app hasn't installed.
    if [[ -x "$YTDLP" ]]; then echo "$YTDLP"
    elif has_tool yt-dlp; then echo yt-dlp
    else return 1
    fi
}

# Builds yt-dlp's -f selector matching the macOS app: prefers avc1+mp4a when
# compat is on, then loosens gradually so we don't trip "format not available"
# for videos that don't publish an exact match at the capped height.
build_video_format() {
    local q h compat
    q=$(video_quality)
    if prefer_compat; then compat=1; else compat=0; fi
    if [[ "$q" == "best" ]]; then
        h=""
    else
        h="[height<=${q}]"
    fi
    local chain
    if (( compat )); then
        chain="bv*[vcodec^=avc1]${h}+ba[acodec^=mp4a]/bv*[ext=mp4]${h}+ba[ext=m4a]/bv*${h}+ba/b${h}/bv*+ba/b/best"
    else
        chain="bv*${h}+ba/b${h}/bv*+ba/b/best"
    fi
    printf '%s' "$chain"
}

# host → SupportedSite key, matching AppSettings.SupportedSite.match
site_for_url() {
    local url="$1"
    local host
    host=$(printf '%s\n' "$url" | awk -F/ '{print tolower($3)}')
    host="${host#www.}"
    case "$host" in
        *youtube.com|youtu.be|*youtube-nocookie.com|music.youtube.com) echo "youtube" ;;
        *tiktok.com|vm.tiktok.com)             echo "tiktok"    ;;
        twitter.com|x.com|t.co)                echo "twitter"   ;;
        *reddit.com|redd.it)                   echo "reddit"    ;;
        *instagram.com|instagr.am)             echo "instagram" ;;
        *facebook.com|fb.watch|fb.com)         echo "facebook"  ;;
        *twitch.tv)                            echo "twitch"    ;;
        *vimeo.com)                            echo "vimeo"     ;;
        *soundcloud.com)                       echo "soundcloud";;
        *bilibili.com|b23.tv)                  echo "bilibili"  ;;
        bsky.app)                              echo "bluesky"   ;;
        *) echo "generic" ;;
    esac
}

# Resolve the effective cookie source for a URL. If the site has cookies
# enabled (present in the siteCookies array) AND the global cookie_source is
# not off, use it. Otherwise return the global source as-is.
cookie_source_for() {
    local url="$1"
    local site enabled global
    site=$(site_for_url "$url")
    global=$(cookie_source)
    enabled=$(defaults read "$APP_BUNDLE" siteCookies 2>/dev/null \
        | tr -d '(),' | awk -v s="\"$site\"" '
            { gsub(/^[ \t]+|[ \t]+$/, "", $0); if ($0 == s) { print "yes"; exit } }')
    if [[ -n "${enabled:-}" && "$global" != "off" ]]; then
        echo "$global"
    else
        echo "$global"
    fi
}

# ── drawing ─────────────────────────────────────────────────────────────────

rule() {
    local cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
    printf "${C_DIM}%*s${RST}\n" "$cols" "" | tr ' ' '─'
}

banner() {
    clear
    # A three-row sky gradient header using background color bands.
    local cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
    local pad="%-${cols}s"
    printf "\033[48;2;0;187;255m${C_WHITE}${BOLD}"
    printf "$pad" "  catapult — terminal companion"
    printf "${RST}\n"
    printf "\033[48;2;100;209;255m${C_WHITE}"
    printf "$pad" "  a tiny yt-dlp thing — paste a link, i'll grab it."
    printf "${RST}\n"
    printf "\033[48;2;200;235;255m${C_INK}${DIM}"
    printf "$pad" "  v$VERSION · shares settings with the menu-bar app"
    printf "${RST}\n\n"
}

print_orb() {
    # Decorative sky-orb, 6×3 unicode blocks, gradient from aqua to lavender.
    printf "   ${C_AQUA}  ▄▄▄▄   ${RST}\n"
    printf "   ${C_SKY}▄${C_AQUA}█████▄${C_SKY} ${RST}\n"
    printf "   ${C_LAV}█${C_BLUE}█████${C_LAV}█${RST}\n"
    printf "   ${C_LAV} ▀███▀  ${RST}\n"
}

menu_item() {
    # menu_item NUMBER GLYPH LABEL SHORTCUT
    printf "   ${C_BLUE}${BOLD}%s${RST}  ${C_INK}%s${RST}  ${BOLD}%s${RST}  ${C_DIM}%s${RST}\n" "$1" "$2" "$3" "$4"
}

status_line() {
    local dl cook prox
    dl=$(download_folder)
    cook=$(cookie_source)
    prox=$(proxy_url)
    printf "${C_DIM}  saves to:${RST} ${C_INK}%s${RST}\n" "${dl/#$HOME/~}"
    [[ -n "$cook" ]]   && printf "${C_DIM}  cookies:${RST}  ${C_INK}%s${RST}\n" "$cook"
    [[ -n "$prox" ]]   && printf "${C_DIM}  proxy:${RST}    ${C_INK}%s${RST}\n" "$prox"
    echo
}

press_any() {
    printf "\n${C_DIM}  — press any key to return —${RST}"
    read -rsn1
    echo
}

# ── preflight ───────────────────────────────────────────────────────────────

ensure_ytdlp() {
    if ! YTDLP_BIN=$(ytdlp_cmd); then
        banner
        printf "${C_RED}${BOLD}  hmm — i can't find yt-dlp.${RST}\n\n"
        printf "${C_INK}  expected it at:${RST}\n"
        printf "    ${DIM}%s${RST}\n\n" "$YTDLP"
        printf "${C_INK}  open the catapult app once and let it install its tools,${RST}\n"
        printf "${C_INK}  or put yt-dlp somewhere on your PATH.${RST}\n"
        press_any
        return 1
    fi
    return 0
}

# ── actions ─────────────────────────────────────────────────────────────────

read_url() {
    local pasted default prompt
    if has_tool pbpaste; then default="$(pbpaste 2>/dev/null | head -n1)"; else default=""; fi

    printf "${C_DIM}  url (blank to use clipboard):${RST}\n  ${C_BLUE}›${RST} "
    read -r pasted
    if [[ -z "$pasted" ]]; then pasted="$default"; fi
    printf '%s' "$pasted"
}

build_common_args() {
    # Echo args common to every mode. Uses one-arg-per-line.
    local url="$1"
    local folder tmpl cookies proxy rate
    folder=$(download_folder)
    tmpl=$(filename_template)
    cookies=$(cookie_source_for "$url")
    proxy=$(proxy_url)
    rate=$(rate_limit)

    mkdir -p "$folder"

    printf -- '--newline\n--no-playlist\n--progress\n--no-mtime\n'
    printf -- '-o\n%s\n' "$folder/$tmpl"
    if [[ -x "$FFMPEG" ]]; then
        printf -- '--ffmpeg-location\n%s\n' "$BIN_DIR"
    fi
    [[ -n "$cookies" ]] && printf -- '--cookies-from-browser\n%s\n' "$cookies"
    [[ -n "$proxy"   ]] && printf -- '--proxy\n%s\n' "$proxy"
    if [[ "$rate" =~ ^[0-9]+$ ]] && (( rate > 0 )); then
        printf -- '--limit-rate\n%sK\n' "$rate"
    fi
}

run_ytdlp() {
    # Feed args via STDIN for portability with URLs/templates that contain
    # spaces. Auto-retries with Safari cookies if the first pass trips an
    # auth-style error (format not available / sign-in / age gate), mirroring
    # the macOS app's fallback behavior.
    local -a args=()
    while IFS= read -r line; do args+=("$line"); done
    echo

    local log rc
    log=$(mktemp -t catapult-ytdlp)
    # shellcheck disable=SC2064
    trap "rm -f '$log'" EXIT
    "$YTDLP_BIN" "${args[@]}" 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    echo

    if (( rc != 0 )) && grep -qiE 'requested format is not available|sign in to confirm|age|private video|members only' "$log"; then
        # Drop any existing --cookies-from-browser arg the caller passed and
        # slap Safari on the end, then re-run once.
        local -a retry=()
        local skip=0
        for a in "${args[@]}"; do
            if (( skip )); then skip=0; continue; fi
            if [[ "$a" == "--cookies-from-browser" ]]; then skip=1; continue; fi
            retry+=("$a")
        done
        retry+=("--cookies-from-browser" "safari")
        printf "${C_SKY}  looks gated — retrying with safari cookies…${RST}\n"
        "$YTDLP_BIN" "${retry[@]}"
        rc=$?
        echo
    fi

    if (( rc == 0 )); then
        printf "${C_GREEN}${BOLD}  done.${RST}\n"
    else
        printf "${C_RED}${BOLD}  yt-dlp exited with code %s.${RST}\n" "$rc"
        if (( rc != 0 )); then
            printf "${C_DIM}  tip: enable cookies in settings › sites, or run 'capu settings' to check.${RST}\n"
        fi
    fi
    return $rc
}

action_video() {
    ensure_ytdlp || return
    banner
    printf "${C_BLUE}${BOLD}  download video${RST}\n"
    printf "${C_DIM}  max quality: %sp · prefers h.264/aac: %s${RST}\n\n" \
        "$(video_quality)" "$(prefer_compat && echo yes || echo no)"
    local url; url=$(read_url)
    if [[ -z "$url" ]]; then echo "  — no url —"; press_any; return; fi

    local fmt; fmt=$(build_video_format)

    {
        build_common_args "$url"
        printf -- '-f\n%s\n--merge-output-format\nmp4\n' "$fmt"
        prefer_compat && printf -- '--remux-video\nmp4\n'
        printf -- '%s\n' "$url"
    } | run_ytdlp
    press_any
}

action_audio() {
    ensure_ytdlp || return
    banner
    printf "${C_LAV}${BOLD}  download audio${RST}\n"
    printf "${C_DIM}  format: %s · bitrate: %s kbps${RST}\n\n" \
        "$(audio_format)" "$(audio_quality)"
    local url; url=$(read_url)
    if [[ -z "$url" ]]; then echo "  — no url —"; press_any; return; fi

    {
        build_common_args "$url"
        printf -- '-f\nbestaudio/best\n-x\n'
        printf -- '--audio-format\n%s\n' "$(audio_format)"
        printf -- '--audio-quality\n%sK\n' "$(audio_quality)"
        printf -- '--embed-thumbnail\n--convert-thumbnails\njpg\n'
        printf -- '--ppa\nEmbedThumbnail+ffmpeg_o1:-c:v mjpeg\n'
        printf -- '%s\n' "$url"
    } | run_ytdlp
    press_any
}

action_thumbnail() {
    ensure_ytdlp || return
    banner
    printf "${C_MAGENTA}${BOLD}  just the thumbnail${RST}\n\n"
    local url; url=$(read_url)
    if [[ -z "$url" ]]; then echo "  — no url —"; press_any; return; fi

    {
        build_common_args "$url"
        printf -- '--skip-download\n--write-thumbnail\n--convert-thumbnails\npng\n'
        printf -- '%s\n' "$url"
    } | run_ytdlp
    press_any
}

action_cut() {
    ensure_ytdlp || return
    banner
    printf "${C_SKY}${BOLD}  cut a clip${RST}  ${C_DIM}— enter start/end as HH:MM:SS or seconds${RST}\n\n"
    local url; url=$(read_url)
    if [[ -z "$url" ]]; then echo "  — no url —"; press_any; return; fi
    printf "  ${C_BLUE}start›${RST} "; read -r tstart
    printf "  ${C_BLUE}  end›${RST} "; read -r tend
    if [[ -z "$tstart" || -z "$tend" ]]; then echo "  — missing times —"; press_any; return; fi

    {
        build_common_args "$url"
        printf -- '-f\nbv*+ba/b\n--merge-output-format\nmp4\n'
        printf -- '--download-sections\n*%s-%s\n' "$tstart" "$tend"
        printf -- '--force-keyframes-at-cuts\n'
        printf -- '--postprocessor-args\nMerger+ffmpeg_o1:-avoid_negative_ts make_zero -fflags +genpts\n'
        printf -- '%s\n' "$url"
    } | run_ytdlp
    press_any
}

action_queue() {
    banner
    printf "${C_BLUE}${BOLD}  recent downloads${RST}\n\n"
    local folder
    folder=$(download_folder)
    if [[ ! -d "$folder" ]]; then
        printf "  ${C_DIM}— nothing here yet —${RST}\n"
    else
        # Show 15 most recent, one per line
        local any=0
        while IFS= read -r f; do
            any=1
            local base size mtime
            base=$(basename "$f")
            size=$(du -h "$f" 2>/dev/null | cut -f1)
            mtime=$(stat -f '%Sm' -t '%b %d %H:%M' "$f" 2>/dev/null)
            printf "  ${C_AQUA}●${RST}  ${C_INK}%-48s${RST}  ${C_DIM}%6s  %s${RST}\n" \
                "${base:0:48}" "$size" "$mtime"
        done < <(/usr/bin/find "$folder" -type f -not -name '.*' -print0 2>/dev/null \
                   | xargs -0 stat -f '%m %N' 2>/dev/null \
                   | sort -rn \
                   | head -n 15 \
                   | cut -d' ' -f2-)
        (( any == 0 )) && printf "  ${C_DIM}— nothing here yet —${RST}\n"
    fi
    echo
    printf "  ${C_DIM}folder:${RST}  ${C_INK}%s${RST}\n" "${folder/#$HOME/~}"
    printf "  ${C_DIM}press ${C_BLUE}o${C_DIM} to open in finder, any other key to return${RST}"
    local k; read -rsn1 k
    if [[ "$k" == "o" || "$k" == "O" ]]; then
        open "$folder" 2>/dev/null || true
    fi
    echo
}

action_settings() {
    banner
    printf "${C_BLUE}${BOLD}  settings${RST}  ${C_DIM}— edit these in the menu-bar app${RST}\n\n"
    local kv=(
        "download folder:|$(download_folder)"
        "filename template:|$(filename_template)"
        "video quality:|$(video_quality)p"
        "audio format:|$(audio_format) @ $(audio_quality) kbps"
        "cookies (global):|$(cookie_source || echo off)"
        "proxy:|$(proxy_url || echo —)"
        "rate limit (KB/s):|$(rate_limit)"
        "prefer h.264/aac:|$(prefer_compat && echo yes || echo no)"
    )
    for pair in "${kv[@]}"; do
        local k="${pair%%|*}" v="${pair#*|}"
        printf "  ${C_DIM}%-22s${RST} ${C_INK}%s${RST}\n" "$k" "$v"
    done
    echo
    printf "  ${C_DIM}yt-dlp:${RST}  ${C_INK}%s${RST}\n" "${YTDLP_BIN:-$YTDLP}"
    printf "  ${C_DIM}ffmpeg:${RST}  ${C_INK}%s${RST}\n" "$FFMPEG"
    press_any
}

# ── main loop ───────────────────────────────────────────────────────────────

main_menu() {
    YTDLP_BIN=$(ytdlp_cmd || true)
    while true; do
        banner
        print_orb
        echo
        status_line
        menu_item "1" "▼" "download video" "[v]"
        menu_item "2" "♪" "download audio" "[a]"
        menu_item "3" "◆" "just thumbnail" "[t]"
        menu_item "4" "✂" "cut a clip    " "[c]"
        menu_item "5" "▦" "recent files  " "[r]"
        menu_item "6" "⚙" "settings      " "[s]"
        menu_item "q" "✕" "quit          " "[esc]"
        echo
        printf "  ${C_BLUE}›${RST} "
        local choice
        read -rsn1 choice
        echo
        case "$choice" in
            1|v|V) action_video ;;
            2|a|A) action_audio ;;
            3|t|T) action_thumbnail ;;
            4|c|C) action_cut ;;
            5|r|R) action_queue ;;
            6|s|S) action_settings ;;
            q|Q|$'\e') clear; exit 0 ;;
            *) : ;;
        esac
    done
}

# ── one-shot flag mode (scriptable) ─────────────────────────────────────────

usage() {
    cat <<EOF
${BOLD}catapult${RST} — terminal companion for the catapult menu-bar app
${C_DIM}(everything below also works with the shorter 'capu' alias)${RST}

  usage:
    catapult                         interactive tui
    catapult video <url>             download as video
    catapult audio <url>             extract audio
    catapult thumb <url>             just the thumbnail
    catapult cut <url> <start> <end> clip a section
    catapult queue                   list recent downloads
    catapult settings                show current settings
    catapult --version               print the version
    catapult --help                  this screen
EOF
}

# Dispatch — if args given, run one-shot. Otherwise launch the TUI.
if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help|help) usage; exit 0 ;;
        --version|-v) printf 'catapult %s\n' "$VERSION"; exit 0 ;;
        video)   shift; ensure_ytdlp && { { build_common_args "$1"; \
                    printf -- '-f\n%s\n--merge-output-format\nmp4\n%s\n' "$(build_video_format)" "$1"; } | run_ytdlp; } ;;
        audio)   shift; ensure_ytdlp && { { build_common_args "$1"; \
                    printf -- '-f\nbestaudio/best\n-x\n--audio-format\n%s\n--audio-quality\n%sK\n%s\n' \
                        "$(audio_format)" "$(audio_quality)" "$1"; } | run_ytdlp; } ;;
        thumb)   shift; ensure_ytdlp && { { build_common_args "$1"; \
                    printf -- '--skip-download\n--write-thumbnail\n--convert-thumbnails\npng\n%s\n' "$1"; } \
                    | run_ytdlp; } ;;
        cut)     shift; ensure_ytdlp && { { build_common_args "$1"; \
                    printf -- '-f\nbv*+ba/b\n--merge-output-format\nmp4\n--download-sections\n*%s-%s\n--force-keyframes-at-cuts\n%s\n' \
                        "$2" "$3" "$1"; } | run_ytdlp; } ;;
        queue)   action_queue ;;
        settings) action_settings ;;
        *) usage; exit 1 ;;
    esac
    exit 0
fi

main_menu

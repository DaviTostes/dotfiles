# AGENTS.md

Guidance for AI agents working in this dotfiles repo.

## Layout

XDG-style tree managed with GNU stow (or manual symlinks): each top-level
directory mirrors `$HOME`, e.g. `quickshell/.config/quickshell/shell.qml`
lands at `~/.config/quickshell/shell.qml`.

- `quickshell/` — quickshell shell config (bar + hypr settings panel +
  Super+Space launcher + Super+Alt+Space clipboard history)
- `hypr/` — Hyprland + awww/hyprlock/hypridle configs (Hyprland itself is
  configured in Lua via `hyprland.lua`, which drives Hyprland through the `hl` API)
- `waybar/`, `swaync/`, `swayosd/`, `kitty/`, `fish/`, `tmux/`, `nvim/` — their respective app configs
  (there is no `wofi/` any more: quickshell serves all four binds it used to)
- `gtk/` — `Quickshell-Dark` GTK 3/4 theme mirroring the quickshell palette
  (installed via symlink at `~/.local/share/themes/`, plus the libadwaita
  override symlinked at `~/.config/gtk-4.0/gtk.css`)
- `backgrounds/` — wallpapers

## Quickshell (`quickshell/.config/quickshell/`)

- `shell.qml` is the entry point; `bar/` holds the bar and its pill widgets;
  `hyprconf/` holds the Hypr Config dropdown panel (edits compositor settings in
  `hyprpanel.lua` via `HyprPanel.js` and `wallpaper.conf` / `hyprlock.conf` /
  `hypridle.conf` via `Conf.js`).
  The panel is a `PopupWindow` anchored under the bar's settings pill
  (Pomodoro-style, one per monitor); click-outside close uses
  `HyprlandFocusGrab` — do not turn it back into a standalone window.
- The dropdown has four tabs, in `HyprConfig.tabs` order: **Hyprland**
  (`HyprlandTab.qml`), **Bluetooth** (`BluetoothTab.qml`), **Wi-Fi**
  (`WifiTab.qml`), **VPN** (`VpnTab.qml`).
  `HyprlandTab.qml` stacks all Hyprland-related configuration in one scrollable
  tab (`LookFeelSection`, `InputSection`, `AnimationsSection`,
  `WallpaperSection`, `LockSection`, `IdleSection`, `MonitorsSection`,
  `AutostartSection`) with a single footer Save that writes and applies only
  dirty sections.
  The bar's `openSettings(name)` resolves a tab by name and the IPC
  `qs ipc call settings open hyprland|bluetooth|wifi|vpn` (plus legacy aliases
  `wallpaper|lock|lockscreen|idle` → `Hyprland`) opens straight on one;
  clicking a tab button still owns `root.tab`. `HyprConfig.tabIndex()`
  normalises names (`wifi` == `Wi-Fi`).
- `BluetoothTab.qml` drives BlueZ through `Quickshell.Bluetooth` (no bzmenu):
  bonded devices connect/disconnect/forget natively. Device *icons* are mapped
  from BlueZ icon names to Nerd Font glyphs — `Quickshell.iconPath()` does not
  reliably resolve names like `audio-headset` here. BlueZ refuses the HID
  profile to a non-bonded device and Quickshell 0.3.1 registers no pairing
  agent, so a fresh device is paired by shelling out to `bluetoothctl`
  (pair → trust → connect via `Process`), which brings its own Just Works
  agent; devices demanding host PIN/passkey entry still can't be paired here.
- `WifiTab.qml` drives **iwd** through `iwctl` (`Process`), *not*
  `Quickshell.Networking` — that module only supports NetworkManager (enum
  `None`/`NetworkManager`) and this machine runs iwd with NetworkManager
  inactive. The iwctl tables are fixed-width + ANSI coloured (signal "stars"
  are dimmed for unfilled slots), and `iwctl` prints errors on **stdout** with
  exit code 1. Never shell-interpolate user text: commands are argv arrays
  (`Process.command`), and the passphrase goes through `--passphrase`.
- `VpnTab.qml` drives Proton VPN CLI (`protonvpn`) through `Process` with argv
  arrays (no shell). Parses `status` (Connected + Server/Load/Protocol),
  `info` (account), `countries list` and `cities list <code>` (tabulate
  tables, header/separator skipped). Actions: fastest, random, per-country,
  per-city, manual server ID, disconnect; P2P / Secure Core / Tor flags append
  to the next connect. Like Wi-Fi it loads lazily (`loadVpnIfVisible`, tab 5).
- `bar/Launcher.qml` is the Super+Space app launcher. It is a fullscreen
  `Overlay` layer-shell `PanelWindow` with `Exclusive` keyboard focus, so it is
  typed into directly — no hidden-TextInput workaround like the bar popups.
  Opened via `qs ipc call launcher toggle`. Launcher, clipboard history and the
  two settings tabs cover all four binds wofi used to serve, and wofi/bzmenu/
  iwmenu are gone from the system.
- `bar/Tasks.qml` is the tasks pill: a Pomodoro-style dropdown (one per bar)
  with **pending** / **done** tabs and a **+** icon top-right that opens the
  editor. A task carries a name, an optional description and an optional
  **prefix**; tasks sharing a prefix get the same color (custom override in
  `tasks-prefix-colors.json`, else a deterministic hash → vivid
  `Theme.tagColors`), drawn as a colored left accent bar + badge on the row.
  Clicking a row opens the same editor sub-panel below the list to update it;
  the editor also carries the per-prefix color swatches. Rows reorder with
  up/down chevrons (`moveTask` swaps within the visible tab), and are checked
  off (or restored) and deleted from the row. The list is **global state**, not
  per-pill: `bar/TasksStore.qml` is a singleton (registered in `bar/qmldir`,
  like `Notifs`) holding the tasks + per-prefix colors and every mutator, so
  all bars stay in sync — `Tasks.qml` is only the view. It persists at
  `Quickshell.stateDir/tasks.json` via `Quickshell.Io.FileView` (the same store
  trick as the launcher). Text entry reuses `hyprconf/TextEntry.qml`; the bar
  holds the keyboard while the panel is open (`Bar.focusable ←
  tasksPanelOpen`), like the settings dropdown. Opened via
  `qs ipc call tasks toggle` (SUPER+O, moved off the omm launcher).
- Launcher ordering is **frecency** (launch count + recency), persisted at
  `Quickshell.stateDir/launcher-usage.json` (i.e.
  `~/.local/state/quickshell/by-shell/<hash>/launcher-usage.json`) through
  `Quickshell.Io.FileView` — quickshell creates that directory itself. Usage
  only breaks ties among matches (capped bonus); it fully drives the
  empty-query list. Reset with `qs ipc call launcher clearUsage`. Note desktop
  entry ids have **no** `.desktop` suffix (`mpv`, not `mpv.desktop`).
- `bar/ClipHistory.qml` is the Super+Alt+Space clipboard history. It only
  replaces wofi's role as the picker — `cliphist` stays as the store (sqlite,
  images included, fed by the `wl-paste --watch cliphist store` autostart).
  It runs `cliphist list` through a `Quickshell.Io.Process` +
  `StdioCollector` (parsing `<id>\t<preview>`, first tab only) and copies with
  `cliphist decode <id> | wl-copy` (the pipe is what keeps images working).
  Opened via `qs ipc call clipboard toggle`; same fullscreen `Overlay` +
  `Exclusive` keyboard approach as the launcher. `Component.onCompleted` warms
  the listing once at shell start and `refresh()` then re-runs `cliphist list`
  in the background on every open **without clearing it**, so the panel never
  opens empty and pops in a moment later; the rows are swapped in when the
  process answers.
- `bar/Calc.qml` is the calculator tab of the intelligence central: a
  terminal-style REPL around the `calc` CLI (the arbitrary-precision
  calculator written in C), not a button pad. One long-lived
  `calc -q -c -u` process is driven over stdin via `Process.write`
  (`stdinEnabled`), so variables, user functions and precision set on one
  line survive into the next; `-c` survives scan/parse errors and `-u` keeps
  stdout unbuffered. Every submitted line is echoed into a scrollback
  transcript (input, output, errors inline) and `show globals` feeds the
  variables column — names/types from the table, then a short second pass
  reprints each numeric global in real mode via `print`, so the column shows
  `56810.22` rather than calc's exact fraction `2840511/50`. Enter evaluates,
  Up/Down recall submitted lines, Ctrl+L
  clears the screen. The bar's `hiddenInput` is the real editor while docked
  (same mirroring as the translate tab); `submit()`/`historyPrev()`/
  `historyNext()` are its API, wired in Opencode.qml. Unbalanced `( [ {` or
  quotes are rejected up front — `calc` otherwise waits for the rest of the
  expression and desyncs the sentinel (`__QS_CALC_DONE__`) protocol.
- `bar/Opencode.qml`'s **full chat is now a standalone instance** from the
  docked intelligence central, so both can be open at once. `shell.qml` hosts a
  second `Opencode` (`id: opencodeFull`, `standalone: true`) in a hidden
  `PanelWindow`; a standalone instance opens straight into full mode
  (`openStandalone()` → `ensureService()` + `openExpanded()`) and never uses the
  pill/docked dropdown. The bar's pill is now docked-only: SUPER+SHIFT+A
  (`qs ipc call opencode toggleExpanded`, which routes to
  `shell.toggleFullChat()`) drives the standalone. The **expand** button was
  removed (the standalone is opened by keybind only; `opencodeFull` IPC remains
  for scripting); the docked (pill) header keeps a **+** new-chat button, while
  the big window uses the history rail's "New chat" row. **Ctrl+N** starts a new
  chat in either window (handled in `hiddenInput`/`inputField`). `Notifs
  .opencodeFullOpen` disables the bar's application-scoped Escape shortcut while
  the standalone is open (two would be ambiguous). The in-pill docked↔full swap
  (`setPanelExpanded`/`modeSwap`/`pendingMode`) was removed as dead code.
- **Panels share the chat HISTORY, not the current chat.** The
  `OpencodeShared` singleton (registered in `bar/qmldir`) owns the remembered
  chat set (`panelSessions`, persisted once at `opencode-panel-sessions.json`,
  via `remember`/`forget`/`prune`) and the recently-used models; every
  `Opencode` reads it so the docked panel and the standalone see the same list.
  The currently-open chat is per-instance (`root.session`/`newChatPending`), so
  the two windows can show **different conversations at once** — switching or
  starting a chat in one does not move the other. Each instance also keeps its
  own message model, SSE stream and turn state.
- The **full window** is chat-only (`tabRow.visible = !panelExpanded`) and shows
  a Claude/ChatGPT-style chat history rail down the left: a full-width **New
  chat** row, a filter box, then the panel-owned chats bucketed by recency
  (Today / Yesterday / Previous 7 days / Previous 30 days / Older, from each
  session's `time.updated`). The rail is available only when `panelExpanded &&
  mode === "chat"` (`panelContent.sidebarAvailable`); the docked dropdown never
  gets it. A bars button at the top-left of the full window toggles
  `root.sidebarOpen`, and the main column plus every floating sibling (input
  row, image chips, empty state, centered labels) are inset by
  `panelContent.sidebarW` (244px, 0 while docked, off the chat tab, or
  collapsed) so every other mode keeps its full-width layout. Rows highlight the
  open chat, show a live dot while its turn runs, and a hover ✕ to delete;
  `sideGroups()` / `sideFilteredSessions()` / `sideSwitch()` / `sideNewChat()`
  are its API.
- **Model / agent pickers** (`menu === "models" | "agents"` in Opencode.qml)
  follow the assistant-ui / ChatGPT patterns: the composer chips show the
  *friendly* name (`modelChipLabel()` / `agentChipLabel()`, with the reasoning
  variant appended), and the pickers are searchable. Models are **grouped by
  provider** (`modelGroups()`; the flat `filteredModels()` order drives the
  keyboard index), each row showing capability/cost cues (`modelMeta()`:
  `img` / `tools` / `reason` / `$in/$out`) and a fixed-width ✓ on the active
  one; agents show their `description`. Opening preselects the active item and
  scrolls to it (`ensureMenuSelVisible()` walks `modelGroups()` so every section
  header is counted). Models that declare `variants` get a reasoning-**effort**
  chip row at the top (`currentVariants()` / `switchVariant()`), and
  `switchModel(m, variant, keepOpen)` carries the variant in the session model
  ref. A **Recent** section is shown first when not searching, backed by
  `OpencodeShared.recentModels` (persisted at `opencode-recent-models.json`,
  updated via `touchModel()`). `modelGroups()` items carry their flat index
  (`{ m, i }`) so the keyboard selection never relies on `indexOf()` on QML
  `modelData` — that is not reference-stable and made every row share one
  selection (all highlighted on hover). **Ctrl+M** opens the model picker.
- **Big pastes collapse, TUI-style.** The composer grows with its draft up to
  a cap, so a pasted log used to bury the panel; a paste reaching
  `pasteCollapseLines` (6) lines or `pasteCollapseChars` (1200) characters is
  now swapped for a `[Pasted +N lines]` marker as it lands and the real text
  goes into `root.pastes` — `send()` runs the draft through `expandPastes()`
  first, so the transcript (and the session title) still get the full text.
  Both editors detect it the same way, in `onTextChanged`: `pasteCollapse()`
  diffs the new text against the *other* editor's (they mirror each other, so
  that is the pre-paste draft) and replaces the inserted slice with the marker,
  returning the caret to put after it. Markers are unique (a second paste of
  the same size gets `(2)`), so deleting one can never re-route another, and a
  marker edited by hand simply goes out as the literal text it looks like.
  `pastes` is cleared when the draft is actually consumed (successful send,
  `newChat()`), never on a failed send — a retry restores the raw draft.
- Per-component QML files are registered in `hyprconf/qmldir`; shared state
  lives in singletons (`HyprSettings`, `Theme`) and is referenced directly by
  name from files in the same directory — no import needed.
- `WallpaperImage.qml` renders wallpaper paths for the gallery grid
  (`WallpaperGrid.qml`) and the `PreviewBox` used by the Wallpaper and Lock
  Screen tabs. It swaps `Image` for `AnimatedImage` on `.gif` sources so live
  wallpapers animate in the panel; `animate` gates playback and callers bind it
  to the panel/gallery being open (via `panelOpen` / `galleryWin.open`) so
  nothing animates off-screen. Needs `qt6-imageformats` (libqgif).
- **Style:** everything must follow the Pomodoro dropdown palette, defined
  once in `hyprconf/Theme.qml` (bg `#161719`, border `#282a2e`, surface
  `#1e2126`, hover `#282c33`, text `#a9afb8`, muted `#5c6470`, accent
  `#d3d9e0`, secondary accent `#8b95a3`, dark-on-accent `#101216`, sidebar
  `#191b1f`, font `Agave Nerd Font`). Never hardcode colors or the font family
  in components — reference `Theme.*`.
- Interactions use Pomodoro-style motion: `ColorAnimation` 150–200ms on
  colors, small hover scale pops (`1.04`–`1.07`) with `OutCubic` easing.
- **Window lifetime is the shell's dominant performance cost.** quickshell
  destroys a layer/popup window the moment it stops being visible
  (`WlrLayershell::deleteOnInvisible` and `ProxyPopupWindow` both return true)
  and rebuilds it — Wayland surface, GL context, render thread, glyph atlas —
  on the next show. Anything bound to `mouse.containsMouse` therefore pays a
  whole window build per hover. `bar/Tip.qml` waits out a `showDelay` dwell
  (260ms) before its window is created and tracks existence with the explicit
  `windowUp` flag, so sweeping the pointer across the bar maps nothing and a
  tip that never appeared never lingers; click-driven tips (the clock's
  calendar) pass `showDelay: 0`. Keep that in mind before adding a
  hover-driven `visible`.
- The launcher and the clipboard picker *cannot* stay mapped (Exclusive
  keyboard focus would swallow every key while hidden), so each open really
  does build a fullscreen window — keep the open path cheap instead.
  `bar/Launcher.qml` snapshots the entries into plain records (`{ id, entry,
  nameL, genericL }`) only when `DesktopEntries` changes, searches the
  pre-lowercased copies with plain string sorts (no `localeCompare`), memoizes
  resolved icon URLs, and both panels hand the `ListView` a new array only when
  the visible slice actually changed — assigning a fresh array rebuilds every
  delegate.
- `bar/Cava.qml` is a singleton that runs **one** `cava` process for the whole
  shell (the Player pill is per-monitor, so running it inside the pill would
  spawn one per screen) and publishes `levels`/`live`. cava runs with its own
  config (`quickshell/.config/quickshell/cava.conf`, reached via
  `Quickshell.shellPath`) that emits raw ASCII frames on stdout; `Process` +
  `SplitParser` read them, `stdbuf -oL` defeats pipe block-buffering.
  `bar/Player.qml`'s soundwave renders `Cava.levels` while `Cava.live`, and
  falls back to its synthetic animation otherwise — so the shell works fine
  when `cava` is not installed.
- `bar/Auror.qml` is the DLNA renderer pill, stacked directly **above the
  volume pill** in the right bar's bottom group. It fronts the user's
  `~/auror` daemon (Go, zero-dep UPnP `MediaRenderer` that plays casts through
  mpv): it polls auror's `/status` JSON for the cast URL, transport state,
  position/duration and volume, and its dropdown drives playback through
  auror's local HTTP control API. auror publishes the port it bound to (it
  walks 49152..) in `~/.cache/auror/port`, which is how the pill finds it —
  `curl` reads that file and `/status`, and the control calls are argv `curl`
  POSTs to `/api/play|pause|toggle|stop|seek|volume|mute|next|previous`
  (no shell). The pill shows `md-cast-off` (dim) while auror is down, `md-cast`
  when idle and `md-cast-connected` (green) while playing, plus a thin progress
  line on the pill itself; left-click opens the panel, right-click toggles
  play/pause, and the wheel steps auror's volume by 5. The daemon is
  autostarted from `hyprland.lua`, not the panel-managed `hyprpanel.lua`.
  Two failure modes shaped this: auror's `/status` must **never block on the
  mpv IPC** (a fresh mpv socket makes `ensureMpvIPC` dial for up to 2s, which
  read as "offline" right after every cast), so status/event reads go through a
  cached, non-dialing `cachedProp` and the pill's `curl -m` is 1.6s — and a
  single poll miss must not flip the pill, so it keeps the last snapshot for
  `missTolerance` (3) misses and polls at 1s while recovering. Volume/mute/seek
  are applied optimistically (`pendingVol`/`pendingMute`/`pendingSeek`) and held
  until `/status` agrees (or 3s), so a stale poll can't yank a slider back.
- `bar/TypeTest.qml` is the desktop "desk toys" window: a fullscreen
  **Bottom**-layer `PanelWindow` (namespace `quickshell-desk`) shown only while
  the focused monitor's active workspace has no toplevels
  (`monitor.activeWorkspace.toplevels`), following the focused monitor like the
  launcher. It hosts the monkeytype-style typing test AND the arcade games
  (`bar/DeskGames.qml`: 2048 / mines / dice — the old arcade bar pill is gone).
  `view` picks what shows: -1 nothing, 0 typing, 1..3 games; a row of tabs at
  the bottom center toggles it — idle they sit flush in the bar's colour with
  only their outer top corners rounded (ONE "mound"), and on hover the gaps
  open, they lift and become pills (all one animation; `HoverHandler`, not a
  MouseArea, so the tabs keep their own hover/click). Keyboard is
  `WlrKeyboardFocus.OnDemand` (constant), **not** `Exclusive` — so Hyprland
  keybinds are never swallowed — and the surface unmaps whenever a window exists
  (an unmapped surface grabs nothing, which also dodges Hyprland's bug where
  dropping interactivity back to `None` strands the keyboard). Typed into
  directly via a hidden `TextInput` (launcher model); the 2048 board reads the
  arrow keys through it too. Modes: time (15/30/60) / words (10/25/50) +
  difficulty (normal/punct/num); metrics WPM/raw/accuracy/consistency. The word
  list is run-grouped RichText in a read-only `TextEdit` (only
  TextEdit/TextInput expose `positionToRectangle`, which the caret needs). PBs
  persist through the `TypeStore` singleton (`typing-pbs.json` in `stateDir`);
  `qs ipc call typetest toggle|enable|disable` flips the typing view.
- **Live Voice Mode** (`bar/voice-daemon.py` + `bar/VoiceStage.qml`) is a
  ChatGPT-style hands-free spoken conversation: continuous mic → adaptive VAD →
  Whisper → opencode → neural TTS, with turn-taking and barge-in. It is a
  long-lived Python daemon spawned by `bar/Opencode.qml` (`Process` +
  `stdinEnabled`, JSON-lines protocol on stdin/stdout) rather than a QML
  re-implementation, because the models must stay warm in RAM: `whisper-server`
  (`ggml-small.bin`, or `ggml-medium-q5_0.bin` in accurate mode) answers
  `/inference` in **~250 ms** because `audio_ctx` is
  scaled to each clip's length (50 ctx frames = 1 s, +headroom, clamped
  512..1500), and Piper (`calibre_extensions.piper`, `pt_BR-faber-medium` /
  `en_US-lessac-medium` at 22 kHz, models in `~/.local/share/piper/`) synthesizes
  a sentence in **~120 ms**. `piper.initialize("")` + `set_voice(cfg, model)`
  must be called once; `piper.next(bool)` streams chunks and reports `is_last`.
  The daemon records **every** non-monitor PipeWire source at once (`pw-record
  --raw --target <name> -`, discovered via `pactl list sources short`) and locks
  onto whichever mic triggers speech, since the default source is often an idle
  headset dongle. **`--raw` is mandatory**: without it `pw-record` writes an
  `.au` header and `pw-cat -p` waits for a container header, so nothing plays.
  VAD is adaptive (tracked noise floor, 1.4 s pause to end a turn, ~96 ms to
  trigger/ barge-in, trailing silence trimmed before STT), and the reply is
  spoken sentence-by-sentence: `Opencode.qml` splits `session.text.delta` on
  sentence boundaries in `feedVoiceStream`, strips markdown/code in
  `cleanForSpeech`, and pipes chunks to the daemon, which synthesizes and plays
  back-to-back through one `pw-cat -p` process. Speaking over the assistant
  kills playback (<50 ms), drops queued synthesis and interrupts the turn.
- **Mixed PT/EN speech** is the hard case for Whisper here (a Brazilian accent
  turns "commit" into "permite", "branch" into "tranche", "deploy" into "etoy"),
  and there are measured numbers for what actually helps. Benchmarked on an
  8-sentence mixed PT/EN set (WER / mean latency):

  | STT config | WER | latency |
  |---|---|---|
  | small, greedy | 24.2% | 0.98 s |
  | small, beam 5 | 20.2% | 0.97 s |
  | medium-q5, greedy | 15.2% | 3.18 s |
  | **medium-q5, beam 5** | **11.3%** | 3.69 s |
  | large-v3-turbo-q5, beam 5 | 22.8% | 3.92 s |

  So `-bs 5` is free accuracy (the encoder dominates a short clip — it was
  *faster* than greedy in the run above) and **medium-q5 + beam 5 halves the
  errors**, which is why Voice Mode has two quality levels (`fast` = small,
  `accurate` = medium-q5, default) picked by the `ACCURATE`/`FAST` chips in the
  voice stage and stored as `voiceStt` in `opencode-voice-prefs.json`.
  `WhisperSTT.set_quality()` swaps by tearing down and rebuilding the server on
  a worker thread (fast reloads in ~0.6 s, medium-q5 in ~1.5 s) and reports
  `stt_ready`. large-v3-turbo is worse *and* slower here — and with beam 5 it
  once fell into a repetition loop — so it is not used.
  Three more traps, all of which were live bugs: (a) **`prompt` is not a
  whisper-server form field** (its multipart table ends at
  `no_language_probabilities`), so sending the vocabulary primer per request did
  nothing — it only works as a **startup** `--prompt`, which is why `PROMPT_BASE`
  (`TECH_TERMS` + a one-line context sentence) is passed in `_start_server()`.
  `no_speech_thold=0.9` and `temperature_inc=0.2` *are* per-request fields and
  are sent on every call (the 0.6 default silently drops segments from a soft
  mic, and `-nf` was disabling the fallback that retries a degenerate decode).
  (b) **`auto` language is a coin flip on a short accented clip** — the detector
  reports `welsh`/`nn` with a ~0.15 probability and the whole utterance is then
  decoded in that language, which is what "frases erradas" looked like; when the
  detected language is neither pt nor en, `transcribe()` redoes the call pinned
  to the sticky last language. (c) In `auto`, the assistant's **reply voice is
  chosen once per reply** and then held (`reply_lang`), instead of re-deciding
  per sentence and switching voices mid-answer.
- `fix_tech_terms()` repairs the near-miss tokens Whisper still produces
  ("teaturi" → "feature"), but only for tokens within a small edit distance of a
  term AND that `hunspell -l -d pt_BR,en_US` rejects (so "pasta", "teste",
  "permite", "quebrou" are never touched); a 2+ edit match must also share the
  onset consonant, else "daon" becomes "main". Verdicts are cached in memory
  *and* in `~/.cache/opencode-voice-words.json`, and hunspell is only spawned for
  near-miss tokens, so a normal utterance costs ~0 ms. `EXACT_MISHEAR` holds the
  high-confidence forms that are too far for the fuzzy pass. Keep `audio_ctx` at
  ≥512 (encoder over-compression is its own accuracy loss) and keep the adaptive
  window: clamping to the full 1500 cost 2.3x the time and scored *worse*.
  `OPENCODE_VOICE_WHISPER_MODEL` / `_MODEL_ACCURATE` override the two models.
- Spoken volume is applied in the daemon (scaled PCM) and persisted with the
  language in `OpencodeShared` (`opencode-voice-prefs.json`). A **Voice Mode
  model** is stored in the same file (`voiceModel: {id, providerID}`): the chip
  in the voice stage / compact dock opens `VoiceStage`'s own picker overlay
  (mouse-only on purpose — the docked popup is keyboard-less, so a search field
  there could never be typed into) and `applyVoiceModel()` re-points the open
  session plus `lastModel`, so every voice turn and any chat born from a voice
  turn uses it; picking `session model` clears the override. Toggled from the
  centered pill under the input on a blank chat (the input row keeps only
  image/mic/send — the voice trigger deliberately does not live there), from
  `Alt+V` / `Ctrl+Shift+V`, and via `qs ipc call opencode voice` —
  which is also what **SUPER+SHIFT+A** runs (`opencode voiceFull` /
  `opencodeFull voice` open the *standalone* window instead). It opens the
  focused bar's **docked** dropdown (`toggleVoiceChat()` → `panelOpen` +
  `startVoiceMode()`, never `pendingExpanded`, so it is the small panel, not
  the big window); `Space` is interrupt/send-now/unmute, `M` mutes.
- Validate changes with `qmllint <file>.qml` (run from
  `quickshell/.config/quickshell/`) before finishing. Live reload with
  `qs` only if the user asks for it.

## Hyprland configs

- `hyprland.lua` uses the Lua config API (`hl.env`, `hl.exec`, …) — keep new
  settings in Lua, don't create a parallel `hyprland.conf`.
- Panel-managed compositor settings (monitors, look & feel, input, per-leaf
  animations, autostart) live in `hyprpanel.lua`, loaded by `hyprland.lua` via
  `package.loaded["hyprpanel"] = nil; require("hyprpanel")`. `HyprPanel.js`
  parses and renders `hyprpanel.lua` deterministically (tested in
  `hyprconf/tests/hyprpanel.mjs`), and saving runs `hyprctl reload`.
- The quickshell `hyprconf/` panel writes `wallpaper.conf`,
  `hyprlock.conf`, and `hypridle.conf` in place; keep its parse/serialize
  round-trip (`Conf.js`) lossless when touching that code.
- Wallpapers run through **awww** (swww's successor), not hyprpaper, so
  animated GIFs work. `wallpaper.conf` is the source of truth
  (`transition = <awww type>` plus one hyprpaper-style `wallpaper { … }`
  block per monitor); `scripts/wallpaper-apply` parses it and issues
  `awww img -o <monitor> --resize <fit_mode>`, and is the single apply path
  used by both the autostart in `hyprland.lua` and the panel's Save.
  `awww-daemon` must be running first — the script polls `awww query` for it.

## Conventions

- QML: 4-space indent in `hyprconf/`, 2-space in `bar/` — match the file
  you are editing.
- No build system or dependency install; plain file edits are the whole
  workflow.

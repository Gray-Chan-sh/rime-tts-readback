-- rime-tts-readback: write committed (on-screen) text to a queue file.
--
--   * one small file per commit, written as .tmp then renamed (atomic; the reader
--     never sees a half-written file)
--   * bare digits (0-9 typed while not composing) are reported too: Rime rejects
--     them and the front end inserts them, so no commit event would fire
--   * if the "muted"/disabled flag file exists, nothing is written at all
--   * pure file I/O inside pcall: no process spawn, no blocking, safe for the IME
--
-- Cross-platform: Weasel (Windows), Squirrel (macOS), ibus-rime / fcitx5-rime (Linux).
-- Set RIME_TTS_DIR to point the queue somewhere else (it names the queue directory).
--
-- Remove: delete this file and drop `lua_processor@tts_reporter` from your *.custom.yaml.

local SEP  = package.config:sub(1, 1)   -- '\' on Windows, '/' everywhere else
local IS_WIN = SEP == "\\"

-- Windows keeps using %USERPROFILE% (unchanged behaviour); elsewhere use $HOME.
local HOME
if IS_WIN then
  HOME = os.getenv("USERPROFILE") or os.getenv("HOME") or "."
else
  HOME = os.getenv("HOME") or "."
end

-- Where the queue and the mute flag live.
--   Windows : %USERPROFILE%\Rime_tts_queue   / %USERPROFILE%\Rime_tts_off
--   macOS   : ~/Library/Rime/tts_queue       / ~/Library/Rime/tts_off
-- (On macOS and Linux the queue lives *inside* the Rime user directory so that it
--  keeps working even if the front end runs sandboxed.)
local function default_base()
  if IS_WIN then
    return HOME
  end
  return HOME .. SEP .. "Library" .. SEP .. "Rime"   -- Squirrel / macOS
end

local BASE      = default_base()
-- RIME_TTS_DIR names the *queue directory* itself (same meaning as on the reader side).
local QUEUE_DIR = os.getenv("RIME_TTS_DIR") or (BASE .. SEP .. (IS_WIN and "Rime_tts_queue" or "tts_queue"))
local OFF_FILE  = BASE .. SEP .. (IS_WIN and "Rime_tts_off" or "tts_off")

local seq = 0

local function muted()
  local f = io.open(OFF_FILE, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function write_queue(text)
  if text == nil or text == "" then
    return
  end
  seq = seq + 1
  local base = string.format("%s%s%d_%d", QUEUE_DIR, SEP, os.time(), seq)
  local f = io.open(base .. ".tmp", "w")
  if f then
    f:write(text)
    f:close()
    os.rename(base .. ".tmp", base .. ".txt")
  end
end

-- Digits with no active composition are rejected by the engine (ascii_composer
-- returns kRejected) and inserted by the front end directly, so commit_notifier
-- never sees them. The same happens to ASCII letters while the IME is in ASCII
-- mode. Report those ourselves and still let the key through (kNoop), so typing
-- is completely unchanged.
--   * while composing, digits select candidates and letters build pinyin; skip
--   * Ctrl/Alt/Cmd combinations are left alone
--   * muted: not reported (the key still reaches the app)
local function bare_char(key)
  if key:release() or key:ctrl() or key:alt() or key:super() then
    return nil
  end
  local repr = key:repr()
  if #repr ~= 1 then
    return repr:match("^KP_(%d)$")
  end
  if repr:match("^%d$") then
    return key:shift() and nil or repr
  end
  if repr:match("^%a$") then
    return repr -- letters, including Shift-ed uppercase
  end
  return nil
end

local function on_commit(ctx)
  pcall(function()
    if muted() then
      return
    end
    write_queue(ctx:get_commit_text())
  end)
end

tts_reporter = {
  init = function(env)
    pcall(function()
      env._tts_conn = env.engine.context.commit_notifier:connect(on_commit)
    end)
  end,
  func = function(key, env)
    pcall(function()
      local ctx = env.engine.context
      if ctx:is_composing() then
        return
      end
      if muted() then
        return
      end
      local ascii_mode = ctx:get_option("ascii_mode")
      -- keep word boundaries for English typed in ASCII mode
      if ascii_mode and key:repr() == " " then
        write_queue(" ")
        return
      end
      local ch = bare_char(key)
      if ch == nil then
        return
      end
      if ch:match("%d") or ascii_mode then
        write_queue(ch)
      end
    end)
    return 2 -- kNoop: never intercept keys, typing stays untouched
  end,
  fini = function(env)
    pcall(function()
      if env._tts_conn then
        env._tts_conn:disconnect()
      end
    end)
  end,
}
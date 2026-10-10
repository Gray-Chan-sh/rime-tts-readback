-- rime-tts-readback: write committed (on-screen) text to a queue file.
--
--   * one small file per commit, written as .tmp then renamed (atomic; the reader
--     never sees a half-written file)
--   * if %USERPROFILE%\Rime_tts_off exists (the "muted"/disabled flag), nothing is
--     written at all
--   * pure file I/O inside pcall: no process spawn, no blocking, safe for the IME
--
-- Remove: delete this file and drop `lua_processor@tts_reporter` from your *.custom.yaml.

local HOME      = os.getenv("USERPROFILE") or "."
local QUEUE_DIR = HOME .. "\\Rime_tts_queue"
local OFF_FILE  = HOME .. "\\Rime_tts_off"
local seq = 0

local function muted()
  local f = io.open(OFF_FILE, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function on_commit(ctx)
  pcall(function()
    if muted() then
      return
    end
    local text = ctx:get_commit_text()
    if text == nil or text == "" then
      return
    end
    seq = seq + 1
    local base = string.format("%s\\%d_%d", QUEUE_DIR, os.time(), seq)
    local f = io.open(base .. ".tmp", "w")
    if f then
      f:write(text)
      f:close()
      os.rename(base .. ".tmp", base .. ".txt")
    end
  end)
end

tts_reporter = {
  init = function(env)
    pcall(function()
      env._tts_conn = env.engine.context.commit_notifier:connect(on_commit)
    end)
  end,
  func = function(key, env)
    return 2 -- kNoop: never intercept keys
  end,
  fini = function(env)
    pcall(function()
      if env._tts_conn then
        env._tts_conn:disconnect()
      end
    end)
  end,
}

-- 上屏文字写入队列：每个提交写一个文件（先写 .tmp 再改名，避免读到半个文件）。
-- 不起进程、不朗读、不做重活；全程 pcall，失败静默跳过，绝不阻塞输入法。
-- 关闭：删掉本文件，并去掉 schema 补丁里的 lua_processor@tts_reporter 一行。

local QUEUE_DIR = (os.getenv("USERPROFILE") or ".") .. "\\Rime_tts_queue"
local seq = 0

local function on_commit(ctx)
  pcall(function()
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
    return 2 -- kNoop：不拦截任何按键
  end,
  fini = function(env)
    pcall(function()
      if env._tts_conn then
        env._tts_conn:disconnect()
      end
    end)
  end,
}

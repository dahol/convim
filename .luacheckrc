-- Luacheck configuration for convim

std = "lua51"
globals = {
  "describe",
  "it",
  "assert",
  "before_each",
  "after_each",
  "vim",
  "mock",
  "stub"
}

files["tests/**.lua"].globals = {
  "describe",
  "it",
  "assert",
  "before_each",
  "after_each",
  "mock",
  "stub"
}

exclude_files = {"vendor/*", "build/*"}

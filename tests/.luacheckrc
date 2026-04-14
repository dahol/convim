-- Test-specific luacheck config
std = "lua51"
globals = {
  "describe",
  "it",
  "assert",
  "before_each",
  "after_each",
  "mock",
  "stub",
  "package",
  "vim"
}

files["*.lua"].globals = {
  "describe",
  "it",
  "assert",
  "before_each",
  "after_each"
}

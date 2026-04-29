# Static lint without `mix deps.get` — for sandboxed environments
# where `repo.hex.pm` is unreachable. Stubs the Jido / Jido.AI / Jason
# surface our code touches, then parallel-compiles every project file
# so all cross-references resolve and any undefined-function /
# arity-mismatch / behaviour-drift bug surfaces as a real warning.
#
# Run from the project root:
#
#     elixir bin/lint/lint.exs
#
# Once `mix deps.get` works, drop this script and use:
#
#     mix format --check-formatted && mix compile --warnings-as-errors && mix test

stubs_path = Path.join([File.cwd!(), "bin", "lint", "jido_stubs.ex"])
Code.require_file(stubs_path)

lib_files = Path.wildcard("lib/**/*.ex") ++ Path.wildcard("test/support/**/*.ex")

case Kernel.ParallelCompiler.compile(lib_files) do
  {:ok, modules, _} ->
    IO.puts("[lint] Compiled #{length(modules)} lib + support modules clean.")

  {:error, errors, warnings} ->
    Enum.each(errors, fn {f, l, m} -> IO.puts("ERR #{f}:#{l} #{m}") end)
    Enum.each(warnings, fn {f, l, m} -> IO.puts("WRN #{f}:#{l} #{m}") end)
    System.halt(1)
end

# Parsing all test files with ExUnit started catches typos / wrong
# module references inside test code as well.
ExUnit.start(autorun: false)

test_files =
  Path.wildcard("test/**/*_test.exs") --
    Path.wildcard("test/integration/**/*.exs")

case Kernel.ParallelCompiler.require(test_files) do
  {:ok, modules, _} ->
    IO.puts("[lint] Required #{length(modules)} test modules clean.")

  {:error, errors, warnings} ->
    Enum.each(errors, fn {f, l, m} -> IO.puts("ERR #{f}:#{l} #{m}") end)
    Enum.each(warnings, fn {f, l, m} -> IO.puts("WRN #{f}:#{l} #{m}") end)
    System.halt(1)
end

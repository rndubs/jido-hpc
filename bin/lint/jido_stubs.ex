# Lint-only stubs of the Jido / Jido.AI / Jason surface this codebase
# touches. The shapes here are educated guesses based on the Jido docs
# (https://github.com/agentjido/jido) and what our `use` callers
# expect — they are NOT a faithful reimplementation. They exist solely
# to make `bin/lint/lint.exs` work in environments where `mix
# deps.get` cannot reach `repo.hex.pm`.
#
# When the real deps land, DELETE THIS FILE and `bin/lint/lint.exs`
# and rely on `mix compile --warnings-as-errors` instead.
#
# Replacement checklist (see plan.md "Phase 4.5"):
#   [ ] Verify `Jido.Action` __using__ option list matches reality
#       (especially `:schema` validation rules).
#   [ ] Verify `Jido.Plugin` exposes `child_spec/1` callback the way
#       SlurmSkill assumes, and that `signal_routes:` is honored.
#   [ ] Verify `Jido.AI.Agent` exposes `ask_stream/3` + `await/2`
#       with the shape REPL.Dispatcher.Live forwards.

defmodule Jido do
  defmacro __using__(_opts) do
    quote do
      def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
      def start_link(_), do: {:ok, self()}
    end
  end
end

defmodule Jido.Signal do
  def new!(map), do: map
  def new(map), do: {:ok, map}
end

defmodule Jido.Action do
  @callback run(map(), map()) :: {:ok, map()} | {:error, any()}

  defmacro __using__(opts) do
    quote do
      @behaviour Jido.Action
      @action_opts unquote(opts)
      def __action_opts__, do: @action_opts
      def name, do: Keyword.get(@action_opts, :name)
      def description, do: Keyword.get(@action_opts, :description)
      def schema, do: Keyword.get(@action_opts, :schema, [])
    end
  end
end

defmodule Jido.Plugin do
  @callback child_spec(keyword()) :: any()

  defmacro __using__(opts) do
    quote do
      @plugin_opts unquote(opts)
      @behaviour Jido.Plugin
      def __plugin_opts__, do: @plugin_opts
      def child_spec(_config), do: nil
      defoverridable child_spec: 1
    end
  end
end

defmodule Jido.AI do
  def ask(_prompt), do: {:ok, "ok"}
end

defmodule Jido.AI.Agent do
  defmacro __using__(opts) do
    quote do
      @agent_opts unquote(opts)
      def __agent_opts__, do: @agent_opts
      def name, do: Keyword.get(@agent_opts, :name)
      def description, do: Keyword.get(@agent_opts, :description)
      def system_prompt, do: Keyword.get(@agent_opts, :system_prompt)
      def skills, do: Keyword.get(@agent_opts, :skills, [])
      def ask_stream(_agent, _prompt, _opts), do: {:ok, %{request: make_ref(), events: []}}
      def await(_agent, _request), do: {:ok, %{}}
    end
  end
end

# Real Jason — full surface so we don't generate fake "undefined" warnings.
defmodule Jason do
  def encode!(term), do: inspect(term)
  def encode(term), do: {:ok, inspect(term)}
  def decode!(_), do: %{}
  def decode(_), do: {:ok, %{}}
end

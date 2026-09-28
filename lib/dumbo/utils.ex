defmodule Dumbo.Utils do
  @moduledoc false

  @doc """
  Chains parser steps inline, threading `rest`, `position` and `context`, which
  the result references as `&rest`, `&position` and `&context`.

  Steps are comma-separated before `->`:

    * `pattern <- parser(args)` — `parser(rest, position, context, args...)`
      returning `{value, rest, position, context}`
    * `pattern <~ transformer(args)` — `transformer(context, args...)`
      returning `{value, context}`
    * `function(args)` — `function(context, args...)`, returning `context`
    * `pattern = expression` — a pure binding

  For example:

      chain(rest, position, context) do
        size <- sized(?:), data <- bytes(size), _ <- expect(?;) ->
          push(data, &rest, &position, &context)
      end
  """
  defmacro chain(rest, position, context, do: [{:->, _, [steps, result]}]) do
    steps = if is_list(steps), do: steps, else: [steps]

    rest_var = Macro.unique_var(:rest, __MODULE__)
    position_var = Macro.unique_var(:position, __MODULE__)
    context_var = Macro.unique_var(:context, __MODULE__)

    inject = fn call, prefix ->
      case call do
        {name, meta, args} when is_list(args) -> {name, meta, prefix ++ args}
        other -> other
      end
    end

    bindings =
      Enum.map(steps, fn
        {:<-, _, [pattern, call]} ->
          quote do
            {unquote(pattern), unquote(rest_var), unquote(position_var), unquote(context_var)} =
              unquote(inject.(call, [rest_var, position_var, context_var]))
          end

        {:<~, _, [pattern, call]} ->
          quote do
            {unquote(pattern), unquote(context_var)} =
              unquote(inject.(call, [context_var]))
          end

        {:=, _, [pattern, expr]} ->
          quote do
            unquote(pattern) = unquote(expr)
          end

        call ->
          quote do
            unquote(context_var) = unquote(inject.(call, [context_var]))
          end
      end)

    result =
      Macro.prewalk(result, fn
        {:&, _, [{name, _, ctx}]}
        when name in [:rest, :position, :context] and is_atom(ctx) ->
          Map.fetch!(%{rest: rest_var, position: position_var, context: context_var}, name)

        node ->
          node
      end)

    quote do
      unquote(rest_var) = unquote(rest)
      unquote(position_var) = unquote(position)
      unquote(context_var) = unquote(context)
      unquote_splicing(bindings)
      unquote(result)
    end
  end
end

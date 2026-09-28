defmodule Docgen.Ingest.Lists do
  @moduledoc """
  Builds nested IR list blocks from a flat sequence of list items.

  Each item is `{indent, kind, inlines}` where `indent` is the number of
  leading spaces and `kind` is `:bullet` or `:number`. An item indented deeper
  than the previous one becomes its child; a change of kind at the same
  indentation starts a new list.
  """

  alias Docgen.Document

  @type item :: {non_neg_integer(), :bullet | :number, [Document.inline()]}

  @spec build([item()]) :: [Document.list_block()]
  def build(items), do: build(items, 1)

  defp build([], _level), do: []

  defp build([{base, kind, _} | _] = items, level) do
    {list_items, rest} = collect(items, base, kind, level, [])
    [{list_type(kind), level, list_items} | build(rest, level)]
  end

  defp collect([{indent, kind, inlines} | rest], base, kind, level, acc) when indent <= base do
    {children, rest} = Enum.split_while(rest, fn {i, _, _} -> i > base end)
    collect(rest, base, kind, level, [{inlines, build(children, level + 1)} | acc])
  end

  defp collect(rest, _base, _kind, _level, acc), do: {Enum.reverse(acc), rest}

  defp list_type(:bullet), do: :bullet_list
  defp list_type(:number), do: :numbered_list
end

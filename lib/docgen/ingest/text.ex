defmodule Docgen.Ingest.Text do
  @moduledoc """
  Plain text → `Docgen.Document` using layout heuristics.

    * Blank lines separate blocks; wrapped lines within a block are joined.
    * Lines starting with `-`, `*`, `•`, `–`, `1.` or `1)` are list items;
      indentation nests them.
    * A short single-line block without terminal punctuation is a heading.
      Section numbers set the level (`2.1 Scope` → level 2); otherwise ALL
      CAPS headings are level 1 and the rest level 2 when both kinds appear.
    * A heading-like first block becomes `meta.title`.

  Text is taken literally — no inline markup is interpreted.
  """

  alias Docgen.Document
  alias Docgen.Ingest.Lists

  @list_item ~r/\A( *)([-*•–]|\d{1,3}[.)])[ \t]+(\S.*)\z/u
  @numbered_heading ~r/\A(\d+(?:\.\d+)*)\.?[ \t]+\S/
  @max_heading_words 12

  @doc """
  Parses plain text into a document.

  ## Options

    * `:meta` — metadata to set on the document
    * `:promote_title` — use a heading-like first block as `meta.title`
      (default `true`)
  """
  @spec parse(String.t(), keyword()) :: Document.t()
  def parse(text, opts \\ []) do
    chunks =
      text
      |> String.replace(~r/\r\n?/, "\n")
      |> String.replace("\t", "    ")
      |> String.split(~r/\n[ \t]*\n/)
      |> Enum.map(&(&1 |> String.split("\n") |> Enum.map(fn l -> String.trim_trailing(l) end)))
      |> Enum.reject(fn lines -> Enum.all?(lines, &(&1 == "")) end)
      |> Enum.map(&Enum.reject(&1, fn l -> l == "" end))

    doc = Document.put_meta(%Document{}, Keyword.get(opts, :meta, %{}))

    {doc, chunks} =
      case chunks do
        [[line] | rest] ->
          if Keyword.get(opts, :promote_title, true) and is_nil(doc.meta[:title]) and
               heading?(line) and not Regex.match?(@numbered_heading, line) do
            {Document.put_meta(doc, title: String.trim(line)), rest}
          else
            {doc, chunks}
          end

        _ ->
          {doc, chunks}
      end

    blocks = chunks |> Enum.flat_map(&chunk/1) |> assign_heading_levels()

    warnings =
      if Enum.any?(blocks, &match?({:heading, _, _}, &1)),
        do: ["Headings were guessed from plain-text layout — check them in the preview."],
        else: []

    %{doc | blocks: blocks, warnings: doc.warnings ++ warnings}
  end

  defp chunk([line]) do
    if heading?(line), do: [{:heading_candidate, String.trim(line)}], else: split_chunk([line])
  end

  defp chunk(lines), do: split_chunk(lines)

  # Leading non-list lines form a paragraph; from the first list item on, the
  # chunk is a list and unmarked lines continue the previous item.
  defp split_chunk(lines) do
    {intro, list} = Enum.split_while(lines, &(not Regex.match?(@list_item, &1)))
    paragraph(intro) ++ list(list)
  end

  defp paragraph([]), do: []

  defp paragraph(lines),
    do: [{:paragraph, [{:text, Enum.map_join(lines, " ", &String.trim/1)}]}]

  defp list([]), do: []

  defp list(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      case Regex.run(@list_item, line) do
        [_, indent, marker, text] ->
          [{byte_size(indent), kind(marker), [text]} | acc]

        nil ->
          [{indent, kind, text} | acc] = acc
          [{indent, kind, [String.trim(line) | text]} | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {indent, kind, text} ->
      {indent, kind, [{:text, text |> Enum.reverse() |> Enum.join(" ")}]}
    end)
    |> Lists.build()
  end

  defp kind(marker) when marker in ["-", "*", "•", "–"], do: :bullet
  defp kind(_), do: :number

  defp heading?(line) do
    line = String.trim(line)

    cond do
      Regex.match?(~r/\A\d+(?:\.\d+)+\.?[ \t]+\S/, line) -> true
      Regex.match?(@list_item, line) -> false
      String.match?(line, ~r/[.,;:!?]\z/) -> false
      not String.match?(line, ~r/\p{L}/u) -> false
      true -> length(String.split(line)) <= @max_heading_words
    end
  end

  defp assign_heading_levels(blocks) do
    candidates = for {:heading_candidate, text} <- blocks, do: text
    unnumbered = Enum.reject(candidates, &Regex.match?(@numbered_heading, &1))
    mixed? = Enum.any?(unnumbered, &all_caps?/1) and not Enum.all?(unnumbered, &all_caps?/1)

    Enum.map(blocks, fn
      {:heading_candidate, text} -> {:heading, level(text, mixed?), [{:text, text}]}
      block -> block
    end)
  end

  defp level(text, mixed?) do
    case Regex.run(@numbered_heading, text) do
      [_, number] -> number |> String.split(".") |> length() |> min(6)
      nil -> if mixed? and not all_caps?(text), do: 2, else: 1
    end
  end

  defp all_caps?(text), do: String.upcase(text) == text and String.downcase(text) != text
end

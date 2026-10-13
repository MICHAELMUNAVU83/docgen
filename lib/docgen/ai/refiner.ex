defmodule Docgen.AI.Refiner do
  @moduledoc """
  Conservative document-layout refinements that never invent content.

  The first refinement targets a common PDF-import failure: table columns are
  flattened into separate paragraphs. Three or more consecutive rows with an
  explicit percentage are reconstructed as an editable Markdown table.

  The second targets lists written without markers (pasted slide content,
  notes): paragraphs the planner identified as list items become bullet
  lists, so they pick up the template's bullet style.
  """

  alias Docgen.Document

  @row ~r/^(.+?)\s+\*{0,2}(\d+(?:\.\d+)?%)\*{0,2}\s+(.+)$/s
  @flattened_header ~r/^\#{1,6}\s+Area\s+Rating\s+Comment\s*$/i

  @spec refine_markdown(String.t()) :: String.t()
  def refine_markdown(markdown) when is_binary(markdown) do
    markdown
    |> String.split(~r/\n\s*\n/)
    |> refine_chunks([])
    |> Enum.join("\n\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  @doc """
  Turns the paragraphs at `indices` (positions in `doc.blocks`) into bullet
  lists, one per run of consecutive paragraphs. A paragraph on its own is
  left alone, as a one-item list isn't a list.
  """
  @spec bullet_paragraphs(Document.t(), [non_neg_integer()]) :: Document.t()
  def bullet_paragraphs(%Document{} = doc, []), do: doc

  def bullet_paragraphs(%Document{blocks: blocks} = doc, indices) do
    marked = MapSet.new(indices)
    item? = fn {block, index} -> match?({:paragraph, _}, block) and index in marked end

    blocks =
      blocks
      |> Enum.with_index()
      |> Enum.chunk_by(item?)
      |> Enum.flat_map(fn
        [first, _ | _] = run ->
          if item?.(first),
            do: [{:bullet_list, 1, for({{:paragraph, inlines}, _} <- run, do: {inlines, []})}],
            else: Enum.map(run, &elem(&1, 0))

        run ->
          Enum.map(run, &elem(&1, 0))
      end)

    %{doc | blocks: blocks}
  end

  defp refine_chunks([], acc), do: Enum.reverse(acc)

  defp refine_chunks([header | rest], acc) do
    {row_chunks, tail} = Enum.split_while(rest, &(parse_row(&1) != nil))

    cond do
      Regex.match?(@flattened_header, String.trim(header)) and length(row_chunks) >= 3 ->
        refine_chunks(tail, [table(row_chunks) | acc])

      parse_row(header) && length(row_chunks) >= 2 ->
        refine_chunks(tail, [table([header | row_chunks]) | acc])

      true ->
        refine_chunks(rest, [header | acc])
    end
  end

  defp table(chunks) do
    rows = Enum.map(chunks, &parse_row/1)

    (["| Area | Rating | Comment |", "| --- | ---: | --- |"] ++
       Enum.map(rows, fn {area, rating, comment} ->
         "| #{cell(area)} | #{cell(rating)} | #{cell(comment)} |"
       end))
    |> Enum.join("\n")
  end

  defp parse_row(chunk) do
    case Regex.run(@row, String.trim(chunk), capture: :all_but_first) do
      [area, rating, comment] ->
        {clean_area(area), String.trim(rating), String.trim(comment)}

      _ ->
        nil
    end
  end

  defp clean_area(area), do: area |> String.replace("**", "") |> String.trim()
  defp cell(value), do: value |> String.replace("|", "\\|") |> String.replace("\n", " ")
end

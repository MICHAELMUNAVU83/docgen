defmodule Docgen.AI.Refiner do
  @moduledoc """
  Conservative document-layout refinements that never invent content.

  The first refinement targets a common PDF-import failure: table columns are
  flattened into separate paragraphs. Three or more consecutive rows with an
  explicit percentage are reconstructed as an editable Markdown table.
  """

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

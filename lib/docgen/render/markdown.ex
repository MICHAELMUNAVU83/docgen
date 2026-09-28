defmodule Docgen.Render.Markdown do
  @moduledoc """
  Renders a `Docgen.Document` as Markdown that `Docgen.Ingest.Markdown`
  parses back to the same IR.

  Used to make imported `.docx`/`.pdf` files editable. Images can't live in
  text, so they are returned separately and referenced as
  `![caption](docgen-image:N)`; pass them back via the `:images` option of
  `Docgen.Ingest.Markdown.parse/2`. Page breaks have no Markdown form and
  are dropped.
  """

  alias Docgen.Document

  @image_scheme "docgen-image:"

  @doc "The URL scheme used for image references."
  def image_scheme, do: @image_scheme

  @doc """
  Returns `{markdown, images}` where `images` maps reference ids to images.
  """
  @spec render(Document.t()) :: {String.t(), %{String.t() => Docgen.Image.t()}}
  def render(%Document{} = doc) do
    {chunks, images} =
      Enum.flat_map_reduce(doc.blocks, %{}, fn block, images ->
        case block(block, images) do
          {nil, images} -> {[], images}
          {chunk, images} -> {[chunk], images}
        end
      end)

    {Enum.join(chunks, "\n\n") <> "\n", images}
  end

  ## Blocks

  defp block({:heading, level, inlines}, images),
    do: {String.duplicate("#", min(level, 6)) <> " " <> line(inlines), images}

  defp block({:paragraph, inlines}, images) do
    case inlines(inlines) do
      "" -> {nil, images}
      text -> {text |> String.split("\n") |> Enum.map_join("\n", &escape_block_start/1), images}
    end
  end

  defp block({:caption, :table, inlines}, images), do: {"Table: " <> line(inlines), images}

  # The label marks it as Important when parsed back.
  defp block({:important, inlines}, images) do
    labelled? =
      inlines
      |> Document.plain_text()
      |> String.trim_leading()
      |> String.match?(~r/\Aimportant\s*:/i)

    block(
      {:note,
       if(labelled?, do: inlines, else: [{:bold, [text: "Important:"]}, {:text, " "} | inlines])},
      images
    )
  end

  defp block({:note, inlines}, images) do
    text = inlines |> inlines() |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1))
    {text, images}
  end

  defp block({:code_block, text}, images) do
    fence = fence(text, "`", 3)
    {fence <> "\n" <> text <> "\n" <> fence, images}
  end

  defp block({type, _level, _items} = list, images) when type in [:bullet_list, :numbered_list],
    do: {list |> list_lines("") |> Enum.join("\n"), images}

  defp block({:table, header_rows, rows}, images) do
    all = header_rows ++ rows
    columns = all |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    if columns == 0 do
      {nil, images}
    else
      {header, body} =
        case header_rows do
          [first | more] -> {first, more ++ rows}
          [] -> {List.duplicate([], columns), rows}
        end

      table =
        [table_row(header, columns), "|" <> String.duplicate(" --- |", columns)] ++
          Enum.map(body, &table_row(&1, columns))

      {Enum.join(table, "\n"), images}
    end
  end

  defp block({:image, image, caption}, images) do
    id = "#{map_size(images) + 1}"
    alt = (caption || "") |> String.replace(~r/[\[\]\n]/, " ") |> String.trim()
    {"![#{alt}](#{@image_scheme}#{id})", Map.put(images, id, image)}
  end

  defp block(:page_break, images), do: {nil, images}

  ## Lists

  defp list_lines({type, _level, items}, indent) do
    items
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {{inlines, children}, n} ->
      marker = if type == :numbered_list, do: "#{n}. ", else: "- "
      child_indent = indent <> String.duplicate(" ", String.length(marker))

      [
        indent <> marker <> escape_block_start(line(inlines))
        | Enum.flat_map(children, &list_lines(&1, child_indent))
      ]
    end)
  end

  ## Tables

  defp table_row(cells, columns) do
    cells = Enum.take(cells ++ List.duplicate([], columns), columns)
    "| " <> Enum.map_join(cells, " | ", &(&1 |> line() |> String.replace("|", "\\|"))) <> " |"
  end

  ## Inlines

  # Single-line contexts (headings, list items, cells) can't hold hard breaks.
  defp line(inlines), do: inlines |> inlines() |> String.replace("\\\n", " ")

  defp inlines(inlines), do: inlines |> Enum.map_join(&inline/1) |> String.trim()

  defp inline({:text, text}) do
    text
    |> escape()
    |> String.replace("\n", "\\\n")
  end

  defp inline({:bold, children}), do: wrap("**", children)
  defp inline({:italic, children}), do: wrap("*", children)

  defp inline({:code, code}) do
    ticks = fence(code, "`", 1)
    pad = if String.starts_with?(code, "`") or String.ends_with?(code, "`"), do: " ", else: ""
    ticks <> pad <> code <> pad <> ticks
  end

  defp inline({:link, url, children}) do
    label = Enum.map_join(children, &inline/1)

    if url =~ ~r/[\s()<>]/,
      do: label,
      else: "[#{label}](#{url})"
  end

  # Emphasis markers must hug non-space text: move edge spaces outside.
  defp wrap(marker, children) do
    text = Enum.map_join(children, &inline/1)

    case Regex.run(~r/\A(\s*)(.*?)(\s*)\z/s, text) do
      [_, lead, "", trail] -> lead <> trail
      [_, lead, core, trail] -> lead <> marker <> core <> marker <> trail
    end
  end

  # Escapes characters the inline parser would treat as markup.
  defp escape(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace(~r/([*`\[\]<])/, "\\\\\\1")
    |> String.replace(~r/(?<![\p{L}\p{N}])_|_(?![\p{L}\p{N}])/u, "\\\\_")
  end

  # Text that would otherwise start a heading, quote, list or rule.
  defp escape_block_start(text) do
    cond do
      match = Regex.run(~r/\A(\d{1,9})([.)])(\s)/, text) ->
        [whole, digits, delim, space] = match
        digits <> "\\" <> delim <> space <> String.slice(text, String.length(whole)..-1//1)

      text =~ ~r/\A(\#|>|[-+]\s|=+\s*\z|-{3,}\s*\z|~~~|\|)/ ->
        "\\" <> text

      true ->
        text
    end
  end

  # A run of `char` longer than any run of it inside `text`.
  defp fence(text, char, min_length) do
    longest =
      ~r/#{Regex.escape(char)}+/
      |> Regex.scan(text)
      |> Enum.map(fn [run] -> byte_size(run) end)
      |> Enum.max(fn -> 0 end)

    String.duplicate(char, max(longest + 1, min_length))
  end
end

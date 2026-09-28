defmodule Docgen.Ingest.Markdown do
  @moduledoc """
  Markdown → `Docgen.Document`.

  A small, dependency-free parser covering the subset the IR can express:
  ATX and setext headings, paragraphs (with hard line breaks), bullet and
  numbered lists (nested by indentation), GFM pipe tables, fenced code blocks,
  block quotes (→ `:note`) and inline formatting (see
  `Docgen.Ingest.Markdown.Inline`).

  A YAML-style front matter block with `title:` / `subtitle:` fills `meta`.

  Block quotes starting with `**Important:**` become `{:important, …}`, others
  `{:note, …}`. A paragraph starting with `Table:` directly before or after a
  table becomes that table's caption (`{:caption, :table, …}`, placed before
  the table).

  A paragraph that is only `![caption](docgen-image:N)` becomes an
  `{:image, ...}` block when image `N` is passed in the `:images` option (see
  `Docgen.Render.Markdown`).
  """

  alias Docgen.Document
  alias Docgen.Ingest.Lists
  alias Docgen.Ingest.Markdown.Inline

  @fence ~r/\A( {0,3})(`{3,}|~{3,})/
  @atx ~r/\A {0,3}(\#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+\#+)?[ \t]*\z/
  @thematic ~r/\A {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*\z/
  @quote ~r/\A {0,3}> ?(.*)\z/
  @list_item ~r/\A( *)([-*+]|\d{1,9}[.)])(?:[ \t]+(.*))?\z/
  @interrupting_item ~r/\A {0,3}(?:[-*+]|1[.)])[ \t]+\S/
  @setext ~r/\A {0,3}(=+|-+)[ \t]*\z/
  @table_delim ~r/\A *\|? *:?-+:? *(\| *:?-+:? *)*\|? *\z/
  @front_matter_keys ~w(title subtitle doc_type description)
  @image_ref ~r/\A!\[([^\]]*)\]\(docgen-image:([\w-]+)\)\z/

  @doc """
  Parses Markdown into a document.

  ## Options

    * `:meta` — metadata merged over any front matter
    * `:promote_title` — lift a sole leading `# Heading` into `meta.title`
      (default `true`)
    * `:images` — `%{id => image}` for `docgen-image:` references
  """
  @spec parse(String.t(), keyword()) :: Document.t()
  def parse(markdown, opts \\ []) do
    {front_matter, body} =
      markdown
      |> String.replace(~r/\r\n?/, "\n")
      |> String.replace("\t", "    ")
      |> front_matter()

    doc =
      %Document{
        blocks:
          body
          |> String.split("\n")
          |> blocks([])
          |> Enum.map(&resolve_image(&1, Keyword.get(opts, :images, %{})))
          |> table_captions()
      }
      |> Document.put_meta(front_matter)
      |> Document.put_meta(Keyword.get(opts, :meta, %{}))

    doc = if Keyword.get(opts, :promote_title, true), do: Document.promote_title(doc), else: doc
    Document.promote_numbered_titles(doc)
  end

  ## Blocks

  defp blocks([], acc), do: Enum.reverse(acc)

  defp blocks([line | rest] = lines, acc) do
    cond do
      blank?(line) ->
        blocks(rest, acc)

      match = Regex.run(@fence, line) ->
        [_, indent, fence] = match
        {code, rest} = fenced(rest, fence, byte_size(indent), [])
        blocks(rest, [{:code_block, code} | acc])

      match = Regex.run(@atx, line) ->
        level = match |> Enum.at(1) |> byte_size()
        text = Enum.at(match, 2) || ""
        blocks(rest, [{:heading, level, Inline.parse(text)} | acc])

      Regex.match?(@thematic, line) ->
        blocks(rest, acc)

      Regex.match?(@quote, line) ->
        {quoted, rest} = Enum.split_while(lines, &Regex.match?(@quote, &1))
        inner = Enum.map(quoted, &(Regex.run(@quote, &1) |> List.last()))
        blocks(rest, Enum.reverse(Enum.map(blocks(inner, []), &to_note/1), acc))

      table?(lines) ->
        {block, rest} = table(lines)
        blocks(rest, [block | acc])

      Regex.match?(@list_item, line) ->
        {items, rest} = list_items(lines, [])
        blocks(rest, Enum.reverse(Lists.build(items), acc))

      true ->
        case take_paragraph(rest, [line]) do
          {:heading, level, text_lines, rest} ->
            blocks(rest, [{:heading, level, text_lines |> join_lines() |> Inline.parse()} | acc])

          {:paragraph, text_lines, rest} ->
            text = join_lines(text_lines)

            block =
              case Regex.run(@image_ref, text) do
                [_, alt, id] -> {:image_ref, id, alt}
                nil -> {:paragraph, Inline.parse(text)}
              end

            blocks(rest, [block | acc])
        end
    end
  end

  defp resolve_image({:image_ref, id, alt}, images) do
    case Map.fetch(images, id) do
      {:ok, image} -> {:image, image, if(alt == "", do: nil, else: alt)}
      :error -> {:paragraph, if(alt == "", do: [], else: [{:text, alt}])}
    end
  end

  defp resolve_image(block, _images), do: block

  defp table_captions([{:paragraph, inlines} = para, {:table, _, _} = table | rest]) do
    case strip_caption_label(inlines) do
      {:ok, caption} -> [{:caption, :table, caption}, table | table_captions(rest)]
      :error -> [para | table_captions([table | rest])]
    end
  end

  defp table_captions([{:table, _, _} = table, {:paragraph, inlines} = para | rest]) do
    case strip_caption_label(inlines) do
      {:ok, caption} -> [{:caption, :table, caption}, table | table_captions(rest)]
      :error -> [table | table_captions([para | rest])]
    end
  end

  defp table_captions([block | rest]), do: [block | table_captions(rest)]
  defp table_captions([]), do: []

  defp strip_caption_label([{:text, text} | rest]) do
    case Regex.run(~r/\ATable:\s*(.*)\z/s, text) do
      [_, ""] when rest != [] -> {:ok, rest}
      [_, caption] -> {:ok, [{:text, caption} | rest] |> Enum.reject(&(&1 == {:text, ""}))}
      nil -> :error
    end
  end

  defp strip_caption_label(_inlines), do: :error

  defp to_note({:paragraph, inlines}) do
    if inlines
       |> Document.plain_text()
       |> String.trim_leading()
       |> String.match?(~r/\Aimportant\s*:/i),
       do: {:important, inlines},
       else: {:note, inlines}
  end

  defp to_note(block), do: block

  ## Fenced code

  defp fenced([], _fence, _indent, acc), do: {acc |> Enum.reverse() |> Enum.join("\n"), []}

  defp fenced([line | rest], fence, indent, acc) do
    if closing_fence?(line, fence) do
      {acc |> Enum.reverse() |> Enum.join("\n"), rest}
    else
      fenced(rest, fence, indent, [strip_indent(line, indent) | acc])
    end
  end

  defp closing_fence?(line, <<char, _::binary>> = fence) do
    trimmed = String.trim(line)

    leading_spaces(line) <= 3 and byte_size(trimmed) >= byte_size(fence) and
      trimmed == String.duplicate(<<char>>, byte_size(trimmed))
  end

  defp strip_indent(line, indent) do
    String.slice(line, min(leading_spaces(line), indent)..-1//1)
  end

  ## Paragraphs & setext headings

  defp take_paragraph([], acc), do: {:paragraph, Enum.reverse(acc), []}

  defp take_paragraph([line | rest] = lines, acc) do
    cond do
      match = Regex.run(@setext, line) ->
        level = if String.contains?(Enum.at(match, 1), "="), do: 1, else: 2
        {:heading, level, Enum.reverse(acc), rest}

      blank?(line) or interrupts?(line) ->
        {:paragraph, Enum.reverse(acc), lines}

      true ->
        take_paragraph(rest, [line | acc])
    end
  end

  defp interrupts?(line) do
    Regex.match?(@atx, line) or Regex.match?(@fence, line) or Regex.match?(@quote, line) or
      Regex.match?(@thematic, line) or Regex.match?(@interrupting_item, line)
  end

  # Joins paragraph lines with spaces; a line ending in two spaces or a
  # backslash becomes a hard line break ("\n").
  defp join_lines(lines) do
    lines
    |> Enum.map(&String.trim_leading/1)
    |> Enum.with_index(1)
    |> Enum.map_join(fn {line, i} ->
      last? = i == length(lines)

      cond do
        last? -> String.trim_trailing(line)
        String.ends_with?(line, "  ") -> String.trim_trailing(line) <> "\n"
        String.ends_with?(line, "\\") -> String.trim_trailing(line, "\\") <> "\n"
        true -> String.trim_trailing(line) <> " "
      end
    end)
  end

  ## Lists

  defp list_items([], acc), do: {finish_items(acc), []}

  defp list_items([line | rest] = lines, acc) do
    cond do
      match = Regex.run(@list_item, line) ->
        [_, indent, marker | text] = match
        kind = if marker in ~w(- * +), do: :bullet, else: :number
        list_items(rest, [{byte_size(indent), kind, [List.first(text) || ""]} | acc])

      blank?(line) ->
        case Enum.drop_while(rest, &blank?/1) do
          [next | _] = remaining ->
            if Regex.match?(@list_item, next) or leading_spaces(next) >= 2,
              do: list_items(remaining, acc),
              else: {finish_items(acc), lines}

          [] ->
            {finish_items(acc), []}
        end

      leading_spaces(line) < 2 and interrupts?(line) ->
        {finish_items(acc), lines}

      true ->
        [{indent, kind, text} | acc] = acc
        list_items(rest, [{indent, kind, [line | text]} | acc])
    end
  end

  defp finish_items(acc) do
    acc
    |> Enum.reverse()
    |> Enum.map(fn {indent, kind, text} ->
      {indent, kind, text |> Enum.reverse() |> join_lines() |> Inline.parse()}
    end)
  end

  ## Tables

  defp table?([header, delim | _]) do
    String.contains?(header, "|") and String.contains?(delim, "|") and
      Regex.match?(@table_delim, delim)
  end

  defp table?(_), do: false

  defp table([header, _delim | rest]) do
    {body, rest} = Enum.split_while(rest, &(not blank?(&1) and String.contains?(&1, "|")))
    header = split_row(header)
    width = length(header)

    rows =
      Enum.map(body, fn line ->
        cells = split_row(line)
        Enum.take(cells ++ List.duplicate([], width), width)
      end)

    {{:table, [header], rows}, rest}
  end

  defp split_row(line) do
    line
    |> String.trim()
    |> String.replace(~r/\A\|/, "")
    |> String.replace(~r/(?<!\\)\|\z/, "")
    |> String.split(~r/(?<!\\)\|/)
    # GFM unescapes `\|` in cells before inline parsing, even inside code spans.
    |> Enum.map(&(&1 |> String.trim() |> String.replace("\\|", "|") |> Inline.parse()))
  end

  ## Front matter

  defp front_matter("---\n" <> rest = markdown) do
    with [yaml, body] <- String.split(rest, ~r/^(?:---|\.\.\.)[ \t]*$/m, parts: 2),
         lines = yaml |> String.split("\n") |> Enum.reject(&blank?/1),
         true <- Enum.all?(lines, &Regex.match?(~r/\A[A-Za-z_][\w-]*[ \t]*:/, &1)) do
      meta =
        lines
        |> Enum.map(&String.split(&1, ":", parts: 2))
        |> Enum.map(fn [key, value] -> {String.trim(key), value} end)
        |> Enum.filter(fn {key, _} -> key in @front_matter_keys end)
        |> Map.new(fn {key, value} -> {String.to_atom(key), unquote_value(value)} end)

      {meta, body}
    else
      _ -> {%{}, markdown}
    end
  end

  defp front_matter(markdown), do: {%{}, markdown}

  defp unquote_value(value) do
    value = String.trim(value)

    case Regex.run(~r/\A(["'])(.*)\1\z/, value) do
      [_, _, inner] -> inner
      nil -> value
    end
  end

  ## Helpers

  defp blank?(line), do: String.trim(line) == ""

  defp leading_spaces(line), do: byte_size(line) - byte_size(String.trim_leading(line, " "))
end

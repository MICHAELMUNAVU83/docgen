defmodule Docgen.Ingest.Pdf do
  @moduledoc """
  `.pdf` → `Docgen.Document`, inferred from layout.

  PDFs carry no semantic structure, so this reconstructs it from
  `pdftohtml -xml` output (text runs with positions and font sizes):

    1. Text runs on the same baseline are merged into lines.
    2. Running headers/footers (text repeated in the page margins on most
       pages) and bare page numbers are dropped.
    3. The most common font size is the body size. Larger lines — and short,
       bold, unpunctuated lines at body size — are headings; distinct heading
       sizes map to levels, largest first.
    4. Body lines are joined into paragraphs until a vertical gap, an indent
       change after a sentence end, or a list marker. Hyphenated line breaks
       are rejoined.
    5. Lines starting with bullets (`•`, `–`, `▪`…) or `1.` / `1)` become
       list items, nested by their indentation.

  Results are marked low-confidence via `warnings`.
  """

  alias Docgen.Document
  alias Docgen.Ingest.{Lists, Xml}

  @warning "Converted from PDF — headings, paragraphs and lists were inferred from the layout. Review them before downloading."

  @bullet ~r/\A\s*(?:[•◦▪▫●○■□‣⁃∙·*\x{F0B7}\x{F0A7}\x{F076}\x{F0D8}-]|[–—])\s+(\S.*)\z/u
  @numbered ~r/\A\s*\d{1,3}[.)]\s+(\S.*)\z/u
  @page_number ~r/\A\s*(?:page\s*)?\d+(?:\s*(?:of|\/)\s*\d+)?\s*\z/i
  @margin 0.1
  @timeout :timer.seconds(60)

  @spec parse(binary(), keyword()) :: {:ok, Document.t()} | {:error, term()}
  def parse(pdf, opts \\ []) when is_binary(pdf) do
    with {:ok, xml} <- pdftohtml(pdf, opts),
         {:ok, root} <- Xml.parse(xml, allow_doctype: true) do
      case root |> lines() |> strip_margins() do
        [] ->
          {:error, :no_text}

        lines ->
          doc =
            %Document{blocks: blocks(lines), warnings: [@warning]}
            |> Document.put_meta(Keyword.get(opts, :meta, %{}))
            |> Document.promote_title()

          {:ok, doc}
      end
    end
  end

  ## pdftohtml

  defp pdftohtml(pdf, opts) do
    case Keyword.get_lazy(opts, :pdftohtml, fn -> Docgen.SystemCheck.find(:pdftohtml) end) do
      nil ->
        {:error, :pdftohtml_not_found}

      exe ->
        dir = Path.join(System.tmp_dir!(), "docgen-pdfin-#{System.unique_integer([:positive])}")
        input = Path.join(dir, "input.pdf")
        File.mkdir_p!(dir)
        File.write!(input, pdf)

        try do
          case Docgen.Cmd.run(exe, ~w(-xml -i -q -stdout -enc UTF-8) ++ [input], @timeout) do
            {:ok, xml} -> {:ok, sanitize(xml)}
            {:error, :timeout} -> {:error, :timeout}
            {:error, {:exit_status, _, _}} -> {:error, :unreadable_pdf}
          end
        after
          File.rm_rf(dir)
        end
    end
  end

  # pdftohtml can emit control characters XML 1.0 forbids.
  defp sanitize(xml) do
    xml
    |> String.replace_invalid()
    |> String.replace(~r/[\x{0}-\x{8}\x{B}\x{C}\x{E}-\x{1F}]/u, "")
  end

  ## Lines

  defp lines(root) do
    pages = Xml.children(root, nil, "page")

    fonts =
      for page <- pages, spec <- Xml.children(page, nil, "fontspec"), into: %{} do
        {Xml.attr(spec, "id"), num(Xml.attr(spec, "size"))}
      end

    for page <- pages,
        number = int(Xml.attr(page, "number")),
        height = num(Xml.attr(page, "height")),
        line <- page_lines(page, fonts),
        do: Map.merge(line, %{page: number, page_height: height})
  end

  defp page_lines(page, fonts) do
    page
    |> Xml.children(nil, "text")
    |> Enum.map(fn text ->
      %{
        top: num(Xml.attr(text, "top")),
        left: num(Xml.attr(text, "left")),
        width: num(Xml.attr(text, "width")),
        height: num(Xml.attr(text, "height")),
        size: Map.get(fonts, Xml.attr(text, "font"), 0),
        segments: segments(text, %{bold: false, italic: false, link: nil})
      }
    end)
    |> Enum.reject(fn run -> run.segments |> segment_text() |> String.trim() == "" end)
    |> Enum.sort_by(&{&1.top, &1.left})
    |> Enum.chunk_while(
      [],
      fn run, acc ->
        case acc do
          [prev | _] when abs(run.top - prev.top) > max(prev.height, run.height) * 0.4 ->
            {:cont, Enum.reverse(acc), [run]}

          _ ->
            {:cont, [run | acc]}
        end
      end,
      fn acc -> {:cont, Enum.reverse(acc), []} end
    )
    |> Enum.reject(&(&1 == []))
    |> Enum.map(&merge_runs/1)
  end

  defp merge_runs(runs) do
    runs = Enum.sort_by(runs, & &1.left)
    first = hd(runs)

    segments =
      runs
      |> Enum.chunk_every(2, 1)
      |> Enum.flat_map(fn
        [a, b] ->
          gap = b.left - (a.left + a.width)
          if gap > a.size * 0.15, do: a.segments ++ [{plain(), " "}], else: a.segments

        [last] ->
          last.segments
      end)

    text = segment_text(segments)

    %{
      top: first.top,
      left: first.left,
      height: runs |> Enum.map(& &1.height) |> Enum.max(),
      size: dominant_size(runs),
      segments: segments,
      text: text,
      bold?: bold_text?(segments)
    }
  end

  defp dominant_size(runs) do
    runs
    |> Enum.group_by(& &1.size, &String.length(segment_text(&1.segments)))
    |> Enum.max_by(fn {_size, lengths} -> Enum.sum(lengths) end)
    |> elem(0)
  end

  defp bold_text?(segments) do
    visible = Enum.reject(segments, fn {_, text} -> String.trim(text) == "" end)
    visible != [] and Enum.all?(visible, fn {format, _} -> format.bold end)
  end

  ## Inline segments from <b>, <i>, <a>

  defp segments({_, _, _, children}, format) do
    Enum.flat_map(children, fn
      text when is_binary(text) -> [{format, text}]
      {nil, "b", _, _} = el -> segments(el, %{format | bold: true})
      {nil, "i", _, _} = el -> segments(el, %{format | italic: true})
      {nil, "a", _, _} = el -> segments(el, %{format | link: safe_link(Xml.attr(el, "href"))})
      el -> segments(el, format)
    end)
  end

  defp safe_link("http" <> _ = url), do: url
  defp safe_link("mailto:" <> _ = url), do: url
  defp safe_link(_), do: nil

  defp plain, do: %{bold: false, italic: false, link: nil}

  defp segment_text(segments), do: Enum.map_join(segments, &elem(&1, 1))

  ## Running headers, footers and page numbers

  defp strip_margins(lines) do
    page_count = lines |> Enum.map(& &1.page) |> Enum.uniq() |> length()

    repeated =
      lines
      |> Enum.filter(&in_margin?/1)
      |> Enum.group_by(&normalize/1, & &1.page)
      |> Enum.filter(fn {_text, pages} ->
        page_count > 1 and length(Enum.uniq(pages)) >= max(2, page_count / 2)
      end)
      |> MapSet.new(&elem(&1, 0))

    Enum.reject(lines, fn line ->
      in_margin?(line) and
        (MapSet.member?(repeated, normalize(line)) or line.text =~ @page_number)
    end)
  end

  defp in_margin?(line) do
    line.top < line.page_height * @margin or
      line.top + line.height > line.page_height * (1 - @margin)
  end

  defp normalize(line),
    do: line.text |> String.replace(~r/\d+/, "#") |> String.trim() |> String.downcase()

  ## Lines → blocks

  defp blocks(lines) do
    body_size = body_size(lines)
    heading_levels = heading_levels(lines, body_size)
    list_indents = list_indents(lines)

    lines
    |> Enum.map(&classify(&1, body_size, heading_levels))
    |> assemble(list_indents)
  end

  defp body_size(lines) do
    lines
    |> Enum.group_by(&round(&1.size), &String.length(&1.text))
    |> Enum.max_by(fn {_size, lengths} -> Enum.sum(lengths) end)
    |> elem(0)
  end

  defp heading?(line, body_size) do
    words = line.text |> String.split() |> length()

    cond do
      list_marker(line.text) != nil -> false
      round(line.size) >= body_size * 1.15 -> words <= 25
      line.bold? -> words <= 15 and not (line.text =~ ~r/[.,;:]\s*\z/)
      true -> false
    end
  end

  # Larger sizes rank higher; bold body-size headings come last.
  defp heading_levels(lines, body_size) do
    lines
    |> Enum.filter(&heading?(&1, body_size))
    |> Enum.map(&max(round(&1.size), body_size))
    |> Enum.uniq()
    |> Enum.sort(:desc)
    |> Enum.with_index(1)
    |> Map.new(fn {size, level} -> {size, min(level, 6)} end)
  end

  # Distinct list-marker indents, so nesting follows indentation.
  defp list_indents(lines) do
    lines
    |> Enum.filter(&(list_marker(&1.text) != nil))
    |> Enum.map(& &1.left)
    |> Enum.sort()
    |> Enum.reduce([], fn left, acc ->
      case acc do
        [prev | _] when left - prev < 4 -> acc
        _ -> [left | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp classify(line, body_size, levels) do
    cond do
      heading?(line, body_size) ->
        Map.put(line, :kind, {:heading, Map.fetch!(levels, max(round(line.size), body_size))})

      marker = list_marker(line.text) ->
        {kind, _text} = marker
        Map.put(line, :kind, {:item, kind})

      true ->
        Map.put(line, :kind, :body)
    end
  end

  defp list_marker(text) do
    cond do
      match = Regex.run(@bullet, text) -> {:bullet, List.last(match)}
      match = Regex.run(@numbered, text) -> {:number, List.last(match)}
      true -> nil
    end
  end

  # Groups classified lines into headings, paragraphs and list items, then
  # builds nested lists from consecutive items.
  defp assemble(lines, list_indents) do
    lines
    |> Enum.reduce([], fn line, acc -> add_line(line, acc) end)
    |> Enum.reverse()
    |> Enum.map(&finish_group/1)
    |> group_lists(list_indents)
  end

  defp add_line(
         %{kind: {:heading, level}} = line,
         [%{kind: {:heading, level}} = prev | rest] = acc
       ) do
    # Multi-line headings: same level, directly below.
    if continues?(prev, line), do: [append(prev, line) | rest], else: [start(line) | acc]
  end

  defp add_line(%{kind: :body} = line, [%{kind: kind} = prev | rest] = acc)
       when kind == :body or elem(kind, 0) == :item do
    if continues?(prev, line) and not new_paragraph?(prev, line),
      do: [append(prev, line) | rest],
      else: [start(line) | acc]
  end

  defp add_line(line, acc), do: [start(line) | acc]

  defp start(line), do: Map.merge(line, %{lines: [line], last: line})

  defp append(group, line), do: %{group | lines: group.lines ++ [line], last: line}

  # The next line sits directly below (or starts the next page).
  defp continues?(group, line) do
    last = group.last

    cond do
      line.page == last.page -> line.top - last.top <= last.height * 1.9
      line.page == last.page + 1 -> not (last.text =~ ~r/[.!?:]\s*\z/)
      true -> false
    end
  end

  # A first-line indent after a sentence end starts a new paragraph; list
  # continuation lines must be indented at least as far as the item text.
  defp new_paragraph?(%{kind: {:item, _}} = group, line), do: line.left < group.left - 2

  defp new_paragraph?(group, line) do
    group.last.text =~ ~r/[.!?:]\s*\z/ and line.left > group.last.left + line.size * 1.5
  end

  defp finish_group(%{kind: {:heading, level}} = group),
    do: {:heading, level, group_inlines(group, &strip_bold/1)}

  defp finish_group(%{kind: :body} = group), do: {:paragraph, group_inlines(group, & &1)}

  defp finish_group(%{kind: {:item, kind}} = group) do
    [first | rest] = group.lines
    {_, text} = list_marker(first.text)

    first = %{
      first
      | segments: drop_prefix(first.segments, String.length(first.text) - String.length(text))
    }

    {:item, kind, group.left, group_inlines(%{group | lines: [first | rest]}, & &1)}
  end

  defp group_lists(blocks, indents) do
    blocks
    |> Enum.chunk_by(&match?({:item, _, _, _}, &1))
    |> Enum.flat_map(fn
      [{:item, _, _, _} | _] = items ->
        Lists.build(
          for {:item, kind, left, inlines} <- items,
              do: {indent_level(indents, left), kind, inlines}
        )

      blocks ->
        blocks
    end)
  end

  defp indent_level(indents, left), do: Enum.count(indents, &(&1 < left - 2))

  ## Inlines

  # Joins line segments, rejoining hyphenated words.
  defp group_inlines(group, transform) do
    group.lines
    |> Enum.map(& &1.segments)
    |> Enum.reduce(fn next, acc ->
      prev_text = segment_text(acc)
      next_text = segment_text(next)

      if prev_text =~ ~r/\p{L}-\s*\z/u and next_text =~ ~r/\A\s*\p{Ll}/u do
        trim_trailing_hyphen(acc) ++ next
      else
        acc ++ [{plain(), " "}] ++ next
      end
    end)
    |> Enum.map(fn {format, text} -> {format, String.replace(text, ~r/\s+/u, " ")} end)
    |> transform.()
    |> to_inlines()
  end

  defp strip_bold(segments),
    do: Enum.map(segments, fn {format, text} -> {%{format | bold: false}, text} end)

  defp trim_trailing_hyphen(segments) do
    {format, text} = List.last(segments)
    List.replace_at(segments, -1, {format, String.replace(text, ~r/-\s*\z/, "")})
  end

  defp drop_prefix(segments, 0), do: segments
  defp drop_prefix([], _n), do: []

  defp drop_prefix([{format, text} | rest], n) do
    length = String.length(text)

    if length <= n,
      do: drop_prefix(rest, n - length),
      else: [{format, String.slice(text, n..-1//1)} | rest]
  end

  defp to_inlines(segments) do
    segments
    # Edge whitespace belongs outside formatting ("<b>loud </b>" → "loud" + " ").
    |> Enum.flat_map(fn {format, text} ->
      case Regex.run(~r/\A(\s*)(.*?)(\s*)\z/su, text) do
        [_, lead, "", trail] -> [{plain(), lead <> trail}]
        [_, lead, core, trail] -> [{plain(), lead}, {format, core}, {plain(), trail}]
      end
    end)
    |> Enum.reject(fn {_format, text} -> text == "" end)
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.map(fn [{format, _} | _] = chunk -> wrap(format, [{:text, segment_text(chunk)}]) end)
    |> trim_edges()
  end

  defp wrap(format, inner) do
    inner = if format.italic, do: [{:italic, inner}], else: inner
    inner = if format.bold, do: [{:bold, inner}], else: inner
    if format.link, do: [{:link, format.link, inner}], else: inner
  end

  defp trim_edges(nodes) do
    nodes = List.flatten(nodes)

    nodes
    |> update_edge(0, &String.trim_leading/1)
    |> update_edge(-1, &String.trim_trailing/1)
    |> Enum.reject(&(&1 == {:text, ""}))
  end

  defp update_edge([], _index, _fun), do: []

  defp update_edge(nodes, index, fun) do
    case Enum.at(nodes, index) do
      {:text, text} -> List.replace_at(nodes, index, {:text, fun.(text)})
      _ -> nodes
    end
  end

  ## Helpers

  defp num(nil), do: 0

  defp num(value) do
    case Float.parse(value) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp int(value), do: value |> num() |> trunc()
end

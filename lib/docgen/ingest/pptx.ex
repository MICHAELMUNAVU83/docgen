defmodule Docgen.Ingest.Pptx do
  @moduledoc """
  `.pptx` → `Docgen.Document`.

  Reads the slides in presentation order and keeps their content, so an
  existing deck can be re-laid on the GS1 PowerPoint template:

    * The first slide, when it only holds a title and a few lines, is the
      title slide: it fills `meta` (`:title`, `:subtitle`, `:presenter`).
    * Every other slide becomes a heading (its title, or "Slide N") followed
      by its content. When the deck has two or more title-only slides
      (section dividers), those become top-level headings and the slides
      between them subheadings, which `Docgen.Render.Pptx.Deck` turns back
      into dividers; an "Agenda" slide before the first divider is dropped,
      as the deck planner writes its own.
    * Text keeps bold, italic and hyperlinks. Paragraphs are bullets inside
      content placeholders and plain text in text boxes, unless the
      paragraph says otherwise (`a:buNone`, `a:buChar`, `a:buAutoNum`);
      `lvl` sets nesting.
    * Tables keep their header row; pictures become `{:image, ...}` blocks.

  Slide numbers, dates, footers and speaker notes are skipped. Charts and
  SmartArt can't be represented and are reported in `warnings`.
  """

  alias Docgen.{Document, Image}
  alias Docgen.Ingest.{Lists, Xml}

  @max_total_size 200_000_000
  @max_part_size 50_000_000

  @title_types ~w(title ctrTitle)
  @skipped_types ~w(sldNum dt ftr hdr sldImg)
  @agenda_titles ~w(agenda contents)

  @spec parse(binary(), keyword()) :: {:ok, Document.t()} | {:error, term()}
  def parse(pptx, opts \\ []) when is_binary(pptx) do
    with {:ok, parts} <- unzip(pptx),
         {:ok, main} <- main_part(parts),
         {:ok, presentation} <- parse_part(parts, main),
         [_ | _] = slide_parts <- slide_parts(parts, main, presentation) do
      slides = Enum.map(slide_parts, &slide(parts, &1))
      {meta, slides} = title_slide(slides)

      doc =
        %Document{blocks: blocks(slides), warnings: warnings(slides)}
        |> Document.put_meta(meta)
        |> Document.put_meta(Keyword.get(opts, :meta, %{}))

      {:ok, doc}
    else
      [] -> {:error, :invalid_pptx}
      {:error, :too_large} -> {:error, :too_large}
      {:error, _} -> {:error, :invalid_pptx}
    end
  end

  ## Package

  defp unzip(pptx) do
    with {:ok, [_comment | entries]} <- :zip.list_dir(pptx),
         total =
           Enum.reduce(entries, 0, fn {:zip_file, _, info, _, _, _}, sum ->
             sum + elem(info, 1)
           end),
         :ok <- if(total <= @max_total_size, do: :ok, else: {:error, :too_large}),
         {:ok, files} <- :zip.unzip(pptx, [:memory]) do
      {:ok, Map.new(files, fn {name, data} -> {to_string(name), data} end)}
    else
      {:error, :too_large} -> {:error, :too_large}
      _ -> {:error, :invalid_pptx}
    end
  end

  defp main_part(parts) do
    with {:ok, root} <- parse_part(parts, "_rels/.rels"),
         %{} = rel <- Enum.find(rel_entries(root), &String.ends_with?(&1.type, "/officeDocument")),
         part = resolve("", rel.target),
         true <- Map.has_key?(parts, part) do
      {:ok, part}
    else
      _ ->
        if Map.has_key?(parts, "ppt/presentation.xml"),
          do: {:ok, "ppt/presentation.xml"},
          else: {:error, :invalid_pptx}
    end
  end

  defp parse_part(parts, name) do
    case Map.fetch(parts, name) do
      {:ok, data} when byte_size(data) <= @max_part_size -> Xml.parse(data)
      {:ok, _} -> {:error, :too_large}
      :error -> {:error, {:missing_part, name}}
    end
  end

  defp relationships(parts, part) do
    rels_name = Path.join([Path.dirname(part), "_rels", Path.basename(part) <> ".rels"])

    case parse_part(parts, rels_name) do
      {:ok, root} -> Map.new(rel_entries(root), &{&1.id, &1})
      {:error, _} -> %{}
    end
  end

  defp rel_entries(root) do
    for rel <- Xml.children(root, :rel, "Relationship") do
      %{
        id: Xml.attr(rel, "Id"),
        type: Xml.attr(rel, "Type") || "",
        target: Xml.attr(rel, "Target") || "",
        external?: Xml.attr(rel, "TargetMode") == "External"
      }
    end
  end

  defp resolve(_dir, "/" <> absolute), do: absolute

  defp resolve(dir, target),
    do: ["/", dir, target] |> Path.join() |> Path.expand("/") |> String.trim_leading("/")

  # Slide parts in the order of the presentation's slide list.
  defp slide_parts(parts, main, presentation) do
    rels = relationships(parts, main)
    dir = Path.dirname(main)

    for id <- Xml.children(Xml.child(presentation, :p, "sldIdLst") || {nil, "", %{}, []}),
        rel = rels[Xml.attr(id, "r:id")],
        rel != nil and not rel.external?,
        part = resolve(dir, rel.target),
        Map.has_key?(parts, part),
        do: part
  end

  ## Slides

  # A slide is `%{title: String.t() | nil, blocks: [block], unsupported?: boolean}`.
  defp slide(parts, part) do
    ctx = %{parts: parts, dir: Path.dirname(part), rels: relationships(parts, part)}

    shapes =
      case parse_part(parts, part) do
        {:ok, root} -> root |> Xml.path([{:p, "cSld"}, {:p, "spTree"}]) |> shapes(ctx)
        {:error, _} -> []
      end

    title =
      Enum.find_value(shapes, fn
        {:title, text} when text != "" -> text
        _ -> nil
      end)

    %{
      title: title,
      blocks:
        Enum.flat_map(shapes, fn
          {:blocks, blocks} -> blocks
          _ -> []
        end),
      unsupported?: :unsupported in shapes
    }
  end

  defp shapes(nil, _ctx), do: []
  defp shapes(tree, ctx), do: tree |> Xml.children() |> Enum.flat_map(&shape(&1, ctx))

  defp shape({:p, "sp", _, _} = sp, ctx) do
    type = sp |> Xml.path([{:p, "nvSpPr"}, {:p, "nvPr"}, {:p, "ph"}]) |> placeholder_type()
    body = Xml.child(sp, :p, "txBody")

    cond do
      is_nil(body) or type in @skipped_types ->
        []

      type in @title_types ->
        [{:title, body |> paragraphs(ctx, false) |> title_text()}]

      true ->
        [{:blocks, body |> paragraphs(ctx, type != nil) |> text_blocks()}]
    end
  end

  defp shape({:p, "pic", _, _} = pic, ctx) do
    with id when is_binary(id) <-
           pic |> Xml.path([{:p, "blipFill"}, {:a, "blip"}]) |> Xml.attr("r:embed"),
         %{external?: false} = rel <- ctx.rels[id],
         part = resolve(ctx.dir, rel.target),
         {:ok, data} <- Map.fetch(ctx.parts, part),
         %{} = image <- Image.new(part, data, picture_size(pic)) do
      [{:blocks, [{:image, image, picture_caption(pic)}]}]
    else
      _ -> []
    end
  end

  defp shape({:p, "graphicFrame", _, _} = frame, ctx) do
    case Xml.descendants(frame, :a, "tbl") do
      [table | _] -> [{:blocks, table(table, ctx)}]
      [] -> [:unsupported]
    end
  end

  defp shape({:p, "grpSp", _, _} = group, ctx), do: shapes(group, ctx)

  # Office wraps newer content in mc:AlternateContent with a fallback.
  defp shape({:mc, "AlternateContent", _, _} = alternate, ctx) do
    case Xml.child(alternate, :mc, "Fallback") || Xml.child(alternate, :mc, "Choice") do
      nil -> []
      branch -> shapes(branch, ctx)
    end
  end

  defp shape(_other, _ctx), do: []

  # `nil` for shapes that aren't placeholders (text boxes); a placeholder
  # without a type is a content placeholder.
  defp placeholder_type(nil), do: nil
  defp placeholder_type(ph), do: Xml.attr(ph, "type") || "body"

  defp picture_size(pic) do
    ext = Xml.path(pic, [{:p, "spPr"}, {:a, "xfrm"}, {:a, "ext"}])

    with {w, ""} <- Integer.parse(Xml.attr(ext, "cx") || ""),
         {h, ""} <- Integer.parse(Xml.attr(ext, "cy") || "") do
      [width: w, height: h]
    else
      _ -> []
    end
  end

  # Alt text, unless it is PowerPoint's generated description or a file name.
  defp picture_caption(pic) do
    descr = pic |> Xml.path([{:p, "nvPicPr"}, {:p, "cNvPr"}]) |> Xml.attr("descr")

    case descr && String.trim(descr) do
      text when text in [nil, ""] ->
        nil

      text ->
        if text =~ ~r/\.\w{3,4}\z|\n|description automatically generated/i, do: nil, else: text
    end
  end

  ## Text

  # Paragraphs of a text body as `{kind, level, inlines}`, `kind` being
  # `:text`, `:bullet` or `:number`. `bullets?` is the default for
  # paragraphs that don't say.
  defp paragraphs(body, ctx, bullets?) do
    for p <- Xml.children(body, :a, "p"),
        inlines = p |> Xml.children() |> Enum.flat_map(&run(&1, ctx)) |> merge_text(),
        String.trim(Document.plain_text(inlines)) != "" do
      props = Xml.child(p, :a, "pPr")

      kind =
        cond do
          Xml.child(props, :a, "buNone") -> :text
          Xml.child(props, :a, "buAutoNum") -> :number
          Xml.child(props, :a, "buChar") -> :bullet
          bullets? -> :bullet
          true -> :text
        end

      level =
        case Integer.parse(Xml.attr(props, "lvl") || "0") do
          {level, _} when level > 0 -> level
          _ -> 0
        end

      {kind, level, inlines}
    end
  end

  defp run({:a, "r", _, _} = run, ctx) do
    props = Xml.child(run, :a, "rPr")
    text = run |> Xml.child(:a, "t") |> text()

    if text == "" do
      []
    else
      [{:text, text}]
      |> wrap(Xml.attr(props, "i") in ["1", "true"], :italic)
      |> wrap(Xml.attr(props, "b") in ["1", "true"], :bold)
      |> link(props, ctx)
    end
  end

  defp run({:a, "br", _, _}, _ctx), do: [{:text, "\n"}]

  defp run({:a, "fld", _, _} = field, _ctx) do
    case field |> Xml.child(:a, "t") |> text() do
      "" -> []
      text -> [{:text, text}]
    end
  end

  defp run(_other, _ctx), do: []

  defp text(nil), do: ""
  defp text(element), do: Xml.text(element)

  defp wrap(inlines, true, format), do: [{format, inlines}]
  defp wrap(inlines, false, _format), do: inlines

  defp link(inlines, props, ctx) do
    with id when is_binary(id) <- props |> Xml.child(:a, "hlinkClick") |> Xml.attr("r:id"),
         %{external?: true, target: url} <- ctx.rels[id],
         true <- url =~ ~r/\A(https?:|mailto:)/i do
      [{:link, url, inlines}]
    else
      _ -> inlines
    end
  end

  # PowerPoint splits text into runs freely; adjacent plain runs are joined.
  defp merge_text([{:text, a}, {:text, b} | rest]), do: merge_text([{:text, a <> b} | rest])
  defp merge_text([inline | rest]), do: [inline | merge_text(rest)]
  defp merge_text([]), do: []

  defp title_text(paragraphs) do
    paragraphs
    |> Enum.map_join(" ", fn {_kind, _level, inlines} -> Document.plain_text(inlines) end)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Runs of list paragraphs become nested lists, the rest paragraphs.
  defp text_blocks(paragraphs) do
    paragraphs
    |> Enum.chunk_by(fn {kind, _level, _inlines} -> kind == :text end)
    |> Enum.flat_map(fn
      [{:text, _, _} | _] = texts ->
        Enum.map(texts, fn {_, _, inlines} -> {:paragraph, inlines} end)

      items ->
        items
        |> Enum.map(fn {kind, level, inlines} -> {level, kind, inlines} end)
        |> Lists.build()
    end)
  end

  ## Tables

  defp table(table, ctx) do
    rows =
      for row <- Xml.children(table, :a, "tr") do
        for cell <- Xml.children(row, :a, "tc") do
          case Xml.child(cell, :a, "txBody") do
            nil -> []
            body -> body |> paragraphs(ctx, false) |> cell_inlines()
          end
        end
      end

    header? = Xml.attr(Xml.child(table, :a, "tblPr"), "firstRow") in ["1", "true"]

    case rows do
      [] -> []
      [header | rest] when header? and rest != [] -> [{:table, [header], rest}]
      rows -> [{:table, [], rows}]
    end
  end

  defp cell_inlines(paragraphs) do
    paragraphs
    |> Enum.map(fn {_kind, _level, inlines} -> inlines end)
    |> Enum.intersperse([{:text, "\n"}])
    |> List.flatten()
  end

  ## Document

  # A first slide with a title and at most three plain lines is the title
  # slide; its lines are the subtitle and the presenter.
  defp title_slide([%{title: title, blocks: blocks} = first | rest]) when is_binary(title) do
    lines = for {:paragraph, inlines} <- blocks, do: String.trim(Document.plain_text(inlines))

    lines =
      lines ++
        for {:bullet_list, 1, items} <- blocks,
            {inlines, []} <- items,
            do: String.trim(Document.plain_text(inlines))

    simple? =
      length(lines) <= 3 and
        Enum.all?(blocks, fn
          {:paragraph, _} -> true
          {:bullet_list, 1, items} -> Enum.all?(items, &match?({_, []}, &1))
          _ -> false
        end)

    if simple? and not first.unsupported? do
      {%{title: title, subtitle: Enum.at(lines, 0), presenter: Enum.at(lines, 1)}, rest}
    else
      {%{}, [first | rest]}
    end
  end

  defp title_slide(slides), do: {%{}, slides}

  defp blocks(slides) do
    slides = Enum.with_index(slides, 2)
    divider? = fn {slide, _number} -> slide.title != nil and slide.blocks == [] end

    if Enum.count(slides, divider?) >= 2 do
      {before, sections} = Enum.split_while(slides, &(not divider?.(&1)))
      before = Enum.reject(before, fn {slide, _} -> agenda?(slide) end)

      Enum.flat_map(before, &slide_blocks(&1, 1)) ++
        Enum.flat_map(sections, &slide_blocks(&1, if(divider?.(&1), do: 1, else: 2)))
    else
      Enum.flat_map(slides, &slide_blocks(&1, 1))
    end
  end

  defp agenda?(%{title: title}),
    do: is_binary(title) and String.downcase(title) in @agenda_titles

  defp slide_blocks({%{title: nil, blocks: []}, _number}, _level), do: []

  defp slide_blocks({slide, number}, level),
    do: [{:heading, level, [{:text, slide.title || "Slide #{number}"}]} | slide.blocks]

  defp warnings(slides) do
    case for({%{unsupported?: true}, number} <- Enum.with_index(slides, 1), do: number) do
      [] ->
        []

      numbers ->
        [
          "Charts and diagrams can't be imported and were left out (slide " <>
            Enum.join(numbers, ", ") <> ")."
        ]
    end
  end
end

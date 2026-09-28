defmodule Docgen.Ingest.Docx do
  @moduledoc """
  `.docx` → `Docgen.Document`.

  Reads the main document part plus its styles, numbering, relationships and
  media:

    * Headings come from paragraph styles — by name (`heading 1`…), outline
      level, or inherited through `basedOn` — so custom heading styles work.
      `Title` / `Subtitle` fill `meta`.
    * Lists come from `w:numPr` (direct or via the style) resolved against
      `numbering.xml` to tell bullets from numbers; `ilvl` sets nesting.
    * Runs keep bold, italic and monospace (→ code); hyperlinks resolve
      through relationships. Tracked deletions are dropped, insertions kept.
    * Tables keep header rows (`tblHeader`, or the first row when the table
      look marks it); merged cells become empty cells.
    * Embedded images become `{:image, ...}` blocks with their displayed size;
      a following caption-styled paragraph becomes the caption.

  Documents built on GS1 Advanced (a paragraph styled `GS1_TOC_Heading`)
  keep their content only: the cover, summary tables, disclaimer and
  contents list before and around the TOC are skipped, and the document
  name, type and description come from the `GS1 DocName` / `GS1 DocType` /
  `GS1 Description` custom properties.

  Underline has no IR equivalent and is dropped.
  """

  alias Docgen.{Document, Image}
  alias Docgen.Ingest.{Lists, Xml}

  @max_total_size 200_000_000
  @max_part_size 50_000_000

  @off_values ["0", "false", "off", "none"]
  @mono_font ~r/courier|consolas|menlo|monaco|mono|source code|lucida console/i

  @spec parse(binary(), keyword()) :: {:ok, Document.t()} | {:error, term()}
  def parse(docx, opts \\ []) when is_binary(docx) do
    with {:ok, parts} <- unzip(docx),
         {:ok, main} <- main_part(parts),
         {:ok, {_, _, _, _} = document} <- parse_part(parts, main),
         body when not is_nil(body) <- Xml.child(document, :w, "body") do
      rels = relationships(parts, main)

      ctx = %{
        parts: parts,
        dir: Path.dirname(main),
        rels: rels,
        styles: styles(parts, rels)
      }

      ctx = Map.put(ctx, :numbering, numbering(parts, rels, ctx.styles))

      {meta, blocks} = body |> body_items(ctx) |> skip_front_matter() |> assemble()

      doc =
        %Document{blocks: blocks, warnings: warnings(body)}
        |> Document.put_meta(meta)
        |> Document.put_meta(custom_properties(parts))
        |> Document.put_meta(Keyword.get(opts, :meta, %{}))

      {:ok, doc}
    else
      nil -> {:error, :invalid_docx}
      {:error, _} = error -> error
    end
  end

  ## Package

  defp unzip(docx) do
    with {:ok, [_comment | entries]} <- :zip.list_dir(docx),
         total =
           Enum.reduce(entries, 0, fn {:zip_file, _, info, _, _, _}, sum ->
             sum + elem(info, 1)
           end),
         :ok <- if(total <= @max_total_size, do: :ok, else: {:error, :too_large}),
         {:ok, files} <- :zip.unzip(docx, [:memory]) do
      {:ok, Map.new(files, fn {name, data} -> {to_string(name), data} end)}
    else
      {:error, :too_large} -> {:error, :too_large}
      _ -> {:error, :invalid_docx}
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
        if Map.has_key?(parts, "word/document.xml"),
          do: {:ok, "word/document.xml"},
          else: {:error, :invalid_docx}
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

  defp related_part(ctx_parts, rels, dir, suffix) do
    with %{} = rel <- rels |> Map.values() |> Enum.find(&String.ends_with?(&1.type, suffix)),
         {:ok, root} <- parse_part(ctx_parts, resolve(dir, rel.target)) do
      root
    else
      _ -> nil
    end
  end

  ## Styles

  defp styles(parts, rels) do
    case related_part(parts, rels, "word", "/styles") do
      nil ->
        %{styles: %{}, default: nil}

      root ->
        styles =
          for style <- Xml.children(root, :w, "style"),
              id = Xml.attr(style, "styleId"),
              into: %{} do
            ppr = Xml.child(style, :w, "pPr")
            rpr = Xml.child(style, :w, "rPr")

            {id,
             %{
               type: Xml.attr(style, "type"),
               default?: Xml.attr(style, "default") in ["1", "true"],
               name: style |> Xml.child(:w, "name") |> Xml.attr("val") |> Kernel.||(id),
               based_on: style |> Xml.child(:w, "basedOn") |> Xml.attr("val"),
               outline: ppr |> Xml.child(:w, "outlineLvl") |> Xml.attr("val") |> int(),
               num: num_pr(ppr),
               bold?: on?(Xml.child(rpr, :w, "b")),
               italic?: on?(Xml.child(rpr, :w, "i")),
               code?: mono?(rpr)
             }}
          end

        default =
          Enum.find_value(styles, fn {id, s} -> (s.type == "paragraph" and s.default?) && id end)

        %{styles: styles, default: default}
    end
  end

  # Walks a style and its basedOn ancestors, returning the first non-nil `fun` result.
  defp inherited(styles, id, fun, depth \\ 0)
  defp inherited(_styles, nil, _fun, _depth), do: nil
  defp inherited(_styles, _id, _fun, depth) when depth > 20, do: nil

  defp inherited(styles, id, fun, depth) do
    case Map.get(styles.styles, id) do
      nil -> nil
      style -> fun.(style) || inherited(styles, style.based_on, fun, depth + 1)
    end
  end

  defp style_role(styles, id) do
    inherited(styles, id, fn style ->
      name = String.downcase(style.name)

      cond do
        name =~ ~r/toc[_ ]heading/ ->
          :toc_heading

        name =~ ~r/^toc \d$/ ->
          :toc_entry

        match = Regex.run(~r/(?:^|[_ ])heading\s*(\d)$/, name) ->
          {:heading, match |> List.last() |> String.to_integer()}

        name =~ ~r/(?:^|[_ ])subtitle$/ ->
          :subtitle

        name =~ ~r/(?:^|[_ ])title$/ ->
          :title

        is_integer(style.outline) and style.outline < 9 ->
          {:heading, style.outline + 1}

        name =~ ~r/(?:^|[_ ])important/ ->
          :important

        name =~ ~r/quote|(?:^|[_ ])note(?:$|[_ ])/ ->
          :note

        name =~ ~r/code|preformatted|verbatim|source/ ->
          :code

        name =~ ~r/caption/ ->
          :caption

        true ->
          nil
      end
    end)
  end

  ## Numbering

  # numId → %{ilvl => numFmt}. Abstract definitions may hold no levels and
  # instead link to a numbering style (`w:numStyleLink`), whose numId leads to
  # the definition that does.
  defp numbering(parts, rels, styles) do
    case related_part(parts, rels, "word", "/numbering") do
      nil ->
        %{}

      root ->
        abstracts =
          for an <- Xml.children(root, :w, "abstractNum"), into: %{} do
            levels =
              for lvl <- Xml.children(an, :w, "lvl"), into: %{} do
                {int(Xml.attr(lvl, "ilvl")) || 0,
                 lvl |> Xml.child(:w, "numFmt") |> Xml.attr("val")}
              end

            link = an |> Xml.child(:w, "numStyleLink") |> Xml.attr("val")
            {Xml.attr(an, "abstractNumId"), %{levels: levels, link: link}}
          end

        nums =
          for num <- Xml.children(root, :w, "num"), into: %{} do
            {Xml.attr(num, "numId"), num |> Xml.child(:w, "abstractNumId") |> Xml.attr("val")}
          end

        Map.new(nums, fn {num_id, abstract_id} ->
          {num_id, resolve_levels(abstract_id, abstracts, nums, styles, 0)}
        end)
    end
  end

  defp resolve_levels(_abstract_id, _abstracts, _nums, _styles, depth) when depth > 5, do: %{}

  defp resolve_levels(abstract_id, abstracts, nums, styles, depth) do
    case Map.get(abstracts, abstract_id) do
      %{levels: levels, link: link} when map_size(levels) == 0 and is_binary(link) ->
        with %{num: %{id: num_id}} <- Map.get(styles.styles, link),
             linked when is_binary(linked) <- Map.get(nums, num_id) do
          resolve_levels(linked, abstracts, nums, styles, depth + 1)
        else
          _ -> %{}
        end

      %{levels: levels} ->
        levels

      nil ->
        %{}
    end
  end

  defp list_kind(ctx, num_id, ilvl) do
    case ctx.numbering |> Map.get(num_id, %{}) |> Map.get(ilvl) do
      format
      when format in [
             "decimal",
             "lowerLetter",
             "upperLetter",
             "lowerRoman",
             "upperRoman",
             "decimalZero",
             "ordinal"
           ] ->
        :number

      _ ->
        :bullet
    end
  end

  defp num_pr(nil), do: nil

  defp num_pr(ppr) do
    case Xml.child(ppr, :w, "numPr") do
      nil ->
        nil

      num_pr ->
        %{
          id: num_pr |> Xml.child(:w, "numId") |> Xml.attr("val"),
          ilvl: num_pr |> Xml.child(:w, "ilvl") |> Xml.attr("val") |> int()
        }
    end
  end

  ## Body

  # Flattens the body into paragraph maps and table blocks, in order.
  defp body_items(container, ctx) do
    Enum.flat_map(Xml.children(container), fn
      {:w, "p", _, _} = p -> [paragraph(p, ctx)]
      {:w, "tbl", _, _} = tbl -> [table(tbl, ctx)]
      {:w, "sdt", _, _} = sdt -> body_items(Xml.child(sdt, :w, "sdtContent") || sdt, ctx)
      {:w, name, _, _} = el when name in ~w(customXml ins moveTo) -> body_items(el, ctx)
      {:mc, "AlternateContent", _, _} = el -> body_items(Xml.child(el, :mc, "Choice") || el, ctx)
      _ -> []
    end)
  end

  defp paragraph(p, ctx) do
    ppr = Xml.child(p, :w, "pPr")
    style_id = ppr |> Xml.child(:w, "pStyle") |> Xml.attr("val") || ctx.styles.default
    direct_outline = ppr |> Xml.child(:w, "outlineLvl") |> Xml.attr("val") |> int()

    role =
      cond do
        is_integer(direct_outline) and direct_outline < 9 -> {:heading, direct_outline + 1}
        true -> style_role(ctx.styles, style_id)
      end

    direct_num = num_pr(ppr)
    style_num = inherited(ctx.styles, style_id, & &1.num)
    num = merge_num(direct_num, style_num, style_level(ctx.styles, style_id))

    char_format = %{
      bold: false,
      italic: false,
      code: inherited(ctx.styles, style_id, &(&1.code? || nil)) || false,
      link: nil
    }

    {segments, extras} =
      runs(Xml.children(p), ctx, char_format, {[], %{images: [], page_break?: false}})

    %{
      role: role,
      list: list_item(num, ctx),
      inlines: segments |> Enum.reverse() |> to_inlines(),
      images: Enum.reverse(extras.images),
      page_break?: extras.page_break?
    }
  end

  defp list_item(%{id: id, ilvl: ilvl}, ctx) when is_binary(id) and id != "0" do
    ilvl = ilvl || 0
    {ilvl, list_kind(ctx, id, ilvl), id}
  end

  defp list_item(_num, _ctx), do: nil

  # A numPr on the paragraph wins field by field over the style's. Styles like
  # "List Bullet 2" each carry their own numbering at level 0, so the level
  # comes from the style name when nothing else sets it.
  defp merge_num(nil, nil, _style_level), do: nil

  defp merge_num(direct, style, style_level) do
    direct = direct || %{id: nil, ilvl: nil}
    style = style || %{id: nil, ilvl: nil}
    %{id: direct.id || style.id, ilvl: direct.ilvl || style.ilvl || style_level}
  end

  defp style_level(styles, id) do
    inherited(styles, id, fn style ->
      case Regex.run(~r/list (?:bullet|number)\s*(\d)$/i, style.name) do
        [_, n] -> String.to_integer(n) - 1
        nil -> nil
      end
    end)
  end

  ## Runs → formatted segments

  # Accumulates `{format, text}` segments (reversed) plus images and page breaks.
  defp runs(children, ctx, format, acc) do
    Enum.reduce(children, acc, fn
      {:w, "r", _, _} = r, acc ->
        run(r, ctx, run_format(Xml.child(r, :w, "rPr"), ctx, format), acc)

      {:w, "hyperlink", _, _} = link, acc ->
        runs(
          Xml.children(link),
          ctx,
          %{format | link: link_target(link, ctx) || format.link},
          acc
        )

      {:w, "sdt", _, _} = sdt, acc ->
        runs(Xml.children(Xml.child(sdt, :w, "sdtContent") || sdt), ctx, format, acc)

      {:w, name, _, _} = el, acc
      when name in ~w(ins moveTo smartTag customXml fldSimple bdo dir) ->
        runs(Xml.children(el), ctx, format, acc)

      {:mc, "AlternateContent", _, _} = el, acc ->
        runs(Xml.children(Xml.child(el, :mc, "Choice") || el), ctx, format, acc)

      _other, acc ->
        acc
    end)
  end

  defp run(r, ctx, format, acc) do
    Enum.reduce(Xml.children(r), acc, fn
      {:w, "t", _, _} = t, acc ->
        add_text(acc, format, Xml.text(t))

      {:w, "tab", _, _}, acc ->
        add_text(acc, format, "\t")

      {:w, "noBreakHyphen", _, _}, acc ->
        add_text(acc, format, "-")

      {:w, "cr", _, _}, acc ->
        add_text(acc, format, "\n")

      {:w, "br", _, _} = br, acc ->
        line_break(acc, format, Xml.attr(br, "type"))

      {:w, name, _, _} = el, acc when name in ~w(drawing pict object) ->
        add_images(acc, el, ctx)

      {:mc, "AlternateContent", _, _} = el, acc ->
        run(Xml.child(el, :mc, "Choice") || el, ctx, format, acc)

      _other, acc ->
        acc
    end)
  end

  defp line_break({segments, extras}, _format, "page"),
    do: {segments, %{extras | page_break?: true}}

  defp line_break(acc, _format, "column"), do: acc
  defp line_break(acc, format, _type), do: add_text(acc, format, "\n")

  defp add_text(acc, _format, ""), do: acc
  defp add_text({segments, extras}, format, text), do: {[{format, text} | segments], extras}

  defp run_format(nil, _ctx, format), do: format

  defp run_format(rpr, ctx, format) do
    char_style = rpr |> Xml.child(:w, "rStyle") |> Xml.attr("val")
    style_name = inherited(ctx.styles, char_style, &String.downcase(&1.name)) || ""

    %{
      format
      | bold:
          toggle(
            rpr,
            "b",
            format.bold or style_name == "strong" or
              inherited(ctx.styles, char_style, &(&1.bold? || nil)) == true
          ),
        italic:
          toggle(
            rpr,
            "i",
            format.italic or style_name == "emphasis" or
              inherited(ctx.styles, char_style, &(&1.italic? || nil)) == true
          ),
        code:
          format.code or mono?(rpr) or
            inherited(ctx.styles, char_style, &(&1.code? || nil)) == true
    }
  end

  defp toggle(rpr, name, default) do
    case Xml.child(rpr, :w, name) do
      nil -> default
      el -> on?(el)
    end
  end

  defp on?(nil), do: false
  defp on?(el), do: Xml.attr(el, "val") not in @off_values

  defp mono?(nil), do: false

  defp mono?(rpr) do
    case Xml.child(rpr, :w, "rFonts") do
      nil -> false
      fonts -> Enum.any?(~w(ascii hAnsi), &((Xml.attr(fonts, &1) || "") =~ @mono_font))
    end
  end

  defp link_target(link, ctx) do
    case {Xml.attr(link, "r:id"), Xml.attr(link, "anchor")} do
      {id, _} when is_binary(id) ->
        case Map.get(ctx.rels, id) do
          %{external?: true, target: target} -> target
          _ -> nil
        end

      {nil, anchor} when is_binary(anchor) ->
        "#" <> anchor

      _ ->
        nil
    end
  end

  ## Images

  defp add_images({segments, extras}, el, ctx) do
    extent = el |> Xml.descendants(:wp, "extent") |> List.first()
    width = extent |> Xml.attr("cx") |> int()
    height = extent |> Xml.attr("cy") |> int()

    ids =
      Enum.map(Xml.descendants(el, :a, "blip"), &Xml.attr(&1, "r:embed")) ++
        Enum.map(Xml.descendants(el, :v, "imagedata"), &Xml.attr(&1, "r:id"))

    images =
      for id <- ids,
          %{external?: false, target: target} <- [Map.get(ctx.rels, id)],
          path = resolve(ctx.dir, target),
          data = Map.get(ctx.parts, path),
          is_binary(data),
          image = Image.new(path, data, width: width, height: height),
          image != nil,
          do: image

    {segments, %{extras | images: Enum.reverse(images, extras.images)}}
  end

  ## Tables

  defp table(tbl, ctx) do
    rows = tbl |> rows() |> Enum.map(&{row_header?(&1), row_cells(&1, ctx)})
    {header, body} = Enum.split_while(rows, fn {header?, _} -> header? end)

    {header, body} =
      if header == [] and first_row_header?(tbl) and length(rows) > 1,
        do: Enum.split(rows, 1),
        else: {header, body}

    header = for {_, cells} <- header, do: Enum.map(cells, &unbold/1)
    {:table, header, Enum.map(body, &elem(&1, 1))}
  end

  # Header cells are bold anyway; drop explicit bold covering the whole cell.
  defp unbold([{:bold, inner}]), do: inner
  defp unbold(cell), do: cell

  defp rows(nil), do: []

  defp rows(tbl) do
    Enum.flat_map(Xml.children(tbl), fn
      {:w, "tr", _, _} = tr -> [tr]
      {:w, "sdt", _, _} = sdt -> sdt |> Xml.child(:w, "sdtContent") |> rows()
      _ -> []
    end)
  end

  defp row_header?(tr), do: tr |> Xml.path([{:w, "trPr"}, {:w, "tblHeader"}]) |> on_or_missing()

  defp on_or_missing(nil), do: false
  defp on_or_missing(el), do: on?(el)

  defp first_row_header?(tbl) do
    look = Xml.path(tbl, [{:w, "tblPr"}, {:w, "tblLook"}])

    case {Xml.attr(look, "firstRow"), Xml.attr(look, "val")} do
      {first_row, _} when is_binary(first_row) ->
        first_row in ["1", "true", "on"]

      {nil, hex} when is_binary(hex) ->
        match?({v, ""} when Bitwise.band(v, 0x20) != 0, Integer.parse(hex, 16))

      _ ->
        false
    end
  end

  defp row_cells(tr, ctx) do
    tr
    |> cells()
    |> Enum.flat_map(fn tc ->
      tcpr = Xml.child(tc, :w, "tcPr")
      span = tcpr |> Xml.child(:w, "gridSpan") |> Xml.attr("val") |> int() |> Kernel.||(1)
      vmerge = Xml.child(tcpr, :w, "vMerge")
      continued? = vmerge != nil and Xml.attr(vmerge, "val") != "restart"

      content = if continued?, do: [], else: cell_inlines(tc, ctx)
      [content | List.duplicate([], max(span, 1) - 1)]
    end)
  end

  defp cells(nil), do: []

  defp cells(tr) do
    Enum.flat_map(Xml.children(tr), fn
      {:w, "tc", _, _} = tc -> [tc]
      {:w, "sdt", _, _} = sdt -> sdt |> Xml.child(:w, "sdtContent") |> cells()
      _ -> []
    end)
  end

  # Cell paragraphs (and nested tables, flattened) joined by line breaks.
  defp cell_inlines(tc, ctx) do
    tc
    |> body_items(ctx)
    |> Enum.flat_map(fn
      %{inlines: inlines} ->
        [inlines]

      {:table, header, rows} ->
        for row <- header ++ rows,
            do:
              row |> Enum.map(&Document.plain_text/1) |> Enum.join(" | ") |> then(&[{:text, &1}])
    end)
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse([{:text, "\n"}])
    |> List.flatten()
    |> merge_text()
  end

  ## Items → blocks

  # Everything up to a GS1 contents heading is front matter; contents entries
  # are generated, not content.
  defp skip_front_matter(items) do
    items =
      case Enum.find_index(items, &match?(%{role: :toc_heading}, &1)) do
        nil -> items
        index -> Enum.drop(items, index + 1)
      end

    Enum.reject(items, &match?(%{role: role} when role in [:toc_heading, :toc_entry], &1))
  end

  @custom_properties %{
    "GS1 DocName" => {:title, "GS1 Document Name"},
    "GS1 DocType" => {:doc_type, "GS1 Document Type"},
    "GS1 Description" => {:description, "Optional Description"}
  }

  # GS1 template properties, ignoring the template's placeholder values.
  defp custom_properties(parts) do
    case parse_part(parts, "docProps/custom.xml") do
      {:ok, root} ->
        for {nil, "property", _, _} = prop <- Xml.children(root),
            {key, placeholder} <- [Map.get(@custom_properties, Xml.attr(prop, "name"))],
            value = prop |> Xml.text() |> String.trim(),
            value not in ["", placeholder],
            into: %{},
            do: {key, value}

      {:error, _} ->
        %{}
    end
  end

  defp assemble(items) do
    {meta, blocks} =
      Enum.reduce(items, {%{}, []}, fn
        {:table, _, _} = table, {meta, acc} ->
          {meta, [table | acc]}

        para, {meta, acc} ->
          {meta, blocks} = para_blocks(para, meta)
          {meta, Enum.reverse(blocks, acc)}
      end)

    {meta, blocks |> Enum.reverse() |> group()}
  end

  defp para_blocks(para, meta) do
    text = para.inlines |> Document.plain_text() |> String.trim()
    images = for image <- para.images, do: {:image, image, nil}
    page_break = if para.page_break?, do: [:page_break], else: []

    {meta, main} =
      cond do
        text == "" ->
          {meta, []}

        para.role == :title and not Map.has_key?(meta, :title) ->
          {Map.put(meta, :title, text), []}

        para.role == :subtitle and not Map.has_key?(meta, :subtitle) ->
          {Map.put(meta, :subtitle, text), []}

        para.role in [:title, :subtitle] ->
          {meta, [{:heading, 1, para.inlines}]}

        match?({:heading, _}, para.role) ->
          {meta,
           [{:heading, min(elem(para.role, 1), 7), strip_generated_heading_number(para.inlines)}]}

        # Note styles may carry (picture-bullet) numbering; the role wins.
        para.role == :note ->
          {meta, [{:note, para.inlines}]}

        para.role == :important ->
          {meta, [{:important, para.inlines}]}

        para.list != nil ->
          {meta, [{:list_item, para.list, para.inlines}]}

        para.role == :code or all_code?(para.inlines) ->
          {meta, [{:code_line, Document.plain_text(para.inlines)}]}

        para.role == :caption ->
          {meta, [{:caption, strip_caption_label(para.inlines)}]}

        true ->
          {meta, [{:paragraph, para.inlines}]}
      end

    {meta, main ++ images ++ page_break}
  end

  defp strip_generated_heading_number([{:bold, [{:text, number}]} | rest]) do
    if Regex.match?(~r/^\d+(?:\.\d+)*$/, number) do
      case rest do
        [{:text, text} | tail] -> [{:text, String.trim_leading(text)} | tail]
        _ -> rest
      end
    else
      [{:bold, [{:text, number}]} | rest]
    end
  end

  defp strip_generated_heading_number(inlines), do: inlines

  # "Table 1: Foo" / "Figure 2-3. Foo" → "Foo" (numbers are regenerated on output).
  defp strip_caption_label([{:text, text} | rest]) do
    case Regex.replace(~r/\A\s*(?:Table|Figure)\s+[\d.\-]+\s*[:.\x{2013}\-]?\s*/u, text, "") do
      "" -> rest
      text -> [{:text, text} | rest]
    end
  end

  defp strip_caption_label(inlines), do: inlines

  defp all_code?(inlines) do
    Enum.all?(inlines, fn
      {:code, _} -> true
      {:text, text} -> String.trim(text) == ""
      _ -> false
    end) and Enum.any?(inlines, &match?({:code, _}, &1))
  end

  # Merges consecutive list items into nested lists, code lines into code
  # blocks, and attaches captions to the preceding image.
  defp group([]), do: []

  defp group([{:list_item, _, _} | _] = blocks) do
    {items, rest} = Enum.split_while(blocks, &match?({:list_item, _, _}, &1))

    lists =
      items
      |> split_lists()
      |> Enum.flat_map(fn items ->
        Lists.build(
          for {:list_item, {ilvl, kind, _id}, inlines} <- items, do: {ilvl, kind, inlines}
        )
      end)

    lists ++ group(rest)
  end

  defp group([{:code_line, _} | _] = blocks) do
    {lines, rest} = Enum.split_while(blocks, &match?({:code_line, _}, &1))
    [{:code_block, Enum.map_join(lines, "\n", &elem(&1, 1))} | group(rest)]
  end

  defp group([{:image, image, nil}, {:caption, caption} | rest]),
    do: [{:image, image, Document.plain_text(caption)} | group(rest)]

  defp group([{:caption, caption}, {:table, _, _} = table | rest]),
    do: [{:caption, :table, caption}, table | group(rest)]

  defp group([{:table, _, _} = table, {:caption, caption} | rest]),
    do: [{:caption, :table, caption}, table | group(rest)]

  defp group([{:caption, caption} | rest]), do: [{:paragraph, [{:italic, caption}]} | group(rest)]

  defp group([block | rest]), do: [block | group(rest)]

  # A new numbering instance at the top level starts a separate list.
  defp split_lists(items) do
    top = items |> Enum.map(fn {:list_item, {ilvl, _, _}, _} -> ilvl end) |> Enum.min()

    items
    |> Enum.chunk_while(
      {nil, []},
      fn {:list_item, {ilvl, _, id}, _} = item, {current, acc} ->
        cond do
          ilvl == top and current != nil and id != current ->
            {:cont, Enum.reverse(acc), {id, [item]}}

          ilvl == top ->
            {:cont, {id, [item | acc]}}

          true ->
            {:cont, {current, [item | acc]}}
        end
      end,
      fn {_, acc} -> {:cont, Enum.reverse(acc), nil} end
    )
    |> Enum.reject(&(&1 == []))
  end

  ## Segments → IR inlines

  @nesting [:link, :bold, :italic, :code]

  defp to_inlines(segments) do
    segments
    # Formatting on whitespace-only runs (e.g. a bold space) is noise.
    |> Enum.map(fn {format, text} ->
      if String.trim(text) == "",
        do: {%{format | bold: false, italic: false, code: false}, text},
        else: {format, text}
    end)
    |> nest(@nesting)
  end

  defp nest([], _keys), do: []
  defp nest(segments, []), do: [{:text, Enum.map_join(segments, &elem(&1, 1))}]

  defp nest(segments, [key | keys]) do
    segments
    |> Enum.chunk_by(fn {format, _} -> Map.fetch!(format, key) end)
    |> Enum.flat_map(fn [{format, _} | _] = chunk ->
      wrap(key, Map.fetch!(format, key), nest(chunk, keys))
    end)
  end

  defp wrap(_key, value, inner) when value in [nil, false], do: inner
  defp wrap(:link, url, inner), do: [{:link, url, inner}]
  defp wrap(:bold, true, inner), do: [{:bold, inner}]
  defp wrap(:italic, true, inner), do: [{:italic, inner}]
  defp wrap(:code, true, inner), do: [{:code, Document.plain_text(inner)}]

  defp merge_text([{:text, a}, {:text, b} | rest]), do: merge_text([{:text, a <> b} | rest])
  defp merge_text([node | rest]), do: [node | merge_text(rest)]
  defp merge_text([]), do: []

  ## Warnings

  defp warnings(body) do
    [
      Xml.descendants(body, :w, "footnoteReference") != [] && "Footnotes weren't imported.",
      Xml.descendants(body, :w, "txbxContent") != [] && "Text inside text boxes wasn't imported.",
      Xml.descendants(body, :w, "commentReference") != [] && "Comments weren't imported."
    ]
    |> Enum.filter(& &1)
  end

  ## Helpers

  defp int(nil), do: nil

  defp int(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end
end

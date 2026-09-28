defmodule Docgen.Render.Docx.Xml do
  @moduledoc """
  IR → WordprocessingML body XML.

  Rendering threads a context through every block to collect what must be
  written to other package parts: hyperlink relationships
  (`document.xml.rels`), numbering instances (`numbering.xml`) — one per
  numbered list, so each list restarts at 1 — images, and the headings a
  table of contents lists.
  """

  alias Docgen.Render.Docx.Context
  alias Docgen.Template.StyleMap

  @code_font "Courier New"
  @link_color "008DBD"
  @header_color "FFFFFF"
  @toc_levels 3

  @drawingml "http://schemas.openxmlformats.org/drawingml/2006/main"
  @picture "http://schemas.openxmlformats.org/drawingml/2006/picture"
  @emu_per_twip 635
  # 4in × 3in when an image's size is unknown.
  @default_size {3_657_600, 2_743_200}

  @type context :: Context.t()

  @doc "Renders `blocks` to body XML."
  @spec blocks([tuple() | atom()], context()) :: {iodata(), context()}
  def blocks(blocks, ctx) do
    Enum.map_reduce(blocks, ctx, fn block, ctx ->
      {xml, ctx} = block(block, ctx)
      {xml, %{ctx | space_before: space_after(block, ctx.styles)}}
    end)
  end

  # Text following a list or table would otherwise sit tight against it.
  defp space_after({kind, _level, _items}, styles) when kind in [:bullet_list, :numbered_list],
    do: StyleMap.option(styles, :spacing).after_list

  defp space_after({:table, _header_rows, _rows}, styles),
    do: StyleMap.option(styles, :spacing).after_table

  defp space_after(_block, _styles), do: nil

  ## Blocks

  defp block({:title, inlines}, ctx), do: paragraph(:title, inlines, ctx)
  defp block({:subtitle, inlines}, ctx), do: paragraph(:subtitle, inlines, ctx)
  defp block({:heading, level, inlines}, ctx), do: heading(level, inlines, ctx)
  defp block({:paragraph, inlines}, ctx), do: paragraph(:paragraph, inlines, ctx)
  defp block({:note, inlines}, ctx), do: paragraph(:note, inlines, ctx)
  defp block({:important, inlines}, ctx), do: paragraph(:important, inlines, ctx)
  defp block({:code_block, text}, ctx), do: paragraph(:code_block, [{:code, text}], ctx)
  defp block({:caption, :table, inlines}, ctx), do: caption(:table, inlines, ctx)

  defp block({:bullet_list, level, items}, ctx) do
    style_id = StyleMap.style(ctx.styles, {:bullet, level})

    # Templates without bullet styles get generated bullet numbering.
    if StyleMap.option(ctx.styles, :generated_bullets) do
      {num_pr, ctx} = new_list(ctx, level, :bullet)
      list_items(items, style_id, num_pr, ctx)
    else
      list_items(items, style_id, "", ctx)
    end
  end

  defp block({:numbered_list, level, items}, ctx) do
    {num_pr, ctx} = new_list(ctx, level, :number)
    list_items(items, StyleMap.style(ctx.styles, {:number, level}), num_pr, ctx)
  end

  defp block({:table, header_rows, rows}, ctx),
    do: table(header_rows, rows, %{ctx | space_before: nil})

  defp block({:image, image, caption}, ctx) do
    n = length(ctx.images) + 1
    id = "rIdDocgenImg#{n}"
    part = "word/media/docgen#{n}.#{Docgen.Image.extension(image.content_type)}"
    ctx = %{ctx | images: [{id, part, image} | ctx.images], space_before: nil}
    {cx, cy} = fit(image, ctx.text_width * @emu_per_twip)

    drawing = [
      ~s(<w:p><w:pPr><w:pStyle w:val="#{escape(StyleMap.style(ctx.styles, :paragraph))}"/></w:pPr>),
      ~s(<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">),
      ~s(<wp:extent cx="#{cx}" cy="#{cy}"/><wp:docPr id="#{1000 + n}" name="Picture #{n}"/>),
      ~s(<wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="#{@drawingml}" noChangeAspect="1"/></wp:cNvGraphicFramePr>),
      ~s(<a:graphic xmlns:a="#{@drawingml}"><a:graphicData uri="#{@picture}">),
      ~s(<pic:pic xmlns:pic="#{@picture}"><pic:nvPicPr><pic:cNvPr id="#{n}" name="#{Path.basename(part)}"/><pic:cNvPicPr/></pic:nvPicPr>),
      ~s(<pic:blipFill><a:blip r:embed="#{id}"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>),
      ~s(<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="#{cx}" cy="#{cy}"/></a:xfrm>),
      ~s(<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>),
      "</a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"
    ]

    if caption in [nil, ""] do
      {drawing, ctx}
    else
      {caption_xml, ctx} = caption(:figure, [{:text, caption}], ctx)
      {[drawing, caption_xml], ctx}
    end
  end

  defp block(:page_break, ctx), do: {~s(<w:p><w:r><w:br w:type="page"/></w:r></w:p>), ctx}

  # A fresh numbering instance, so each list restarts.
  defp new_list(ctx, level, kind) do
    num_id = ctx.next_num_id
    ilvl = min(level, 9) - 1

    ctx = %{
      ctx
      | next_num_id: num_id + 1,
        numbered_lists: [{num_id, ilvl, kind} | ctx.numbered_lists]
    }

    {~s(<w:numPr><w:ilvl w:val="#{ilvl}"/><w:numId w:val="#{num_id}"/></w:numPr>), ctx}
  end

  defp list_items(items, style_id, num_pr, ctx) do
    after_item = StyleMap.option(ctx.styles, :spacing).list_item

    Enum.map_reduce(items, ctx, fn {inlines, children}, ctx ->
      {para, ctx} = styled_paragraph(style_id, num_pr, inlines, ctx, %{}, after_item)
      # Nested lists belong to the item, so they don't space what follows.
      {nested, ctx} = Enum.map_reduce(children, ctx, &block/2)
      {[para, nested], ctx}
    end)
  end

  ## Headings (bookmarked for the table of contents)

  defp heading(level, inlines, ctx) do
    style_id = StyleMap.style(ctx.styles, {:heading, level})
    {number, ctx} = next_heading_number(ctx, level)

    case StyleMap.option(ctx.styles, :heading_indent) do
      nil ->
        # Heading styles bring their own space before; bold body text doesn't.
        if StyleMap.option(ctx.styles, :bold_headings),
          do: styled_paragraph(style_id, "", inlines, ctx, %{bold: true}),
          else: styled_paragraph(style_id, "", inlines, %{ctx | space_before: nil})

      indent ->
        # The style's own numbering is switched off for the typed number the
        # table of contents repeats, so the indent and tab stop it set are
        # restated to keep heading text aligned. Deeper levels need more room.
        indent = indent + 144 * max(level - 4, 0)
        inlines = Docgen.Document.strip_heading_number(inlines)
        {bookmark_start, bookmark_end, ctx} = toc_bookmark(ctx, level, number, inlines)
        {runs, ctx} = inlines(inlines, ctx, %{})

        {[
           ~s(<w:p><w:pPr><w:pStyle w:val="#{escape(style_id)}"/><w:numPr><w:numId w:val="0"/></w:numPr>),
           ~s(<w:tabs><w:tab w:val="left" w:pos="#{indent}"/></w:tabs>),
           ~s(<w:ind w:left="#{indent}" w:hanging="#{indent}"/></w:pPr>),
           bookmark_start,
           run(number, %{bold: true}),
           ~s(<w:r><w:tab/></w:r>),
           runs,
           bookmark_end,
           "</w:p>"
         ], %{ctx | space_before: nil}}
    end
  end

  defp toc_bookmark(ctx, level, number, inlines) do
    if StyleMap.option(ctx.styles, :toc) and level <= @toc_levels do
      n = length(ctx.headings) + 1
      bookmark = "_TocDocgen#{n}"
      id = 90_000 + n
      text = Docgen.Document.plain_text(inlines)
      heading = %{level: level, number: number, text: text, bookmark: bookmark}

      {~s(<w:bookmarkStart w:id="#{id}" w:name="#{bookmark}"/>),
       ~s(<w:bookmarkEnd w:id="#{id}"/>), %{ctx | headings: [heading | ctx.headings]}}
    else
      {[], [], ctx}
    end
  end

  # Tracks outline numbers (1, 1.1, 1.1.1 …) as auto-numbered heading styles show them.
  defp next_heading_number(ctx, level) do
    counters =
      ctx.heading_counters
      |> Enum.take(level)
      |> then(&(&1 ++ List.duplicate(0, level - length(&1))))
      |> List.update_at(level - 1, &(&1 + 1))

    {Enum.join(counters, "."), %{ctx | heading_counters: counters}}
  end

  ## Captions

  defp caption(kind, inlines, ctx) do
    style_id =
      StyleMap.style(ctx.styles, if(kind == :table, do: :caption_table, else: :caption_figure))

    if StyleMap.option(ctx.styles, :caption_labels) do
      n = Map.get(ctx.captions, kind, 0) + 1
      ctx = %{ctx | captions: Map.put(ctx.captions, kind, n)}
      label = if kind == :table, do: "Table", else: "Figure"
      {runs, ctx} = inlines(inlines, ctx, %{})

      {[
         ~s(<w:p><w:pPr><w:pStyle w:val="#{escape(style_id)}"/>),
         spacing(ctx.space_before, nil),
         "</w:pPr>",
         run(label <> " ", %{}),
         field(" SEQ #{label} \\* ARABIC ", Integer.to_string(n)),
         run(": ", %{}),
         runs,
         "</w:p>"
       ], %{ctx | space_before: nil}}
    else
      styled_paragraph(style_id, "", [{:italic, inlines}], ctx)
    end
  end

  @doc false
  # A complex field with a cached result, e.g. SEQ or PAGEREF.
  def field(instruction, result, rpr \\ "") do
    [
      ~s(<w:r>#{rpr}<w:fldChar w:fldCharType="begin"/></w:r>),
      ~s(<w:r>#{rpr}<w:instrText xml:space="preserve">#{escape(instruction)}</w:instrText></w:r>),
      ~s(<w:r>#{rpr}<w:fldChar w:fldCharType="separate"/></w:r>),
      ~s(<w:r>#{rpr}<w:t xml:space="preserve">#{escape(result)}</w:t></w:r>),
      ~s(<w:r>#{rpr}<w:fldChar w:fldCharType="end"/></w:r>)
    ]
  end

  ## Paragraphs & runs

  defp paragraph(key, inlines, ctx) do
    styled_paragraph(StyleMap.style(ctx.styles, key), "", inlines, ctx, %{})
  end

  defp styled_paragraph(style_id, extra_ppr, inlines, ctx, format \\ %{}, space_after \\ nil) do
    space_before = ctx.space_before
    {runs, ctx} = inlines(inlines, %{ctx | space_before: nil}, format)

    {[
       ~s(<w:p><w:pPr><w:pStyle w:val="),
       escape(style_id),
       ~s("/>),
       extra_ppr,
       spacing(space_before, space_after),
       "</w:pPr>",
       runs,
       "</w:p>"
     ], ctx}
  end

  # Follows `w:numPr` in CT_PPr's schema sequence.
  defp spacing(nil, nil), do: []

  defp spacing(before, space_after) do
    attrs = [before && ~s( w:before="#{before}"), space_after && ~s( w:after="#{space_after}")]
    ["<w:spacing", Enum.filter(attrs, & &1), "/>"]
  end

  defp inlines(inlines, ctx, format), do: Enum.map_reduce(inlines, ctx, &inline(&1, &2, format))

  defp inline({:text, text}, ctx, format), do: {run(text, format), ctx}

  defp inline({:code, text}, ctx, format),
    do: {run(text, Map.put(format, :code, StyleMap.style(ctx.styles, :code_char) || true)), ctx}

  defp inline({:bold, children}, ctx, format),
    do: inlines(children, ctx, Map.put(format, :bold, true))

  defp inline({:italic, children}, ctx, format),
    do: inlines(children, ctx, Map.put(format, :italic, true))

  defp inline({:link, url, children}, ctx, format) do
    case link_target(url, format) do
      nil ->
        inlines(children, ctx, format)

      {:anchor, anchor} ->
        {runs, ctx} = inlines(children, ctx, Map.put(format, :link, true))

        {[~s(<w:hyperlink w:anchor="#{escape(anchor)}" w:history="1">), runs, "</w:hyperlink>"],
         ctx}

      {:external, url} ->
        id = "rIdDocgen#{ctx.next_link}"
        ctx = %{ctx | next_link: ctx.next_link + 1, links: [{id, url} | ctx.links]}
        {runs, ctx} = inlines(children, ctx, Map.put(format, :link, true))
        {[~s(<w:hyperlink r:id="#{id}" w:history="1">), runs, "</w:hyperlink>"], ctx}
    end
  end

  # Hyperlinks can't nest, and Word rejects malformed relationship targets, so
  # anything that isn't a clean absolute URI renders as plain text.
  defp link_target(_url, %{link: true}), do: nil
  defp link_target("#" <> anchor, _format) when anchor != "", do: {:anchor, anchor}

  defp link_target(url, _format) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) -> {:external, url}
      _ -> nil
    end
  end

  defp run("", _format), do: []

  defp run(text, format) do
    content =
      text
      |> String.split(~r/(\n|\t)/, include_captures: true, trim: true)
      |> Enum.map(fn
        "\n" -> "<w:br/>"
        "\t" -> "<w:tab/>"
        chunk -> [~s(<w:t xml:space="preserve">), escape(chunk), "</w:t>"]
      end)

    ["<w:r>", run_properties(format), content, "</w:r>"]
  end

  # Child order follows the CT_RPr schema sequence; Word rejects other orders.
  defp run_properties(format) do
    props = [
      is_binary(format[:code]) && ~s(<w:rStyle w:val="#{escape(format[:code])}"/>),
      format[:code] == true &&
        ~s(<w:rFonts w:ascii="#{@code_font}" w:hAnsi="#{@code_font}" w:cs="#{@code_font}"/>),
      format[:bold] && "<w:b/><w:bCs/>",
      format[:italic] && "<w:i/><w:iCs/>",
      color(format) && ~s(<w:color w:val="#{color(format)}"/>),
      format[:link] && ~s(<w:u w:val="single"/>)
    ]

    case Enum.filter(props, & &1) do
      [] -> []
      props -> ["<w:rPr>", props, "</w:rPr>"]
    end
  end

  defp color(%{link: true}), do: @link_color
  defp color(format), do: format[:color]

  # Scales an image down (never up) to fit the text width, keeping its aspect ratio.
  defp fit(%{width: w, height: h}, max_width)
       when is_integer(w) and is_integer(h) and w > max_width,
       do: {max_width, div(h * max_width, w)}

  defp fit(%{width: w, height: h}, _max_width) when is_integer(w) and is_integer(h), do: {w, h}
  defp fit(image, max_width), do: fit(Map.merge(image, size_map(@default_size)), max_width)

  defp size_map({w, h}), do: %{width: w, height: h}

  ## Tables

  defp table(header_rows, rows, ctx) do
    columns = (header_rows ++ rows) |> Enum.map(&length/1) |> Enum.max(fn -> 1 end) |> max(1)
    widths = table_column_widths(header_rows, columns, ctx.text_width)
    grid = for width <- widths, do: ~s(<w:gridCol w:w="#{width}"/>)

    {header_xml, ctx} = table_rows(header_rows, columns, widths, true, ctx)
    {body_xml, ctx} = table_rows(rows, columns, widths, false, ctx)

    {[
       "<w:tbl><w:tblPr>",
       ~s(<w:tblStyle w:val="#{escape(StyleMap.style(ctx.styles, :table))}"/>),
       ~s(<w:tblW w:w="5000" w:type="pct"/>),
       ~s(<w:tblLook w:val="04A0" w:firstRow="1" w:lastRow="0" w:firstColumn="1" w:lastColumn="0" w:noHBand="0" w:noVBand="1"/>),
       "</w:tblPr><w:tblGrid>",
       grid,
       "</w:tblGrid>",
       header_xml,
       body_xml,
       "</w:tbl>"
     ], ctx}
  end

  defp table_column_widths([header | _], 3, total_width) do
    labels = Enum.map(header, &(&1 |> Docgen.Document.plain_text() |> String.downcase()))

    if labels == ["area", "rating", "comment"] do
      first = round(total_width * 0.34)
      second = round(total_width * 0.17)
      [first, second, total_width - first - second]
    else
      equal_column_widths(3, total_width)
    end
  end

  defp table_column_widths(_header_rows, columns, total_width),
    do: equal_column_widths(columns, total_width)

  defp equal_column_widths(columns, total_width) do
    width = div(total_width, columns)
    List.duplicate(width, columns - 1) ++ [total_width - width * (columns - 1)]
  end

  defp table_rows(rows, columns, widths, header?, ctx) do
    Enum.map_reduce(rows, ctx, fn cells, ctx ->
      cells = Enum.take(cells ++ List.duplicate([], columns), columns)

      {cells_xml, ctx} =
        cells
        |> Enum.zip(widths)
        |> Enum.map_reduce(ctx, fn {cell, width}, ctx ->
          table_cell(cell, width, header?, ctx)
        end)

      row_props = if header?, do: "<w:trPr><w:tblHeader/></w:trPr>", else: ""
      {["<w:tr>", row_props, cells_xml, "</w:tr>"], ctx}
    end)
  end

  defp table_cell(inlines, width, header?, ctx) do
    fill = StyleMap.option(ctx.styles, :table_header_fill)

    {shading, format} =
      cond do
        header? and fill ->
          {~s(<w:shd w:val="clear" w:color="auto" w:fill="#{fill}"/>),
           %{bold: true, color: @header_color}}

        # The table style's first-row formatting provides the look.
        header? ->
          {"", %{}}

        true ->
          {"", %{}}
      end

    style_id = StyleMap.style(ctx.styles, if(header?, do: :table_heading, else: :table_text))
    {para, ctx} = styled_paragraph(style_id, "", inlines, ctx, format)

    {[
       ~s(<w:tc><w:tcPr><w:tcW w:w="#{width}" w:type="dxa"/><w:tcMar><w:top w:w="50" w:type="dxa"/><w:bottom w:w="50" w:type="dxa"/><w:left w:w="80" w:type="dxa"/><w:right w:w="80" w:type="dxa"/></w:tcMar>),
       shading,
       "</w:tcPr>",
       para,
       "</w:tc>"
     ], ctx}
  end

  ## Escaping

  @invalid_xml_chars ~r/[^\x{9}\x{A}\x{D}\x{20}-\x{D7FF}\x{E000}-\x{FFFD}\x{10000}-\x{10FFFF}]/u

  @doc """
  Escapes text for XML content and attribute values, dropping characters XML
  1.0 can't represent.
  """
  @spec escape(String.t()) :: String.t()
  def escape(text) do
    text
    |> String.replace(@invalid_xml_chars, "")
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end

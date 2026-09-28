defmodule Docgen.Render.Pptx.Xml do
  @moduledoc """
  Slide content → PresentationML/DrawingML XML.

  Every function threads a list of the slide's relationships (hyperlinks
  and images, newest first) so the renderer can write the slide's `.rels`
  part. Text inherits fonts, sizes, colours and bullets from the GS1 slide
  masters; only what the IR adds (bold, links, code, numbering) is set.
  """

  alias Docgen.Document
  alias Docgen.Render.Docx.Xml, as: DocxXml

  @code_font "Courier New"
  @lang ~s(lang="en-GB")
  @safe_schemes ~w(http https mailto)

  @table_border "BFBFBF"
  @table_font_size 1100
  @caption_font_size 1100

  @type rel :: {:link, String.t()} | {:image, String.t()}
  @type rels :: [rel()]

  @doc "The relationship id of the `n`th slide relationship (1 is the layout)."
  @spec rel_id(pos_integer()) :: String.t()
  def rel_id(n), do: "rId#{n}"

  @doc "Escapes text for XML."
  defdelegate escape(text), to: DocxXml

  ## Slides

  @doc "Wraps shapes in a slide part."
  @spec slide(iodata()) :: iodata()
  def slide(shapes) do
    [
      ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n),
      ~s(<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" ),
      ~s(xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" ),
      ~s(xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">),
      "<p:cSld><p:spTree>",
      ~s(<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>),
      ~s(<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>),
      ~s(<a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>),
      shapes,
      "</p:spTree></p:cSld>",
      "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>",
      "</p:sld>"
    ]
  end

  @doc """
  A placeholder shape filled with `paragraphs`. `ph` is the `<p:ph>`
  attribute string from the layout, e.g. `type="title"`.
  """
  @spec placeholder(pos_integer(), String.t(), String.t(), iodata(), keyword()) :: iodata()
  def placeholder(id, name, ph, paragraphs, opts \\ []) do
    body_pr = if opts[:autofit], do: "<a:bodyPr><a:normAutofit/></a:bodyPr>", else: "<a:bodyPr/>"

    [
      ~s(<p:sp><p:nvSpPr><p:cNvPr id="#{id}" name="#{escape(name)}"/>),
      ~s(<p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>),
      ~s(<p:nvPr><p:ph #{ph}/></p:nvPr></p:nvSpPr><p:spPr/>),
      "<p:txBody>",
      body_pr,
      "<a:lstStyle/>",
      paragraphs,
      "</p:txBody></p:sp>"
    ]
  end

  @doc "The slide number placeholder of a layout (`idx` from the layout)."
  @spec slide_number(pos_integer(), pos_integer(), pos_integer()) :: iodata()
  def slide_number(id, idx, number) do
    placeholder(id, "Slide Number", ~s(type="sldNum" sz="quarter" idx="#{idx}"), [
      ~s(<a:p><a:fld id="{4472AB7F-E8D0-4874-A9B8-335B68DC5F05}" type="slidenum">),
      ~s(<a:rPr #{@lang}/><a:t>#{number}</a:t></a:fld></a:p>)
    ])
  end

  @doc "A text box (not a placeholder) at `{x, y, cx, cy}` EMU."
  @spec text_box(
          pos_integer(),
          String.t(),
          {integer(), integer(), integer(), integer()},
          iodata()
        ) ::
          iodata()
  def text_box(id, name, {x, y, cx, cy}, paragraphs) do
    [
      ~s(<p:sp><p:nvSpPr><p:cNvPr id="#{id}" name="#{escape(name)}"/>),
      ~s(<p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>),
      ~s(<p:spPr><a:xfrm><a:off x="#{x}" y="#{y}"/><a:ext cx="#{cx}" cy="#{cy}"/></a:xfrm>),
      ~s(<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>),
      ~s(<p:txBody><a:bodyPr wrap="square" lIns="0" tIns="0" rIns="0" bIns="0"><a:normAutofit/></a:bodyPr>),
      "<a:lstStyle/>",
      paragraphs,
      "</p:txBody></p:sp>"
    ]
  end

  @doc "A picture at `{x, y, cx, cy}` EMU using relationship `rel_id`."
  @spec picture(
          pos_integer(),
          String.t(),
          String.t(),
          {integer(), integer(), integer(), integer()}
        ) ::
          iodata()
  def picture(id, rel_id, descr, {x, y, cx, cy}) do
    [
      ~s(<p:pic><p:nvPicPr><p:cNvPr id="#{id}" name="Picture #{id}" descr="#{escape(descr)}"/>),
      ~s(<p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>),
      ~s(<p:blipFill><a:blip r:embed="#{rel_id}"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>),
      ~s(<p:spPr><a:xfrm><a:off x="#{x}" y="#{y}"/><a:ext cx="#{cx}" cy="#{cy}"/></a:xfrm>),
      ~s(<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>)
    ]
  end

  ## Paragraphs

  @doc "A single paragraph of plain text (no bullet)."
  @spec text(String.t(), keyword()) :: iodata()
  def text(text, opts \\ []) do
    rpr = if size = opts[:size], do: ~s( sz="#{size}"), else: ""

    [
      ~s(<a:p><a:pPr marL="0" indent="0"><a:buNone/></a:pPr>),
      text_runs(text, ~s(<a:rPr #{@lang}#{rpr} dirty="0"/>)),
      "</a:p>"
    ]
  end

  @doc "One bulleted paragraph per item (bullets come from the layout)."
  @spec bullets([String.t()]) :: iodata()
  def bullets(items) do
    Enum.map(items, fn item ->
      [~s(<a:p><a:pPr lvl="0"/>), text_runs(item, ~s(<a:rPr #{@lang} dirty="0"/>)), "</a:p>"]
    end)
  end

  @doc "Renders content slide blocks to paragraphs."
  @spec blocks([Docgen.Render.Pptx.Deck.block()], rels()) :: {iodata(), rels()}
  def blocks(blocks, rels), do: Enum.map_reduce(blocks, rels, &block/2)

  defp block({:paragraph, inlines}, rels), do: plain_paragraph(inlines, rels)

  defp block({:subheading, inlines}, rels) do
    {runs, rels} = inlines(inlines, rels, %{bold: true, color: "tx2"})

    {[
       ~s(<a:p><a:pPr marL="0" indent="0"><a:spcBef><a:spcPts val="900"/></a:spcBef>),
       "<a:buNone/></a:pPr>",
       runs,
       "</a:p>"
     ], rels}
  end

  defp block({kind, inlines}, rels) when kind in [:note, :important] do
    {runs, rels} = inlines(inlines, rels, %{color: if(kind == :important, do: "accent1")})

    {[
       ~s(<a:p><a:pPr marL="0" indent="0"><a:spcBef><a:spcPts val="900"/></a:spcBef>),
       "<a:buNone/></a:pPr>",
       runs,
       "</a:p>"
     ], rels}
  end

  defp block({:code_block, text}, rels) do
    rpr = ~s(<a:rPr #{@lang} sz="1200" dirty="0"><a:latin typeface="#{@code_font}"/></a:rPr>)

    {[
       ~s(<a:p><a:pPr marL="0" indent="0"><a:lnSpc><a:spcPct val="100000"/></a:lnSpc>),
       "<a:buNone/></a:pPr>",
       text_runs(text, rpr),
       "</a:p>"
     ], rels}
  end

  defp block({:bullet_list, level, items}, rels), do: list_items(items, level, :bullet, 1, rels)
  defp block({:numbered_list, level, items}, rels), do: list_items(items, level, :number, 1, rels)

  defp block({:numbered_list, level, items, start}, rels),
    do: list_items(items, level, :number, start, rels)

  defp block(_block, rels), do: {[], rels}

  defp plain_paragraph(inlines, rels) do
    {runs, rels} = inlines(inlines, rels, %{})
    {[~s(<a:p><a:pPr marL="0" indent="0"><a:buNone/></a:pPr>), runs, "</a:p>"], rels}
  end

  defp list_items(items, level, kind, start, rels) do
    items
    |> Enum.with_index(start)
    |> Enum.map_reduce(rels, fn {{inlines, nested}, n}, rels ->
      {runs, rels} = inlines(inlines, rels, %{})
      {nested_xml, rels} = blocks(nested, rels)
      {[~s(<a:p>), list_ppr(level, kind, n), runs, "</a:p>", nested_xml], rels}
    end)
  end

  # The masters define five bullet levels.
  defp list_ppr(level, :bullet, _n), do: ~s(<a:pPr lvl="#{min(level, 5) - 1}"/>)

  defp list_ppr(level, :number, n) do
    [
      ~s(<a:pPr lvl="#{min(level, 5) - 1}">),
      ~s(<a:buFont typeface="+mj-lt"/><a:buAutoNum type="#{number_type(level)}" startAt="#{n}"/>),
      "</a:pPr>"
    ]
  end

  defp number_type(level) when rem(level, 3) == 2, do: "alphaLcPeriod"
  defp number_type(level) when rem(level, 3) == 0, do: "romanLcPeriod"
  defp number_type(_level), do: "arabicPeriod"

  ## Inlines

  @doc false
  @spec inlines([Document.inline()], rels(), map()) :: {iodata(), rels()}
  def inlines(inlines, rels, format), do: Enum.map_reduce(inlines, rels, &inline(&1, &2, format))

  defp inline({:text, text}, rels, format), do: {text_runs(text, rpr(format)), rels}

  defp inline({:code, text}, rels, format),
    do: {text_runs(text, rpr(Map.put(format, :code, true))), rels}

  defp inline({:bold, children}, rels, format),
    do: inlines(children, rels, Map.put(format, :bold, true))

  defp inline({:italic, children}, rels, format),
    do: inlines(children, rels, Map.put(format, :italic, true))

  defp inline({:link, url, children}, rels, format) do
    if safe_url?(url) and not Map.has_key?(format, :link) do
      rels = [{:link, url} | rels]
      # +1: relationship 1 is the slide layout.
      inlines(children, rels, Map.put(format, :link, rel_id(length(rels) + 1)))
    else
      inlines(children, rels, format)
    end
  end

  defp safe_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in @safe_schemes -> true
      _ -> false
    end
  end

  # Properties in schema order: attributes, fill, latin, hlinkClick.
  defp rpr(format) do
    attrs =
      [
        format[:bold] && ~s( b="1"),
        format[:italic] && ~s( i="1"),
        format[:link] && ~s( u="sng")
      ]
      |> Enum.filter(& &1)

    children =
      [
        format[:color] && ~s(<a:solidFill><a:schemeClr val="#{format[:color]}"/></a:solidFill>),
        format[:code] && ~s(<a:latin typeface="#{@code_font}"/>),
        format[:link] && ~s(<a:hlinkClick r:id="#{format[:link]}"/>)
      ]
      |> Enum.filter(& &1)

    if children == [],
      do: [~s(<a:rPr #{@lang}), attrs, ~s( dirty="0"/>)],
      else: [~s(<a:rPr #{@lang}), attrs, ~s( dirty="0">), children, "</a:rPr>"]
  end

  # Runs for `text`, with `<a:br/>` for line breaks.
  defp text_runs(text, rpr) do
    text
    |> String.split("\n")
    |> Enum.map(fn
      "" -> []
      line -> ["<a:r>", rpr, "<a:t>", escape(line), "</a:t></a:r>"]
    end)
    |> Enum.intersperse(~s(<a:br><a:rPr #{@lang}/></a:br>))
  end

  ## Tables

  @doc """
  A table graphic frame at `{x, y, cx}` EMU. Header rows get the GS1 blue
  fill with white bold text.
  """
  @spec table(
          pos_integer(),
          [Document.row()],
          [Document.row()],
          {integer(), integer(), integer()},
          rels()
        ) ::
          {iodata(), rels()}
  def table(id, header_rows, rows, {x, y, cx}, rels) do
    columns = (header_rows ++ rows) |> Enum.map(&length/1) |> Enum.max(fn -> 1 end) |> max(1)
    widths = column_widths(header_rows ++ rows, columns, cx)

    {header_xml, rels} = rows_xml(header_rows, columns, true, rels)
    {body_xml, rels} = rows_xml(rows, columns, false, rels)
    row_count = length(header_rows) + length(rows)

    {[
       ~s(<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="#{id}" name="Table #{id}"/>),
       ~s(<p:cNvGraphicFramePr><a:graphicFrameLocks noGrp="1"/></p:cNvGraphicFramePr><p:nvPr/>),
       "</p:nvGraphicFramePr>",
       ~s(<p:xfrm><a:off x="#{x}" y="#{y}"/><a:ext cx="#{cx}" cy="#{row_count * row_height()}"/></p:xfrm>),
       ~s(<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table">),
       ~s(<a:tbl><a:tblPr firstRow="#{if header_rows == [], do: 0, else: 1}" bandRow="1"/>),
       "<a:tblGrid>",
       Enum.map(widths, &~s(<a:gridCol w="#{&1}"/>)),
       "</a:tblGrid>",
       header_xml,
       body_xml,
       "</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
     ], rels}
  end

  defp row_height, do: 320_040

  # Wider columns for longer text, within 0.5–3× of an equal share.
  defp column_widths(rows, columns, total) do
    weights =
      for column <- 0..(columns - 1) do
        rows
        |> Enum.map(fn row ->
          row |> Enum.at(column, []) |> Document.plain_text() |> String.length()
        end)
        |> Enum.max(fn -> 0 end)
        |> max(1)
        |> :math.sqrt()
      end

    mean = Enum.sum(weights) / columns
    weights = Enum.map(weights, &min(max(&1, mean * 0.5), mean * 3))
    sum = Enum.sum(weights)
    widths = Enum.map(weights, &trunc(total * &1 / sum))
    # Rounding leftovers go to the last column.
    List.update_at(widths, -1, &(&1 + total - Enum.sum(widths)))
  end

  defp rows_xml(rows, columns, header?, rels) do
    Enum.map_reduce(rows, rels, fn row, rels ->
      cells = row ++ List.duplicate([], max(columns - length(row), 0))

      {cells_xml, rels} =
        cells
        |> Enum.take(columns)
        |> Enum.map_reduce(rels, &cell(&1, header?, &2))

      {[~s(<a:tr h="#{row_height()}">), cells_xml, "</a:tr>"], rels}
    end)
  end

  defp cell(inlines, header?, rels) do
    format = if header?, do: %{bold: true, color: "bg1"}, else: %{}
    {runs, rels} = inlines(inlines, rels, format)
    border = ~s(<a:solidFill><a:srgbClr val="#{@table_border}"/></a:solidFill>)

    fill =
      if header?, do: ~s(<a:solidFill><a:schemeClr val="tx2"/></a:solidFill>), else: "<a:noFill/>"

    {[
       "<a:tc><a:txBody><a:bodyPr/><a:lstStyle/>",
       ~s(<a:p><a:pPr marL="0" indent="0"><a:buNone/><a:defRPr sz="#{@table_font_size}"/></a:pPr>),
       sized(runs),
       ~s(<a:endParaRPr #{@lang} sz="#{@table_font_size}" dirty="0"/></a:p>),
       "</a:txBody>",
       ~s(<a:tcPr marL="68580" marR="68580" marT="45720" marB="45720" anchor="ctr">),
       Enum.map(~w(lnL lnR lnT lnB), &~s(<a:#{&1} w="12700">#{border}</a:#{&1}>)),
       fill,
       "</a:tcPr></a:tc>"
     ], rels}
  end

  # Table runs get an explicit size: table text doesn't inherit the
  # layout's body size.
  defp sized(runs) do
    runs
    |> IO.iodata_to_binary()
    |> String.replace(~s(<a:rPr #{@lang}), ~s(<a:rPr #{@lang} sz="#{@table_font_size}"))
  end

  @doc "A small caption paragraph."
  @spec caption(String.t()) :: iodata()
  def caption(text) do
    [
      ~s(<a:p><a:pPr marL="0" indent="0"><a:buNone/></a:pPr>),
      text_runs(text, ~s(<a:rPr #{@lang} sz="#{@caption_font_size}" i="1" dirty="0"/>)),
      "</a:p>"
    ]
  end
end

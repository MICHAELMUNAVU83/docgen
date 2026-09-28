defmodule Docgen.Render.Docx do
  @moduledoc """
  Renders a `Docgen.Document` into a `.docx` built on its GS1 template.

  The template's body is replaced with generated content while its final
  `<w:sectPr>` — and with it headers, footers and margins — is kept. Macros
  are stripped so the result is a plain Word document.

  Templates with front matter (GS1 Advanced) keep their cover page, document
  summary and table-of-contents heading; the generated contents list and the
  document follow. Cover and header/footer placeholders are `DOCPROPERTY`
  fields, filled from `meta` (see `Docgen.Render.Docx.Fields`):

    * `:title` → "GS1 DocName", `:doc_type` → "GS1 DocType",
      `:description` → "GS1 Description", `:version` → "GS1 Version",
      `:status` → "GS1 Status", `:date` → "GS1 Date" (ISO dates are shown
      as "May 2025")
    * `:cover` — `"corporate"` (default), `"none"`, or an industry icon from
      `Docgen.Template.cover_icons/0`

  The Letterhead fills its content controls instead (see
  `Docgen.Render.Docx.Letter`); `meta.hide_graphics` removes the letterhead
  graphics for pre-printed paper. MO localisation settings (logo,
  organisation name, address, website) apply to every template — see
  `Docgen.Render.Docx.Branding`.
  """

  alias Docgen.Document
  alias Docgen.Render.Docx.{Branding, Context, Fields, Letter, Toc, Xml}
  alias Docgen.Template
  alias Docgen.Template.{Macros, StyleMap}

  @document "word/document.xml"
  @document_rels "word/_rels/document.xml.rels"
  @numbering "word/numbering.xml"
  @core "docProps/core.xml"

  @content_types "[Content_Types].xml"
  @settings "word/settings.xml"
  @styles "word/styles.xml"
  @custom "docProps/custom.xml"

  @properties [
    title: "GS1 DocName",
    doc_type: "GS1 DocType",
    description: "GS1 Description",
    version: "GS1 Version",
    status: "GS1 Status",
    date: "GS1 Date"
  ]

  @property_defaults %{version: "1.0", status: "Draft"}

  # The first-page header of GS1 Advanced holds the cover visual.
  @cover %{part: "word/header3.xml", media: "word/media/image6.png", name: "GS1 Cover Page Image"}

  @hyperlink_type "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
  @image_type "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"

  @doc """
  Renders `doc` to a `.docx` binary.

  ## Options

    * `:toc_pages` — `%{bookmark => page}` to fill table-of-contents page
      numbers (see `Docgen.Convert.TocPages`)
    * `:localisation` — overrides `Docgen.Render.Docx.Branding.settings/0`
  """
  @spec render(Document.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def render(%Document{} = doc, opts \\ []) do
    with {:ok, styles} <- StyleMap.fetch(doc.template),
         {:ok, template} <- Template.load(doc.template) do
      template = Macros.strip(template)

      document_xml =
        template
        |> Template.part(@document)
        |> prepare_front_matter(StyleMap.option(styles, :front_matter_until))

      numbering_xml = Template.part(template, @numbering) || ""
      width = text_width(document_xml)

      ctx =
        Context.new(styles,
          text_width: width,
          next_num_id: max_attr(numbering_xml, ~r/<w:num\b[^>]*\bw:numId="(\d+)"/) + 1
        )

      {body, ctx} = Xml.blocks(body_blocks(doc, styles), ctx)

      toc =
        if StyleMap.option(styles, :toc),
          do: Toc.render(Enum.reverse(ctx.headings), Keyword.get(opts, :toc_pages, %{}), width),
          else: []

      front_matter_until = StyleMap.option(styles, :front_matter_until)
      properties = properties(doc, front_matter_until)

      # Without headings there are no contents to list under the heading.
      document_xml =
        if toc == [],
          do: drop_toc_heading(document_xml, StyleMap.option(styles, :front_matter_until)),
          else: document_xml

      template
      |> Template.put_part(@document, document(document_xml, [toc, body], doc, styles))
      |> Template.update_part(@document_rels, &add_links(&1, Enum.reverse(ctx.links)))
      |> add_images(Enum.reverse(ctx.images))
      |> Template.update_part(
        @numbering,
        &add_numbering(&1, Enum.reverse(ctx.numbered_lists), StyleMap.option(styles, :numbering))
      )
      |> Template.update_part(@core, &set_core_title(&1, doc.meta[:title] || doc.meta[:subject]))
      |> apply_font_policy(doc.template)
      |> fill_properties(properties)
      |> hide_document_version(front_matter_until)
      |> preserve_cached_fields(StyleMap.option(styles, :toc))
      |> set_cover(front_matter_until && doc.meta[:cover])
      |> Branding.apply(
        Keyword.get_lazy(opts, :localisation, &Branding.settings/0),
        StyleMap.option(styles, :branding)
      )
      |> then(
        &if(doc.meta[:hide_graphics] in [true, "true"], do: Branding.hide_graphics(&1), else: &1)
      )
      |> Template.to_zip()
    end
  end

  @doc "Bookmark, level, number and text of each heading listed in the TOC."
  @spec toc_headings(Document.t()) :: {:ok, [map()]} | {:error, term()}
  def toc_headings(%Document{} = doc) do
    with {:ok, styles} <- StyleMap.fetch(doc.template) do
      {_body, ctx} = Xml.blocks(body_blocks(doc, styles), Context.new(styles))
      {:ok, Enum.reverse(ctx.headings)}
    end
  end

  defp body_blocks(doc, styles) do
    title =
      [:title, :subtitle]
      |> Enum.filter(&StyleMap.style(styles, &1))
      |> Enum.map(&{&1, doc.meta[&1]})
      |> Enum.reject(fn {_key, text} -> text in [nil, ""] end)
      |> Enum.map(fn {key, text} -> {key, [{:text, text}]} end)

    blocks =
      if StyleMap.option(styles, :normalize_headings),
        do: Document.normalize_headings(doc.blocks),
        else: doc.blocks

    blocks = title ++ blocks

    # Word expects a paragraph after a table, and a body with at least one.
    case List.last(blocks) do
      nil -> [{:paragraph, []}]
      {:table, _, _} -> blocks ++ [{:paragraph, []}]
      _ -> blocks
    end
  end

  ## document.xml

  defp document(document_xml, body, doc, styles) do
    if StyleMap.option(styles, :letter),
      do: Letter.fill(document_xml, doc.meta, body),
      else: replace_body(document_xml, body, StyleMap.option(styles, :front_matter_until))
  end

  defp replace_body(document_xml, body, front_matter_until) do
    {sect_pr, _} = document_xml |> :binary.matches("<w:sectPr") |> List.last()

    head =
      document_xml
      |> binary_part(0, head_end(document_xml, front_matter_until))
      |> drop_orphan_bookmarks()

    tail = binary_part(document_xml, sect_pr, byte_size(document_xml) - sect_pr)
    IO.iodata_to_binary([head, body, tail])
  end

  # The stock Advanced template includes governance fields that are useful for
  # standards but noisy for ordinary reports. Keep the summary, contributors,
  # disclaimer and TOC while removing the version row and change log.
  defp prepare_front_matter(document_xml, nil), do: document_xml

  defp prepare_front_matter(document_xml, _front_matter) do
    document_xml =
      Regex.replace(
        ~r{<w:tr\b(?:(?!</w:tr>).)*?<w:t>Document Version</w:t>.*?</w:tr>}s,
        document_xml,
        ""
      )

    document_xml =
      Regex.replace(
        ~r{<w:p\b(?:(?!</w:p>).)*?<w:t>Log of Changes</w:t>.*?</w:p>\s*<w:tbl>.*?</w:tbl>}s,
        document_xml,
        ""
      )

    Enum.reduce(["Document Summary", "Contributors"], document_xml, fn heading, xml ->
      Regex.replace(
        ~r{<w:p\b(?:(?!</w:p>).)*?<w:t>#{heading}</w:t>.*?</w:p>\s*<w:tbl>.*?</w:tbl>}s,
        xml,
        ""
      )
    end)
  end

  # The contents heading starts its own page, so a bare page break takes its
  # place and its style still marks where the front matter ends.
  defp drop_toc_heading(document_xml, nil), do: document_xml

  defp drop_toc_heading(document_xml, style) do
    Regex.replace(
      ~r{<w:p\b(?:(?!</w:p>).)*?<w:pStyle w:val="#{Regex.escape(style)}"/>.*?</w:p>}s,
      document_xml,
      ~s(<w:p><w:pPr><w:pStyle w:val="#{style}"/><w:pageBreakBefore w:val="0"/><w:spacing w:before="0" w:after="0"/><w:rPr><w:sz w:val="2"/></w:rPr></w:pPr><w:r><w:rPr><w:sz w:val="2"/></w:rPr><w:br w:type="page"/></w:r></w:p>),
      global: false
    )
  end

  # Everything up to <w:body>, or through the end of the paragraph styled
  # `style` when keeping the template's front matter.
  defp head_end(document_xml, nil) do
    {start, len} = :binary.match(document_xml, "<w:body>")
    start + len
  end

  defp head_end(document_xml, style) do
    case :binary.match(document_xml, ~s(<w:pStyle w:val="#{style}"/>)) do
      {pos, _} ->
        {end_pos, len} =
          :binary.match(document_xml, "</w:p>", scope: {pos, byte_size(document_xml) - pos})

        end_pos + len

      :nomatch ->
        head_end(document_xml, nil)
    end
  end

  # Bookmarks whose end was cut off with the template's sample content.
  defp drop_orphan_bookmarks(xml) do
    ends =
      ~r/<w:bookmarkEnd\b[^>]*w:id="(\d+)"/
      |> Regex.scan(xml, capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

    Regex.replace(~r/<w:bookmarkStart\b[^>]*w:id="(\d+)"[^>]*\/>/, xml, fn tag, id ->
      if MapSet.member?(ends, id), do: tag, else: ""
    end)
  end

  ## Document properties & fields

  defp properties(_doc, nil), do: %{}

  defp properties(doc, _front_matter) do
    meta = Map.merge(@property_defaults, Map.reject(doc.meta, fn {_k, v} -> v in [nil, ""] end))

    Map.new(@properties, fn {key, name} ->
      value =
        case {key, meta[key]} do
          {:title, nil} -> "Untitled document"
          {:date, nil} -> format_date(Date.utc_today())
          {:date, date} -> format_date(date)
          {_key, nil} -> ""
          {_key, value} -> to_string(value)
        end

      {name, value}
    end)
  end

  defp format_date(%Date{} = date), do: Calendar.strftime(date, "%B %Y")

  defp format_date(text) when is_binary(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> format_date(date)
      {:error, _} -> text
    end
  end

  defp fill_properties(template, properties) when map_size(properties) == 0, do: template

  defp fill_properties(template, properties) do
    parts =
      Enum.filter(template.order, &(&1 == @document or &1 =~ ~r{^word/(header|footer)\d*\.xml$}))

    parts
    |> Enum.reduce(template, fn part, acc ->
      Template.update_part(acc, part, &Fields.fill(&1, properties))
    end)
    |> Template.update_part(@custom, &Fields.set_properties(&1, properties))
  end

  defp hide_document_version(template, nil), do: template

  # "Release 1.0, Draft, May 2025" — on the cover and at the footer's left,
  # up to the centred copyright.
  defp hide_document_version(template, _front_matter) do
    template.order
    |> Enum.filter(&(&1 =~ ~r{^word/footer\d*\.xml$}))
    |> Enum.reduce(template, fn part, acc ->
      Template.update_part(acc, part, fn xml ->
        Regex.replace(
          ~r{<w:r\b(?:(?!</w:r>).)*?<w:t[^>]*>Release </w:t>.*?(?=<w:r\b[^>]*>(?:(?!</w:r>).)*?<w:ptab\b[^>]*w:alignment="center")}s,
          xml,
          "",
          global: false
        )
      end)
    end)
    |> Template.update_part(@document, fn xml ->
      # Emptied rather than removed: it is the only paragraph of a cover
      # table cell, and the row keeps the cover's layout.
      Regex.replace(
        ~r{(<w:p\b[^>]*>)(<w:pPr>(?:(?!</w:p>).)*?</w:pPr>)?(?:(?!</w:p>).)*?<w:t[^>]*>Release </w:t>.*?</w:p>}s,
        xml,
        "\\1\\2</w:p>",
        global: false
      )
    end)
  end

  ## Font policy

  defp apply_font_policy(template, :advanced) do
    Template.update_part(template, @styles, fn xml ->
      xml
      |> set_style_fonts(~w(Normal GS1Body), "Verdana")
      |> set_style_fonts(
        ~w(Title Heading1 Heading2 Heading3 Heading4 GS1IntroHeading GS1TableHeading),
        "Verdana"
      )
      |> set_style_fonts(~w(GS1TableText Footer PageNumber TOC1 TOC2 TOC3), "Arial")
    end)
  end

  # GS1 Basic's list styles fall back to Normal's 9pt inside 11pt body text,
  # and only numbered lists pack their items. Its headings are no larger
  # than body text (Heading 2 and 3 smaller) and can be stranded at the foot
  # of a page.
  defp apply_font_policy(template, :basic) do
    Template.update_part(template, @styles, fn xml ->
      xml
      |> update_styles(~w(ListBullet ListBullet2 ListBullet3 ListNumber), fn style ->
        # Explicit, as List Bullet 3 inherits packing from List 2.
        style
        |> String.replace("<w:contextualSpacing/>", "")
        |> String.replace("</w:pPr>", ~s(<w:contextualSpacing w:val="0"/></w:pPr>), global: false)
        |> put_run_property(~s(<w:sz w:val="22"/><w:szCs w:val="22"/>))
      end)
      |> update_styles(~w(Heading1 Heading2 Heading3), fn style ->
        if style =~ "<w:keepNext/>",
          do: style,
          else:
            String.replace(style, "<w:pPr>", "<w:pPr><w:keepNext/><w:keepLines/>", global: false)
      end)
      |> heading_size("Heading1", 28, 360)
      |> heading_size("Heading2", 24, 320)
      |> heading_size("Heading3", 22, 280)
    end)
  end

  defp apply_font_policy(template, _template), do: template

  defp heading_size(xml, style_id, size, before) do
    update_styles(xml, [style_id], fn style ->
      style
      |> String.replace(~r{<w:szCs? w:val="\d+"/>}, "")
      |> String.replace(
        ~r{<w:spacing\b[^>]*/>},
        ~s(<w:spacing w:before="#{before}" w:after="120"/>)
      )
      |> put_run_property(~s(<w:sz w:val="#{size}"/><w:szCs w:val="#{size}"/>))
    end)
  end

  defp update_styles(xml, style_ids, fun) do
    Enum.reduce(style_ids, xml, fn style_id, xml ->
      Regex.replace(
        ~r{<w:style\b(?=[^>]*\bw:styleId="#{Regex.escape(style_id)}")[^>]*>.*?</w:style>}s,
        xml,
        fun,
        global: false
      )
    end)
  end

  defp put_run_property(style, props) do
    if String.contains?(style, "<w:rPr>"),
      do: String.replace(style, "</w:rPr>", props <> "</w:rPr>", global: false),
      else: String.replace(style, "</w:style>", "<w:rPr>#{props}</w:rPr></w:style>")
  end

  defp set_style_fonts(xml, style_ids, font) do
    Enum.reduce(style_ids, xml, fn style_id, xml ->
      Regex.replace(
        ~r{<w:style\b(?=[^>]*\bw:styleId="#{Regex.escape(style_id)}")[^>]*>.*?</w:style>}s,
        xml,
        fn style -> set_style_font(style, font) end,
        global: false
      )
    end)
  end

  defp set_style_font(style, font) do
    fonts = ~s(<w:rFonts w:ascii="#{font}" w:hAnsi="#{font}" w:cs="#{font}"/>)
    style = Regex.replace(~r{<w:rFonts\b[^>]*/>}, style, "")

    if String.contains?(style, "<w:rPr>") do
      String.replace(style, "<w:rPr>", "<w:rPr>#{fonts}", global: false)
    else
      String.replace(style, "</w:style>", "<w:rPr>#{fonts}</w:rPr></w:style>")
    end
  end

  # LibreOffice cannot rebuild Word TOC fields reliably and replaces the cached
  # entries with "No table of contents entries found." Preserve Docgen's
  # generated entries and the page numbers populated by the PDF second pass.
  defp preserve_cached_fields(template, false), do: template

  defp preserve_cached_fields(template, true) do
    Template.update_part(template, @settings, fn xml ->
      Regex.replace(~r{<w:updateFields\b[^>]*/>}, xml, "")
    end)
  end

  ## Cover graphic

  defp set_cover(template, choice) when choice in [nil, "", "corporate"], do: template

  defp set_cover(template, "none") do
    Template.update_part(template, @cover.part, fn xml ->
      Regex.replace(cover_drawing(), xml, "")
    end)
  end

  defp set_cover(template, icon) do
    case Template.cover_icon(icon) do
      {:ok, png} ->
        {width, height} = Docgen.Image.size_emu(png)

        template
        |> Template.put_part(@cover.media, png)
        |> Template.update_part(@cover.part, fn xml ->
          Regex.replace(cover_drawing(), xml, fn drawing ->
            # Keep the banner's height; the icon's width follows its aspect ratio.
            [_, cy] = Regex.run(~r/<wp:extent cx="\d+" cy="(\d+)"/, drawing)
            cy = String.to_integer(cy)
            cx = if width && height, do: div(cy * width, height), else: cy

            drawing
            |> String.replace(
              ~r/(<wp:extent|<a:ext) cx="\d+" cy="\d+"/,
              "\\1 cx=\"#{cx}\" cy=\"#{cy}\""
            )
          end)
        end)

      :error ->
        template
    end
  end

  defp cover_drawing,
    do: ~r{<w:drawing>(?:(?!</w:drawing>).)*?name="#{@cover.name}".*?</w:drawing>}s

  # Usable width (twips) = page width minus left/right margins of the final section.
  defp text_width(document_xml) do
    page = attr_int(document_xml, ~r/<w:pgSz\b[^>]*\bw:w="(\d+)"/)
    left = attr_int(document_xml, ~r/<w:pgMar\b[^>]*\bw:left="(\d+)"/)
    right = attr_int(document_xml, ~r/<w:pgMar\b[^>]*\bw:right="(\d+)"/)

    if page && left && right, do: page - left - right, else: 9000
  end

  ## Relationships

  defp add_links(rels, []), do: rels

  defp add_links(rels, links) do
    entries =
      for {id, url} <- links do
        ~s(<Relationship Id="#{id}" Type="#{@hyperlink_type}" Target="#{Xml.escape(url)}" TargetMode="External"/>)
      end

    String.replace(
      rels,
      "</Relationships>",
      [entries, "</Relationships>"] |> IO.iodata_to_binary()
    )
  end

  ## Images

  defp add_images(template, []), do: template

  defp add_images(template, images) do
    rels =
      for {id, part, _image} <- images do
        target = String.trim_leading(part, "word/")
        ~s(<Relationship Id="#{id}" Type="#{@image_type}" Target="#{target}"/>)
      end

    template =
      Enum.reduce(images, template, fn {_id, part, image}, acc ->
        Template.put_part(acc, part, image.data)
      end)
      |> Template.update_part(@document_rels, fn xml ->
        String.replace(xml, "</Relationships>", IO.iodata_to_binary([rels, "</Relationships>"]))
      end)

    Template.update_part(template, @content_types, fn xml ->
      images
      |> Enum.map(fn {_id, part, image} ->
        {part |> Path.extname() |> String.trim_leading("."), image.content_type}
      end)
      |> Enum.uniq()
      |> Enum.reduce(xml, fn {ext, type}, xml ->
        if xml =~ ~r/<Default Extension="#{ext}"/i,
          do: xml,
          else:
            String.replace(
              xml,
              "<Default ",
              ~s(<Default Extension="#{ext}" ContentType="#{type}"/><Default ),
              global: false
            )
      end)
    end)
  end

  ## Numbering

  # One multi-level decimal definition (1. / a. / i.) is appended, plus a
  # `<w:num>` per numbered list with a start override so each restarts at 1.
  defp add_numbering(xml, [], _strategy), do: xml

  # Restart the template's own list definition, keeping its look.
  defp add_numbering(xml, lists, {:template, num_id}) do
    case abstract_for_num(xml, num_id) do
      abstract_id when is_binary(abstract_id) ->
        String.replace(
          xml,
          "</w:numbering>",
          IO.iodata_to_binary([nums(lists, fn _kind -> abstract_id end), "</w:numbering>"])
        )

      nil ->
        add_numbering(xml, lists, :generated)
    end
  end

  defp add_numbering(xml, lists, :generated) do
    number_id = max_attr(xml, ~r/<w:abstractNum\b[^>]*\bw:abstractNumId="(\d+)"/) + 1
    bullet_id = number_id + 1

    nums = nums(lists, fn kind -> if kind == :bullet, do: bullet_id, else: number_id end)
    abstract = abstract_num(number_id, :number) <> abstract_num(bullet_id, :bullet)

    # Schema order: every <w:abstractNum> precedes every <w:num>.
    xml =
      case Regex.run(~r/<w:num\b/, xml, return: :index) do
        [{pos, _}] ->
          binary_part(xml, 0, pos) <> abstract <> binary_part(xml, pos, byte_size(xml) - pos)

        nil ->
          String.replace(xml, "</w:numbering>", abstract <> "</w:numbering>")
      end

    String.replace(xml, "</w:numbering>", IO.iodata_to_binary([nums, "</w:numbering>"]))
  end

  # The definition holding the levels. One that only links to a numbering
  # style (`w:numStyleLink`) is followed to the definition declaring that
  # style, as restarts pointing at the empty link aren't reliably honoured.
  defp abstract_for_num(xml, num_id) do
    with [_, abstract_id] <-
           Regex.run(
             ~r/<w:num\b[^>]*w:numId="#{num_id}"[^>]*>\s*<w:abstractNumId w:val="(\d+)"/,
             xml
           ) do
      abstract =
        Regex.run(
          ~r{<w:abstractNum\b[^>]*w:abstractNumId="#{abstract_id}"[^>]*>.*?</w:abstractNum>}s,
          xml
        )

      with [abstract] <- abstract,
           [_, style] <- Regex.run(~r/<w:numStyleLink w:val="([^"]+)"/, abstract),
           [_, linked_id] <-
             Regex.run(
               ~r{<w:abstractNum\b[^>]*w:abstractNumId="(\d+)"[^>]*>(?:(?!</w:abstractNum>).)*<w:styleLink w:val="#{Regex.escape(style)}"/>}s,
               xml
             ) do
        linked_id
      else
        _ -> abstract_id
      end
    end
  end

  defp nums(lists, abstract_for) do
    for {num_id, ilvl, kind} <- lists do
      ~s(<w:num w:numId="#{num_id}"><w:abstractNumId w:val="#{abstract_for.(kind)}"/>) <>
        ~s(<w:lvlOverride w:ilvl="#{ilvl}"><w:startOverride w:val="1"/></w:lvlOverride></w:num>)
    end
  end

  defp abstract_num(id, kind) do
    formats =
      if kind == :bullet,
        do: Stream.cycle([{"bullet", "\u2022"}, {"bullet", "o"}, {"bullet", "\u25AA"}]),
        else: Stream.cycle(~w(decimal lowerLetter lowerRoman))

    levels =
      for {format, ilvl} <- Enum.zip(formats, 0..8) do
        {format, text} =
          case format do
            {format, text} -> {format, text}
            format -> {format, "%#{ilvl + 1}."}
          end

        ~s(<w:lvl w:ilvl="#{ilvl}"><w:start w:val="1"/><w:numFmt w:val="#{format}"/>) <>
          ~s(<w:lvlText w:val="#{text}"/><w:lvlJc w:val="left"/>) <>
          ~s(<w:pPr><w:ind w:left="#{360 * (ilvl + 1)}" w:hanging="360"/></w:pPr></w:lvl>)
      end

    IO.iodata_to_binary([
      ~s(<w:abstractNum w:abstractNumId="#{id}"><w:multiLevelType w:val="multilevel"/>),
      levels,
      "</w:abstractNum>"
    ])
  end

  ## docProps/core.xml

  defp set_core_title(xml, title) when is_binary(title) and title != "" do
    Regex.replace(~r{<dc:title\s*/>|<dc:title>.*?</dc:title>}s, xml, fn _ ->
      "<dc:title>#{Xml.escape(title)}</dc:title>"
    end)
  end

  defp set_core_title(xml, _title), do: xml

  ## Helpers

  defp max_attr(xml, regex) do
    regex
    |> Regex.scan(xml, capture: :all_but_first)
    |> Enum.map(fn [n] -> String.to_integer(n) end)
    |> Enum.max(fn -> 0 end)
  end

  defp attr_int(xml, regex) do
    case Regex.scan(regex, xml, capture: :all_but_first) |> List.last() do
      [n] -> String.to_integer(n)
      nil -> nil
    end
  end
end

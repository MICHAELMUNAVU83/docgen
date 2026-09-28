defmodule Docgen.Render.Pptx do
  @moduledoc """
  Renders a `Docgen.Document` into a `.pptx` built on the GS1 PowerPoint
  template (`priv/templates/presentation.pptx`, from
  `GS1_Template_PPT_16-9_rev/`).

  The template's 48 sample slides are removed — with every part only they
  used (photos, notes, revision history) — and replaced by the slides
  planned by `Docgen.Render.Pptx.Deck`, each on the matching GS1 layout:

  | Slide | Layout |
  |---|---|
  | title | "Photo 1"–"Photo 6", or "No photo" (`meta.cover`) |
  | agenda | "Agenda" |
  | section | "Blue Divider" |
  | content | "Text Only" |
  | table, image | "Blank" (title only) |

  Masters, layouts and theme are kept untouched, so the result can be
  edited like any deck made from the template. MO localisation settings
  (logo and organisation name) apply as for Word — see
  `Docgen.Render.Docx.Branding.settings/0`.
  """

  alias Docgen.Document
  alias Docgen.Render.Pptx.{Deck, Xml}
  alias Docgen.Template

  @content_types "[Content_Types].xml"
  @presentation "ppt/presentation.xml"
  @presentation_rels "ppt/_rels/presentation.xml.rels"
  @core "docProps/core.xml"
  @app "docProps/app.xml"
  @logo "ppt/media/image1.png"

  @rel_ns "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  @slide_type @rel_ns <> "/slide"
  @layout_type @rel_ns <> "/slideLayout"
  @image_type @rel_ns <> "/image"
  @hyperlink_type @rel_ns <> "/hyperlink"
  @slide_content_type "application/vnd.openxmlformats-officedocument.presentationml.slide+xml"

  # Package parts that describe the template's own editing history; they
  # refer to the removed slides.
  @dropped_rel_types ~w(
    http://schemas.microsoft.com/office/2016/11/relationships/changesInfo
    http://schemas.microsoft.com/office/2015/10/relationships/revisionInfo
    http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail
  )

  # {layout number, <p:ph> attributes of its placeholders}
  @photo_layouts %{
    "photo1" => 1,
    "photo2" => 2,
    "photo3" => 3,
    "photo4" => 4,
    "photo5" => 5,
    "photo6" => 6
  }
  @photo_placeholders %{subtitle: 11, presenter: 12, date: 14}
  @no_photo_layout 9
  @no_photo_placeholders %{subtitle: 15, presenter: 16, date: 17}

  @layouts %{
    agenda: %{layout: 14, body: ~s(type="body" sz="quarter" idx="12"), number: 13},
    section: %{layout: 31, number: 12},
    content: %{layout: 12, body: ~s(idx="11"), number: 12},
    blank: %{layout: 11, number: 12}
  }

  @title_ph ~s(type="title")

  # Slide area below the title, in EMU (from the "Text Only" layout).
  @body_x 447_721
  @body_y 1_091_409
  @body_width 8_241_707
  @body_height 3_312_086
  @caption_height 260_000

  @doc """
  Renders `doc` to a `.pptx` binary.

  ## Options

    * `:localisation` — overrides `Docgen.Render.Docx.Branding.settings/0`
  """
  @spec render(Document.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def render(%Document{} = doc, opts \\ []) do
    with {:ok, template} <- Template.load(:presentation) do
      slides = Deck.build(doc)
      settings = Keyword.get_lazy(opts, :localisation, &Docgen.Render.Docx.Branding.settings/0)

      template
      |> remove_slides()
      |> add_slides(slides)
      |> prune()
      |> Template.update_part(@core, &set_core_title(&1, doc.meta[:title]))
      |> Template.put_part(@app, app_properties(length(slides)))
      |> localise(settings)
      |> Template.to_zip()
    end
  end

  ## Removing the sample slides

  defp remove_slides(template) do
    template
    |> Template.reject_parts(&(&1 =~ ~r{^ppt/(slides|notesSlides)/}))
    |> Template.update_part(@presentation_rels, fn rels ->
      Enum.reduce([@slide_type | @dropped_rel_types], rels, &remove_relationships(&2, &1))
    end)
    |> Template.update_part("_rels/.rels", fn rels ->
      Enum.reduce(@dropped_rel_types, rels, &remove_relationships(&2, &1))
    end)
    |> Template.update_part(@presentation, fn xml ->
      String.replace(xml, ~r{<p:sldIdLst>.*?</p:sldIdLst>}s, "")
    end)
    |> Template.update_part(@content_types, fn types ->
      String.replace(types, ~r{<Override PartName="/ppt/(slides|notesSlides)/[^"]*"[^>]*/>}, "")
    end)
  end

  defp remove_relationships(rels, type) do
    String.replace(rels, ~r{<Relationship\b[^>]*\bType="#{Regex.escape(type)}"[^>]*/>}, "")
  end

  # Drops every part no longer reachable through relationships from the
  # package root, and its content type override.
  defp prune(template) do
    reachable = reachable(template, ["_rels/.rels"], MapSet.new())

    keep? = fn part ->
      part in [@content_types, "_rels/.rels"] or MapSet.member?(reachable, part) or
        (String.ends_with?(part, ".rels") and MapSet.member?(reachable, rels_owner(part)))
    end

    removed = Enum.reject(template.order, keep?)

    template
    |> Template.reject_parts(&(&1 in removed))
    |> Template.update_part(@content_types, fn types ->
      Enum.reduce(removed, types, fn part, types ->
        String.replace(types, ~r{<Override PartName="/#{Regex.escape(part)}"[^>]*/>}, "")
      end)
    end)
  end

  defp reachable(_template, [], seen), do: seen

  defp reachable(template, [rels_part | queue], seen) do
    targets =
      case Template.part(template, rels_part) do
        nil -> []
        xml -> internal_targets(xml, rels_owner(rels_part))
      end

    new = Enum.reject(targets, &(MapSet.member?(seen, &1) or is_nil(Template.part(template, &1))))
    seen = Enum.reduce(new, seen, &MapSet.put(&2, &1))
    reachable(template, queue ++ Enum.map(new, &rels_for/1), seen)
  end

  defp internal_targets(xml, owner) do
    base = if owner == "", do: "", else: Path.dirname(owner)

    ~r{<Relationship\b[^>]*/>}
    |> Regex.scan(xml)
    |> Enum.map(fn [rel] -> rel end)
    |> Enum.reject(&(&1 =~ ~r/TargetMode="External"/))
    |> Enum.flat_map(fn rel ->
      case Regex.run(~r/Target="([^"]+)"/, rel) do
        [_, "/" <> absolute] -> [absolute]
        [_, target] -> [resolve(base, target)]
        nil -> []
      end
    end)
  end

  defp resolve(base, target) do
    path = if base in ["", "."], do: target, else: Path.join(base, target)

    path
    |> String.split("/")
    |> Enum.reduce([], fn
      "..", acc -> tl(acc)
      ".", acc -> acc
      segment, acc -> [segment | acc]
    end)
    |> Enum.reverse()
    |> Enum.join("/")
  end

  # "ppt/_rels/presentation.xml.rels" → "ppt/presentation.xml"; the package
  # relationships ("_rels/.rels") belong to the root, "".
  defp rels_owner("_rels/.rels"), do: ""

  defp rels_owner(rels_part) do
    dir = rels_part |> Path.dirname() |> Path.dirname()
    file = rels_part |> Path.basename() |> String.trim_trailing(".rels")
    if dir == ".", do: file, else: Path.join(dir, file)
  end

  defp rels_for(part) do
    dir = Path.dirname(part)
    rels = "_rels/" <> Path.basename(part) <> ".rels"
    if dir == ".", do: rels, else: Path.join(dir, rels)
  end

  ## Adding slides

  defp add_slides(template, slides) do
    {template, entries, _media} =
      slides
      |> Enum.with_index(1)
      |> Enum.reduce({template, [], 0}, fn {slide, number}, {template, entries, media} ->
        {layout, shapes, rels} = slide_xml(slide, number)
        {rels_xml, template, media} = slide_rels(template, layout, Enum.reverse(rels), media)

        template =
          template
          |> Template.put_part("ppt/slides/slide#{number}.xml", render_xml(Xml.slide(shapes)))
          |> Template.put_part("ppt/slides/_rels/slide#{number}.xml.rels", rels_xml)

        {template, [number | entries], media}
      end)

    numbers = Enum.reverse(entries)

    template
    |> Template.update_part(@presentation_rels, fn rels ->
      entries =
        Enum.map(numbers, fn n ->
          ~s(<Relationship Id="docgenSlide#{n}" Type="#{@slide_type}" Target="slides/slide#{n}.xml"/>)
        end)

      String.replace(rels, "</Relationships>", IO.iodata_to_binary([entries, "</Relationships>"]))
    end)
    |> Template.update_part(@presentation, fn xml ->
      list = [
        "<p:sldIdLst>",
        Enum.map(numbers, &~s(<p:sldId id="#{255 + &1}" r:id="docgenSlide#{&1}"/>)),
        "</p:sldIdLst>"
      ]

      # The slide list follows the master (and notes/handout master) lists.
      String.replace(xml, "<p:sldSz ", IO.iodata_to_binary([list, "<p:sldSz "]), global: false)
    end)
    |> Template.update_part(@content_types, fn types ->
      overrides =
        Enum.map(numbers, fn n ->
          ~s(<Override PartName="/ppt/slides/slide#{n}.xml" ContentType="#{@slide_content_type}"/>)
        end)

      String.replace(types, "</Types>", IO.iodata_to_binary([overrides, "</Types>"]))
    end)
  end

  defp render_xml(iodata), do: IO.iodata_to_binary(iodata)

  # Writes the slide's relationships: the layout first (rId1), then links
  # and images in the order `Xml` numbered them. Images become media parts.
  defp slide_rels(template, layout, rels, media) do
    {entries, {template, media}} =
      rels
      |> Enum.with_index(2)
      |> Enum.map_reduce({template, media}, fn
        {{:link, url}, n}, acc ->
          {~s(<Relationship Id="#{Xml.rel_id(n)}" Type="#{@hyperlink_type}" Target="#{Xml.escape(url)}" TargetMode="External"/>),
           acc}

        {{:image, image}, n}, {template, media} ->
          media = media + 1
          ext = Docgen.Image.extension(image.content_type)
          name = "docgen_image#{media}.#{ext}"

          template =
            template
            |> Template.put_part("ppt/media/" <> name, image.data)
            |> ensure_default_type(ext, image.content_type)

          {~s(<Relationship Id="#{Xml.rel_id(n)}" Type="#{@image_type}" Target="../media/#{name}"/>),
           {template, media}}
      end)

    xml = [
      ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n),
      ~s(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">),
      ~s(<Relationship Id="rId1" Type="#{@layout_type}" Target="../slideLayouts/slideLayout#{layout}.xml"/>),
      entries,
      "</Relationships>"
    ]

    {render_xml(xml), template, media}
  end

  defp ensure_default_type(template, ext, content_type) do
    Template.update_part(template, @content_types, fn types ->
      if types =~ ~r/<Default Extension="#{ext}"/i,
        do: types,
        else:
          String.replace(
            types,
            "<Default ",
            ~s(<Default Extension="#{ext}" ContentType="#{content_type}"/><Default ),
            global: false
          )
    end)
  end

  ## Slides

  # Returns {layout number, shapes iodata, relationships (newest first)}.
  defp slide_xml(%{kind: :title} = slide, _number) do
    {layout, ph} =
      case Map.fetch(@photo_layouts, slide.photo) do
        {:ok, layout} -> {layout, @photo_placeholders}
        :error -> {@no_photo_layout, @no_photo_placeholders}
      end

    fields =
      Enum.flat_map([subtitle: 3, presenter: 4, date: 5], fn {key, id} ->
        case Map.fetch!(slide, key) do
          "" -> []
          value -> [Xml.placeholder(id, "Text #{id}", body_ph(ph[key]), Xml.text(value))]
        end
      end)

    shapes = [title_shape(slide.title), fields]

    {layout, shapes, []}
  end

  defp slide_xml(%{kind: :agenda} = slide, number) do
    spec = @layouts.agenda

    {spec.layout,
     [
       title_shape(slide.title),
       Xml.placeholder(3, "Agenda", spec.body, Xml.bullets(slide.items), autofit: true),
       Xml.slide_number(4, spec.number, number)
     ], []}
  end

  defp slide_xml(%{kind: :section} = slide, number) do
    spec = @layouts.section
    {spec.layout, [title_shape(slide.title), Xml.slide_number(4, spec.number, number)], []}
  end

  defp slide_xml(%{kind: :content} = slide, number) do
    spec = @layouts.content
    {paragraphs, rels} = Xml.blocks(slide.blocks, [])

    {spec.layout,
     [
       title_shape(slide.title),
       Xml.placeholder(3, "Content", spec.body, paragraphs, autofit: true),
       Xml.slide_number(4, spec.number, number)
     ], rels}
  end

  defp slide_xml(%{kind: :table} = slide, number) do
    spec = @layouts.blank

    {caption, y} =
      if slide.caption,
        do:
          {Xml.text_box(
             5,
             "Caption",
             {@body_x, @body_y, @body_width, @caption_height},
             Xml.caption(slide.caption)
           ), @body_y + @caption_height + 60_000},
        else: {[], @body_y + 109_448}

    {table, rels} = Xml.table(3, slide.header_rows, slide.rows, {@body_x, y, @body_width}, [])

    {spec.layout,
     [title_shape(slide.title), caption, table, Xml.slide_number(4, spec.number, number)], rels}
  end

  defp slide_xml(%{kind: :image} = slide, number) do
    spec = @layouts.blank
    caption_height = if slide.caption, do: @caption_height + 60_000, else: 0
    {x, y, cx, cy} = fit(slide.image, @body_width, @body_height - caption_height)

    caption =
      if slide.caption,
        do:
          Xml.text_box(5, "Caption", {@body_x, y + cy + 60_000, @body_width, @caption_height}, [
            ~s(<a:p><a:pPr algn="ctr" marL="0" indent="0"><a:buNone/></a:pPr>),
            ~s(<a:r><a:rPr lang="en-GB" sz="1100" i="1" dirty="0"/><a:t>),
            Xml.escape(slide.caption),
            "</a:t></a:r></a:p>"
          ]),
        else: []

    {spec.layout,
     [
       title_shape(slide.title),
       Xml.picture(3, Xml.rel_id(2), slide.caption || "", {x, y, cx, cy}),
       caption,
       Xml.slide_number(4, spec.number, number)
     ], [{:image, slide.image}]}
  end

  defp body_ph(idx), do: ~s(type="body" sz="quarter" idx="#{idx}")

  defp title_shape(""), do: []
  defp title_shape(title), do: Xml.placeholder(2, "Title", @title_ph, Xml.text(title))

  # Largest size with the image's aspect ratio (4:3 when unknown) that fits,
  # centred horizontally and top-aligned. Images are enlarged at most 2×.
  defp fit(image, max_w, max_h) do
    {w, h, max_scale} =
      case image do
        %{width: w, height: h} when is_integer(w) and is_integer(h) and w > 0 and h > 0 ->
          {w, h, 2}

        _ ->
          {4, 3, :infinity}
      end

    scale = min(min(max_w / w, max_h / h), max_scale)
    cx = trunc(w * scale)
    cy = trunc(h * scale)
    {@body_x + div(max_w - cx, 2), @body_y, cx, cy}
  end

  ## Properties

  defp set_core_title(xml, title) when is_binary(title) and title != "" do
    Regex.replace(~r{<dc:title\s*/>|<dc:title>.*?</dc:title>}s, xml, fn _ ->
      "<dc:title>#{Xml.escape(title)}</dc:title>"
    end)
  end

  defp set_core_title(xml, _title), do: xml

  defp app_properties(slides) do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" \
    xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">\
    <Template>GS1 Template 2026</Template><PresentationFormat>On-screen Show (16:9)</PresentationFormat>\
    <Slides>#{slides}</Slides><Notes>0</Notes><HiddenSlides>0</HiddenSlides></Properties>\
    """
  end

  ## Localisation

  defp localise(template, settings) do
    template
    |> replace_footer(settings[:organisation])
    |> replace_logo(settings[:logo])
  end

  # The masters' footer reads "© GS1".
  defp replace_footer(template, org) when org in [nil, ""], do: template

  defp replace_footer(template, org) do
    template.order
    |> Enum.filter(&(&1 =~ ~r{^ppt/slide(Masters|Layouts)/[^/]+\.xml$}))
    |> Enum.reduce(template, fn part, acc ->
      Template.update_part(acc, part, fn xml ->
        String.replace(xml, "<a:t>© GS1</a:t>", "<a:t>© #{Xml.escape(org)}</a:t>")
      end)
    end)
  end

  defp replace_logo(template, path) when path in [nil, ""], do: template

  defp replace_logo(template, path) do
    with {:ok, data} <- File.read(path),
         %{} = image <- Docgen.Image.new(path, data),
         true <- image.content_type in ~w(image/png image/jpeg) do
      ext = Docgen.Image.extension(image.content_type)
      new_part = "ppt/media/docgen_logo.#{ext}"
      old_target = "../media/" <> Path.basename(@logo)
      new_target = "../media/" <> Path.basename(new_part)

      template
      |> Template.put_part(new_part, data)
      |> ensure_default_type(ext, image.content_type)
      |> retarget_logo(old_target, new_target, image)
    else
      _ -> template
    end
  end

  # Points master/layout relationships at the new logo and gives the
  # pictures that show it the logo's aspect ratio (keeping their height).
  defp retarget_logo(template, old_target, new_target, image) do
    template.order
    |> Enum.filter(&(&1 =~ ~r{^ppt/slide(Masters|Layouts)/_rels/[^/]+\.xml\.rels$}))
    |> Enum.reduce(template, fn rels_part, acc ->
      xml = Template.part(acc, rels_part)

      ids =
        ~r/<Relationship\b[^>]*Id="([^"]+)"[^>]*Target="#{Regex.escape(old_target)}"/
        |> Regex.scan(xml, capture: :all_but_first)
        |> List.flatten()

      if ids == [] do
        acc
      else
        acc
        |> Template.put_part(
          rels_part,
          String.replace(xml, ~s(Target="#{old_target}"), ~s(Target="#{new_target}"))
        )
        |> Template.update_part(rels_owner(rels_part), &resize_pictures(&1, ids, image))
      end
    end)
  end

  defp resize_pictures(xml, ids, %{width: w, height: h}) when is_integer(w) and is_integer(h) do
    Regex.replace(~r{<p:pic>.*?</p:pic>}s, xml, fn pic ->
      if Enum.any?(ids, &String.contains?(pic, ~s(r:embed="#{&1}"))) do
        case Regex.run(~r/<a:ext cx="\d+" cy="(\d+)"/, pic) do
          [_, cy] ->
            cx = div(String.to_integer(cy) * w, h)

            Regex.replace(~r/<a:ext cx="\d+" cy="(\d+)"/, pic, "<a:ext cx=\"#{cx}\" cy=\"\\1\"",
              global: false
            )

          nil ->
            pic
        end
      else
        pic
      end
    end)
  end

  defp resize_pictures(xml, _ids, _image), do: xml
end

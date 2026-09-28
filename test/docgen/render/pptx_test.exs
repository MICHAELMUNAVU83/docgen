defmodule Docgen.Render.PptxTest do
  use ExUnit.Case, async: true

  import Docgen.DocxHelpers

  alias Docgen.Render.Pptx.Deck

  @markdown """
  # Rollout

  ## Why it matters

  More **product data** — see [GS1](https://www.gs1.org).

  - One QR code
    - Checkout
  - Built on the GTIN

  ## Plan

  1. Pilot
  2. Scan

  # Results

  ## Pilot figures

  Table: Results by region

  | Region | Stores |
  |---|---|
  | North | 120 |

  # Next steps

  ## Timeline

  Phase two starts in Q1.
  """

  defp parse(markdown \\ @markdown, meta \\ %{}),
    do: Docgen.parse(markdown, :markdown, template: :presentation, meta: meta)

  defp render!(doc, opts \\ []) do
    {:ok, pptx} = Docgen.to_pptx(doc, Keyword.put_new(opts, :localisation, []))
    unzip!(pptx)
  end

  defp slide_layout(parts, n) do
    [_, layout] =
      Regex.run(~r/slideLayout(\d+)\.xml/, parts["ppt/slides/_rels/slide#{n}.xml.rels"])

    String.to_integer(layout)
  end

  describe "package" do
    test "replaces the sample slides with the generated ones" do
      doc = parse(@markdown, %{title: "Rollout"})
      parts = render!(doc)
      slides = Deck.build(doc)

      slide_parts = Enum.filter(Map.keys(parts), &(&1 =~ ~r{^ppt/slides/slide\d+\.xml$}))
      assert length(slide_parts) == length(slides)

      presentation = parts["ppt/presentation.xml"]
      assert length(Regex.scan(~r/<p:sldId /, presentation)) == length(slides)
      refute Enum.any?(Map.keys(parts), &String.starts_with?(&1, "ppt/notesSlides/"))
      refute Map.has_key?(parts, "ppt/changesInfos/changesInfo1.xml")
      refute Map.has_key?(parts, "docProps/thumbnail.jpeg")
      assert parts["docProps/app.xml"] =~ "<Slides>#{length(slides)}</Slides>"
      assert parts["docProps/core.xml"] =~ "<dc:title>Rollout</dc:title>"
    end

    test "is well-formed and self-consistent" do
      parts = render!(parse())
      types = parts["[Content_Types].xml"]
      defaults = ~r/<Default Extension="([^"]+)"/ |> Regex.scan(types) |> Enum.map(&List.last/1)

      overrides =
        ~r/<Override PartName="\/([^"]+)"/ |> Regex.scan(types) |> Enum.map(&List.last/1)

      for {name, data} <- parts, name =~ ~r/\.(xml|rels)$/ do
        assert well_formed?(data), "#{name} is not well-formed"
      end

      for name <- overrides, do: assert(Map.has_key?(parts, name), "override for missing #{name}")

      for name <- Map.keys(parts), name != "[Content_Types].xml" do
        ext = name |> String.split(".") |> List.last() |> String.downcase()
        assert name in overrides or ext in defaults, "no content type for #{name}"
      end

      for {rels, xml} <- parts, String.ends_with?(rels, ".rels") do
        base = rels |> Path.dirname() |> Path.dirname()

        for [rel] <- Regex.scan(~r/<Relationship\b[^>]*\/>/, xml),
            not (rel =~ "TargetMode=\"External\"") do
          [_, target] = Regex.run(~r/Target="([^"]+)"/, rel)
          path = target |> then(&Path.expand(&1, "/" <> base)) |> String.trim_leading("/")
          assert Map.has_key?(parts, path), "#{rels} points at missing #{target}"
        end
      end
    end

    test "keeps masters, layouts and theme but drops unused sample media" do
      parts = render!(parse())
      assert Map.has_key?(parts, "ppt/slideMasters/slideMaster4.xml")
      assert Map.has_key?(parts, "ppt/slideLayouts/slideLayout39.xml")
      assert Map.has_key?(parts, "ppt/media/image1.png")

      {:ok, template} = Docgen.Template.load(:presentation)
      assert map_size(parts) < map_size(template.parts)
    end
  end

  describe "slides" do
    test "use the matching GS1 layouts" do
      parts = render!(parse(@markdown, %{cover: "photo2"}))
      # title, agenda, section, content, content, section, table, section, content
      assert Enum.map(1..9, &slide_layout(parts, &1)) == [2, 14, 31, 12, 12, 31, 11, 31, 12]
    end

    test "the title slide has no photo when asked" do
      assert slide_layout(render!(parse(@markdown, %{cover: "none"})), 1) == 9
    end

    test "fill the title slide placeholders" do
      meta = %{title: "Rollout", subtitle: "Review", presenter: "Jo, GS1", date: "2026-09-28"}
      slide = render!(parse(@markdown, meta))["ppt/slides/slide1.xml"]

      assert slide =~ "<a:t>Rollout</a:t>"
      assert slide =~ ~s(idx="11"/>) and slide =~ "<a:t>Review</a:t>"
      assert slide =~ "<a:t>Jo, GS1</a:t>"
      assert slide =~ "<a:t>28 September 2026</a:t>"
    end

    test "render lists, formatting and links" do
      parts = render!(parse())
      slide = parts["ppt/slides/slide4.xml"]

      assert slide =~ ~s(<a:rPr lang="en-GB" b="1" dirty="0"/><a:t>product data</a:t>)
      assert slide =~ ~s(<a:pPr lvl="1"/><a:r><a:rPr lang="en-GB" dirty="0"/><a:t>Checkout)
      assert slide =~ ~s(<a:hlinkClick r:id="rId2"/>)

      assert parts["ppt/slides/_rels/slide4.xml.rels"] =~
               ~s(Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://www.gs1.org" TargetMode="External")

      assert parts["ppt/slides/slide5.xml"] =~ ~s(<a:buAutoNum type="arabicPeriod" startAt="2"/>)
    end

    test "render tables with a header row and caption" do
      slide = render!(parse())["ppt/slides/slide7.xml"]
      assert slide =~ "<a:tbl>"
      assert slide =~ "<a:t>Results by region</a:t>"
      assert slide =~ ~s(<a:schemeClr val="tx2"/>)
      assert length(Regex.scan(~r/<a:tr /, slide)) == 2
    end

    test "embed images as media" do
      png = File.read!(Application.app_dir(:docgen, "priv/templates/icons/retail.png"))
      image = Docgen.Image.new("logo.png", png)
      doc = %{parse("## Logo\n\nText.") | blocks: [{:image, image, "Our logo"}]}
      parts = render!(doc)

      assert parts["ppt/media/docgen_image1.png"] == png
      assert parts["ppt/slides/slide2.xml"] =~ ~s(<a:blip r:embed="rId2"/>)
      assert parts["ppt/slides/_rels/slide2.xml.rels"] =~ ~s(Target="../media/docgen_image1.png")
    end
  end

  describe "localisation" do
    @tag :tmp_dir
    test "replaces the footer organisation and the logo", %{tmp_dir: tmp_dir} do
      png = File.read!(Application.app_dir(:docgen, "priv/templates/icons/retail.png"))
      logo = Path.join(tmp_dir, "logo.png")
      File.write!(logo, png)

      parts = render!(parse(), localisation: [organisation: "GS1 Kenya", logo: logo])

      assert parts["ppt/slideMasters/slideMaster2.xml"] =~ "<a:t>© GS1 Kenya</a:t>"
      refute parts["ppt/slideMasters/slideMaster2.xml"] =~ "<a:t>© GS1</a:t>"
      assert parts["ppt/media/docgen_logo.png"] == png
      rels = parts["ppt/slideMasters/_rels/slideMaster2.xml.rels"]
      assert rels =~ ~s(Target="../media/docgen_logo.png")
      refute rels =~ ~s(Target="../media/image1.png")
    end
  end

  test "Docgen dispatches presentations to .pptx" do
    doc = parse()

    assert Docgen.native_format(doc) ==
             {"pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation"}

    assert {:ok, <<"PK", _::binary>>} = Docgen.to_native(doc)
    assert Docgen.supported_template?(:presentation)
  end

  @tag :libreoffice
  test "converts to PDF with LibreOffice" do
    start_supervised!({Docgen.Convert.Limiter, name: __MODULE__.Limiter, max_concurrency: 1})
    assert {:ok, <<"%PDF", _::binary>>} = Docgen.to_pdf(parse(), limiter: __MODULE__.Limiter)
  end
end

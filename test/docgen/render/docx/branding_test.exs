defmodule Docgen.Render.Docx.BrandingTest do
  use ExUnit.Case, async: true

  import Docgen.DocxHelpers

  @moduletag :tmp_dir

  defp render(template, localisation) do
    doc = Docgen.parse("Hello.", :markdown, template: template, meta: %{title: "T"})
    {:ok, docx} = Docgen.to_docx(doc, localisation: localisation)
    unzip!(docx)
  end

  test "no settings leave the template untouched" do
    parts = render(:letterhead, [])
    assert parts["word/footer3.xml"] =~ "GS1 AISBL"
    refute Map.has_key?(parts, "word/media/docgen_logo.png")
  end

  test "organisation, website and address", %{tmp_dir: _} do
    parts =
      render(:letterhead,
        organisation: "GS1 Kenya",
        website: "www.gs1kenya.org",
        address: "GS1 Kenya\nWestlands\nNairobi"
      )

    footer = parts["word/footer3.xml"]
    refute footer =~ "Avenue Louise"
    assert footer =~ ">Westlands<"
    assert parts["word/footer2.xml"] =~ "www.gs1kenya.org"
    assert well_formed?(footer)

    assert render(:advanced, organisation: "GS1 Kenya")["word/footer2.xml"] =~ "GS1 Kenya"
  end

  test "the logo is swapped and drawings take its aspect ratio", %{tmp_dir: tmp_dir} do
    logo = Path.join(tmp_dir, "logo.png")
    File.write!(logo, Docgen.DocxBuilder.png(200, 100))

    for {template, header} <- [
          basic: "word/_rels/header1.xml.rels",
          advanced: "word/_rels/header2.xml.rels",
          letterhead: "word/_rels/header2.xml.rels"
        ] do
      parts = render(template, logo: logo)

      assert parts["word/media/docgen_logo.png"] == File.read!(logo)

      assert parts[header] =~ ~s(Target="media/docgen_logo.png"),
             "#{template} header not retargeted"
    end

    # 2:1 logo → width is twice the drawing's height.
    xml = render(:letterhead, logo: logo)["word/header2.xml"]

    [_, cx, cy] =
      Regex.run(
        ~r/<wp:extent cx="(\d+)" cy="(\d+)"\/>(?:(?!<\/w:drawing>).)*LogoHeaderPrimary/s,
        xml
      )

    assert String.to_integer(cx) == 2 * String.to_integer(cy)
  end

  test "an unreadable logo is ignored" do
    parts = render(:basic, logo: "/nonexistent/logo.png")
    refute Map.has_key?(parts, "word/media/docgen_logo.png")
  end

  test "a replacement containing the original text doesn't loop" do
    assert render(:advanced, organisation: "GS1 AISBL Kenya")["word/footer2.xml"] =~
             "GS1 AISBL Kenya"
  end
end

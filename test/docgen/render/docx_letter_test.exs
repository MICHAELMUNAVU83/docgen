defmodule Docgen.Render.DocxLetterTest do
  use ExUnit.Case, async: true

  import Docgen.DocxHelpers

  alias Docgen.Render.Docx.Letter

  @meta %{
    sender_name: "Jane Doe",
    sender_title: "CEO",
    sender_address: "GS1 Kenya\nNairobi",
    recipient: "John Smith\nACME Ltd\nMombasa",
    date: "2026-09-28",
    subject: "Membership & fees"
  }

  defp render(meta \\ @meta, opts \\ []) do
    doc =
      Docgen.parse("Thank you for joining.\n\n- one\n- two\n\n## Next steps\n\nMore.", :markdown,
        template: :letterhead,
        meta: meta
      )

    {:ok, docx} = Docgen.to_docx(doc, opts)
    unzip!(docx)
  end

  setup_all do
    %{parts: render()}
  end

  test "all parts are well-formed", %{parts: parts} do
    for {name, data} <- parts, Path.extname(name) in ~w(.xml .rels) do
      assert well_formed?(data), "#{name} is not well-formed"
    end
  end

  test "content controls are replaced by their values", %{parts: parts} do
    xml = parts["word/document.xml"]

    refute xml =~ "<w:sdt>"
    refute xml =~ "Click here"
    refute xml =~ "PlaceholderText"

    for text <- [
          "Jane Doe",
          "CEO",
          "GS1 Kenya",
          "Nairobi",
          "John Smith",
          "ACME Ltd",
          "Mombasa",
          "September 28, 2026",
          "Membership &amp; fees",
          "Sir or Madam",
          "Kind regards"
        ] do
      assert xml =~ text, "missing #{text}"
    end

    # Multi-line values keep their line breaks.
    assert xml =~ ~s(GS1 Kenya</w:t><w:br/><w:t xml:space="preserve">Nairobi)
  end

  test "the letter body is rendered where the body control was", %{parts: parts} do
    xml = parts["word/document.xml"]
    [before, rest] = String.split(xml, "Thank you for joining.", parts: 2)

    assert before =~ "Sir or Madam"
    assert rest =~ "Kind regards"
    # Bullets get generated numbering; headings are bold.
    assert rest =~ ~r{<w:numPr><w:ilvl w:val="0"/><w:numId w:val="\d+"/></w:numPr>.*?one}s
    assert parts["word/numbering.xml"] =~ ~s(<w:numFmt w:val="bullet"/>)
    assert rest =~ ~r{<w:b/><w:bCs/></w:rPr><w:t xml:space="preserve">Next steps}
  end

  test "bookmarks stay paired", %{parts: parts} do
    xml = parts["word/document.xml"]
    starts = Regex.scan(~r/<w:bookmarkStart[^>]*w:id="(\d+)"/, xml, capture: :all_but_first)
    ends = Regex.scan(~r/<w:bookmarkEnd[^>]*w:id="(\d+)"/, xml, capture: :all_but_first)
    assert Enum.sort(starts) == Enum.sort(ends)
  end

  test "values: recipient split, defaults and overrides" do
    assert %{recipient_name: "A", recipient_address: "B\nC", salutation: "Sir or Madam"} =
             Letter.values(%{recipient: " A\nB\nC "})

    assert %{salutation: "Ms Smith", closing: "Yours sincerely"} =
             Letter.values(%{salutation: "Ms Smith", closing: "Yours sincerely"})

    assert Letter.values(%{date: "not a date"}).date == "not a date"
  end

  test "letterhead graphics can be hidden for pre-printed paper" do
    shown = render()
    hidden = render(Map.put(@meta, :hide_graphics, "true"))

    assert shown["word/header3.xml"] =~ "<w:drawing>"
    refute hidden["word/header3.xml"] =~ "<w:drawing>"
    refute hidden["word/header2.xml"] =~ "<w:drawing>"
    assert well_formed?(hidden["word/header3.xml"])
  end

  test "list items are packed, with the usual gap after the list", %{parts: parts} do
    xml = parts["word/document.xml"]

    assert xml =~
             ~r{<w:numPr>.*?</w:numPr><w:spacing w:after="80"/></w:pPr><w:r><w:t xml:space="preserve">one}

    assert xml =~
             ~r{<w:spacing w:before="160"/></w:pPr><w:r><w:rPr><w:b/><w:bCs/></w:rPr><w:t xml:space="preserve">Next steps}
  end
end

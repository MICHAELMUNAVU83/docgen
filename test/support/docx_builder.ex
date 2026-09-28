defmodule Docgen.DocxBuilder do
  @moduledoc """
  Builds `.docx` packages from raw WordprocessingML body XML for tests.

  The package mimics a document authored in Word: its own styles (including
  a custom heading style), bullet and decimal numbering, an external
  hyperlink relationship and an embedded PNG (`rIdImg`).
  """

  @w "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
  @r "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

  def build(body_xml, opts \\ []) do
    document = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="#{@w}" xmlns:r="#{@r}"
      xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
      xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
      xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"
      xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><w:body>#{body_xml}<w:sectPr/></w:body></w:document>
    """

    files = [
      {"[Content_Types].xml", content_types()},
      {"_rels/.rels", root_rels()},
      {"word/document.xml", Keyword.get(opts, :document, document)},
      {"word/_rels/document.xml.rels", document_rels()},
      {"word/styles.xml", styles()},
      {"word/numbering.xml", numbering()},
      {"word/media/image1.png", png(4, 2)}
    ]

    {:ok, {_, zip}} =
      :zip.create(~c"test.docx", Enum.map(files, fn {n, d} -> {String.to_charlist(n), d} end), [
        :memory
      ])

    zip
  end

  @doc "A valid `width`×`height` PNG."
  def png(width, height) do
    raw = for _ <- 1..height, into: <<>>, do: <<0>> <> :binary.copy(<<255, 0, 0>>, width)

    IO.iodata_to_binary([
      <<0x89, "PNG", 13, 10, 26, 10>>,
      chunk("IHDR", <<width::32, height::32, 8, 2, 0, 0, 0>>),
      chunk("IDAT", :zlib.compress(raw)),
      chunk("IEND", "")
    ])
  end

  defp chunk(type, data),
    do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>

  ## Paragraph helpers for building bodies

  def p(text, opts \\ []) do
    ppr =
      [
        opts[:style] && ~s(<w:pStyle w:val="#{opts[:style]}"/>),
        opts[:num] &&
          ~s(<w:numPr><w:ilvl w:val="#{elem(opts[:num], 1)}"/><w:numId w:val="#{elem(opts[:num], 0)}"/></w:numPr>),
        opts[:outline] && ~s(<w:outlineLvl w:val="#{opts[:outline]}"/>)
      ]
      |> Enum.filter(& &1)
      |> Enum.join()

    runs = if is_binary(text), do: r(text), else: Enum.join(text)
    "<w:p><w:pPr>#{ppr}</w:pPr>#{runs}</w:p>"
  end

  def r(text, rpr \\ ""),
    do: ~s(<w:r><w:rPr>#{rpr}</w:rPr><w:t xml:space="preserve">#{text}</w:t></w:r>)

  def image_run do
    """
    <w:r><w:drawing><wp:inline><wp:extent cx="1828800" cy="914400"/><wp:docPr id="1" name="Picture 1"/>
    <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
    <pic:pic><pic:blipFill><a:blip r:embed="rIdImg"/></pic:blipFill></pic:pic>
    </a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
    """
  end

  ## Package parts

  defp content_types do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Default Extension="png" ContentType="image/png"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """
  end

  defp root_rels do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """
  end

  defp document_rels do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    <Relationship Id="rIdNum" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
    <Relationship Id="rIdLink" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://www.gs1.org/" TargetMode="External"/>
    <Relationship Id="rIdImg" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>
    </Relationships>
    """
  end

  defp styles do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <w:styles xmlns:w="#{@w}">
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
    <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/></w:style>
    <w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/><w:basedOn w:val="Normal"/></w:style>
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr><w:outlineLvl w:val="1"/></w:pPr></w:style>
    <w:style w:type="paragraph" w:styleId="MySection"><w:name w:val="My Section"/><w:basedOn w:val="Heading2"/></w:style>
    <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/></w:style>
    <w:style w:type="paragraph" w:styleId="SourceCode"><w:name w:val="Source Code"/><w:basedOn w:val="Normal"/></w:style>
    <w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="caption"/><w:basedOn w:val="Normal"/></w:style>
    <w:style w:type="paragraph" w:styleId="ListBullet"><w:name w:val="List Bullet"/><w:basedOn w:val="Normal"/><w:pPr><w:numPr><w:numId w:val="1"/></w:numPr></w:pPr></w:style>
    <w:style w:type="character" w:styleId="Strong"><w:name w:val="Strong"/></w:style>
    </w:styles>
    """
  end

  defp numbering do
    level = fn ilvl, fmt -> ~s(<w:lvl w:ilvl="#{ilvl}"><w:numFmt w:val="#{fmt}"/></w:lvl>) end

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <w:numbering xmlns:w="#{@w}">
    <w:abstractNum w:abstractNumId="0">#{level.(0, "bullet")}#{level.(1, "bullet")}</w:abstractNum>
    <w:abstractNum w:abstractNumId="1">#{level.(0, "decimal")}#{level.(1, "lowerLetter")}</w:abstractNum>
    <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
    <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
    <w:num w:numId="3"><w:abstractNumId w:val="1"/></w:num>
    </w:numbering>
    """
  end
end

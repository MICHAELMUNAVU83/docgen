defmodule Docgen.Render.Docx.Toc do
  @moduledoc """
  Writes a table of contents as a real `TOC` field whose cached result lists
  the document's headings.

  Each entry links to its heading's bookmark and ends in a `PAGEREF` field.
  Page numbers can't be known without laying the document out, so they are
  taken from `pages` (`%{bookmark => page}`, see `Docgen.Convert.TocPages`)
  when available and left blank otherwise; Word refreshes them on open
  because the document is marked `updateFields`.
  """

  alias Docgen.Render.Docx.Xml

  @instruction ~s( TOC \\o "1-3" \\h \\z \\u )
  # Where entry text starts, per level: past the TOC styles' left indents
  # (0, 504, 936) with room for "1", "1.1" and "1.1.1".
  @text_tabs %{1 => 504, 2 => 1170, 3 => 1710}

  @spec render([map()], %{String.t() => pos_integer()}, pos_integer()) :: iodata()
  def render([], _pages, _text_width), do: []

  def render(headings, pages, text_width) do
    begin = [
      ~s(<w:r><w:fldChar w:fldCharType="begin"/></w:r>),
      ~s(<w:r><w:instrText xml:space="preserve">#{Xml.escape(@instruction)}</w:instrText></w:r>),
      ~s(<w:r><w:fldChar w:fldCharType="separate"/></w:r>)
    ]

    finish = [
      ~s(<w:p><w:pPr><w:pStyle w:val="TOC1"/></w:pPr>),
      ~s(<w:r><w:fldChar w:fldCharType="end"/></w:r>),
      # The document content starts on a new page after the contents.
      ~s(<w:r><w:br w:type="page"/></w:r></w:p>)
    ]

    [first | rest] = headings

    [
      entry(first, pages, text_width, begin),
      Enum.map(rest, &entry(&1, pages, text_width, [])),
      finish
    ]
  end

  defp entry(heading, pages, text_width, prefix) do
    page = pages |> Map.get(heading.bookmark, "") |> to_string()
    indent = Map.fetch!(@text_tabs, heading.level)

    [
      ~s(<w:p><w:pPr><w:pStyle w:val="TOC#{heading.level}"/><w:tabs>),
      ~s(<w:tab w:val="left" w:pos="#{indent}"/>),
      ~s(<w:tab w:val="right" w:leader="dot" w:pos="#{text_width}"/></w:tabs></w:pPr>),
      prefix,
      ~s(<w:hyperlink w:anchor="#{heading.bookmark}" w:history="1">),
      ~s(<w:r><w:t xml:space="preserve">#{Xml.escape(heading.number)}</w:t></w:r><w:r><w:tab/></w:r>),
      ~s(<w:r><w:t xml:space="preserve">#{Xml.escape(heading.text)}</w:t></w:r><w:r><w:tab/></w:r>),
      Xml.field(" PAGEREF #{heading.bookmark} \\h ", page, "<w:rPr><w:webHidden/></w:rPr>"),
      "</w:hyperlink></w:p>"
    ]
  end
end

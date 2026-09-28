defmodule Docgen.PdfBuilder do
  @moduledoc """
  Writes minimal PDFs for tests, using the standard (non-embedded) Helvetica
  fonts so `pdftohtml` can read them without fixture files.

      Docgen.PdfBuilder.build([
        [{:text, 72, 760, 20, :bold, "Title"}, {:text, 72, 730, 11, :regular, "Body"}]
      ])

  Each page is a list of `{:text, x, y, size, :regular | :bold, text}` with
  PDF coordinates (origin bottom-left, A4 = 595×842).
  """

  @fonts %{regular: "F1", bold: "F2"}

  def build(pages) do
    page_count = length(pages)
    # Objects: 1 catalog, 2 pages, 3 regular font, 4 bold font, then a
    # page + content stream pair per page.
    page_ids = for i <- 0..(page_count - 1), do: 5 + i * 2

    objects =
      [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [#{Enum.map_join(page_ids, " ", &"#{&1} 0 R")}] /Count #{page_count} >>",
        font("Helvetica"),
        font("Helvetica-Bold")
      ] ++
        Enum.flat_map(Enum.zip(pages, page_ids), fn {items, id} ->
          stream = content(items)

          [
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] " <>
              "/Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents #{id + 1} 0 R >>",
            "<< /Length #{byte_size(stream)} >>\nstream\n#{stream}\nendstream"
          ]
        end)

    header = "%PDF-1.4\n"

    {body, xref_offset} =
      objects
      |> Enum.with_index(1)
      |> Enum.map_reduce(byte_size(header), fn {obj, n}, offset ->
        chunk = "#{n} 0 obj\n#{obj}\nendobj\n"
        {{chunk, offset}, offset + byte_size(chunk)}
      end)

    chunks = Enum.map(body, &elem(&1, 0))
    positions = Enum.map(body, &elem(&1, 1))

    xref =
      "xref\n0 #{length(objects) + 1}\n0000000000 65535 f \n" <>
        Enum.map_join(positions, "", &(String.pad_leading("#{&1}", 10, "0") <> " 00000 n \n"))

    IO.iodata_to_binary([
      header,
      chunks,
      xref,
      "trailer\n<< /Size #{length(objects) + 1} /Root 1 0 R >>\nstartxref\n#{xref_offset}\n%%EOF\n"
    ])
  end

  defp font(base),
    do: "<< /Type /Font /Subtype /Type1 /BaseFont /#{base} /Encoding /WinAnsiEncoding >>"

  defp content(items) do
    Enum.map_join(items, "\n", fn {:text, x, y, size, weight, text} ->
      "BT /#{@fonts[weight]} #{size} Tf #{x} #{y} Td (#{escape(text)}) Tj ET"
    end)
  end

  # PDF literal strings are bytes; map to WinAnsi (Latin-1 plus the bullet).
  defp escape(text) do
    text
    |> String.split("•")
    |> Enum.map_join(<<149>>, &:unicode.characters_to_binary(&1, :utf8, :latin1))
    |> String.replace("\\", "\\\\")
    |> String.replace("(", "\\(")
    |> String.replace(")", "\\)")
  end
end

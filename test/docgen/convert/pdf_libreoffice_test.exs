defmodule Docgen.Convert.PdfLibreOfficeTest do
  # Runs real LibreOffice; excluded automatically when `soffice` is missing.
  use ExUnit.Case, async: false

  @moduletag :libreoffice
  @moduletag timeout: :timer.minutes(3)

  setup do
    start_supervised!({Docgen.Convert.Limiter, name: __MODULE__.Limiter, max_concurrency: 2})
    :ok
  end

  test "renders Markdown to a PDF containing the text" do
    doc = Docgen.parse("# PDF Check\n\nHello from **Docgen**.\n\n- one\n- two", :markdown)
    assert {:ok, <<"%PDF", _::binary>> = pdf} = Docgen.to_pdf(doc, limiter: __MODULE__.Limiter)

    if pdftotext = Docgen.SystemCheck.find(:pdftotext) do
      path =
        Path.join(System.tmp_dir!(), "docgen-check-#{System.unique_integer([:positive])}.pdf")

      File.write!(path, pdf)
      {text, 0} = System.cmd(pdftotext, [path, "-"])
      File.rm(path)

      assert text =~ "PDF Check"
      assert text =~ "Hello from Docgen."
    end
  end

  test "concurrent conversions all succeed" do
    doc = Docgen.parse("Concurrent run", :text)

    1..3
    |> Enum.map(fn _ -> Task.async(fn -> Docgen.to_pdf(doc, limiter: __MODULE__.Limiter) end) end)
    |> Task.await_many(:timer.minutes(3))
    |> Enum.each(&assert({:ok, <<"%PDF", _::binary>>} = &1))
  end
end

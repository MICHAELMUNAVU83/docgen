defmodule Docgen.Convert.PdfTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Docgen.Convert.{Limiter, Pdf}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} = context do
    limiter = Module.concat(__MODULE__, "L#{context.line}")
    start_supervised!({Limiter, name: limiter, max_concurrency: 1})
    %{opts: [limiter: limiter, profile_dir: Path.join(tmp_dir, "profiles")]}
  end

  # A stand-in for soffice: a shell script with `body` that sees the real args.
  defp fake_soffice(tmp_dir, body) do
    path = Path.join(tmp_dir, "soffice")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  @write_pdf """
  while [ $# -gt 0 ]; do
    case "$1" in --outdir) shift; out="$1";; -env:*) echo "$1" > "$out_log";; esac
    shift
  done
  printf '%%PDF-1.7 fake' > "$out/document.pdf"
  """

  test "returns the PDF LibreOffice wrote", %{tmp_dir: tmp_dir, opts: opts} do
    log = Path.join(tmp_dir, "args")
    soffice = fake_soffice(tmp_dir, "out_log=#{log}\n" <> @write_pdf)

    assert {:ok, "%PDF-1.7 fake"} = Pdf.from_docx("docx", [soffice: soffice] ++ opts)
    assert File.read!(log) =~ "-env:UserInstallation=file://#{tmp_dir}/profiles/slot-0"
  end

  test "cleans up its work directory", %{tmp_dir: tmp_dir, opts: opts} do
    soffice = fake_soffice(tmp_dir, "echo \"$@\" > #{tmp_dir}/args\n" <> @write_pdf)
    {:ok, _} = Pdf.from_docx("docx", [soffice: soffice] ++ opts)

    [input] = Regex.run(~r{\S+/document\.docx}, File.read!(Path.join(tmp_dir, "args")))
    refute File.exists?(Path.dirname(input))
  end

  test "non-zero exit is a conversion failure", %{tmp_dir: tmp_dir, opts: opts} do
    soffice = fake_soffice(tmp_dir, "echo 'Error: source file could not be loaded'\nexit 1\n")

    log =
      capture_log(fn ->
        assert {:error, :conversion_failed} = Pdf.from_docx("docx", [soffice: soffice] ++ opts)
      end)

    assert log =~ "source file could not be loaded"
  end

  test "success without a PDF is a conversion failure", %{tmp_dir: tmp_dir, opts: opts} do
    soffice = fake_soffice(tmp_dir, "exit 0\n")

    capture_log(fn ->
      assert {:error, :conversion_failed} = Pdf.from_docx("docx", [soffice: soffice] ++ opts)
    end)
  end

  test "kills LibreOffice on timeout and resets the slot profile", %{tmp_dir: tmp_dir, opts: opts} do
    profile = Path.join([tmp_dir, "profiles", "slot-0"])
    File.mkdir_p!(profile)
    soffice = fake_soffice(tmp_dir, "exec sleep 10\n")

    capture_log(fn ->
      assert {:error, :timeout} = Pdf.from_docx("docx", [soffice: soffice, timeout: 100] ++ opts)
    end)

    refute File.exists?(profile)
  end

  test "missing soffice", %{opts: opts} do
    assert {:error, :soffice_not_found} = Pdf.from_docx("docx", [soffice: nil] ++ opts)
  end

  test "documents with a TOC are converted twice to fill in page numbers", %{
    tmp_dir: tmp_dir,
    opts: opts
  } do
    runs = Path.join(tmp_dir, "runs")
    File.mkdir_p!(runs)

    # Keeps a copy of every .docx it is given.
    soffice =
      fake_soffice(tmp_dir, """
      n=$(ls #{runs} | wc -l | tr -d ' ')
      while [ $# -gt 0 ]; do
        case "$1" in --outdir) shift; out="$1";; *.docx) cp "$1" #{runs}/run$n.docx;; esac
        shift
      done
      printf '%%PDF-1.7 fake' > "$out/document.pdf"
      """)

    pdftotext = Path.join(tmp_dir, "pdftotext")

    File.write!(
      pdftotext,
      "#!/bin/sh\nprintf 'Cover\\fTable of Contents\\nIntro\\nOutro\\fIntro\\fMore\\fOutro\\n'\n"
    )

    File.chmod!(pdftotext, 0o755)

    doc =
      Docgen.parse("# Intro\n\nText.\n\n# Outro\n\nEnd.", :markdown,
        template: :advanced,
        promote_title: false
      )

    assert {:ok, "%PDF-1.7 fake"} =
             Docgen.to_pdf(doc, [soffice: soffice, pdftotext: pdftotext] ++ opts)

    assert ["run0.docx", "run1.docx"] = runs |> File.ls!() |> Enum.sort()
    second = runs |> Path.join("run1.docx") |> File.read!() |> Docgen.DocxHelpers.unzip!()
    xml = second["word/document.xml"]

    assert xml =~ ~r{PAGEREF _TocDocgen1 \\h </w:instrText>.*?<w:t xml:space="preserve">3</w:t>}s
    assert xml =~ ~r{PAGEREF _TocDocgen2 \\h </w:instrText>.*?<w:t xml:space="preserve">5</w:t>}s
  end
end

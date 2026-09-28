defmodule Mix.Tasks.Docgen.Render do
  @shortdoc "Renders a text, Markdown, Word or PDF file to a GS1-styled .docx (and PDF)"

  @moduledoc """
  Renders a `.txt`, `.md`, `.docx` or `.pdf` file to a `.docx` using a GS1
  template.

      $ mix docgen.render notes.md
      $ mix docgen.render notes.txt -o out/notes.docx --title "Report" --subtitle "Draft"
      $ mix docgen.render notes.md --pdf
      $ mix docgen.render report.docx        # writes report-gs1.docx
      $ mix docgen.render spec.md --template advanced --title "Supplier Guide" \\
          --doc-type Guideline --cover retail

  ## Options

    * `-o`, `--output` — output path (default: input path with `.docx`, or
      `-gs1.docx` when the input is itself a `.docx`)
    * `--template` — `basic` (default) or `advanced`
    * `--title`, `--subtitle` — document metadata
    * `--doc-type`, `--description`, `--version`, `--status`, `--date`,
      `--cover` — GS1 Advanced cover fields (`--cover` is `corporate`, `none`
      or an industry icon such as `retail`)
    * `--pdf` — also write a PDF next to the `.docx` (needs LibreOffice)
  """

  use Mix.Task

  @meta_switches [:title, :subtitle, :doc_type, :description, :version, :status, :date, :cover]

  @switches [output: :string, template: :string, pdf: :boolean] ++
              Enum.map(@meta_switches, &{&1, :string})

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    case OptionParser.parse(args, strict: @switches, aliases: [o: :output]) do
      {opts, [input], []} ->
        render(input, opts)

      _ ->
        Mix.raise("Usage: mix docgen.render INPUT [-o OUTPUT] [--title T] [--subtitle S] [--pdf]")
    end
  end

  defp render(input, opts) do
    template = opts |> Keyword.get(:template, "basic") |> template!()
    output = Keyword.get_lazy(opts, :output, fn -> default_output(input) end)
    meta = Map.new(@meta_switches, &{&1, opts[&1]})

    doc =
      case Docgen.ingest(File.read!(input), Docgen.format_for(input),
             template: template,
             meta: meta
           ) do
        {:ok, doc} -> doc
        {:error, reason} -> Mix.raise("Could not read #{input}: #{inspect(reason)}")
      end

    for warning <- doc.warnings, do: Mix.shell().info([:yellow, "warning: ", :reset, warning])

    case Docgen.to_docx(doc) do
      {:ok, docx} ->
        File.mkdir_p!(Path.dirname(output))
        File.write!(output, docx)
        Mix.shell().info("Wrote #{output}")
        if opts[:pdf], do: write_pdf(docx, Path.rootname(output) <> ".pdf")

      {:error, reason} ->
        Mix.raise("Could not render #{input}: #{inspect(reason)}")
    end
  end

  defp default_output(input) do
    output = Path.rootname(input) <> ".docx"

    if Path.expand(output) == Path.expand(input),
      do: Path.rootname(input) <> "-gs1.docx",
      else: output
  end

  defp write_pdf(docx, output) do
    # The app isn't started by this task, so bring up the converter's limiter.
    case Docgen.Convert.Limiter.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Docgen.Convert.Pdf.from_docx(docx) do
      {:ok, pdf} ->
        File.write!(output, pdf)
        Mix.shell().info("Wrote #{output}")

      {:error, reason} ->
        Mix.raise("PDF conversion failed: #{inspect(reason)}")
    end
  end

  defp template!(name) do
    Enum.find(Docgen.Template.names(), &(Atom.to_string(&1) == name)) ||
      Mix.raise("Unknown template #{inspect(name)}")
  end
end

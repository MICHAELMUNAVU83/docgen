defmodule Docgen do
  @moduledoc """
  Turns text and Markdown into documents styled with the GS1 Word templates.

      doc = Docgen.parse(markdown, :markdown, meta: %{subtitle: "Draft"})
      {:ok, docx} = Docgen.to_docx(doc)
      {:ok, pdf} = Docgen.to_pdf(doc)
  """

  alias Docgen.Convert
  alias Docgen.Document
  alias Docgen.Ingest
  alias Docgen.Render

  @type format :: :markdown | :text
  @type file_format :: format() | :docx | :pdf

  @doc """
  Parses `content` into a `Docgen.Document`.

  ## Options

    * `:template` — `:basic` (default), `:advanced` or `:letterhead`
    * `:meta` — metadata such as `:title` and `:subtitle`
    * `:promote_title` — see `Docgen.Ingest.Markdown.parse/2` (default `true`)
    * `:images` — images referenced from Markdown (see `to_markdown/1`)
  """
  @spec parse(String.t(), format(), keyword()) :: Document.t()
  def parse(content, format, opts \\ []) do
    content = ensure_utf8(content)

    doc =
      case format do
        :markdown -> Ingest.Markdown.parse(content, opts)
        :text -> Ingest.Text.parse(content, opts)
      end

    %{doc | template: Keyword.get(opts, :template, :basic)}
  end

  @doc """
  Imports content of any supported format.

  Unlike `parse/3`, this also handles binary `.docx` and `.pdf` input, which
  can fail (corrupt file, missing `pdftohtml`, scanned PDF without text…).
  Options are as for `parse/3`.
  """
  @spec ingest(binary(), file_format(), keyword()) :: {:ok, Document.t()} | {:error, term()}
  def ingest(content, format, opts \\ [])

  def ingest(content, format, opts) when format in [:markdown, :text],
    do: {:ok, parse(content, format, opts)}

  def ingest(content, :docx, opts), do: content |> Ingest.Docx.parse(opts) |> put_template(opts)
  def ingest(content, :pdf, opts), do: content |> Ingest.Pdf.parse(opts) |> put_template(opts)

  defp put_template({:ok, doc}, opts),
    do: {:ok, %{doc | template: Keyword.get(opts, :template, :basic)}}

  defp put_template(error, _opts), do: error

  @doc """
  Guesses the input format from a file name.
  """
  @spec format_for(String.t()) :: file_format()
  def format_for(filename) do
    case filename |> Path.extname() |> String.downcase() do
      ext when ext in ~w(.md .markdown) -> :markdown
      ".docx" -> :docx
      ".pdf" -> :pdf
      _ -> :text
    end
  end

  @doc """
  Renders a document as editable Markdown.

  Returns `{markdown, images}`; pass `images` back to `parse/3` (option
  `:images`) to keep embedded images. See `Docgen.Render.Markdown`.
  """
  @spec to_markdown(Document.t()) :: {String.t(), %{String.t() => Docgen.Image.t()}}
  def to_markdown(%Document{} = doc), do: Render.Markdown.render(doc)

  @doc """
  True if `template` can be rendered to `.docx`/PDF yet.
  """
  @spec supported_template?(Document.template()) :: boolean()
  def supported_template?(template),
    do: match?({:ok, _}, Docgen.Template.StyleMap.fetch(template))

  @doc """
  A download file name for `doc` with extension `ext`, based on its title.
  """
  @spec filename(Document.t(), String.t()) :: String.t()
  def filename(%Document{} = doc, ext) do
    slug =
      (doc.meta[:title] || "")
      |> String.normalize(:nfd)
      |> String.replace(~r/[^A-Za-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 80)

    if(slug == "", do: "document", else: slug) <> "." <> ext
  end

  @doc """
  Renders a document to preview HTML.
  """
  @spec to_html(Document.t()) :: Phoenix.HTML.safe()
  def to_html(%Document{} = doc), do: Render.Html.render(doc)

  @doc """
  Renders a document to a `.docx` binary. Options are passed to
  `Docgen.Render.Docx.render/2`.
  """
  @spec to_docx(Document.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def to_docx(%Document{} = doc, opts \\ []), do: Render.Docx.render(doc, opts)

  @doc """
  Renders a document to PDF (via `.docx` and LibreOffice).

  Templates with a table of contents are converted twice: the first PDF is
  used to find each heading's page (`Docgen.Convert.TocPages`), then the
  document is rendered again with those page numbers. If the lookup fails
  the first PDF is returned.

  Options are passed to `Docgen.Convert.Pdf.from_docx/2` and
  `Docgen.Convert.TocPages.find/3`.
  """
  @spec to_pdf(Document.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def to_pdf(%Document{} = doc, opts \\ []) do
    with {:ok, docx} <- to_docx(doc),
         {:ok, pdf} <- Convert.Pdf.from_docx(docx, opts) do
      case Render.Docx.toc_headings(doc) do
        {:ok, [_ | _] = headings} -> with_toc_pages(doc, pdf, headings, opts)
        _ -> {:ok, pdf}
      end
    end
  end

  defp with_toc_pages(doc, first_pdf, headings, opts) do
    with {:ok, pages} when map_size(pages) > 0 <- Convert.TocPages.find(first_pdf, headings, opts),
         {:ok, docx} <- Render.Docx.render(doc, toc_pages: pages),
         {:ok, pdf} <- Convert.Pdf.from_docx(docx, opts) do
      {:ok, pdf}
    else
      _ -> {:ok, first_pdf}
    end
  end

  # Uploaded text isn't always UTF-8; fall back to Latin-1, which never fails.
  defp ensure_utf8(content) do
    if String.valid?(content), do: content, else: :unicode.characters_to_binary(content, :latin1)
  end
end

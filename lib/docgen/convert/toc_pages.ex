defmodule Docgen.Convert.TocPages do
  @moduledoc """
  Finds the page each table-of-contents heading lands on in a rendered PDF.

  LibreOffice keeps a `.docx` TOC's cached page numbers rather than
  recomputing them, so PDF export runs twice: render, convert, look up the
  headings here, then render again with the page numbers filled in. The
  TOC's size doesn't change between passes, so the pagination holds.

  Headings are searched in document order, starting after the contents pages
  (every heading also appears *in* the TOC, which is followed by a page
  break). A heading matches a whole line of page text, optionally preceded
  by its outline number, so body text mentioning it doesn't count.
  """

  @doc """
  Maps heading bookmarks to 1-based page numbers from the PDF's text.
  """
  @spec find(binary(), [map()], keyword()) ::
          {:ok, %{String.t() => pos_integer()}} | {:error, term()}
  def find(pdf, headings, opts \\ [])
  def find(_pdf, [], _opts), do: {:ok, %{}}

  def find(pdf, headings, opts) do
    case Keyword.get_lazy(opts, :pdftotext, fn -> Docgen.SystemCheck.find(:pdftotext) end) do
      nil ->
        {:error, :pdftotext_not_found}

      exe ->
        path =
          Path.join(System.tmp_dir!(), "docgen-toc-#{System.unique_integer([:positive])}.pdf")

        File.write!(path, pdf)

        try do
          case Docgen.Cmd.run(exe, ["-enc", "UTF-8", path, "-"], :timer.seconds(60)) do
            {:ok, text} -> {:ok, pages_from_text(String.split(text, "\f"), headings)}
            {:error, reason} -> {:error, reason}
          end
        after
          File.rm(path)
        end
    end
  end

  @doc """
  Pure lookup over per-page text (exposed for testing).
  """
  @spec pages_from_text([String.t()], [map()]) :: %{String.t() => pos_integer()}
  def pages_from_text(_pages, []), do: %{}

  def pages_from_text(pages, headings) do
    lines = Enum.map(pages, fn page -> page |> String.split("\n") |> Enum.map(&normalize/1) end)
    texts = Enum.map(lines, &Enum.join(&1, " "))

    toc_start = Enum.find_index(texts, &String.contains?(&1, "table of contents")) || 0
    last = headings |> List.last() |> Map.fetch!(:text) |> normalize()
    toc_end = find_page(texts, from: toc_start, match: &String.contains?(&1, last)) || toc_start

    {found, _cursor} =
      Enum.map_reduce(headings, toc_end + 1, fn heading, cursor ->
        line = heading_line(heading)

        case find_page(lines,
               from: cursor,
               match: &Enum.any?(&1, fn l -> Regex.match?(line, l) end)
             ) do
          nil -> {nil, cursor}
          index -> {{heading.bookmark, index + 1}, index}
        end
      end)

    found |> Enum.reject(&is_nil/1) |> Map.new()
  end

  defp find_page(pages, from: from, match: match) do
    pages
    |> Enum.drop(from)
    |> Enum.find_index(match)
    |> case do
      nil -> nil
      index -> index + from
    end
  end

  # "Scope" or "1.2 Scope" as a whole line.
  defp heading_line(heading),
    do: ~r/\A(?:[\d.]+\s+)?#{Regex.escape(normalize(heading.text))}\z/u

  defp normalize(text),
    do: text |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()
end

defmodule Docgen.Render.Docx.Letter do
  @moduledoc """
  Fills the GS1 Letterhead's content controls (`<w:sdt>`).

  Controls are recognised by their placeholder text and replaced by their
  value ("unwrapped"), keeping the paragraph formatting, so no grey
  "Click here to…" placeholder can end up in a printed letter. The
  letter-body control is replaced by the rendered document.

  Meta keys: `:sender_name`, `:sender_title`, `:sender_address`, `:date`,
  `:recipient` (first line is the name, the rest the address — or
  `:recipient_name` / `:recipient_address`), `:subject`, `:salutation`,
  `:closing`. Multi-line values keep their line breaks.
  """

  alias Docgen.Render.Docx.Xml

  # Placeholder text → meta key. Checked in order.
  @controls [
    {"Recipient’s Name", :recipient_name},
    {"Recipient’s Address", :recipient_address},
    {"Sender’s Address", :sender_address},
    {"Sender’s Title", :sender_title},
    {"Sender’s Name", :sender_name},
    {"select a date", :date},
    {"the Subject", :subject},
    {"the Salutation", :salutation},
    {"body of the letter", :body},
    {"the Closing", :closing}
  ]

  @defaults %{
    sender_name: "",
    sender_title: "",
    sender_address: "",
    recipient_name: "",
    recipient_address: "",
    subject: "",
    salutation: "Sir or Madam",
    closing: "Kind regards"
  }

  @doc "Fills `document_xml` from `meta`, putting `body_xml` in the letter body."
  @spec fill(String.t(), map(), iodata()) :: String.t()
  def fill(document_xml, meta, body_xml) do
    values = values(meta)

    ~r{<w:sdt>.*?</w:sdt>}s
    |> Regex.replace(document_xml, fn sdt -> replace(sdt, values, body_xml) end)
    |> drop_orphan_bookmarks()
  end

  @doc "The values each control receives."
  @spec values(map()) :: %{atom() => String.t()}
  def values(meta) do
    meta = Map.reject(meta, fn {_k, v} -> v in [nil, ""] end)
    {name, address} = split_recipient(meta[:recipient])

    @defaults
    |> Map.merge(%{recipient_name: name, recipient_address: address})
    |> Map.merge(
      Map.take(
        meta,
        ~w(sender_name sender_title sender_address subject salutation closing recipient_name recipient_address)a
      )
    )
    |> Map.put(:date, format_date(meta[:date] || Date.utc_today()))
    |> Map.new(fn {k, v} -> {k, to_string(v || "")} end)
  end

  defp split_recipient(nil), do: {"", ""}

  defp split_recipient(text) do
    case text |> String.trim() |> String.split(~r/\r?\n/, parts: 2) do
      [name, address] -> {String.trim(name), String.trim(address)}
      [name] -> {String.trim(name), ""}
    end
  end

  # The template shows dates as "MMMM d, yyyy".
  defp format_date(%Date{} = date), do: Calendar.strftime(date, "%B %-d, %Y")

  defp format_date(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> format_date(date)
      {:error, _} -> text
    end
  end

  defp replace(sdt, values, body_xml) do
    content =
      case Regex.run(~r{<w:sdtContent>(.*)</w:sdtContent>}s, sdt) do
        [_, content] -> content
        nil -> ""
      end

    text =
      ~r{<w:t\b[^>]*>([^<]*)</w:t>} |> Regex.scan(content, capture: :all_but_first) |> Enum.join()

    case Enum.find(@controls, fn {label, _key} -> String.contains?(text, label) end) do
      nil -> sdt
      {_label, :body} -> IO.iodata_to_binary(body_xml)
      {_label, key} -> unwrap(sdt, content, Map.get(values, key, ""))
    end
  end

  # Block-level controls hold a paragraph; inline ones hold runs.
  defp unwrap(sdt, content, value) do
    # Placeholder (grey) styling must not carry over to the value.
    rpr =
      case Regex.run(~r{<w:sdtPr>.*?(<w:rPr>.*?</w:rPr>)}s, sdt) do
        [_, rpr] -> String.replace(rpr, ~s(<w:rStyle w:val="PlaceholderText"/>), "")
        nil -> ""
      end

    runs = runs(value, rpr)

    if content =~ ~r/<w:p[ >]/ do
      ppr =
        case Regex.run(~r{<w:p[ >].*?(<w:pPr>.*?</w:pPr>)}s, content) do
          [_, ppr] -> ppr
          nil -> ""
        end

      "<w:p>#{ppr}#{runs}</w:p>"
    else
      runs
    end
  end

  defp runs("", _rpr), do: ""

  defp runs(value, rpr) do
    lines =
      value
      |> String.split(~r/\r?\n/)
      |> Enum.map(&~s(<w:t xml:space="preserve">#{Xml.escape(&1)}</w:t>))

    "<w:r>#{rpr}#{Enum.join(lines, "<w:br/>")}</w:r>"
  end

  # Bookmarks split between a replaced control and the rest of the body.
  defp drop_orphan_bookmarks(xml) do
    ids = fn tag ->
      ~r/<w:#{tag}\b[^>]*w:id="(\d+)"/
      |> Regex.scan(xml, capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()
    end

    starts = ids.("bookmarkStart")
    ends = ids.("bookmarkEnd")

    Regex.replace(~r/<w:(bookmarkStart|bookmarkEnd)\b[^>]*w:id="(\d+)"[^>]*\/>/, xml, fn tag,
                                                                                         kind,
                                                                                         id ->
      paired = if kind == "bookmarkStart", do: ends, else: starts
      if MapSet.member?(paired, id), do: tag, else: ""
    end)
  end
end

defmodule DocgenWeb.HistoryController do
  use DocgenWeb, :controller

  alias Docgen.History

  def download(conn, %{"id" => id} = params) do
    entry = History.get!(id)
    {ext, content_type} = native_format(entry)

    case Map.get(params, "format", ext) do
      "pdf" ->
        case Docgen.Convert.Pdf.from_office(entry.docx, ext) do
          {:ok, pdf} ->
            send_download(conn, {:binary, pdf},
              filename: Path.rootname(entry.filename) <> ".pdf",
              content_type: "application/pdf"
            )

          {:error, _reason} ->
            conn
            |> put_flash(:error, "PDF conversion failed. The .#{ext} download still works.")
            |> redirect(to: ~p"/history")
        end

      _ ->
        send_download(conn, {:binary, entry.docx},
          filename: entry.filename,
          content_type: content_type
        )
    end
  end

  defp native_format(%{template: "presentation"}), do: Docgen.native_format(:presentation)
  defp native_format(_entry), do: Docgen.native_format(:basic)
end

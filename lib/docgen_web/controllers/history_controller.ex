defmodule DocgenWeb.HistoryController do
  use DocgenWeb, :controller

  alias Docgen.History

  @docx "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  def download(conn, %{"id" => id} = params) do
    entry = History.get!(id)

    case Map.get(params, "format", "docx") do
      "pdf" ->
        case Docgen.Convert.Pdf.from_docx(entry.docx) do
          {:ok, pdf} ->
            send_download(conn, {:binary, pdf},
              filename: Path.rootname(entry.filename) <> ".pdf",
              content_type: "application/pdf"
            )

          {:error, _reason} ->
            conn
            |> put_flash(:error, "PDF conversion failed. The .docx download still works.")
            |> redirect(to: ~p"/history")
        end

      _ ->
        send_download(conn, {:binary, entry.docx}, filename: entry.filename, content_type: @docx)
    end
  end
end

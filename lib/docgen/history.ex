defmodule Docgen.History do
  @moduledoc """
  The history of generated documents.
  """

  import Ecto.Query

  require Logger

  alias Docgen.History.Entry
  alias Docgen.Repo

  @doc """
  Records a generated `.docx` (or `.pptx` for presentations). `source` is
  the editor text it came from.
  """
  @spec record(Docgen.Document.t(), binary(), keyword()) :: {:ok, Entry.t()} | {:error, term()}
  def record(%Docgen.Document{} = doc, docx, opts \\ []) do
    %Entry{}
    |> Entry.changeset(%{
      title: doc.meta[:title] || doc.meta[:subject] || "Untitled document",
      template: Atom.to_string(doc.template),
      source_format: Keyword.get(opts, :format, "markdown"),
      source: Keyword.get(opts, :source, ""),
      meta: stringify(doc.meta),
      filename: Docgen.filename(doc, doc |> Docgen.native_format() |> elem(0)),
      docx: docx
    })
    |> Repo.insert()
  end

  @doc """
  Like `record/3`, but never fails: history is best-effort, so a database
  outage must not block a download.
  """
  @spec record_quietly(Docgen.Document.t(), binary(), keyword()) :: :ok
  def record_quietly(doc, docx, opts \\ []) do
    case record(doc, docx, opts) do
      {:ok, _entry} -> :ok
      {:error, reason} -> Logger.warning("Could not save document history: #{inspect(reason)}")
    end

    :ok
  rescue
    error ->
      Logger.warning("Could not save document history: #{Exception.message(error)}")
      :ok
  end

  @doc "Most recent entries first, without their `.docx` data."
  @spec list(keyword()) :: [Entry.t()]
  def list(opts \\ []) do
    Entry
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
  end

  @doc "Fetches an entry including its `.docx`."
  @spec get!(integer() | String.t()) :: Entry.t()
  def get!(id) do
    Entry
    |> select([e], e)
    |> select_merge([e], %{docx: e.docx})
    |> Repo.get!(id)
  end

  @doc "Deletes an entry."
  @spec delete(Entry.t()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Entry{} = entry), do: Repo.delete(entry)

  # Ecto maps are JSON; keep plain strings only.
  defp stringify(meta) do
    for {key, value} <- meta,
        is_binary(value) or is_boolean(value),
        into: %{},
        do: {to_string(key), value}
  end
end

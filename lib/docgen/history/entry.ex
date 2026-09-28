defmodule Docgen.History.Entry do
  @moduledoc """
  A generated document kept for the history page: its source, metadata and
  the `.docx` or `.pptx` produced, in the `docx` field (PDFs are regenerated
  from it on demand).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @templates ~w(basic advanced letterhead presentation)
  @formats ~w(markdown text)

  schema "generated_documents" do
    field :title, :string
    field :template, :string
    field :source_format, :string
    field :source, :string, default: ""
    field :meta, :map, default: %{}
    field :filename, :string
    field :docx, :binary, load_in_query: false

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:title, :template, :source_format, :source, :meta, :filename, :docx])
    |> validate_required([:title, :template, :source_format, :filename, :docx])
    |> validate_inclusion(:template, @templates)
    |> validate_inclusion(:source_format, @formats)
    |> validate_length(:title, max: 255)
  end
end

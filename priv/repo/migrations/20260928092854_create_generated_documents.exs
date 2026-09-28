defmodule Docgen.Repo.Migrations.CreateGeneratedDocuments do
  use Ecto.Migration

  def change do
    create table(:generated_documents) do
      add :title, :string, null: false
      add :template, :string, null: false
      add :source_format, :string, null: false
      add :source, :text, null: false, default: ""
      add :meta, :map, null: false, default: %{}
      add :filename, :string, null: false
      add :docx, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:generated_documents, [:inserted_at])
  end
end

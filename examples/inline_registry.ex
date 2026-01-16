defmodule Example.InlineRegistry do
  @moduledoc """
  Example: Inline table registry (all tables in one file).

  This approach is simpler but makes the file grow large with many tables.
  """
  use Sieve.Registry

  tables do
    table "profiles", %{
      schema: MyApp.Accounts.Profile,
      pk: :id,
      owner_key: :user_id,
      readable: [:id, :display_name, :bio, :inserted_at, :updated_at],
      writable: [:display_name, :bio]
    }

    table "todos", %{
      schema: MyApp.Tasks.Todo,
      pk: :id,
      owner_key: :user_id,
      readable: [:id, :title, :done, :inserted_at, :updated_at],
      writable: [:title, :done]
    }

    table "posts", %{
      schema: MyApp.Content.Post,
      pk: :id,
      owner_key: :author_id,
      readable: [:id, :title, :body, :published, :inserted_at, :updated_at],
      writable: [:title, :body, :published]
    }
  end
end

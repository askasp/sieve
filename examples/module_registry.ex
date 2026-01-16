defmodule Example.ModuleRegistry do
  @moduledoc """
  Example: Module-based table registry (recommended for codegen).

  Each table is defined in its own module implementing Sieve.TableSpec.
  This makes it easier to:
  - Generate table definitions from schema introspection
  - Edit tables individually in a visual editor
  - Keep the codebase organized with many tables
  """
  use Sieve.Registry

  register_modules([
    Example.Tables.Profiles,
    Example.Tables.Todos,
    Example.Tables.Posts
  ])
end

# Each table in a separate file:

defmodule Example.Tables.Profiles do
  @moduledoc """
  Table definition for profiles.
  """
  @behaviour Sieve.TableSpec

  @impl true
  def spec do
    %{
      schema: MyApp.Accounts.Profile,
      pk: :id,
      owner_key: :user_id,
      readable: [:id, :display_name, :bio, :inserted_at, :updated_at],
      writable: [:display_name, :bio]
    }
  end

  @impl true
  def name, do: "profiles"
end

defmodule Example.Tables.Todos do
  @moduledoc """
  Table definition for todos.
  """
  @behaviour Sieve.TableSpec

  @impl true
  def spec do
    %{
      schema: MyApp.Tasks.Todo,
      pk: :id,
      owner_key: :user_id,
      readable: [:id, :title, :done, :inserted_at, :updated_at],
      writable: [:title, :done]
    }
  end

  @impl true
  def name, do: "todos"
end

defmodule Example.Tables.Posts do
  @moduledoc """
  Table definition for posts.
  """
  @behaviour Sieve.TableSpec

  @impl true
  def spec do
    %{
      schema: MyApp.Content.Post,
      pk: :id,
      owner_key: :author_id,
      readable: [:id, :title, :body, :published, :inserted_at, :updated_at],
      writable: [:title, :body, :published]
    }
  end

  @impl true
  def name, do: "posts"
end

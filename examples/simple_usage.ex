# Simple Usage Example

## 1. Create your schema

```elixir
# Generated with: mix phx.gen.schema Blog.Post posts title:string body:text user_id:integer
defmodule MyApp.Blog.Post do
  use Ecto.Schema
  import Ecto.Changeset

  schema "posts" do
    field :title, :string
    field :body, :string
    field :user_id, :integer
    timestamps()
  end

  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body, :user_id])
    |> validate_required([:title, :body])
  end
end
```

## 2. Create a policy

```elixir
defmodule MyApp.Blog.PostPolicy do
  use Sieve.Policy,
    schema: MyApp.Blog.Post,
    name: "posts",
    owner_key: :user_id

  # That's it! Default implementations are auto-generated.
  # Override callbacks only if you need custom logic.
end
```

## 3. Register policies

```elixir
defmodule MyApp.PolicyRegistry do
  use Sieve.Registry,
    policies: [
      MyApp.Blog.PostPolicy,
      MyApp.Accounts.ProfilePolicy,
      MyApp.Tasks.TodoPolicy
    ]
end
```

## 4. Forward to Sieve.Router (that's it!)

```elixir
# In your Phoenix router.ex
scope "/api", MyAppWeb do
  pipe_through [:api, :auth]  # :auth must set current_user

  forward "/", Sieve.Router,
    registry: MyApp.PolicyRegistry,
    repo: MyApp.Repo,
    actor_key: :current_user
end
```

**No controller needed!** Just forward to `Sieve.Router` with your config.

## 6. Use the API

```bash
# List posts
curl -H "Authorization: Bearer $TOKEN" \
  "http://localhost:4000/api/posts?select=id,title&order=title.asc&limit=10"

# Get single post
curl -H "Authorization: Bearer $TOKEN" \
  "http://localhost:4000/api/posts/123"

# Update post
curl -X PATCH -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title": "New Title", "body": "Updated content"}' \
  "http://localhost:4000/api/posts/123"
```

## 7. Reuse policies in LiveViews

```elixir
defmodule MyAppWeb.PostLive do
  use MyAppWeb, :live_view
  alias Sieve.Repo, as: SieveRepo
  alias MyApp.Blog.PostPolicy

  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user

    case SieveRepo.list(MyApp.Repo, PostPolicy, current_user, %{}) do
      {:ok, posts} ->
        {:ok, assign(socket, posts: posts)}

      {:error, _} ->
        {:ok, assign(socket, posts: [])}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    current_user = socket.assigns.current_user

    case SieveRepo.get(MyApp.Repo, PostPolicy, current_user, id) do
      {:ok, post} ->
        case PostPolicy.for_delete(post, current_user) do
          :ok ->
            MyApp.Repo.delete(post)
            {:noreply, reload_posts(socket)}

          {:error, :forbidden} ->
            {:noreply, put_flash(socket, :error, "Not allowed")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Post not found")}
    end
  end
end
```

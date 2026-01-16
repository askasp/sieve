defmodule Example.TableController do
  @moduledoc """
  Example Phoenix controller using Sieve.

  Add this to your router.ex:

      scope "/api", MyAppWeb do
        pipe_through [:api, :auth]

        get  "/:table",     TableController, :index
        get  "/:table/:id", TableController, :show
        patch "/:table/:id", TableController, :update
      end
  """
  use Phoenix.Controller

  use Sieve.Controller,
    registry: MyApp.TableRegistry,
    repo: MyApp.Repo,
    actor_key: :current_user

  action_fallback MyAppWeb.FallbackController
end

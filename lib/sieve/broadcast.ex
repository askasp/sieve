defmodule Sieve.Broadcast do
  @moduledoc """
  Broadcasting for real-time updates when resources change.

  Sieve can broadcast changes to Phoenix.PubSub when records are created,
  updated, or deleted. This enables real-time UIs that automatically
  refresh when data changes.

  ## Configuration

  Add the `broadcast` option to your resource spec:

      resource "lab_visits", %{
        schema: MyApp.LabVisit,
        policy: MyApp.Policies.OwnedByUserId,
        broadcast: %{
          pubsub: MyApp.PubSub,
          topic: fn record -> "user:\#{record.auth_user_id}" end
        }
      }

  ## Broadcast Options

  - `pubsub` - The PubSub module to use (required)
  - `topic` - Function that takes a record and returns the topic string (required)
    The function receives the record and should return the topic to broadcast to.
    For deleted records, the before-state record is passed.

  ## Broadcast Payload

  The broadcast payload looks like:

      %{
        event: "created" | "updated" | "deleted",
        resource: "lab_visits",
        id: "uuid-here",
        data: %{...}  # The record data (nil for deletes)
      }

  ## Channel Integration

  In your channel, you can handle these broadcasts:

      def handle_info(%{event: event, resource: resource, id: id, data: data}, socket) do
        push(socket, "resource_change", %{
          event: event,
          resource: resource,
          id: id,
          data: data
        })
        {:noreply, socket}
      end
  """

  require Logger

  @doc """
  Broadcasts a resource change event.

  Called automatically by Sieve.Engine after create/update/delete operations
  when a broadcast configuration is present in the resource spec.

  The payload is kept minimal (no record data) - just enough for the client
  to know which query to invalidate.
  """
  @spec broadcast(atom(), String.t(), term(), map() | nil, map() | nil, map()) :: :ok
  def broadcast(event, resource_name, pk_value, before_record, after_record, broadcast_config) do
    pubsub = Map.fetch!(broadcast_config, :pubsub)
    topic_fn = Map.fetch!(broadcast_config, :topic)

    # Determine which record to use for topic (after for create/update, before for delete)
    record_for_topic = after_record || before_record

    # Get the topic
    topic = topic_fn.(record_for_topic)

    # Build minimal payload - just enough for cache invalidation
    payload = %{
      event: event,
      resource: resource_name,
      id: pk_value
    }

    # Broadcast via PubSub - this will be received by the channel process
    Phoenix.PubSub.broadcast(pubsub, topic, payload)

    Logger.debug("Sieve broadcast: #{event} #{resource_name}/#{pk_value} to #{topic}")

    :ok
  end

  @doc """
  Checks if a resource spec has broadcast configured.
  """
  @spec broadcast_configured?(map()) :: boolean()
  def broadcast_configured?(spec) do
    Map.has_key?(spec, :broadcast) and is_map(spec.broadcast)
  end
end

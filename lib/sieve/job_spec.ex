defmodule Sieve.JobSpec do
  @moduledoc """
  Specification for a background job to be enqueued after a CRUD operation.

  ## Fields

  - `worker` - The Oban worker module (required)
  - `args` - Function `(before, after) -> map()` to build job args, or a static map
  - `opts` - Oban job options (queue, priority, etc.)
  - `when` - Function `(before, after) -> boolean()` to conditionally run the job.
             If provided, the engine will fetch before/after records.
             If nil, job is always queued (and fetching before/after is skipped for performance).

  ## Examples

      # Always run, no conditions
      %Sieve.JobSpec{worker: MyApp.IndexWorker}

      # With static args
      %Sieve.JobSpec{worker: MyApp.AuditWorker, args: %{type: "post"}}

      # With dynamic args (note: "after" is reserved, use different name)
      %Sieve.JobSpec{worker: MyApp.NotifyWorker, args: fn _before, record -> %{post_id: record.id} end}

      # Conditional - only when title changed
      %Sieve.JobSpec{
        worker: MyApp.ReindexWorker,
        when: fn before, record -> before.title != record.title end
      }

      # Conditional via args (return nil to skip enqueueing)
      %Sieve.JobSpec{
        worker: MyApp.NotifyWorker,
        args: fn before, record ->
          if before.status != :published and record.status == :published do
            %{post_id: record.id}
          end
          # Returns nil if condition not met -> job not enqueued
        end
      }

      # Conditional - only when published
      %Sieve.JobSpec{
        worker: MyApp.NotifyFollowersWorker,
        when: fn _before, record -> record.published end,
        opts: [queue: :notifications, priority: 1]
      }

  ## Before/After Values by Operation

  - `:create` - before is `nil`, after is the created record
  - `:update` - before is record before update, after is record after update
  - `:delete` - before is record before deletion, after is `nil`
  """

  @enforce_keys [:worker]
  defstruct [:worker, :args, :when, opts: []]

  @type before_after :: struct() | nil
  @type args_fun :: (before_after(), before_after() -> map())
  @type when_fun :: (before_after(), before_after() -> boolean())

  @type t :: %__MODULE__{
          worker: module(),
          args: args_fun() | map() | nil,
          opts: keyword(),
          when: when_fun() | nil
        }

  @doc """
  Determines if any job specs require fetching before/after records.
  Used for optimization - if no `when` clauses, skip the extra query.
  """
  @spec needs_before_after?([t()]) :: boolean()
  def needs_before_after?(job_specs) when is_list(job_specs) do
    Enum.any?(job_specs, fn spec -> spec.when != nil or is_function(spec.args) end)
  end

  def needs_before_after?(_), do: false

  @doc """
  Builds the args map for a job spec given before/after records.
  """
  @spec build_args(t(), before_after(), before_after()) :: map()
  def build_args(%__MODULE__{args: nil}, _before, _after), do: %{}
  def build_args(%__MODULE__{args: args}, _before, _after) when is_map(args), do: args
  def build_args(%__MODULE__{args: args_fun}, before, after_rec) when is_function(args_fun, 2) do
    args_fun.(before, after_rec)
  end

  @doc """
  Checks if a job should run given before/after records.
  """
  @spec should_run?(t(), before_after(), before_after()) :: boolean()
  def should_run?(%__MODULE__{when: nil}, _before, _after), do: true
  def should_run?(%__MODULE__{when: when_fun}, before, after_rec) when is_function(when_fun, 2) do
    when_fun.(before, after_rec)
  end
end
